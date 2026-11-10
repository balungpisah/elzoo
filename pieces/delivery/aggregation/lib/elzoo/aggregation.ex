# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Aggregation do
  @moduledoc """
  Bounded correlated join over declared branch delivery results.

  `new/2` declares the expected branch identities and the join configuration;
  `accept/2` records one validated `core/envelope` DeliveryResult, `mark_lost/3`
  records a first-class loss, `status/1` exposes payload-free branch records and
  `decision/2` is the pure `{join, outcome}` transition over `pending`, `all`,
  `partial`, `failed` and `expired`.

  Branch identity comes only from the configured `branch_key` field path —
  never from arrival order or position. Each declared branch contributes at
  most once: the first accepted input stands, later on-time inputs are
  `duplicate` records and a differing outcome/value marks the branch
  `conflicted`. Post-deadline and post-close input is recorded `late` and
  never merged. Accepted results are retained redacted — outcome, dispatch,
  error class and a SHA-256 `value_digest` for conflict comparison — so the
  join state never holds branch payloads and stays safe to inspect, log or
  persist. The join state is a plain map the caller may persist. `decision/2`
  performs no I/O. `accept/2` and `mark_lost/3` read the injected clock port;
  this module starts no process.
  """

  @statuses [
    :pending,
    :fulfilled,
    :failed,
    :timed_out,
    :killed,
    :unavailable,
    :missing,
    :conflicted,
    :late
  ]
  @unsettled [:pending, :late]
  @loss_kinds [:timed_out, :killed, :unavailable]
  @decisions [:all, :partial, :failed, :expired]
  @result_fields ~w(outcome dispatch error_class value_digest value_schema_id value_schema_version)

  @doc """
  Build a join over `declared` branch identities.

  `declared` is a nonempty proper list of unique identities bounded by
  `config[:max_branches]`; duplicates are refused. Each encoded identity term
  must also fit `max_result_bytes` (inclusive), bounding declaration bytes as
  well as incoming results. `config` is a keyword list:

    * `:branch_key` — required `{:field, path}`; `path` is exactly
      `["correlation_id"]` or `["attempt_id"]`, or `["value", key, ...]`
      descending map keys inside the result's `value`. Identity is read from a
      validated Envelope result, never positionally.
    * `:deadline_unix_ms` — optional nonnegative integer or `:unbounded`
      (default `:unbounded`).
    * `:max_result_bytes` — required positive integer; the encoded result term
      (`:erlang.term_to_binary/1`) must not exceed it.
    * `:max_branches` — required positive integer cap on `declared`.
    * `:now` — optional clock port, a 0-arity function returning unix
      milliseconds (default `System.os_time(:millisecond)`).

  Returns `{:ok, join}` or `{:error, :invalid_declaration}`.
  """
  def new(declared, config) when is_list(declared) and is_list(config) do
    with {:ok, opts} <- join_config(config),
         :ok <- declared_ok?(declared, opts) do
      branches = Map.new(declared, &{&1, empty_record()})

      {:ok,
       %{
         declared: declared,
         branch_key: opts.branch_key,
         deadline_unix_ms: opts.deadline_unix_ms,
         max_result_bytes: opts.max_result_bytes,
         max_branches: opts.max_branches,
         now: opts.now,
         branches: branches,
         closed: false,
         outcome: nil
       }}
    end
  end

  def new(_, _), do: {:error, :invalid_declaration}

  @doc """
  Record one Envelope result for its declared branch.

  The result is validated through `Elzoo.Envelope.validate_result/1`; malformed
  input is `{:error, :invalid_result}` and never partially merged. Identity is
  read through the configured `branch_key`: a missing carrier is
  `{:error, :invalid_branch_key}`, an undeclared identity
  `{:error, :unknown_branch}`, an encoded result over `max_result_bytes`
  `{:error, :too_large}`. A result at or after `deadline_unix_ms`, or any input
  after the join closed, is recorded `late` on its branch — never an error and
  never merged. Otherwise the first input settles the branch by the outcome
  table (`completed`→`fulfilled`, `rejected`/`failed`→`failed`,
  `timed_out`→`timed_out`, `unknown`→`unavailable`) and later on-time inputs
  are duplicates; a differing outcome/value marks the branch `conflicted`.

  Returns `{:ok, join}` or `{:error, reason}`.
  """
  def accept(join, result) do
    with :ok <- check_join(join),
         :ok <- check_result(result),
         {:ok, branch_id} <- branch_identity(join, result),
         :ok <- check_declared(join, branch_id) do
      record_input(join, branch_id, {:result, result})
    end
  end

  @doc """
  Record a first-class loss `{:timed_out | :killed | :unavailable}` for
  `branch_id` — not a synthetic Envelope result. Loss records carry no
  payload, so unlike `accept/2` they are not held to the deadline: a loss
  recorded at or after `deadline_unix_ms` still settles an unsettled branch
  (a `:timed_out` loss at the deadline is the truthful record). After the
  join closes, losses are recorded `late` like results. On-time losses on a
  settled branch are duplicates and follow the same conflict rule.
  Returns `{:ok, join}` or `{:error, reason}`.
  """
  def mark_lost(join, branch_id, kind) do
    with :ok <- check_join(join),
         :ok <- check_loss_kind(kind),
         :ok <- check_declared(join, branch_id) do
      record_input(join, branch_id, {:loss, kind})
    end
  end

  @doc """
  Payload-free view of every declared branch record, keyed by branch identity.
  Result `value` payloads and loss payloads are never exposed here.
  """
  def status(join) do
    with :ok <- check_join(join) do
      {:ok, public_branches(join)}
    end
  end

  @doc """
  Pure decision transition returning `{join, outcome}`.

  `now` is the caller-read unix-millisecond time. While any branch is
  `pending`/`late` and the deadline has not passed the outcome is `:pending`
  and the join stays open. At or after `deadline_unix_ms` with branches still
  unsettled the outcome is `:expired`: pending branches are recorded `missing`
  (no evidence ever arrived) and late branches `timed_out`, and the join
  closes. Otherwise `:all` (every branch `fulfilled`), `:partial` (at least
  one `fulfilled` and at least one terminal non-fulfilled) or `:failed` (no
  `fulfilled`, at least one terminal) closes the join. A closed join returns
  its recorded outcome with the current branch map; `:pending` is never
  stored.

  `outcome` is `%{decision: atom, branches: %{branch_id => record}}` covering
  exactly the declared identities.
  """
  def decision(join, now) do
    with :ok <- check_join(join),
         :ok <- check_now(now) do
      if join.closed do
        {join, outcome_map(join.outcome, join)}
      else
        decide_open(join, now)
      end
    end
  end

  @doc "True when `term` has the join state shape; used by runners and tests."
  def valid_state?(term), do: check_join(term) == :ok

  defp decide_open(join, now) do
    statuses = Enum.map(join.branches, fn {_id, record} -> record.status end)

    cond do
      Enum.any?(statuses, &(&1 in @unsettled)) ->
        if past_deadline?(join, now) do
          join = join |> expire(now) |> close(:expired)
          {join, outcome_map(:expired, join)}
        else
          {join, outcome_map(:pending, join)}
        end

      true ->
        outcome = terminal_outcome(statuses)
        join = close(join, outcome)
        {join, outcome_map(outcome, join)}
    end
  end

  defp terminal_outcome(statuses) do
    fulfilled = Enum.count(statuses, &(&1 == :fulfilled))

    cond do
      fulfilled == length(statuses) -> :all
      fulfilled > 0 -> :partial
      true -> :failed
    end
  end

  defp expire(join, now) do
    branches =
      Map.new(join.branches, fn {id, record} ->
        record =
          case record.status do
            :pending -> %{record | status: :missing, decided_unix_ms: now}
            :late -> %{record | status: :timed_out, decided_unix_ms: now}
            _ -> record
          end

        {id, record}
      end)

    %{join | branches: branches}
  end

  defp close(join, outcome), do: %{join | closed: true, outcome: outcome}

  defp record_input(join, branch_id, input) do
    now = join.now.()

    if not is_integer(now) do
      {:error, :invalid_clock}
    else
      record = join.branches[branch_id]
      late? = join.closed or (match?({:result, _}, input) and past_deadline?(join, now))

      cond do
        late? ->
          {:ok, put_in(join.branches[branch_id], mark_late(record, now))}

        too_large?(input, join) ->
          {:error, :too_large}

        true ->
          {:ok, put_in(join.branches[branch_id], merge_record(record, input, now))}
      end
    end
  end

  defp too_large?({:result, result}, join) do
    byte_size(:erlang.term_to_binary(result)) > join.max_result_bytes
  end

  defp too_large?(_input, _join), do: false

  defp mark_late(record, now) do
    record = %{record | late_count: record.late_count + 1}

    if record.status == :pending do
      %{record | status: :late, first_seen_unix_ms: record.first_seen_unix_ms || now}
    else
      record
    end
  end

  defp merge_record(%{status: status} = record, input, now)
       when status in @unsettled do
    {result, loss} =
      case input do
        {:result, result} -> {redact_result(result), nil}
        {:loss, kind} -> {nil, %{kind: kind, recorded_unix_ms: now}}
      end

    status =
      case input do
        {:result, result} -> outcome_status(result["outcome"])
        {:loss, kind} -> kind
      end

    %{
      record
      | status: status,
        result: result,
        loss: loss,
        decided_unix_ms: now,
        first_seen_unix_ms: record.first_seen_unix_ms || now
    }
  end

  defp merge_record(%{status: :conflicted} = record, _input, _now) do
    %{record | duplicate_count: record.duplicate_count + 1}
  end

  defp merge_record(record, input, now) do
    record = %{record | duplicate_count: record.duplicate_count + 1}

    if conflict?(record, input) do
      %{record | status: :conflicted, conflicted: true, decided_unix_ms: now}
    else
      record
    end
  end

  defp conflict?(%{result: %{} = stored, loss: nil}, {:result, incoming}) do
    semantic(stored) != semantic(redact_result(incoming))
  end

  defp conflict?(%{result: %{} = stored, loss: nil}, {:loss, kind}) do
    outcome_status(stored["outcome"]) != kind
  end

  defp conflict?(%{result: nil, loss: %{kind: stored}}, {:result, incoming}) do
    stored != outcome_status(incoming["outcome"])
  end

  defp conflict?(%{result: nil, loss: %{kind: stored}}, {:loss, kind}) do
    stored != kind
  end

  defp semantic(result), do: Map.take(result, @result_fields)

  # The join retains outcome metadata and a digest of the payload for conflict
  # detection — never the payload itself, so state inspection and caller
  # persistence cannot leak branch data.
  defp redact_result(result) do
    case Map.fetch(result, "value") do
      {:ok, value} ->
        result
        |> Map.delete("value")
        |> Map.put("value_digest", value_digest(value))

      :error ->
        result
    end
  end

  defp value_digest(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp outcome_status("completed"), do: :fulfilled
  defp outcome_status("rejected"), do: :failed
  defp outcome_status("failed"), do: :failed
  defp outcome_status("timed_out"), do: :timed_out
  defp outcome_status("unknown"), do: :unavailable

  defp past_deadline?(%{deadline_unix_ms: :unbounded}, _now), do: false

  defp past_deadline?(%{deadline_unix_ms: deadline}, now), do: now >= deadline

  defp branch_identity(%{branch_key: {:field, path}}, result) do
    case fetch_path(result, path) do
      {:ok, nil} -> {:error, :invalid_branch_key}
      {:ok, branch_id} -> {:ok, branch_id}
      :error -> {:error, :invalid_branch_key}
    end
  end

  defp fetch_path(result, ["correlation_id"]), do: {:ok, result["correlation_id"]}

  defp fetch_path(result, ["attempt_id"]) do
    if Map.has_key?(result, "attempt_id"), do: {:ok, result["attempt_id"]}, else: :error
  end

  defp fetch_path(result, ["value" | keys]) do
    with %{} = value <- result["value"],
         {:ok, found} <- descend(value, keys) do
      {:ok, found}
    else
      _ -> :error
    end
  end

  defp fetch_path(_, _), do: :error

  defp descend(map, [key]) do
    if is_map(map) and Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: :error
  end

  defp descend(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      %{} = nested -> descend(nested, rest)
      _ -> :error
    end
  end

  defp descend(_, _), do: :error

  defp join_config(config) do
    if keyword_config?(config) do
      with {:ok, branch_key} <- fetch_config(config, :branch_key),
           :ok <- check_branch_key(branch_key),
           {:ok, deadline} <- fetch_deadline(config),
           {:ok, max_result_bytes} <- fetch_positive(config, :max_result_bytes),
           {:ok, max_branches} <- fetch_positive(config, :max_branches),
           {:ok, now} <- fetch_now(config) do
        {:ok,
         %{
           branch_key: branch_key,
           deadline_unix_ms: deadline,
           max_result_bytes: max_result_bytes,
           max_branches: max_branches,
           now: now
         }}
      end
    else
      {:error, :invalid_declaration}
    end
  end

  defp keyword_config?(config) do
    proper_list?(config) and Keyword.keyword?(config)
  end

  defp fetch_config(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_declaration}
    end
  end

  defp check_branch_key({:field, path}) do
    if valid_key_path?(path), do: :ok, else: {:error, :invalid_declaration}
  end

  defp check_branch_key(_), do: {:error, :invalid_declaration}

  defp valid_key_path?(path) do
    proper_list?(path) and
      case path do
        ["correlation_id"] -> true
        ["attempt_id"] -> true
        ["value" | rest] -> rest != [] and Enum.all?(rest, &is_binary/1)
        _ -> false
      end
  end

  defp fetch_deadline(config) do
    case Keyword.get(config, :deadline_unix_ms, :unbounded) do
      :unbounded -> {:ok, :unbounded}
      deadline when is_integer(deadline) and deadline >= 0 -> {:ok, deadline}
      _ -> {:error, :invalid_declaration}
    end
  end

  defp fetch_positive(config, key) do
    case Keyword.get(config, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_declaration}
    end
  end

  defp fetch_now(config) do
    case Keyword.get(config, :now, fn -> System.os_time(:millisecond) end) do
      now when is_function(now, 0) -> {:ok, now}
      _ -> {:error, :invalid_declaration}
    end
  end

  defp declared_ok?(declared, opts) do
    cond do
      not proper_list?(declared) or declared == [] ->
        {:error, :invalid_declaration}

      length(declared) > opts.max_branches ->
        {:error, :invalid_declaration}

      Enum.any?(declared, &(byte_size(:erlang.term_to_binary(&1)) > opts.max_result_bytes)) ->
        {:error, :invalid_declaration}

      length(Enum.uniq(declared)) != length(declared) ->
        {:error, :invalid_declaration}

      true ->
        :ok
    end
  end

  defp empty_record do
    %{
      status: :pending,
      result: nil,
      loss: nil,
      duplicate_count: 0,
      conflicted: false,
      late_count: 0,
      first_seen_unix_ms: nil,
      decided_unix_ms: nil
    }
  end

  defp check_result(result) do
    case Elzoo.Envelope.validate_result(result) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_result}
    end
  end

  defp check_loss_kind(kind) do
    if kind in @loss_kinds, do: :ok, else: {:error, :invalid_loss_kind}
  end

  defp check_declared(%{branches: branches}, branch_id) do
    if Map.has_key?(branches, branch_id), do: :ok, else: {:error, :unknown_branch}
  end

  defp check_now(now) do
    if is_integer(now), do: :ok, else: {:error, :invalid_now}
  end

  defp check_join(%{
         declared: declared,
         branch_key: {:field, path},
         deadline_unix_ms: deadline,
         max_result_bytes: max_result_bytes,
         max_branches: max_branches,
         now: now,
         branches: branches,
         closed: closed,
         outcome: outcome
       }) do
    cond do
      not proper_list?(declared) or declared == [] ->
        {:error, :invalid_state}

      not valid_key_path?(path) ->
        {:error, :invalid_state}

      not (deadline == :unbounded or (is_integer(deadline) and deadline >= 0)) ->
        {:error, :invalid_state}

      not (is_integer(max_result_bytes) and max_result_bytes > 0) ->
        {:error, :invalid_state}

      not (is_integer(max_branches) and max_branches > 0) ->
        {:error, :invalid_state}

      declared_ok?(declared, %{max_branches: max_branches, max_result_bytes: max_result_bytes}) !=
          :ok ->
        {:error, :invalid_state}

      not is_function(now, 0) ->
        {:error, :invalid_state}

      not is_map(branches) or not is_boolean(closed) ->
        {:error, :invalid_state}

      not (is_nil(outcome) or outcome in @decisions) ->
        {:error, :invalid_state}

      closed != not is_nil(outcome) ->
        {:error, :invalid_state}

      map_size(branches) != length(declared) ->
        {:error, :invalid_state}

      true ->
        check_branch_records(declared, branches)
    end
  end

  defp check_join(_), do: {:error, :invalid_state}

  defp check_branch_records(declared, branches) do
    declared_set = MapSet.new(declared)

    if Enum.all?(branches, fn {id, record} ->
         MapSet.member?(declared_set, id) and valid_record?(record)
       end),
       do: :ok,
       else: {:error, :invalid_state}
  end

  defp valid_record?(%{
         status: status,
         result: result,
         loss: loss,
         duplicate_count: duplicates,
         conflicted: conflicted,
         late_count: late,
         first_seen_unix_ms: first_seen,
         decided_unix_ms: decided
       }) do
    status in @statuses and
      (is_nil(result) or is_map(result)) and
      (is_nil(loss) or valid_loss?(loss)) and
      is_integer(duplicates) and duplicates >= 0 and
      is_boolean(conflicted) and
      is_integer(late) and late >= 0 and
      (is_nil(first_seen) or (is_integer(first_seen) and first_seen >= 0)) and
      (is_nil(decided) or (is_integer(decided) and decided >= 0)) and
      (is_nil(result) or is_nil(loss))
  end

  defp valid_record?(_), do: false

  defp valid_loss?(%{kind: kind, recorded_unix_ms: at}) do
    kind in @loss_kinds and is_integer(at) and at >= 0
  end

  defp valid_loss?(_), do: false

  defp public_branches(join) do
    Map.new(join.branches, fn {id, record} -> {id, public_record(record)} end)
  end

  defp public_record(record) do
    result = record.result
    loss = record.loss

    %{
      status: record.status,
      outcome: result && result["outcome"],
      dispatch: result && result["dispatch"],
      error_class: result && result["error_class"],
      value_schema_id: result && result["value_schema_id"],
      value_schema_version: result && result["value_schema_version"],
      loss: loss && loss.kind,
      duplicate_count: record.duplicate_count,
      conflicted: record.conflicted,
      late_count: record.late_count,
      first_seen_unix_ms: record.first_seen_unix_ms,
      decided_unix_ms: record.decided_unix_ms
    }
  end

  defp outcome_map(outcome, join) do
    %{decision: outcome, branches: public_branches(join)}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
