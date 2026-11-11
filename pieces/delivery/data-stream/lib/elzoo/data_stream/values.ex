# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Handle do
  @moduledoc "Process-local reference; authority is the submitting GenServer caller."
  defstruct [:owner, :generation, :ref]
end

defmodule Elzoo.DataStream.Frame do
  @moduledoc "One acknowledged partial text offer."
  defstruct [:handle_ref, :callback_ref, :seq, :chunk, completeness: :partial]
end

defmodule Elzoo.DataStream.FinishFrame do
  @moduledoc "Source-complete offer; its acknowledgement establishes local delivery only."
  defstruct [
    :handle_ref,
    :callback_ref,
    :seq,
    :chunk,
    completeness: :source_complete,
    source_complete: true
  ]
end

defmodule Elzoo.DataStream.Terminal do
  @moduledoc "Bounded authorized local result; Inspect conceals observations and identities."
  defstruct status: :partial,
            reason: :absent,
            provider_reason: :absent,
            source_complete: false,
            delivery_complete: false,
            offered_frames: 0,
            acknowledged_frames: 0,
            received_body_bytes: 0,
            raw_blocks: 0,
            last_usage: :absent,
            incurred_usage: :unknown,
            provenance: :absent,
            correlation: :absent,
            intent_confirmation: :no_attempt,
            retry_after: :unknown

  @doc false
  def maximal_size do
    max = 9_223_372_036_854_775_807
    id = String.duplicate("i", 128)
    local = String.duplicate("i", 64)

    usage = %{
      counters:
        Enum.map(
          [:input_uncached_tokens, :cache_read_tokens, :output_tokens, :reasoning_tokens],
          &%{unit: &1, amount: max}
        ),
      cache_writes: [%{ttl: "1h", amount: max}, %{ttl: "5m", amount: max}],
      convention: %{input_includes_cached: false},
      source: :provider_reported
    }

    t = %__MODULE__{
      status: :partial,
      reason: :credentials_unavailable,
      provider_reason: :authentication_error,
      source_complete: true,
      delivery_complete: true,
      offered_frames: 65_537,
      acknowledged_frames: 65_537,
      received_body_bytes: max,
      raw_blocks: 65_536,
      last_usage: %{usage: usage, event_index: 65_535, stage: :message_start},
      incurred_usage: {:provider_reported, usage},
      provenance: %{
        model_ref: %{provider: "anthropic", model_id: id, wire_surface: "messages"},
        provider_model: id,
        response_id: id,
        request_id: id,
        provider_piece: "delivery/data-stream"
      },
      correlation: %{
        message_id: local,
        correlation_id: local,
        logical_ref: local,
        intent_key: local,
        attempt_id: local <> "/attempt/256"
      },
      intent_confirmation: :unconfirmed,
      retry_after: 86_400
    }

    size(t)
  end

  def size(value), do: value |> plain() |> :erlang.term_to_binary([:deterministic]) |> byte_size()
  def plain(%_{} = s), do: s |> Map.from_struct() |> plain()
  def plain(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, plain(v)} end)
  def plain(l) when is_list(l), do: Enum.map(l, &plain/1)
  def plain(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&plain/1) |> List.to_tuple()
  def plain(v), do: v

  def snapshot(t, phase),
    do:
      Map.take(Map.from_struct(t), [
        :reason,
        :source_complete,
        :delivery_complete,
        :offered_frames,
        :acknowledged_frames,
        :received_body_bytes,
        :raw_blocks
      ])
      |> Map.put(:phase, phase)
end

for module <- [
      Elzoo.DataStream.Handle,
      Elzoo.DataStream.Frame,
      Elzoo.DataStream.FinishFrame,
      Elzoo.DataStream.Terminal,
      Elzoo.DataStream.Framer,
      Elzoo.DataStream.Protocol
    ] do
  defimpl Inspect, for: module do
    def inspect(_, _), do: "#DataStream<redacted>"
  end
end
