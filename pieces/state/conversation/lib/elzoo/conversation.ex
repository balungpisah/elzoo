# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Conversation do
  @moduledoc """
  One conversation on its own `state/event-log` stream,
  `conversation/<target_tenant>/<conversation_id>`.

  `start_link/1` starts the owner of one conversation under the caller's
  supervisor. The owner reads and validates the whole stream once, keeps a
  model of it in memory and appends immutable, self-contained records through
  the Store's head compare-and-set: `append_input/3`, `associate_run/3` and
  `append_answer/3`. `check/3` decides intents against the stream without
  appending. `page/5` and `tail/4` read without an owner, and `import_v1/3`
  migrates a version 1 field snapshot offline. See the README for the exact
  DTOs, results, bounds and Needs.
  """
  use GenServer

  alias Elzoo.Conversation.{History, Record, V1}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}

  @call_timeout 30_000
  @max_conflicts 8
  @read_page 1_000
  @max_count 1_000
  @max_resources 64
  @max_sequence 9_223_372_036_854_775_807

  @doc """
  Start the owner of one conversation. Options, exactly: `store` (a ready
  Store term `{module, %{fold: fold, limits: limits, ...}}`), `target_tenant`
  and `conversation_id` (stream-name segments). Returns `{:ok, pid}` or
  `{:error, :invalid_options | :unsupported_store | :damaged | :unavailable}`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Append one input message: `%{message_id, role, actor, text}`."
  def append_input(owner, dto, timeout \\ @call_timeout), do: write(owner, :input, dto, timeout)

  @doc "Associate one input with a Run: `%{input_message_id, run_id}`."
  def associate_run(owner, dto, timeout \\ @call_timeout),
    do: write(owner, :association, dto, timeout)

  @doc "Append one answer: `%{message_id, actor, text, run_id, input_message_id, completed}`."
  def append_answer(owner, dto, timeout \\ @call_timeout),
    do: write(owner, :answer, dto, timeout)

  @doc """
  Decide intents in order without appending. `intents` is a non-empty proper
  list of `{:input | :association | :answer, dto}`. Returns
  `{:ok, decisions}` with one `:ok`, `{:ok, :already_present}` or
  `{:refused, code}` per intent, or
  `{:error, :invalid_request | :timeout | :unavailable | :damaged}`.
  """
  def check(owner, intents, timeout \\ @call_timeout)
      when is_integer(timeout) and timeout > 0 do
    case prepare(intents) do
      {:ok, prepared} ->
        try do
          GenServer.call(owner, {:check, prepared}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, _ -> {:error, :unavailable}
        end

      :error ->
        {:error, :invalid_request}
    end
  end

  @doc """
  Read the entries `from_sequence..min(head, from_sequence + limit - 1)`.
  Returns `{:ok, %{revision: head_revision, entries: entries}}`, `:not_found`
  or `{:error, :invalid_scope | :invalid_request | :damaged | :unavailable}`.
  """
  def page(store, scope, reference, from_sequence, limit) do
    with {:ok, context} <- read_request(store, scope, reference, from_sequence, limit) do
      case Store.read(context.store, :read, [context.stream, from_sequence, limit]) do
        {:ok, rows, head} ->
          through = min(head.revision, from_sequence + limit - 1)
          entries(context, rows, head, from_sequence, through, head.revision)

        error ->
          read_error(error)
      end
    end
  end

  @doc """
  Read the last `count` entries up to the sampled head. Returns the same
  shapes as `page/5`.
  """
  def tail(store, scope, reference, count) do
    with {:ok, context} <- read_request(store, scope, reference, 1, count),
         {:ok, head} <- head(context) do
      if head.revision == 0 do
        {:ok, %{revision: 0, entries: []}}
      else
        from = max(1, head.revision - count + 1)
        limit = head.revision - from + 1

        case Store.read(context.store, :read, [context.stream, from, limit]) do
          {:ok, rows, second} ->
            if second.revision >= head.revision,
              do: entries(context, rows, second, from, head.revision, head.revision),
              else: {:error, :damaged}

          error ->
            read_error(error)
        end
      end
    end
  end

  @doc """
  Import a version 1 conversation snapshot (the value that
  `CheckedCommand.resource/3` returns) into the empty stream of `reference`.
  Returns `{:ok, %{sequence: last_row}}`, `{:ok, :already_present}`,
  `{:error, :not_empty | :invalid_snapshot | :invalid_request |
  :unsupported_store | :damaged | :unavailable | :rejected | :contended}` or
  `{:unknown, :unresolved}`.
  """
  def import_v1(store, reference, snapshot) do
    with {:ok, tenant, id} <- reference(reference),
         {:ok, context} <- context(store, tenant, id),
         :ok <- atomic(store),
         {:ok, v1} <- V1.parse(snapshot),
         {:ok, planned} <- plan(v1) do
      import_planned(%{context: context, v1: v1, planned: planned, appended?: false, restarts: 0})
    end
  end

  @impl true
  def init(opts) do
    with {:ok, store, tenant, id} <- options(opts),
         {:ok, context} <- context(store, tenant, id),
         :ok <- atomic(store),
         {:ok, head} <- head(context),
         {:ok, model} <- read_fold(context, History.new(), 1, head.revision) do
      {:ok, Map.merge(context, %{head: head.revision, model: model})}
    end
  end

  @impl true
  def handle_call({:write, entry, completed}, _from, state) do
    {reply, state} = attempt(state, entry, completed, 0)
    {:reply, reply, state}
  end

  def handle_call({:check, intents}, _from, state) do
    case refresh(state) do
      {:ok, state, _first} -> {:reply, {:ok, History.check(state.model, intents)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp write(owner, mode, dto, timeout) when is_integer(timeout) and timeout > 0 do
    case Record.intent(mode, dto) do
      {:ok, entry, completed} ->
        try do
          GenServer.call(owner, {:write, entry, completed}, timeout)
        catch
          :exit, _ -> {:unknown, :unresolved}
        end

      :error ->
        {:refused, "invalid_request"}
    end
  end

  defp prepare(intents) do
    with true <- proper_list?(intents),
         true <- intents != [],
         true <-
           Enum.all?(intents, &match?({mode, _} when mode in [:input, :association, :answer], &1)) do
      {:ok,
       Enum.map(intents, fn {mode, dto} ->
         case Record.intent(mode, dto) do
           {:ok, entry, completed} -> {:ok, entry, completed}
           :error -> :invalid
         end
       end)}
    else
      _ -> :error
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp attempt(state, entry, completed, conflicts) do
    case History.decide(state.model, entry, completed) do
      :proceed -> append(state, entry, completed, conflicts)
      :already_present -> {{:ok, :already_present}, state}
      {:refused, code} -> refuse(state, entry, completed, conflicts, code)
    end
  end

  # A refusal decided on the owner's model can be stale: rows that another
  # writer appended after the owner's head can make the same record identical
  # (already present) or admissible. The owner reads them before it refuses
  # and decides once more on the refreshed model; a refresh that cannot read
  # or finds damage returns its error and appends nothing.
  defp refuse(state, entry, completed, conflicts, code) do
    case refresh(state) do
      {:ok, state, nil} ->
        {{:refused, code}, state}

      {:ok, state, _first} ->
        case History.decide(state.model, entry, completed) do
          :proceed -> append(state, entry, completed, conflicts)
          :already_present -> {{:ok, :already_present}, state}
          {:refused, code} -> {{:refused, code}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp append(state, entry, completed, conflicts) do
    row = Record.row(state.stream, state.head + 1, entry, :crypto.strong_rand_bytes(16))

    case Store.write(
           state.store,
           :append,
           [state.stream, state.head, [row], []],
           Record.request(row)
         ) do
      {:committed, sequence} ->
        {{:ok, %{sequence: sequence}}, commit(state, entry, sequence)}

      {:conflict, _} ->
        lost(state, entry, completed, conflicts)

      {:indeterminate, _} ->
        resolve(state, entry, completed, row, conflicts)

      {:rejected, _} ->
        {{:error, :rejected}, state}
    end
  end

  # The compare-and-set lost: read only the new rows, fold them and decide again.
  defp lost(state, _entry, _completed, conflicts) when conflicts >= @max_conflicts,
    do: {{:error, :contended}, state}

  defp lost(state, entry, completed, conflicts) do
    case refresh(state) do
      {:ok, state, _first} -> attempt(state, entry, completed, conflicts + 1)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # An indeterminate append is resolved by its own nonce and bytes, or by
  # finding the identical record; a missing row is not proof of non-commit.
  defp resolve(state, entry, completed, row, conflicts) do
    case Log.confirm(state.store, state.stream, state.head, row.nonce, [row]) do
      {:committed, sequence} ->
        {{:ok, %{sequence: sequence}}, commit(state, entry, sequence)}

      :superseded ->
        lost(state, entry, completed, conflicts)

      {:unknown, _} ->
        case refresh(state) do
          {:ok, _refreshed, nil} ->
            {{:unknown, :unresolved}, state}

          {:ok, refreshed, first} ->
            if same_row?(first, row),
              do: {{:ok, %{sequence: row.sequence}}, refreshed},
              else: lost_after_refresh(refreshed, entry, completed, conflicts)

          {:error, _} ->
            {{:unknown, :unresolved}, state}
        end
    end
  end

  # Another row owns the slot of the indeterminate append: its compare-and-set lost.
  defp lost_after_refresh(state, _entry, _completed, conflicts) when conflicts >= @max_conflicts,
    do: {{:error, :contended}, state}

  defp lost_after_refresh(state, entry, completed, conflicts),
    do: attempt(state, entry, completed, conflicts + 1)

  defp commit(state, entry, sequence),
    do: %{state | head: sequence, model: History.admit(state.model, entry)}

  # Read and fold the rows after the owner's head. Returns the refreshed state
  # and the raw row at the old head + 1 (nil when the head did not move).
  defp refresh(state) do
    with {:ok, head} <- head(state) do
      cond do
        head.revision == state.head ->
          {:ok, state, nil}

        head.revision < state.head ->
          {:error, :damaged}

        true ->
          from = state.head + 1
          limit = min(@read_page, head.revision - from + 1)

          with {:ok, [first | _] = rows} <- read_rows(state, from, limit, head.revision),
               {:ok, model, next} <- History.fold_rows(state.model, rows, state, from),
               {:ok, model} <- read_fold(state, model, next, head.revision) do
            {:ok, %{state | head: head.revision, model: model}, first}
          end
      end
    end
  end

  defp read_fold(_context, model, from, through) when from > through, do: {:ok, model}

  defp read_fold(context, model, from, through) do
    limit = min(@read_page, through - from + 1)

    with {:ok, rows} <- read_rows(context, from, limit, through),
         {:ok, model, next} <- History.fold_rows(model, rows, context, from) do
      read_fold(context, model, next, through)
    end
  end

  defp read_rows(context, from, limit, through) do
    case Store.read(context.store, :read, [context.stream, from, limit]) do
      {:ok, rows, head} ->
        if head.low_water == 0 and head.revision >= through and length(rows) == limit,
          do: {:ok, rows},
          else: {:error, :damaged}

      error ->
        read_error(error)
    end
  end

  defp head(context) do
    case Store.read(context.store, :head, [context.stream]) do
      {:ok, %{low_water: 0} = head} -> {:ok, head}
      {:ok, _pruned} -> {:error, :damaged}
      error -> read_error(error)
    end
  end

  defp read_error({:error, {:pruned, _}}), do: {:error, :damaged}
  defp read_error({:error, :malformed}), do: {:error, :damaged}
  defp read_error(_), do: {:error, :unavailable}

  defp entries(context, rows, head, from, through, revision) do
    expected = max(through - from + 1, 0)

    if head.low_water == 0 and length(rows) == expected do
      rows
      |> Enum.with_index(from)
      |> Enum.reduce_while({:ok, []}, fn {row, sequence}, {:ok, acc} ->
        case Record.decode(row, context.stream, sequence, context.fold, context.limits) do
          {:ok, entry} -> {:cont, {:ok, [Record.public(entry, sequence) | acc]}}
          :error -> {:halt, {:error, :damaged}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, %{revision: revision, entries: Enum.reverse(entries)}}
        error -> error
      end
    else
      {:error, :damaged}
    end
  end

  defp read_request(store, scope, reference, from, count) do
    with {:ok, scope} <- read_scope(scope),
         {:ok, tenant, id} <- reference(reference),
         :ok <- grant(scope, tenant, id),
         :ok <- operands(from, count),
         {:ok, context} <- context(store, tenant, id) do
      {:ok, context}
    else
      {:error, :unsupported_store} -> {:error, :invalid_request}
      other -> other
    end
  end

  defp read_scope(scope) do
    with true <- exact_map?(scope, [:tenant, :actor, :resources]),
         true <- Record.id?(scope.tenant) and Record.id?(scope.actor),
         {:ok, resources} <- bounded_list(scope.resources, @max_resources),
         true <- Enum.all?(resources, &Record.id?/1) do
      {:ok, scope}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp reference(reference) do
    if exact_map?(reference, [:target_tenant, :conversation_id]) and
         Record.segment?(reference.target_tenant) and Record.segment?(reference.conversation_id),
       do: {:ok, reference.target_tenant, reference.conversation_id},
       else: {:error, :invalid_request}
  end

  defp grant(scope, tenant, id),
    do: if(scope.tenant == tenant and id in scope.resources, do: :ok, else: :not_found)

  defp operands(from, count) do
    if is_integer(from) and from >= 1 and from <= @max_sequence and is_integer(count) and
         count in 1..@max_count,
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and length(opts) == 3 and
         Enum.sort(Keyword.keys(opts)) == [:conversation_id, :store, :target_tenant] and
         Record.segment?(opts[:target_tenant]) and Record.segment?(opts[:conversation_id]),
       do: {:ok, opts[:store], opts[:target_tenant], opts[:conversation_id]},
       else: {:error, :invalid_options}
  end

  # The Store term carries the fold and limits that its rows are validated with.
  defp context({module, %{fold: fold, limits: limits}} = store, tenant, id)
       when is_atom(module) do
    if Codec.fold_valid?(fold) and Enum.all?(Record.kinds(), &Map.has_key?(fold.kinds, &1)) and
         Record.version() in fold.versions and is_map(limits) and
         is_integer(Map.get(limits, :max_record_bytes)) and
         limits.max_record_bytes >= Record.max_payload_bytes() and
         is_integer(Map.get(limits, :max_batch_size)) and limits.max_batch_size >= 1,
       do: {:ok, %{store: store, stream: Record.stream(tenant, id), fold: fold, limits: limits}},
       else: {:error, :unsupported_store}
  end

  defp context(_store, _tenant, _id), do: {:error, :unsupported_store}

  defp atomic(store) do
    case Store.read(store, :capabilities, []) do
      %{append_visibility: :atomic} -> :ok
      _ -> {:error, :unsupported_store}
    end
  end

  # Version 1 import: each message in list order, each association directly
  # after its input.
  defp plan(v1) do
    runs = Map.new(v1.associations, &{&1.input_message_id, &1.run_id})

    v1.messages
    |> Enum.flat_map(fn
      %{role: "assistant"} = message ->
        [Record.entry(:answer, message)]

      message ->
        case Map.fetch(runs, message.message_id) do
          {:ok, run} ->
            [
              Record.entry(:input, message),
              Record.entry(:association, %{input_message_id: message.message_id, run_id: run})
            ]

          :error ->
            [Record.entry(:input, message)]
        end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, entry}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
      :error, _ -> {:halt, {:error, :invalid_snapshot}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp import_planned(job) do
    with {:ok, head} <- head(job.context) do
      if head.revision > length(job.planned) do
        {:error, :not_empty}
      else
        with {:ok, existing} <- read_entries(job.context, head.revision) do
          if existing == Enum.take(job.planned, length(existing)),
            do: import_rest(job, Enum.drop(job.planned, length(existing)), head.revision),
            else: {:error, :not_empty}
        end
      end
    end
  end

  defp import_rest(job, [], head) do
    with :ok <- verify(job) do
      if job.appended?, do: {:ok, %{sequence: head}}, else: {:ok, :already_present}
    end
  end

  defp import_rest(job, [entry | rest], head) do
    context = job.context
    row = Record.row(context.stream, head + 1, entry, :crypto.strong_rand_bytes(16))

    case Store.write(
           context.store,
           :append,
           [context.stream, head, [row], []],
           Record.request(row)
         ) do
      {:committed, sequence} ->
        import_rest(%{job | appended?: true}, rest, sequence)

      {:conflict, _} ->
        restart(job)

      {:indeterminate, _} ->
        case Log.confirm(context.store, context.stream, head, row.nonce, [row]) do
          {:committed, sequence} -> import_rest(%{job | appended?: true}, rest, sequence)
          :superseded -> restart(job)
          {:unknown, _} -> inspect_import(job, rest, row)
        end

      {:rejected, :caller_transaction} ->
        {:error, :unavailable}

      {:rejected, _} ->
        {:error, :rejected}
    end
  end

  # The append's outcome is unknown: its own row in the slot proves the commit,
  # another row proves that its compare-and-set lost, and no row proves nothing.
  defp inspect_import(job, rest, row) do
    with {:ok, head} <- head(job.context),
         true <- head.revision >= row.sequence,
         {:ok, [stored]} <- read_rows(job.context, row.sequence, 1, row.sequence) do
      if same_row?(stored, row),
        do: import_rest(%{job | appended?: true}, rest, row.sequence),
        else: restart(job)
    else
      _ -> {:unknown, :unresolved}
    end
  end

  # Another writer appended: read the stream again and compare it with the plan.
  defp restart(job) do
    if job.restarts >= length(job.planned) + @max_conflicts,
      do: {:error, :contended},
      else: import_planned(%{job | restarts: job.restarts + 1})
  end

  defp same_row?(stored, row),
    do:
      is_map(stored) and
        Enum.all?(
          [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest],
          &(Map.get(stored, &1) == Map.fetch!(row, &1))
        )

  # After the import, the stream must hold exactly the planned rows, and its
  # ordered message list and input-to-Run mapping must equal version 1's.
  defp verify(%{context: context, v1: v1, planned: planned}) do
    with {:ok, head} <- head(context),
         true <- head.revision == length(planned) || {:error, :not_empty},
         {:ok, entries} <- read_entries(context, head.revision),
         true <- entries == planned || {:error, :not_empty},
         true <-
           (messages(entries) == v1.messages and
              runs(entries) == Map.new(v1.associations, &{&1.input_message_id, &1.run_id})) ||
             {:error, :damaged} do
      :ok
    end
  end

  defp read_entries(_context, 0), do: {:ok, []}

  defp read_entries(context, through) do
    with {:ok, rows} <- read_rows(context, 1, through, through),
         {:ok, _model, _next} <- History.fold_rows(History.new(), rows, context, 1) do
      {:ok,
       rows
       |> Enum.with_index(1)
       |> Enum.map(fn {row, sequence} ->
         {:ok, entry} =
           Record.decode(row, context.stream, sequence, context.fold, context.limits)

         entry
       end)}
    end
  end

  defp messages(entries) do
    for %{kind: kind} = entry <- entries, kind in [:input, :answer] do
      case entry do
        %{kind: :input} ->
          Map.take(entry, [:message_id, :role, :actor, :text])

        %{kind: :answer} ->
          entry
          |> Map.take([:message_id, :actor, :text, :run_id, :input_message_id])
          |> Map.put(:role, "assistant")
      end
    end
  end

  defp runs(entries),
    do: Map.new(for %{kind: :association} = e <- entries, do: {e.input_message_id, e.run_id})

  defp bounded_list(list, limit), do: bounded_list(list, limit, 0, [])
  defp bounded_list([], _limit, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp bounded_list([head | tail], limit, count, acc) when count < limit,
    do: bounded_list(tail, limit, count + 1, [head | acc])

  defp bounded_list(_list, _limit, _count, _acc), do: :error

  defp exact_map?(value, keys),
    do:
      is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))
end
