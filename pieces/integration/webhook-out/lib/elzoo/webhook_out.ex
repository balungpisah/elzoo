# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WebhookOut do
  @moduledoc """
  Signed outbound events to tenant endpoints over a consumer-owned Ecto Repo on PostgreSQL 16,
  under the `state/tenant-isolation` floor (ELZ-362).

  A tenant registers HTTPS endpoints for named events (`register/3`, egress-checked); the host
  enqueues an event once (`enqueue/3`), which writes one delivery per listening endpoint. The
  delivery rows are the queue: `claim_due/3` leases due rows and returns each try's
  `delivery/effect-intent` admission; the Adapter (`Elzoo.WebhookOut.Adapter`) makes one signed
  Standard Webhooks POST per intent attempt and stores its typed result; `record/3` applies that
  result once per attempt. A not-sent refusal is sent again on the same try; a possibly sent
  failure gets a new try (a new intent, the same `webhook-id`) only for a `dedup: true`
  endpoint, else the delivery goes to `delivery/dead-letter-store`.

  Writes check shape (`:invalid`), then the caller's open transaction (`:in_transaction`), both
  before any query, and run in `Elzoo.TenantIsolation.transact/3` whose first query refuses any
  isolation level but read committed. Errors are fixed atoms that never echo a URL, a payload or
  a secret. Queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.{DeadLetter, DeadLetterStore, RetryTimeout, TenantIsolation}
  alias Elzoo.WebhookOut.{Binding, Migration}

  @keys Enum.sort([
          :repo,
          :prefix,
          :policy,
          :resolver,
          :transport,
          :secrets,
          :clock,
          :retry,
          :max_tries,
          :send_timeout_ms,
          :try_deadline_ms,
          :dead_letters,
          :effect
        ])

  @enforce_keys @keys ++ [:seal_key]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}

  # A trusted clock reads 0..2^53-1 ms and new/1 bounds the retry policy's max_backoff_ms by the
  # same value; a delay is at most twice that, so every sum below fits a signed bigint.
  @max_clock 9_007_199_254_740_991
  @max_payload 65_536
  @max_depth 32
  @refusals [:isolation, :conflict, :unknown_delivery, :stale_try, :invalid]
  @states %{"pending" => :pending, "delivered" => :delivered, "dead_lettered" => :dead_lettered}
  @marks %{"none" => :none, "pending" => :pending, "filed" => :filed}
  @fallbacks [nil, :delivered, :unknown, :not_sent, :expired]

  @doc """
  A binding from exactly the options in the README. `{:ok, binding}` or `{:error, :invalid}`.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == @keys,
         o = Map.new(opts),
         true <- is_atom(o.repo) and o.repo not in [nil, true, false],
         true <- Migration.identifier?(o.prefix),
         true <- Enum.all?([o.policy, o.resolver, o.transport, o.secrets], &is_function(&1, 1)),
         true <- is_function(o.clock, 0),
         # Each not-sent refusal of a try is another attempt of one intent, which holds at most
         # 256 attempts.
         true <- RetryTimeout.valid_policy?(o.retry) and elem(o.retry, 1) <= 256,
         true <- elem(o.retry, 3) <= @max_clock,
         true <- int?(o.max_tries, 1, 16) and int?(o.send_timeout_ms, 1, 60_000),
         true <- int?(o.try_deadline_ms, 1_000, 86_400_000),
         true <- is_struct(o.dead_letters, DeadLetterStore),
         %{binding: module, provider_account: account} = effect when map_size(effect) == 2 <-
           o.effect,
         {:ok, descriptor} <- Binding.load(module),
         true <- descriptor.provider_account == account do
      {:ok, struct!(__MODULE__, Map.put(o, :seal_key, :crypto.strong_rand_bytes(32)))}
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  # ---------------------------------------------------------------- register

  @doc """
  Register `%{endpoint_id, url, secret_ref, events, dedup}` for `tenant` after the URL passes
  `Elzoo.EgressPolicy.resolve/3` under the tenant's policy. `{:ok, :applied}`, `{:ok, :duplicate}`
  for equal fields, `{:error, :conflict}` for others, or `{:error, {:egress, reason}}`.
  """
  def register(
        %__MODULE__{} = b,
        tenant,
        %{endpoint_id: id, url: url, secret_ref: secret, events: events, dedup: dedup} = r
      )
      when map_size(r) == 5 do
    with true <- text?(tenant) and text?(id) and url?(url) and secret_ref?(secret),
         true <- names?(events) and is_boolean(dedup) do
      events = Enum.sort(events)

      with :ok <- outside(b),
           {:ok, _} <- egress(b, tenant, url) do
        run(b, tenant, fn -> insert_endpoint(b, tenant, id, url, secret, events, dedup) end)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def register(_, _, _), do: {:error, :invalid}

  defp insert_endpoint(b, tenant, id, url, secret, events, dedup) do
    inserted =
      q!(
        b,
        "INSERT INTO #{t(b, :endpoints)} (tenant, endpoint_id, url, secret_ref, secret_scope, events, dedup) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT DO NOTHING RETURNING 1",
        [tenant, id, url, secret.ref, secret.scope, events, dedup]
      )

    if inserted == [[1]] do
      {:ok, :applied}
    else
      case q!(
             b,
             "SELECT url, secret_ref, secret_scope, events, dedup FROM #{t(b, :endpoints)} WHERE tenant = $1 AND endpoint_id = $2",
             [tenant, id]
           ) do
        [[^url, ref, scope, ^events, ^dedup]] when ref == secret.ref and scope == secret.scope ->
          {:ok, :duplicate}

        [_] ->
          {:error, :conflict}
      end
    end
  end

  @doc false
  # The tenant's current policy and the resolver Need: {:ok, target} or {:error, {:egress, r}}.
  def egress(b, tenant, url) do
    policy =
      try do
        b.policy.(tenant)
      catch
        _, _ -> :error
      end

    case policy do
      {:ok, p} ->
        case Elzoo.EgressPolicy.resolve(url, p, b.resolver) do
          {:ok, target} -> {:ok, target}
          {:error, reason} -> {:error, {:egress, reason}}
        end

      _ ->
        {:error, {:egress, :unavailable}}
    end
  rescue
    _ -> {:error, {:egress, :unavailable}}
  end

  # ---------------------------------------------------------------- enqueue

  @doc """
  Store `%{event_id, name, payload}` once and one delivery, at try 1 and due now, for each
  endpoint of `tenant` that lists `name`. `{:ok, %{deliveries: n}}`, `{:ok, :duplicate}` for equal
  canonical bytes, or `{:error, :conflict}`.
  """
  def enqueue(%__MODULE__{} = b, tenant, %{event_id: id, name: name, payload: payload} = r)
      when map_size(r) == 3 do
    with true <- text?(tenant) and event_id?(id) and name?(name),
         {:ok, bytes} <- json(payload) do
      digest = sha256(bytes)

      run(b, tenant, fn ->
        now = now!(b)

        inserted =
          q!(
            b,
            "INSERT INTO #{t(b, :events)} (tenant, event_id, name, payload, payload_sha256) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING RETURNING 1",
            [tenant, id, name, bytes, digest]
          )

        if inserted == [[1]] do
          endpoints =
            q!(
              b,
              ~s|SELECT endpoint_id FROM #{t(b, :endpoints)} WHERE tenant = $1 AND $2 = ANY (events) ORDER BY endpoint_id COLLATE "C"|,
              [tenant, name]
            )
            |> Enum.map(&hd/1)

          q!(
            b,
            "INSERT INTO #{t(b, :deliveries)} (tenant, delivery_id, event_id, endpoint_id, payload_sha256, state, try, due_at_ms, rearm, not_sent, attempts, dead_letter) SELECT $1, d, $2, e, $3, 'pending', 1, $4, false, 0, 0, 'none' FROM unnest($5::text[], $6::text[]) AS u(d, e)",
            [tenant, id, digest, now, Enum.map(endpoints, &delivery_id(id, &1)), endpoints]
          )

          {:ok, %{deliveries: length(endpoints)}}
        else
          case q!(
                 b,
                 "SELECT name, payload FROM #{t(b, :events)} WHERE tenant = $1 AND event_id = $2",
                 [tenant, id]
               ) do
            [[^name, ^bytes]] -> {:ok, :duplicate}
            [_] -> {:error, :conflict}
          end
        end
      end)
    else
      _ -> {:error, :invalid}
    end
  end

  def enqueue(_, _, _), do: {:error, :invalid}

  @doc "The delivery ID: lowercase hex SHA-256 of the canonical JSON of `{event_id, endpoint_id}`."
  def delivery_id(event_id, endpoint_id),
    do: sha256(canonical(%{"event_id" => event_id, "endpoint_id" => endpoint_id}))

  # ---------------------------------------------------------------- claim_due

  @doc """
  Lease up to `limit` (1..256) due pending deliveries of `tenant` for `lease_ms`
  (1,000..600,000), oldest due first. `{:ok, tries}`; see the README for each try's map.
  """
  def claim_due(%__MODULE__{} = b, tenant, %{limit: limit, lease_ms: lease} = r)
      when map_size(r) == 2 do
    if text?(tenant) and int?(limit, 1, 256) and int?(lease, 1_000, 600_000) do
      run(b, tenant, fn ->
        now = now!(b)

        rows =
          q!(
            b,
            """
            WITH due AS (
              SELECT delivery_id FROM #{t(b, :deliveries)}
              WHERE tenant = $1 AND state = 'pending' AND due_at_ms <= $2
                AND (claimed_until_ms IS NULL OR claimed_until_ms <= $2)
              ORDER BY due_at_ms, delivery_id COLLATE "C"
              LIMIT $3
              FOR UPDATE SKIP LOCKED
            )
            UPDATE #{t(b, :deliveries)} AS d
            SET claimed_until_ms = $2::bigint + $4::bigint,
                try_deadline_ms = COALESCE(d.try_deadline_ms, $2::bigint + $5::bigint)
            FROM due WHERE d.tenant = $1 AND d.delivery_id = due.delivery_id
            RETURNING d.due_at_ms, d.delivery_id, d.endpoint_id, d.event_id, d.try,
                      d.payload_sha256, d.try_deadline_ms, d.rearm
            """,
            [tenant, now, limit, lease, b.try_deadline_ms]
          )

        tries =
          rows
          |> Enum.sort_by(fn [due, id | _] -> {due, id} end)
          |> Enum.map(fn [_, id, endpoint, event, try, digest, deadline, rearm] ->
            %{
              delivery_id: id,
              endpoint_id: endpoint,
              event_id: event,
              try: try,
              admission: admission(b, tenant, id, endpoint, event, try, digest, deadline),
              rearm: rearm
            }
          end)

        {:ok, tries}
      end)
    else
      {:error, :invalid}
    end
  end

  def claim_due(_, _, _), do: {:error, :invalid}

  defp admission(b, tenant, id, endpoint, event, try, digest, deadline) do
    identity = identity(b, tenant, id, try)

    %{
      key: Elzoo.EffectIntent.Model.key(identity),
      identity: identity,
      arguments: arguments(tenant, id, endpoint, event, digest),
      deadline: deadline
    }
  end

  @doc false
  def identity(b, tenant, delivery_id, try),
    do: [
      tenant,
      b.effect.provider_account,
      "webhook-out",
      "post",
      delivery_id <> "/try/" <> Integer.to_string(try)
    ]

  @doc false
  # The canonical intent arguments: never the payload, only its digest.
  def arguments(tenant, id, endpoint, event, digest),
    do:
      canonical(%{
        "tenant" => tenant,
        "delivery_id" => id,
        "endpoint_id" => endpoint,
        "event_id" => event,
        "payload_sha256" => digest
      })

  # ---------------------------------------------------------------- record

  @doc """
  Apply the stored observation of `%{delivery_id, try, attempt, fallback}`, or `fallback` when
  none is stored. `{:ok, :applied | :duplicate | :no_result}`, `{:error, :dead_letter}` when the
  result was applied but the dead-letter put did not complete, or another fixed error.
  """
  def record(
        %__MODULE__{} = b,
        tenant,
        %{delivery_id: id, try: try, attempt: attempt, fallback: fallback} = r
      )
      when map_size(r) == 4 do
    if text?(tenant) and delivery_id?(id) and int?(try, 1, 16) and int?(attempt, 1, 256) and
         fallback in @fallbacks do
      random = :rand.uniform(4_294_967_296) - 1

      case run(b, tenant, fn -> apply_record(b, tenant, r, random) end) do
        {:ok, {status, nil}} -> {:ok, status}
        {:ok, {status, inputs}} -> if file(b, tenant, inputs), do: {:ok, status}, else: dead()
        error -> error
      end
    else
      {:error, :invalid}
    end
  end

  def record(_, _, _), do: {:error, :invalid}

  defp dead, do: {:error, :dead_letter}

  @row ~w(state try try_deadline_ms not_sent attempts event_id dead_letter dl_reason dl_at_ms
          last_outcome last_dispatch last_error_class)

  defp apply_record(b, tenant, r, random) do
    case q!(
           b,
           "SELECT #{Enum.map_join(@row, ", ", &("d." <> &1))}, e.dedup FROM #{t(b, :deliveries)} d JOIN #{t(b, :endpoints)} e ON e.tenant = d.tenant AND e.endpoint_id = d.endpoint_id WHERE d.tenant = $1 AND d.delivery_id = $2 FOR UPDATE OF d",
           [tenant, r.delivery_id]
         ) do
      [] ->
        {:error, :unknown_delivery}

      [values] ->
        row = @row |> Enum.map(&String.to_atom/1) |> Enum.zip(values) |> Map.new()
        row = Map.merge(row, %{dedup: List.last(values), id: r.delivery_id, now: now!(b)})

        cond do
          r.try != row.try -> {:error, :stale_try}
          row.state != "pending" -> {:ok, {:duplicate, pending_inputs(row)}}
          r.fallback == :expired -> expire(b, tenant, row)
          true -> observe(b, tenant, row, r, random)
        end
    end
  end

  # The record inputs of a dead-lettered row whose put has not completed, else nil.
  defp pending_inputs(%{dead_letter: "pending"} = row), do: inputs(row)
  defp pending_inputs(_), do: nil

  defp inputs(row) do
    %{
      delivery_id: row.id,
      event_id: row.event_id,
      attempts: row.attempts,
      reason: row.dl_reason,
      triple: if(row.last_outcome, do: {row.last_outcome, row.last_dispatch, row.last_error_class}),
      at_ms: row.dl_at_ms
    }
  end

  defp expire(b, tenant, row) do
    if is_integer(row.try_deadline_ms) and row.now >= row.try_deadline_ms do
      dispatched =
        q!(
          b,
          "SELECT 1 FROM #{t(b, :observations)} WHERE tenant = $1 AND delivery_id = $2 AND try = $3 LIMIT 1",
          [tenant, row.id, row.try]
        ) != [] or row.not_sent > 0

      reason = if dispatched, do: "deadline_expired", else: "deadline_before_dispatch"
      dead_letter(b, tenant, row, reason, nil, 0)
    else
      {:error, :invalid}
    end
  end

  defp observe(b, tenant, row, r, random) do
    case q!(
           b,
           "SELECT result, applied FROM #{t(b, :observations)} WHERE tenant = $1 AND delivery_id = $2 AND try = $3 AND attempt = $4",
           [tenant, row.id, r.try, r.attempt]
         ) do
      [[_, true]] ->
        {:ok, {:duplicate, nil}}

      [[stored, false]] ->
        q!(
          b,
          "UPDATE #{t(b, :observations)} SET applied = true WHERE tenant = $1 AND delivery_id = $2 AND try = $3 AND attempt = $4",
          [tenant, row.id, r.try, r.attempt]
        )

        settle(b, tenant, row, decode_result(stored), random)

      [] when r.fallback == nil ->
        {:ok, {:no_result, nil}}

      [] ->
        result = {:fallback, r.fallback}

        # An Adapter write of the same attempt that committed, or is in flight, before this
        # insert wins: ON CONFLICT DO NOTHING waits for its commit, and the next read applies the
        # stored observation instead. An Adapter write after this insert changes nothing.
        case q!(
               b,
               "INSERT INTO #{t(b, :observations)} (tenant, delivery_id, try, attempt, result, applied) VALUES ($1, $2, $3, $4, $5, true) ON CONFLICT DO NOTHING RETURNING 1",
               [tenant, row.id, r.try, r.attempt, encode_result(result)]
             ) do
          [[1]] -> settle(b, tenant, row, result, random)
          [] -> observe(b, tenant, row, %{r | fallback: nil}, random)
        end
    end
  end

  # One applied result of the current try.
  defp settle(b, tenant, row, result, random) do
    triple = triple(result)

    case class(result) do
      :delivered ->
        update!(b, tenant, row, "state = 'delivered', claimed_until_ms = NULL", [], triple)
        {:ok, {:applied, nil}}

      :not_sent ->
        n = row.not_sent + 1

        case RetryTimeout.decide(b.retry, n, :retryable) do
          {:ok, :retry} ->
            {:ok, ms} =
              RetryTimeout.delay(b.retry, n, :retryable, %{failure_delay_ms: nil, random: random})

            update!(
              b,
              tenant,
              row,
              "not_sent = $4, due_at_ms = $5::bigint + $6::bigint, claimed_until_ms = NULL, rearm = true",
              [n, row.now, ms],
              triple
            )

            {:ok, {:applied, nil}}

          {:ok, :exhausted} ->
            dead_letter(b, tenant, row, "retries_exhausted", triple, 1)
        end

      :possibly_sent ->
        cond do
          row.dedup and row.try < b.max_tries ->
            {:ok, ms} = RetryTimeout.backoff(b.retry, row.try)

            update!(
              b,
              tenant,
              row,
              "try = try + 1, due_at_ms = $4::bigint + $5::bigint, claimed_until_ms = NULL, try_deadline_ms = NULL, rearm = false, not_sent = 0",
              [row.now, ms],
              # The new try has no result yet.
              {nil, nil, nil}
            )

            {:ok, {:applied, nil}}

          row.dedup ->
            dead_letter(b, tenant, row, "retries_exhausted", triple, 1)

          true ->
            dead_letter(b, tenant, row, "dispatched_unresolved", triple, 1)
        end

      :permanent ->
        dead_letter(b, tenant, row, "permanent", triple, 1)
    end
  end

  # Every applied result counts one attempt and sets the current try's last-result triple.
  defp update!(b, tenant, row, set, params, {o, d, e}) do
    n = length(params)

    q!(
      b,
      "UPDATE #{t(b, :deliveries)} SET #{set}, attempts = attempts + 1, last_outcome = $#{n + 4}, last_dispatch = $#{n + 5}, last_error_class = $#{n + 6} WHERE tenant = $1 AND delivery_id = $2 AND try = $3",
      [tenant, row.id, row.try] ++ params ++ [o, d, e]
    )
  end

  # The transaction that dead-letters a delivery fixes the record's inputs in the row and marks it
  # pending; the put happens after the commit.
  defp dead_letter(b, tenant, row, reason, triple, count) do
    {o, d, e} = triple || {row.last_outcome, row.last_dispatch, row.last_error_class}

    q!(
      b,
      "UPDATE #{t(b, :deliveries)} SET state = 'dead_lettered', claimed_until_ms = NULL, dead_letter = 'pending', dl_reason = $4, dl_at_ms = $5, attempts = attempts + $6, last_outcome = $7, last_dispatch = $8, last_error_class = $9 WHERE tenant = $1 AND delivery_id = $2 AND try = $3",
      [tenant, row.id, row.try, reason, row.now, count, o, d, e]
    )

    inputs =
      inputs(%{
        row
        | attempts: row.attempts + count,
          dl_reason: reason,
          dl_at_ms: row.now,
          last_outcome: o,
          last_dispatch: d,
          last_error_class: e
      })

    {:ok, {:applied, inputs}}
  end

  # ---------------------------------------------------------------- dead letters

  @doc """
  File up to `limit` (1..256) dead letters of `tenant` whose put has not completed, oldest first.
  `{:ok, %{filed: n, pending: m}}`, `m` those whose put failed again.
  """
  def file_dead_letters(%__MODULE__{} = b, tenant, %{limit: limit} = r) when map_size(r) == 1 do
    if text?(tenant) and int?(limit, 1, 256) do
      read =
        run(b, tenant, fn ->
          rows =
            q!(
              b,
              ~s|SELECT delivery_id, event_id, attempts, dl_reason, dl_at_ms, last_outcome, last_dispatch, last_error_class FROM #{t(b, :deliveries)} WHERE tenant = $1 AND dead_letter = 'pending' ORDER BY dl_at_ms, delivery_id COLLATE "C" LIMIT $2|,
              [tenant, limit]
            )

          {:ok, rows}
        end)

      with {:ok, rows} <- read do
        filed =
          Enum.count(rows, fn [id, event, attempts, reason, at, o, d, e] ->
            file(b, tenant, %{
              delivery_id: id,
              event_id: event,
              attempts: attempts,
              reason: reason,
              triple: if(o, do: {o, d, e}),
              at_ms: at
            })
          end)

        {:ok, %{filed: filed, pending: length(rows) - filed}}
      end
    else
      {:error, :invalid}
    end
  end

  def file_dead_letters(_, _, _), do: {:error, :invalid}

  # The put, built from the row's fixed inputs only, then `filed`. True when both completed.
  defp file(b, tenant, inputs) do
    with {:ok, record} <- dead_letter_record(inputs),
         {:ok, s} when s in [:applied, :duplicate] <-
           DeadLetterStore.put(b.dead_letters, tenant, %{
             source: "webhook-out",
             record: record,
             work_ref: inputs.delivery_id,
             at_ms: inputs.at_ms
           }),
         {:ok, _} <-
           run(b, tenant, fn ->
             q!(
               b,
               "UPDATE #{t(b, :deliveries)} SET dead_letter = 'filed' WHERE tenant = $1 AND delivery_id = $2 AND dead_letter = 'pending'",
               [tenant, inputs.delivery_id]
             )

             {:ok, :filed}
           end) do
      true
    else
      _ -> false
    end
  end

  @doc false
  def dead_letter_record(%{delivery_id: id, event_id: event} = inputs) do
    request = %{
      "version" => 1,
      "message_id" => id,
      "correlation_id" => event,
      "schema_id" => "elzoo/webhook-out-delivery",
      "schema_version" => 1,
      "kind" => "event",
      "producer" => %{"unit_id" => "webhook-out", "port_id" => "post"},
      "payload" => nil
    }

    result =
      case inputs.triple do
        nil ->
          nil

        {o, d, e} ->
          %{
            "version" => 1,
            "message_id" => id,
            "correlation_id" => event,
            "outcome" => o,
            "dispatch" => d,
            "error_class" => e
          }
      end

    DeadLetter.from_result(request, result, inputs.attempts, inputs.reason)
  end

  # ---------------------------------------------------------------- status and verify

  @doc """
  `{:ok, %{state, try, due_at_ms, claimed_until_ms, dead_letter}}` of one delivery, or
  `{:error, :unknown_delivery}`.
  """
  def status(%__MODULE__{} = b, tenant, %{delivery_id: id} = r) when map_size(r) == 1 do
    if text?(tenant) and delivery_id?(id) do
      run(b, tenant, fn ->
        case q!(
               b,
               "SELECT state, try, due_at_ms, claimed_until_ms, dead_letter FROM #{t(b, :deliveries)} WHERE tenant = $1 AND delivery_id = $2",
               [tenant, id]
             ) do
          [] ->
            {:error, :unknown_delivery}

          [[state, try, due, claimed, mark]] ->
            {:ok,
             %{
               state: Map.fetch!(@states, state),
               try: try,
               due_at_ms: due,
               claimed_until_ms: claimed,
               dead_letter: Map.fetch!(@marks, mark)
             }}
        end
      end)
    else
      {:error, :invalid}
    end
  end

  def status(_, _, _), do: {:error, :invalid}

  @doc "Check the four tables with `Elzoo.TenantIsolation.verify/3`: `:ok` or the first error."
  def verify(%__MODULE__{repo: repo, prefix: prefix}) do
    Enum.find_value(Migration.tables(), :ok, fn table ->
      case TenantIsolation.verify(repo, {prefix, table},
             prefix: prefix,
             tenant_column: "tenant",
             space_column: nil
           ) do
        :ok -> nil
        error -> error
      end
    end)
  end

  def verify(_), do: {:error, :invalid}

  # ---------------------------------------------------------------- results

  # Typed results as stored in the observations table.
  @results %{
    :delivered => "delivered",
    {:not_sent, :egress} => "not_sent:egress",
    {:not_sent, :dns} => "not_sent:dns",
    {:not_sent, :secret} => "not_sent:secret",
    {:not_sent, :unavailable} => "not_sent:unavailable",
    {:failed, :retryable} => "failed:retryable",
    {:failed, :permanent} => "failed:permanent",
    {:unknown, :timed_out} => "unknown:timed_out",
    {:unknown, :transport} => "unknown:transport",
    {:fallback, :delivered} => "fallback:delivered",
    {:fallback, :unknown} => "fallback:unknown",
    {:fallback, :not_sent} => "fallback:not_sent"
  }
  @decoded Map.new(@results, fn {k, v} -> {v, k} end)

  @doc false
  def encode_result(result), do: Map.fetch!(@results, result)
  defp decode_result(text), do: Map.fetch!(@decoded, text)

  defp class(:delivered), do: :delivered
  defp class({:fallback, :delivered}), do: :delivered
  defp class({:not_sent, _}), do: :not_sent
  defp class({:fallback, :not_sent}), do: :not_sent
  defp class({:failed, :permanent}), do: :permanent
  defp class(_), do: :possibly_sent

  @doc false
  # The delivery triple {outcome, dispatch, error_class} of a typed result.
  def triple(result) do
    case result do
      r when r in [:delivered, {:fallback, :delivered}] -> {"completed", "dispatched", nil}
      {:not_sent, tag} -> Map.fetch!(Binding.failures(), tag)
      {:fallback, :not_sent} -> Map.fetch!(Binding.failures(), :unavailable)
      {:failed, class} -> Map.fetch!(Binding.failures(), class)
      {:unknown, tag} -> Map.fetch!(Binding.failures(), tag)
      {:fallback, :unknown} -> Map.fetch!(Binding.failures(), :transport)
    end
  end

  # ---------------------------------------------------------------- transaction

  defp outside(b) do
    if b.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  # The caller's transaction, then one transaction under the tenant floor whose first query
  # checks the isolation level. Any failure of the Repo, the database, the driver or the clock
  # Need is :unavailable; nothing raised reaches the caller, so no driver message does either.
  def run(%__MODULE__{repo: repo} = b, tenant, fun) do
    with :ok <- outside(b) do
      result =
        TenantIsolation.transact(repo, %{tenant: tenant}, fn ->
          case q!(b, "SELECT current_setting('transaction_isolation')", []) do
            [["read committed"]] -> fun.()
            _ -> {:error, :isolation}
          end
        end)

      case result do
        {:ok, _} = ok -> ok
        {:error, reason} when reason in @refusals -> result
        _ -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  def now!(b) do
    case b.clock.() do
      now when is_integer(now) and now >= 0 and now <= @max_clock -> now
      _ -> raise ArgumentError, "clock"
    end
  end

  @doc false
  def q!(b, sql, params), do: SQL.query!(b.repo, sql, params, log: false).rows

  @doc false
  def t(b, table) do
    name =
      Map.fetch!(
        %{
          endpoints: "elzoo_webhook_endpoints",
          events: "elzoo_webhook_events",
          deliveries: "elzoo_webhook_deliveries",
          observations: "elzoo_webhook_observations"
        },
        table
      )

    ~s("#{b.prefix}".#{name})
  end

  # ---------------------------------------------------------------- shapes

  # A JSON term (the delivery/durable-mailbox rule) and its canonical bytes, at most 65,536.
  defp json(term) do
    with true <- json?(term, 0),
         bytes when byte_size(bytes) <= @max_payload <- canonical(term) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp json?(v, depth) when is_map(v) and not is_struct(v),
    do:
      depth < @max_depth and
        Enum.all?(v, fn {k, x} -> is_binary(k) and String.valid?(k) and json?(x, depth + 1) end)

  defp json?(v, depth) when is_list(v), do: depth < @max_depth and elements?(v, depth + 1)
  defp json?(v, _) when is_binary(v), do: String.valid?(v)
  defp json?(v, _) when is_integer(v) or is_float(v) or v in [nil, true, false], do: true
  defp json?(_, _), do: false

  defp elements?([], _), do: true
  defp elements?([h | rest], depth), do: json?(h, depth) and elements?(rest, depth)
  defp elements?(_, _), do: false

  @doc false
  # Compact Jason 1.4.5 with the keys of every object sorted by their bytes.
  def canonical(term), do: Jason.encode!(ordered(term))

  defp ordered(map) when is_map(map),
    do:
      map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, ordered(v)} end) |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  @doc false
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp int?(n, lo, hi), do: is_integer(n) and n >= lo and n <= hi

  defp url?(url),
    do:
      is_binary(url) and byte_size(url) in 1..2048 and String.valid?(url) and
        not String.contains?(url, <<0>>)

  defp secret_ref?(%{ref: ref, scope: scope} = s) when map_size(s) == 2 and not is_struct(s),
    do:
      is_binary(ref) and byte_size(ref) in 1..128 and is_binary(scope) and
        byte_size(scope) in 1..128

  defp secret_ref?(_), do: false

  defp names?(events) do
    is_list(events) and length(events) in 1..64 and Enum.all?(events, &name?/1) and
      length(Enum.uniq(events)) == length(events)
  end

  defp name?(n), do: is_binary(n) and byte_size(n) in 1..128 and n =~ ~r/\A[a-z0-9._-]+\z/

  # 1..128 bytes of visible ASCII: it is sent and signed as the webhook-id header.
  defp event_id?(id), do: is_binary(id) and byte_size(id) in 1..128 and visible?(id)

  defp visible?(<<>>), do: true
  defp visible?(<<c, rest::binary>>) when c in 0x21..0x7E, do: visible?(rest)
  defp visible?(_), do: false

  defp delivery_id?(id), do: is_binary(id) and byte_size(id) == 64 and id =~ ~r/\A[0-9a-f]+\z/

  @doc false
  # The domain/principal text rule: 1..128 bytes of valid UTF-8 with no C0 or C1 character.
  def text?(t) when is_binary(t) and byte_size(t) in 1..128, do: String.valid?(t) and printable?(t)
  def text?(_), do: false

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  defimpl Inspect do
    def inspect(_, _), do: "#Elzoo.WebhookOut<redacted>"
  end
end
