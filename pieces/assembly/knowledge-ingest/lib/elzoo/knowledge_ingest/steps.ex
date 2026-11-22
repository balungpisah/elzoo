# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.KnowledgeIngest.Steps do
  @moduledoc """
  The runner of `Elzoo.KnowledgeIngest`: one `Elzoo.Jobs.Worker` job per step (prepare, the
  embed job of each batch, index). Each step's work runs in a process linked to the job's process
  that the runner kills at the step's deadline, so a transaction the work holds rolls back. A job
  acts only in its own state: every write takes the ingest row `FOR UPDATE` and checks the state
  first, and writes nothing when the ingest has moved on.
  """
  alias Elzoo.{AiEmbedding, Artifact, DocumentParse, EffectIntent, SearchData, TextChunking}
  alias Elzoo.AiEmbedding.{Request, Sink}
  alias Elzoo.KnowledgeIngest, as: KI

  @job_attempts 3
  @retryable [:throttled, :overloaded, :credentials_unavailable]
  @artifact_retry [:store_unavailable, :object_store_unknown]

  @doc false
  def job_attempts, do: @job_attempts

  @doc false
  def runner(c) do
    %{perform: fn job -> perform(c, job) end, backoff: fn job -> 5 * max(job.attempt, 1) end}
  end

  defp perform(c, %Oban.Job{args: %{"job_key" => key}} = job) do
    case parse(key) do
      {:ok, j} ->
        j = Map.merge(j, %{attempt: job.attempt, last: job.attempt >= job.max_attempts})

        case bounded(c, j.step, fn -> step(c, j) end) do
          {:ok, :ok} -> :ok
          {:ok, {:snooze, d}} -> {:snooze, d}
          {:ok, {:retry, reason, last}} -> job_error(c, j, reason, last)
          {:ok, _} -> job_error(c, j, :unexpected, {:step_failed, j.step})
          {:error, reason} -> job_error(c, j, reason, {:step_failed, j.step})
        end

      :error ->
        {:cancel, :invalid_job}
    end
  end

  defp perform(_, _), do: {:cancel, :invalid_job}

  # tenant/ingest_id/step[/batch]/n; the tenant follows the artifact segment rule (no "/").
  defp parse(key) do
    case String.split(key, "/") do
      [tenant, id, "prepare", _] -> job(tenant, id, :prepare, 0)
      [tenant, id, "embed", batch, _] -> job(tenant, id, :embed, batch)
      [tenant, id, "index", _] -> job(tenant, id, :index, 0)
      _ -> :error
    end
  end

  defp job(tenant, id, step, batch) do
    batch = if is_binary(batch), do: Integer.parse(batch), else: {batch, ""}

    with true <- KI.segment?(tenant) and id =~ ~r/\A[0-9a-f]{64}\z/,
         {b, ""} when b >= 0 <- batch do
      {:ok, %{tenant: tenant, id: id, step: step, batch: b}}
    else
      _ -> :error
    end
  end

  # On a job error Oban retries; on the job's last attempt the runner first fails the ingest
  # with `last` under the own-state rule.
  defp job_error(c, j, reason, last) do
    if j.last do
      try do
        KI.hook(c, :last_failure, info(j))
        tx(c, j, &own?(&1, j), fn row -> failed!(c, row, last, j.step) end)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

      {:cancel, reason}
    else
      {:error, reason}
    end
  end

  ## The deadline

  # The work runs linked to this process (a node death takes it down) and is killed at the
  # step's deadline; the runner then waits for the work's Task.Supervisor to end, so a send
  # task never outlives its step.
  defp bounded(c, step, fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        Process.put(__MODULE__, {parent, ref})

        result =
          try do
            {:ok, fun.()}
          rescue
            _ -> {:error, :raised}
          catch
            :exit, _ -> {:error, :exit}
            _, _ -> {:error, :thrown}
          end

        send(parent, {ref, result})
      end)

    mref = Process.monitor(pid)
    await(ref, pid, mref, [], System.monotonic_time(:millisecond) + KI.deadline(c, step))
  end

  defp await(ref, pid, mref, sups, at) do
    receive do
      {^ref, :supervisor, sup} ->
        await(ref, pid, mref, [Process.monitor(sup) | sups], at)

      {^ref, result} ->
        down(mref)
        Enum.each(sups, &down/1)
        result

      {:DOWN, ^mref, :process, _, _} ->
        Enum.each(sups, &down/1)
        {:error, :exit}
    after
      max(at - System.monotonic_time(:millisecond), 0) ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        down(mref)
        Enum.each(sups, &down/1)
        {:error, :deadline}
    end
  end

  defp down(mref) do
    receive do
      {:DOWN, ^mref, :process, _, _} -> :ok
    end
  end

  ## Shared transactions

  defp info(j), do: Map.take(j, [:tenant, :id, :step, :batch, :attempt])

  defp own?(%{state: s}, %{step: :prepare}), do: s in ["requested", "preparing"]

  defp own?(%{state: s, batches_done: d}, %{step: :embed, batch: b}),
    do: s == "embedding" and d == b

  defp own?(%{state: s}, %{step: :index}), do: s == "indexing"

  # One write transaction that takes the ingest row FOR UPDATE and runs `fun` only when `own`
  # holds. `fun` returns `{:ok, value}`, `{:ok, {:done, result}}` or `{:error, reason}`
  # (rolled back). The reply is `{:ok, value}` or `{:done, result}`.
  defp tx(c, j, own, fun) do
    result =
      KI.scoped(c, j.tenant, true, fn ->
        case KI.lock(c, j.tenant, j.id) do
          nil -> {:ok, {:done, :ok}}
          row -> if own.(row), do: fun.(row), else: {:ok, {:done, :ok}}
        end
      end)

    case result do
      {:ok, {:done, r}} -> {:done, r}
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:done, {:retry, :unavailable, {:step_failed, j.step}}}
    end
  end

  defp failed!(c, row, reason, step) do
    KI.q(
      c,
      """
      UPDATE #{KI.table(c, :ingests)} SET state = 'failed', reason = $3, failed_step = $4
      WHERE tenant = $1 AND ingest_id = $2
      """,
      [row.tenant, row.ingest_id, KI.encode(reason), Atom.to_string(step)]
    )

    {:ok, {:done, :ok}}
  end

  # A step failure that the step decides itself, written under the own-state rule.
  defp fail(c, j, reason) do
    {:done, r} = tx(c, j, &own?(&1, j), fn row -> failed!(c, row, reason, j.step) end)
    r
  end

  defp mismatch?(c, row), do: row.index_identity != KI.index_identity(c)

  defp override(c, point, info, fun) do
    case KI.hook(c, point, info) do
      {:override, value} -> value
      _ -> fun.()
    end
  end

  ## Steps

  defp step(c, %{step: :prepare} = j) do
    KI.hook(c, :start, info(j))

    begin =
      tx(c, j, &own?(&1, j), fn row ->
        cond do
          mismatch?(c, row) ->
            failed!(c, row, :index_mismatch, :prepare)

          row.state == "requested" ->
            KI.q(
              c,
              "UPDATE #{KI.table(c, :ingests)} SET state = 'preparing' WHERE tenant = $1 AND ingest_id = $2",
              [row.tenant, row.ingest_id]
            )

            {:ok, row}

          true ->
            {:ok, row}
        end
      end)

    with {:ok, row} <- begin,
         {:ok, bytes} <- artifact(c, j, row),
         {:ok, parsed} <- parse(c, j, row, bytes),
         {:ok, chunks} <- chunk(c, j, row, parsed),
         {:ok, batches} <- batches(c, j, chunks) do
      KI.hook(c, :prepare_commit, info(j))

      committed =
        tx(c, j, &(&1.state == "preparing"), fn row ->
          stage!(c, row, chunks, batches, parsed)

          KI.schedule(c, row, :embed, 0)
          |> then(fn r -> if r == :ok, do: {:ok, :ok}, else: r end)
        end)

      with {:ok, :ok} <- committed do
        KI.hook(c, :prepare_committed, info(j))
        :ok
      end
    end
    |> result()
  end

  defp step(c, %{step: :embed} = j) do
    KI.hook(c, :start, info(j))

    begin =
      tx(c, j, &own?(&1, j), fn row ->
        if mismatch?(c, row), do: failed!(c, row, :index_mismatch, :embed), else: next(c, j, row)
      end)

    case begin do
      {:ok, {:classify, n, contents}} ->
        classify(c, j, n, contents)

      {:ok, {:dispatch, n, contents}} ->
        KI.hook(c, :pending, Map.put(info(j), :number, n))
        dispatch(c, j, n, contents)

      other ->
        result(other)
    end
  end

  defp step(c, %{step: :index} = j) do
    KI.hook(c, :start, info(j))

    begin =
      tx(c, j, &own?(&1, j), fn row ->
        if mismatch?(c, row),
          do: failed!(c, row, :index_mismatch, :index),
          else: {:ok, {row, staged(c, row)}}
      end)

    with {:ok, {row, chunks}} <- begin do
      source = {row.source_ref, row.version, row.text_sha256}
      hook = Map.put(info(j), :version, row.version)

      put =
        override(c, :put_source, Map.put(hook, :chunks, chunks), fn ->
          SearchData.put_source(c.search, row.tenant, source, chunks, if_newer: true)
        end)

      case put do
        {:committed, _} ->
          KI.hook(c, :index_committed, hook)
          finish(c, j, "indexed")

        {:refused, :stale_version} ->
          finish(c, j, "superseded")

        {:refused, reason} ->
          fail(c, j, {:index, reason})

        _ ->
          {:retry, :index_indeterminate, {:step_failed, :index}}
      end
    end
    |> result()
  end

  defp result({:done, r}), do: r
  defp result({:ok, r}), do: r
  defp result(r), do: r

  ## Prepare

  defp artifact(c, j, row) do
    caller = %{tenant: row.tenant, principal: row.actor, scopes: c.artifact_scopes}

    got =
      override(c, :artifact, info(j), fn ->
        Artifact.get(c.artifact, caller, row.artifact_id, row.artifact_version)
      end)

    case got do
      {:ok, %{bytes: bytes}} ->
        {:ok, bytes}

      {:error, error} ->
        a = if is_tuple(error), do: elem(error, 0), else: error

        if a in @artifact_retry,
          do: {:done, {:retry, :artifact_unavailable, {:artifact, a}}},
          else: {:done, fail(c, j, {:artifact, a})}
    end
  end

  defp parse(c, j, row, bytes) do
    case DocumentParse.parse(bytes, row.media_type) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:done, fail(c, j, {:parse, reason})}
    end
  end

  defp chunk(c, j, row, parsed) do
    opts = [
      format: parsed.format,
      chunk_size: row.chunk_size,
      chunk_overlap: row.chunk_overlap,
      max_chunks: row.max_chunks
    ]

    case TextChunking.chunk(parsed.text, parsed.text_sha256, row.source_ref, opts) do
      {:ok, %{chunks: chunks}} -> {:ok, chunks}
      {:error, reason} -> {:done, fail(c, j, {:chunk, reason})}
    end
  end

  # Each chunk must fit one input and its own one-input request; under text_search no chunk
  # may hold a NUL. Then greedy batches in chunk order within max_inputs and max_request_bytes.
  # The canonical request of k inputs is base + the inputs' JSON strings + (k - 1) commas,
  # where base is the canonical request with `"inputs":[]`.
  defp batches(c, j, chunks) do
    l = c.limits
    base = byte_size(Request.canonical(KI.request_json(c.request, [])))
    sized = Enum.map(chunks, &{&1, byte_size(Jason.encode!(&1.content))})

    cond do
      Enum.any?(sized, fn {ch, enc} ->
        byte_size(ch.content) > l.max_input_bytes or base + enc > l.max_request_bytes
      end) ->
        {:done, fail(c, j, :chunk_too_large)}

      Map.has_key?(c.search.declaration, :text_search) and
          Enum.any?(chunks, &String.contains?(&1.content, <<0>>)) ->
        {:done, fail(c, j, {:index, :invalid_chunk})}

      true ->
        {:ok,
         sized
         |> Enum.reduce([], fn {ch, enc}, acc ->
           case acc do
             [%{count: k, bytes: b} = cur | rest]
             when k < l.max_inputs and b + enc + 1 <= l.max_request_bytes ->
               [%{cur | count: k + 1, bytes: b + enc + 1} | rest]

             _ ->
               [%{first: ch.index, count: 1, bytes: base + enc} | acc]
           end
         end)
         |> Enum.reverse()}
    end
  end

  defp stage!(c, row, chunks, batches, parsed) do
    KI.q(
      c,
      """
      INSERT INTO #{KI.table(c, :chunks)}
        (tenant, ingest_id, chunk_index, start_byte, end_byte, content, content_digest, embedding)
      SELECT $1, $2, i, s, e, t, d, NULL
      FROM unnest($3::integer[], $4::bigint[], $5::bigint[], $6::bytea[], $7::bytea[]) AS u(i, s, e, t, d)
      """,
      [
        row.tenant,
        row.ingest_id,
        Enum.map(chunks, & &1.index),
        Enum.map(chunks, & &1.start_byte),
        Enum.map(chunks, & &1.end_byte),
        Enum.map(chunks, & &1.content),
        Enum.map(chunks, & &1.content_digest)
      ]
    )

    KI.q(
      c,
      """
      INSERT INTO #{KI.table(c, :batches)}
        (tenant, ingest_id, batch, first_chunk, chunk_count, completed, budget_base)
      SELECT $1, $2, b, f, n, false, 0
      FROM unnest($3::integer[], $4::integer[], $5::integer[]) AS u(b, f, n)
      """,
      [
        row.tenant,
        row.ingest_id,
        Enum.to_list(0..(length(batches) - 1)),
        Enum.map(batches, & &1.first),
        Enum.map(batches, & &1.count)
      ]
    )

    KI.q(
      c,
      """
      UPDATE #{KI.table(c, :ingests)} SET state = 'embedding', text_sha256 = $3, parser = $4,
        chunk_count = $5, batch_count = $6, batches_done = 0
      WHERE tenant = $1 AND ingest_id = $2
      """,
      [
        row.tenant,
        row.ingest_id,
        parsed.text_sha256,
        KI.encode(parsed.parser),
        length(chunks),
        length(batches)
      ]
    )
  end

  ## Embed

  # In the first transaction: the batch's latest attempt. A :pending one was recorded by
  # another run and is classified by status; otherwise the next attempt is recorded :pending
  # and committed before its admission.
  defp next(c, j, row) do
    batch = batch!(c, row, j.batch)
    contents = contents(c, row, batch)

    case latest(c, row, j.batch) do
      {n, :pending} ->
        {:ok, {:classify, n, contents}}

      latest ->
        n = if latest, do: elem(latest, 0) + 1, else: 1

        if n - batch.budget_base > c.max_attempts do
          failed!(c, row, :embedding_exhausted, :embed)
        else
          KI.q(
            c,
            """
            INSERT INTO #{KI.table(c, :attempts)} (tenant, ingest_id, batch, number, outcome, usage)
            VALUES ($1, $2, $3, $4, $5, NULL)
            """,
            [row.tenant, row.ingest_id, j.batch, n, KI.encode(:pending)]
          )

          {:ok, {:dispatch, n, contents}}
        end
    end
  end

  defp batch!(c, row, b) do
    %{rows: [[first, count, base]]} =
      KI.q(
        c,
        """
        SELECT first_chunk, chunk_count, budget_base FROM #{KI.table(c, :batches)}
        WHERE tenant = $1 AND ingest_id = $2 AND batch = $3 FOR UPDATE
        """,
        [row.tenant, row.ingest_id, b]
      )

    %{first: first, count: count, budget_base: base}
  end

  defp contents(c, row, batch) do
    KI.q(
      c,
      """
      SELECT content FROM #{KI.table(c, :chunks)}
      WHERE tenant = $1 AND ingest_id = $2 AND chunk_index >= $3 AND chunk_index < $4
      ORDER BY chunk_index
      """,
      [row.tenant, row.ingest_id, batch.first, batch.first + batch.count]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp latest(c, row, b) do
    case KI.q(
           c,
           """
           SELECT number, outcome FROM #{KI.table(c, :attempts)}
           WHERE tenant = $1 AND ingest_id = $2 AND batch = $3 ORDER BY number DESC LIMIT 1
           """,
           [row.tenant, row.ingest_id, b]
         ).rows do
      [[n, outcome]] -> {n, KI.decode(outcome)}
      [] -> nil
    end
  end

  defp declaration(c, j, n, contents) do
    wait = c.limits.receive_timeout_ms + 10_000
    ref = KI.attempt_ref(j.id, j.batch, n)
    KI.declaration(c.request, ref, contents, c.intent.clock.() + wait)
  end

  defp configure(c, tenant),
    do: AiEmbedding.configure(c.embedding ++ [tenant: tenant, sink: Sink.to_pid(self())])

  defp dispatch(c, j, n, contents) do
    outcome =
      supervised(fn sup ->
        with {:ok, cfg} <- configure(c, j.tenant) |> or_retry(:configure),
             {:ok, a} <- admit(cfg, declaration(c, j, n, contents)),
             task_sup = override(c, :task_supervisor, info(j), fn -> sup end),
             {:ok, owner} <- start_owner(c, cfg, a, task_sup, true) do
          reply = EffectIntent.advance(owner, :dispatch)

          outcome =
            case reply do
              {:ok, :dispatched} -> delivery(c, a.key, sup, owner)
              _ -> recovered(c, EffectIntent.status(owner).phase)
            end

          stop(owner)
          {:outcome, outcome}
        end
      end)

    case outcome do
      {:outcome, o} -> record(c, j, n, o)
      other -> other
    end
  end

  defp classify(c, j, n, contents) do
    outcome =
      supervised(fn sup ->
        with {:ok, cfg} <- configure(c, j.tenant) |> or_retry(:recovery),
             {:ok, a} <- admit(cfg, declaration(c, j, n, contents)),
             {:ok, owner} <- start_owner(c, cfg, a, sup, false) do
          phase = EffectIntent.status(owner).phase
          stop(owner)
          {:outcome, recovered(c, phase)}
        end
      end)

    case outcome do
      {:outcome, o} -> record(c, j, n, o)
      other -> other
    end
  end

  defp or_retry({:ok, _} = ok, _), do: ok
  defp or_retry(_, reason), do: {:retry, reason, {:step_failed, :embed}}

  # A local refusal is the attempt's outcome; a malformed declaration is a job error.
  defp admit(cfg, declaration) do
    case AiEmbedding.admission(cfg, declaration) do
      {:ok, a} -> {:ok, a}
      {:error, {:refused, r}} -> {:outcome, {:refused, r, %{retry_after: nil}}}
      _ -> {:retry, :admission, {:step_failed, :embed}}
    end
  end

  # The step's own Task.Supervisor, linked to the work process and stopped before the step
  # returns; the runner learns its pid so that a deadline kill also waits for it.
  defp supervised(fun) do
    {:ok, sup} = Task.Supervisor.start_link()
    {parent, ref} = Process.get(__MODULE__)
    send(parent, {ref, :supervisor, sup})

    try do
      fun.(sup)
    after
      Supervisor.stop(sup)
    end
  end

  # A recovery start (no host) stays read-only and admits nothing on an empty snapshot.
  defp start_owner(c, cfg, a, sup, host?) do
    opts =
      [
        binding: cfg.binding,
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        clock: c.intent.clock,
        store: c.intent.store,
        task_supervisor: sup,
        adapter_context: cfg
      ] ++
        if(host?, do: [host: c.intent.host], else: []) ++
        if(volatile?(c), do: [allow_volatile: true], else: [])

    {parent, _} = Process.get(__MODULE__)
    previous = Process.flag(:trap_exit, true)
    started = EffectIntent.start_link(opts)
    Process.flag(:trap_exit, previous)

    receive do
      {:EXIT, ^parent, reason} -> exit(reason)
    after
      0 -> :ok
    end

    case started do
      {:ok, owner} -> {:ok, owner}
      _ -> {:retry, :owner_start, {:step_failed, :embed}}
    end
  end

  defp stop(owner) do
    GenServer.stop(owner)
  catch
    :exit, _ -> :ok
  end

  defp volatile?(c), do: Map.get(c.intent, :allow_volatile) == true

  # After a delivery the send task is let finish within the wait, so the owner settles its
  # result before it is stopped.
  defp delivery(c, key, sup, owner) do
    at = System.monotonic_time(:millisecond) + KI.wait_ms(c)

    receive do
      {AiEmbedding, ^key, {:outcome, _, outcome}} ->
        settle(sup, owner, at)
        outcome

      {AiEmbedding, ^key, {:sink_failed, _}} ->
        :unknown
    after
      KI.wait_ms(c) -> :unknown
    end
  end

  defp settle(sup, owner, at) do
    for task <- Task.Supervisor.children(sup) do
      mref = Process.monitor(task)

      receive do
        {:DOWN, ^mref, :process, _, _} -> :ok
      after
        max(at - System.monotonic_time(:millisecond), 0) -> Process.demonitor(mref, [:flush])
      end
    end

    EffectIntent.status(owner)
  end

  # The status of an attempt whose outcome was not delivered. A volatile Store's absence is no
  # evidence that nothing was sent.
  defp recovered(c, phase) do
    case phase do
      {:Confirmed, _} -> :completed_lost
      :absent -> if volatile?(c), do: :unknown, else: :not_dispatched
      {:Intended, _, _} -> :not_dispatched
      _ -> :unknown
    end
  end

  # The first recorded outcome of an attempt wins, under the batch's row lock and only while
  # it is :pending; the transition applies only in the job's own state.
  defp record(c, j, n, outcome) do
    outcome =
      override(c, :outcome, Map.merge(info(j), %{number: n, outcome: outcome}), fn -> outcome end)

    {stored, usage} =
      case outcome do
        {:completed, body} -> {:completed, body.usage}
        {:refused, r, _} -> {{:refused, r}, nil}
        {:unknown, _} -> {:unknown, nil}
        other -> {other, nil}
      end

    result =
      KI.scoped(c, j.tenant, true, fn ->
        row = KI.lock(c, j.tenant, j.id)
        batch = batch!(c, row, j.batch)

        %{rows: [[current]]} =
          KI.q(
            c,
            """
            SELECT outcome FROM #{KI.table(c, :attempts)}
            WHERE tenant = $1 AND ingest_id = $2 AND batch = $3 AND number = $4
            """,
            [j.tenant, j.id, j.batch, n]
          )

        if KI.decode(current) != :pending do
          {:ok, :ok}
        else
          KI.q(
            c,
            """
            UPDATE #{KI.table(c, :attempts)} SET outcome = $5, usage = $6
            WHERE tenant = $1 AND ingest_id = $2 AND batch = $3 AND number = $4
            """,
            [j.tenant, j.id, j.batch, n, KI.encode(stored), KI.encode(usage)]
          )

          if own?(row, j), do: apply_outcome(c, j, row, batch, n, outcome), else: {:ok, :ok}
        end
      end)

    case result do
      {:ok, {:done, r}} -> r
      {:ok, r} -> r
      _ -> {:retry, :unavailable, {:step_failed, :embed}}
    end
  end

  defp apply_outcome(c, j, row, batch, _n, {:completed, body}) do
    {indices, embeddings} =
      body.embeddings
      |> Enum.map(fn e ->
        {batch.first + e.index,
         KI.encode(%{
           index: e.index,
           vector: e.vector,
           descriptor: body.descriptor,
           provenance: body.provenance
         })}
      end)
      |> Enum.unzip()

    KI.q(
      c,
      """
      UPDATE #{KI.table(c, :chunks)} AS c SET embedding = u.e
      FROM unnest($3::integer[], $4::bytea[]) AS u(i, e)
      WHERE c.tenant = $1 AND c.ingest_id = $2 AND c.chunk_index = u.i
      """,
      [row.tenant, row.ingest_id, indices, embeddings]
    )

    KI.q(
      c,
      """
      UPDATE #{KI.table(c, :batches)} SET completed = true
      WHERE tenant = $1 AND ingest_id = $2 AND batch = $3
      """,
      [row.tenant, row.ingest_id, j.batch]
    )

    done = j.batch + 1
    state = if done < row.batch_count, do: "embedding", else: "indexing"

    KI.q(
      c,
      """
      UPDATE #{KI.table(c, :ingests)} SET batches_done = $3, state = $4
      WHERE tenant = $1 AND ingest_id = $2
      """,
      [row.tenant, row.ingest_id, done, state]
    )

    step = if state == "embedding", do: :embed, else: :index

    case KI.schedule(c, row, step, done) do
      :ok -> {:ok, :ok}
      error -> error
    end
  end

  defp apply_outcome(c, _j, row, batch, n, outcome) do
    case kind(outcome) do
      {:retry, retry_after} ->
        k = n - batch.budget_base

        if k < c.max_attempts,
          do: {:ok, {:snooze, delay(retry_after, k)}},
          else: failed!(c, row, :embedding_exhausted, :embed)

      :unknown ->
        failed!(c, row, :embedding_unknown, :embed)

      {:refused, r} ->
        failed!(c, row, {:embedding_refused, r}, :embed)
    end
  end

  defp kind({:refused, r, meta}) when r in @retryable, do: {:retry, meta[:retry_after]}
  defp kind({:refused, r, _}), do: {:refused, r}
  defp kind(outcome) when outcome in [:not_dispatched, :completed_lost], do: {:retry, nil}
  defp kind(_), do: :unknown

  # The provider's retry_after clamped to 1..3,600 s, otherwise 5 × 2^(k−1) s after the k-th
  # attempt of the budget.
  defp delay(s, _) when is_integer(s), do: s |> max(1) |> min(3_600)
  defp delay(_, k), do: 5 * Integer.pow(2, k - 1)

  ## Index

  defp staged(c, row) do
    KI.q(
      c,
      """
      SELECT chunk_index, start_byte, end_byte, content, content_digest, embedding
      FROM #{KI.table(c, :chunks)} WHERE tenant = $1 AND ingest_id = $2 ORDER BY chunk_index
      """,
      [row.tenant, row.ingest_id]
    ).rows
    |> Enum.map(fn [i, s, e, content, digest, embedding] ->
      %{
        index: i,
        start_byte: s,
        end_byte: e,
        content: content,
        content_digest: digest,
        embedding: KI.decode(embedding)
      }
    end)
  end

  # The state write and the staged-chunk delete share one transaction.
  defp finish(c, j, state) do
    tx(c, j, &own?(&1, j), fn row ->
      KI.q(
        c,
        "UPDATE #{KI.table(c, :ingests)} SET state = $3 WHERE tenant = $1 AND ingest_id = $2",
        [row.tenant, row.ingest_id, state]
      )

      KI.delete_chunks(c, row.tenant, row.ingest_id)
      {:ok, :ok}
    end)
    |> result()
  end
end
