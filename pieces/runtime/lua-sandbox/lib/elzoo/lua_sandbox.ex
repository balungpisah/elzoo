# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox do
  @moduledoc """
  Bounded Lua evaluation outside the VM (policy version 2, with the safe helper set).

  A trusted host builds the executable once with `build/2` from the installed
  pinned `lua_source` checkout and an owned C host. Each `run/2` starts one fresh
  OS process over an OTP Port, sends one request frame, reads one reply frame and
  reaps the process. There is no pool, no service and no shared state.

  * `build(source_directory, build_directory)` ->
    `{:ok, executable} | {:error, :build_failed}`. Both operands are trusted
    host-supplied paths, never Lua input.
  * `policy()` -> `%{identity: "policy-v2:sha256:<hex>", descriptor: map}`.
  * `run(executable, request)` -> `{:ok, %{value: v, identity: i, runtime: r}}`,
    `{:refused, reason}` or `{:host_outcome, reason}`.

  The request has exactly `source`, `input`, `policy` and `limits`
  (`steps call_depth value_bytes memory_bytes wall_ms`, positive integers with
  the inclusive maxima 1_000_000, 64, 65_536, 16_777_216 and 1_000).
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

  ## Outcomes

  Refusals: `:invalid_request`, `:policy_mismatch`, `:invalid_result`, `:steps`,
  `:call_depth`, `:value_size`, `:unlisted_name`, `:lua_error`. Host outcomes:
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

  The calling process holds the Port. On every return path the child is killed by
  OS pid and its exit report is awaited, so no child outlives `run/2`. If the
  calling process dies, the Port closes the child's input; the child polls for
  that while it runs Lua instructions and also arms a self-termination timer a
  little after `wall_ms`.
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
  @child_refusals %{
    "invalid_request" => :invalid_request,
    "policy_mismatch" => :policy_mismatch,
    "invalid_result" => :invalid_result,
    "steps" => :steps,
    "call_depth" => :call_depth,
    "value_size" => :value_size,
    "unlisted_name" => :unlisted_name,
    "lua_error" => :lua_error
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
  @type host_outcome :: :memory | :wall_time | :process_exit | :protocol_error

  @spec build(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, :build_failed}
  def build(source_directory, build_directory), do: Build.build(source_directory, build_directory)

  @spec policy() :: %{identity: String.t(), descriptor: map()}
  def policy, do: @policy

  @spec run(Path.t(), map()) ::
          {:ok, %{value: term(), identity: String.t(), runtime: map()}}
          | {:refused, refusal()}
          | {:host_outcome, host_outcome()}
  def run(executable, request) when is_binary(executable) do
    started = System.monotonic_time(:millisecond)

    case validate(request) do
      {:ok, frame, limits} ->
        deadline = started + limits.wall_ms

        case Child.exchange(executable, Json.frame(frame), deadline) do
          {:frame, body} -> interpret(body, limits)
          {:host_outcome, _} = outcome -> outcome
        end

      {:refused, _} = refusal ->
        refusal
    end
  end

  defp validate(%{} = request) when not is_struct(request) do
    with true <- Enum.sort(Map.keys(request)) == [:input, :limits, :policy, :source],
         %{source: source, input: input, policy: policy, limits: limits} = request,
         true <- is_binary(policy),
         {:policy, true} <- {:policy, policy == @policy.identity},
         {:ok, limits} <- check_limits(limits),
         true <- is_binary(source) and byte_size(source) <= @source_max and String.valid?(source),
         :ok <- check_input(input, limits.value_bytes) do
      frame =
        Json.encode(%{
          "source" => source,
          "input" => input,
          "policy" => policy,
          "limits" => stringify(limits)
        })

      if byte_size(frame) <= Json.frame_max(),
        do: {:ok, frame, limits},
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

  defp stringify(limits), do: Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)

  defp interpret(body, limits) do
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

      _ ->
        {:host_outcome, :protocol_error}
    end
  end

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
