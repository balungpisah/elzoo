# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox do
  @moduledoc """
  Bounded Lua evaluation outside the VM (policy version 3: the safe helper set and module-call bindings).

  A trusted host builds the executable once with `build/2` from the installed
  pinned `lua_source` checkout and an owned C host. Each `run/2` starts one fresh
  OS process over an OTP Port that a short-lived owner process holds, sends one request frame, reads one reply frame and
  reaps the process. There is no pool, no service and no shared state.

  * `build(source_directory, build_directory)` ->
    `{:ok, executable} | {:error, :build_failed}`. Both operands are trusted
    host-supplied paths, never Lua input.
  * `policy()` -> `%{identity: "policy-v3:sha256:<hex>", descriptor: map}`.
  * `run(executable, request)` -> `{:ok, %{value: v, identity: i, runtime: r}}`,
    `{:refused, reason}`, `{:host_outcome, reason}` or `{:pending_call, call}`.

  The request has exactly `source`, `input`, `policy`, `limits` and `calls`
  (`limits` is `steps call_depth value_bytes memory_bytes wall_ms`, positive integers with
  the inclusive maxima 1_000_000, 64, 65_536, 16_777_216 and 1_000; `calls` is below).
  The source is UTF-8 Lua text of at most 65_536 bytes: a chunk that returns
  exactly one function; the function takes the plain input and returns exactly
  one plain result. Bytecode is never accepted.

  ## Plain data

  `nil`, booleans, UTF-8 binaries, integers in signed 64-bit, finite floats,
  lists and maps with binary keys, nested at most 32 containers. In Lua, null
  is one light userdata sentinel (compare with `==`; `tostring` refuses it); a
  single `nil` result also encodes as null. A decoded array and a decoded object
  keep their kind in a host-private record, so an empty array and an empty object
  round-trip distinctly. An unrecorded table with keys exactly `1..n` is an array,
  with only string keys an object, and an empty unrecorded table is an empty
  array; a source builds a fresh empty object with `helpers.object()` and reaches null as
  `helpers.null`.

  ## Module-call bindings

  `calls` is a plain map with exactly `mode`, `names` and `recorded`:

    * `mode` is `"none"`, `"data"` or `"replay"`.
    * `names` is a list of at most 64 unique binaries that match `[a-z][a-z0-9_]{0,63}`;
      with mode `"none"` it is empty.
    * `recorded` is a list of at most 256 maps with exactly `name` (a listed name),
      `arguments` and `result` (plain values); with modes `"none"` and `"data"` it is empty.

  Any other shape is `:invalid_request`. The canonical JSON of each `arguments` and each
  `result` is at most `value_bytes`, else `:value_size`. All of this is decided before a
  process starts; in the frame `calls` is one more member with string keys.

  With mode `"none"` the global `bindings` does not exist (`bindings.x` is `:unlisted_name`).
  With the other modes it is a fresh table with the strict lookup of a library: for each
  name of `names`, `bindings.<name>` is a function, and every other field is
  `:unlisted_name`. A source may assign a field of it in its own run. The sandbox answers
  every call itself: no callback, no second process, no state between runs.

  A binding function takes exactly one value (`nil` is null). No value, two values or a
  value that a result would refuse is an ordinary Lua error with a fixed message that
  `pcall` catches, and the call gets no index. An argument whose canonical JSON is over
  `value_bytes` is the sticky `:value_size` stop. The order inside a call: one step for each
  byte of the canonical JSON of the argument; then the mode rule; then one step for each byte
  of a value that the call returns. So a `steps` limit reached while the argument is
  charged is `:steps`, never a pending call.

  Mode `"data"`: the call returns a fresh object `{"binding" => name, "arguments" => copy}`
  (null for `nil`); nothing is recorded and the run continues.

  Mode `"replay"`: the binding calls are counted from 0 over the chunk and the function.
  Call `k < length(recorded)` must have the name and the canonical JSON of the arguments of
  `recorded[k]` (object keys in any order); it returns the plain `result`, else the sticky
  refusal `:call_mismatch`. Call `k == length(recorded)` is the sticky stop that ends the
  run as `{:pending_call, %{index: k, name: name, arguments: plain}}`: no later statement
  runs and `pcall` does not catch it. A function that returns one value after fewer calls
  than `length(recorded)` is `:call_mismatch`, a record that the source did not ask for.
  A limit reached first wins: the stops stay sticky in the order in which they happen.
  The same request gives the same reply.

  ## Outcomes

  `run/2` returns one of four forms: `{:ok, _}`, `{:refused, reason}`,
  `{:host_outcome, reason}` or `{:pending_call, call}` (mode `"replay"` only).
  Refusals: `:invalid_request`, `:policy_mismatch`, `:invalid_result`, `:steps`,
  `:call_depth`, `:value_size`, `:unlisted_name`, `:lua_error`, `:call_mismatch`. Host outcomes:
  `:memory`, `:wall_time`, `:process_exit`, `:protocol_error`. Memory, wall time
  and abnormal exits are inputs to record, never deterministic replay decisions.

  The host executable also carries the policy identity (a build-time define) and
  answers `policy_mismatch` before it creates a Lua state when a frame names another.

  Request validation happens before any process starts. An input string or an
  input whose canonical encoding is over `value_bytes` is `:value_size`; any
  other input that is not plain data, or that nests deeper than 32 containers,
  is `:invalid_request`.

  ## A budget below what initialization needs

  Creating the state runs no Lua instruction, so `steps` and `call_depth` have no
  budget below initialization: their minimum 1 is an ordinary budget (a chunk
  needs two counted instructions, so `steps: 1` ends `{:refused, :steps}`).
  Loading any source creates a string of four bytes (`_ENV`), so `value_bytes`
  below 4 is `{:refused, :value_size}` before any user code runs.
  `memory_bytes` below the state baseline is `{:host_outcome, :memory}` with no
  user code run. `wall_ms` below the time to start the process is
  `{:host_outcome, :wall_time}` when the deadline passes first (an ordinary
  result when the process answers within the budget).

  ## Cleanup

  Each `run/2` starts one owner process for the Port. It is not linked to the
  calling process, traps exits and monitors the caller. The caller holds the
  absolute deadline and waits for the end of the owner. On every return path the
  child is killed by OS pid and reaped before `run/2` returns, so no child and no
  process of the Piece outlives it. An exit of the Port, for example a write into
  a closed child input, is a message to the owner and a host outcome
  (`process_exit`, or `protocol_error` when bytes that are not one reply frame were
  read), never an exit signal to the caller. The caller's links, monitors, flags
  and mailbox are the same after `run/2` as before it. If the calling process
  dies, the owner sees it, kills the child by OS pid and reaps it; the child also
  polls for the closed input while it runs Lua instructions and arms a
  self-termination timer a little after `wall_ms`, as backstops.
  """

  alias Elzoo.LuaSandbox.{Build, Child, Descriptor, Json}

  @policy (fn ->
             descriptor = Descriptor.descriptor()
             %{identity: Descriptor.identity(descriptor), descriptor: descriptor}
           end).()

  @limit_keys ~w(call_depth memory_bytes steps value_bytes wall_ms)a
  @limits %{
    steps: 1_000_000,
    call_depth: 64,
    value_bytes: 65_536,
    memory_bytes: 16_777_216,
    wall_ms: 1_000
  }
  @source_max 65_536
  @calls_keys [:mode, :names, :recorded]
  @record_keys [:arguments, :name, :result]
  @modes ~w(none data replay)
  @name_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_names 64
  @max_recorded 256
  @child_refusals %{
    "invalid_request" => :invalid_request,
    "policy_mismatch" => :policy_mismatch,
    "invalid_result" => :invalid_result,
    "steps" => :steps,
    "call_depth" => :call_depth,
    "value_size" => :value_size,
    "unlisted_name" => :unlisted_name,
    "lua_error" => :lua_error,
    "call_mismatch" => :call_mismatch
  }
  @runtime_keys %{
    "build_options" => :build_options,
    "host_sha256" => :host_sha256,
    "lua_release" => :lua_release,
    "seed" => :seed,
    "upstream_revision" => :upstream_revision
  }

  @type refusal ::
          :invalid_request
          | :policy_mismatch
          | :invalid_result
          | :steps
          | :call_depth
          | :value_size
          | :unlisted_name
          | :lua_error
          | :call_mismatch
  @type host_outcome :: :memory | :wall_time | :process_exit | :protocol_error

  @spec build(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, :build_failed}
  def build(source_directory, build_directory), do: Build.build(source_directory, build_directory)

  @spec policy() :: %{identity: String.t(), descriptor: map()}
  def policy, do: @policy

  @spec run(Path.t(), map()) ::
          {:ok, %{value: term(), identity: String.t(), runtime: map()}}
          | {:refused, refusal()}
          | {:host_outcome, host_outcome()}
          | {:pending_call, %{index: non_neg_integer(), name: String.t(), arguments: term()}}
  def run(executable, request) when is_binary(executable) do
    started = System.monotonic_time(:millisecond)

    case validate(request) do
      {:ok, frame, limits, calls} ->
        deadline = started + limits.wall_ms

        case Child.exchange(executable, Json.frame(frame), deadline) do
          {:frame, body} -> interpret(body, limits, calls)
          {:host_outcome, _} = outcome -> outcome
        end

      {:refused, _} = refusal ->
        refusal
    end
  end

  defp validate(%{} = request) when not is_struct(request) do
    with true <- Enum.sort(Map.keys(request)) == [:calls, :input, :limits, :policy, :source],
         %{source: source, input: input, policy: policy, limits: limits, calls: calls} = request,
         true <- is_binary(policy),
         {:policy, true} <- {:policy, policy == @policy.identity},
         {:ok, limits} <- check_limits(limits),
         true <- is_binary(source) and byte_size(source) <= @source_max and String.valid?(source),
         :ok <- check_input(input, limits.value_bytes),
         {:ok, calls} <- check_calls(calls, limits.value_bytes) do
      frame =
        Json.encode(%{
          "source" => source,
          "input" => input,
          "policy" => policy,
          "limits" => stringify(limits),
          "calls" => calls
        })

      if byte_size(frame) <= Json.frame_max(),
        do: {:ok, frame, limits, calls},
        else: {:refused, :invalid_request}
    else
      {:policy, false} -> {:refused, :policy_mismatch}
      {:refused, _} = refusal -> refusal
      _ -> {:refused, :invalid_request}
    end
  end

  defp validate(_), do: {:refused, :invalid_request}

  defp check_limits(%{} = limits) when not is_struct(limits) do
    if Enum.sort(Map.keys(limits)) == @limit_keys and
         Enum.all?(limits, fn {key, value} ->
           is_integer(value) and value >= 1 and value <= @limits[key]
         end) do
      {:ok, limits}
    else
      :error
    end
  end

  defp check_limits(_), do: :error

  defp check_input(input, value_bytes) do
    case Json.check(input, value_bytes) do
      :ok -> :ok
      :size -> {:refused, :value_size}
      :invalid -> {:refused, :invalid_request}
    end
  end

  defp check_calls(%{} = calls, value_bytes) when not is_struct(calls) do
    with true <- Enum.sort(Map.keys(calls)) == @calls_keys,
         %{mode: mode, names: names, recorded: recorded} = calls,
         true <- mode in @modes,
         true <- valid_names?(names),
         true <- is_list(recorded) and length_at_most?(recorded, @max_recorded),
         true <- mode_shape?(mode, names, recorded),
         {:ok, records} <- check_records(recorded, names, value_bytes) do
      {:ok, %{"mode" => mode, "names" => names, "recorded" => records}}
    else
      {:refused, _} = refusal -> refusal
      _ -> {:refused, :invalid_request}
    end
  end

  defp check_calls(_, _), do: {:refused, :invalid_request}

  defp length_at_most?(list, max), do: length_at_most?(list, max, 0)
  defp length_at_most?([], _max, _count), do: true

  defp length_at_most?([_ | rest], max, count) when count < max,
    do: length_at_most?(rest, max, count + 1)

  defp length_at_most?(_, _max, _count), do: false

  defp valid_names?(names) do
    is_list(names) and length_at_most?(names, @max_names) and
      Enum.all?(names, &(is_binary(&1) and Regex.match?(@name_pattern, &1))) and
      length(Enum.uniq(names)) == length(names)
  end

  defp mode_shape?("none", names, recorded), do: names == [] and recorded == []
  defp mode_shape?("data", _names, recorded), do: recorded == []
  defp mode_shape?("replay", _names, _recorded), do: true

  defp check_records(recorded, names, value_bytes) do
    Enum.reduce_while(recorded, {:ok, []}, fn record, {:ok, acc} ->
      case check_record(record, names, value_bytes) do
        {:ok, checked} -> {:cont, {:ok, [checked | acc]}}
        {:refused, _} = refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp check_record(%{} = record, names, value_bytes) when not is_struct(record) do
    with true <- Enum.sort(Map.keys(record)) == @record_keys,
         %{name: name, arguments: arguments, result: result} = record,
         true <- name in names,
         :ok <- check_input(arguments, value_bytes),
         :ok <- check_input(result, value_bytes) do
      {:ok, %{"name" => name, "arguments" => arguments, "result" => result}}
    else
      {:refused, _} = refusal -> refusal
      _ -> {:refused, :invalid_request}
    end
  end

  defp check_record(_, _, _), do: {:refused, :invalid_request}

  defp stringify(limits), do: Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)

  defp interpret(body, limits, calls) do
    case Json.decode(body) do
      {:ok, %{"status" => "ok", "runtime" => runtime, "value" => value} = reply}
      when map_size(reply) == 3 ->
        with {:ok, runtime} <- runtime_map(runtime),
             :ok <- Json.check(value, limits.value_bytes) do
          {:ok, %{value: value, identity: @policy.identity, runtime: runtime}}
        else
          _ -> {:host_outcome, :protocol_error}
        end

      {:ok, %{"status" => "refused", "reason" => reason} = reply}
      when map_size(reply) == 2 and is_map_key(@child_refusals, reason) ->
        {:refused, Map.fetch!(@child_refusals, reason)}

      {:ok, %{"status" => "memory"} = reply} when map_size(reply) == 1 ->
        {:host_outcome, :memory}

      {:ok, %{"status" => "pending", "call" => call} = reply} when map_size(reply) == 2 ->
        pending_call(call, limits, calls)

      _ ->
        {:host_outcome, :protocol_error}
    end
  end

  defp pending_call(
         %{"index" => index, "name" => name, "arguments" => arguments} = call,
         limits,
         %{"mode" => "replay", "names" => names, "recorded" => recorded}
       )
       when map_size(call) == 3 do
    if is_integer(index) and index == length(recorded) and name in names and
         Json.check(arguments, limits.value_bytes) == :ok do
      {:pending_call, %{index: index, name: name, arguments: arguments}}
    else
      {:host_outcome, :protocol_error}
    end
  end

  defp pending_call(_, _, _), do: {:host_outcome, :protocol_error}

  defp runtime_map(%{} = runtime) do
    if Enum.sort(Map.keys(runtime)) == Enum.sort(Map.keys(@runtime_keys)) and
         Enum.all?(runtime, &is_binary(elem(&1, 1))) do
      {:ok, Map.new(runtime, fn {key, value} -> {Map.fetch!(@runtime_keys, key), value} end)}
    else
      :error
    end
  end

  defp runtime_map(_), do: :error
end
