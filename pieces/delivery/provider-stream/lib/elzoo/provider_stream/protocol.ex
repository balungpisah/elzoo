# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream.Protocol do
  @moduledoc false
  # Pure reader of one Anthropic event stream, one raw block at a time. It reads
  # the members named in the Contract, checks their types and ignores each other
  # member, each other event type and each comment block. It assembles the
  # result inside the byte bound.
  alias Elzoo.AiModel.{Provenance, Usage}
  alias Elzoo.ProviderStream.Chunk

  defstruct [
    :limit,
    :id,
    :model,
    :open,
    :stop_reason,
    phase: :start,
    next: 0,
    size: 0,
    content: "",
    calls: [],
    counters: %{}
  ]

  @counters %{
    "input_tokens" => :input,
    "output_tokens" => :output,
    "cache_read_input_tokens" => :cache_read,
    "cache_creation_input_tokens" => :cache_write
  }

  def new(limit), do: %__MODULE__{limit: limit}

  # {:ok, state, nil | {kind, payload}} | {:stop, state} | {:error, reason}
  def block(s, raw) do
    case ServerSentEvents.Parser.parse(raw) do
      {[], _} -> {:ok, s, nil}
      {[%{data: data} = e], _} -> decode(s, Map.get(e, :event), data)
      _ -> {:error, :malformed_response}
    end
  end

  defp decode(s, name, data) do
    with {:ok, %{"type" => type} = m} when is_binary(type) <- Jason.decode(data),
         true <- name in [nil, type] do
      event(s, type, m)
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp event(%{phase: :stopped}, _, _), do: {:error, :malformed_response}
  defp event(s, "ping", _), do: {:ok, s, nil}
  defp event(_, "error", _), do: {:error, :stream_error}

  defp event(%{phase: :start} = s, "message_start", %{"message" => %{} = m}) do
    with true <- is_binary(m["id"]) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, m["id"]),
         true <- Elzoo.AiModel.text?(m["model"], 256),
         {:ok, s} <- usage(s, m) do
      {:ok, %{s | phase: :message, id: m["id"], model: m["model"]}, nil}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp event(%{phase: :message, next: i} = s, "content_block_start", %{"index" => i} = m)
       when i < 64 do
    case m["content_block"] do
      %{"type" => "text", "text" => t} when is_binary(t) ->
        s = %{s | phase: :block, next: i + 1, open: %{index: i, kind: :text}}
        text(s, t)

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        if Chunk.tool_id?(id) and Chunk.tool_name?(name) and input == %{} do
          s = %{s | phase: :block, next: i + 1, open: %{index: i, kind: :tool, args: ""}}

          with {:ok, s} <- grow(s, byte_size(id) + byte_size(name)) do
            calls = [%{id: id, name: name, arguments_json: ""} | s.calls]
            {:ok, %{s | calls: calls}, {:tool_start, %{index: i, id: id, name: name}}}
          end
        else
          {:error, :malformed_response}
        end

      %{"type" => type} when is_binary(type) and type not in ["text", "tool_use"] ->
        {:error, :unsupported_response}

      _ ->
        {:error, :malformed_response}
    end
  end

  defp event(%{phase: :block, open: %{index: i} = open} = s, "content_block_delta", m) do
    case {m["index"], open.kind, m["delta"]} do
      {^i, :text, %{"type" => "text_delta", "text" => t}} when is_binary(t) ->
        text(s, t)

      {^i, :tool, %{"type" => "input_json_delta", "partial_json" => j}} when is_binary(j) ->
        tool_delta(s, j)

      {^i, _, %{"type" => type}} when type in ["text_delta", "input_json_delta"] ->
        {:error, :malformed_response}

      {^i, _, %{"type" => type}} when is_binary(type) ->
        {:error, :unsupported_response}

      _ ->
        {:error, :malformed_response}
    end
  end

  defp event(%{phase: :block, open: %{index: i} = open} = s, "content_block_stop", %{"index" => i}) do
    s = %{s | phase: :message, open: nil}

    case open.kind do
      :text -> {:ok, s, nil}
      :tool -> close_tool(s, open.args)
    end
  end

  defp event(%{phase: phase} = s, "message_delta", %{"delta" => %{"stop_reason" => r}} = m)
       when phase in [:message, :stopping] and is_binary(r) do
    case usage(s, m) do
      {:ok, s} -> {:ok, %{s | phase: :stopping, stop_reason: r}, nil}
      _ -> {:error, :malformed_response}
    end
  end

  defp event(%{phase: :stopping} = s, "message_stop", _), do: {:stop, %{s | phase: :stopped}}

  defp event(_, type, _)
       when type in ~w(message_start content_block_start content_block_delta content_block_stop message_delta message_stop),
       do: {:error, :malformed_response}

  defp event(s, _other, _), do: {:ok, s, nil}

  defp text(s, ""), do: {:ok, s, nil}

  defp text(s, t) do
    with {:ok, s} <- grow(s, byte_size(t)) do
      {:ok, %{s | content: s.content <> t}, {:text_delta, t}}
    end
  end

  defp tool_delta(s, ""), do: {:ok, s, nil}

  defp tool_delta(%{open: open} = s, j) do
    with {:ok, s} <- grow(s, byte_size(j)) do
      {:ok, %{s | open: %{open | args: open.args <> j}},
       {:tool_delta, %{index: open.index, delta: j}}}
    end
  end

  defp close_tool(%{calls: [call | rest]} = s, joined) do
    {args, extra} = if joined == "", do: {"{}", 2}, else: {joined, 0}

    with {:ok, %{}} <- Jason.decode(args),
         {:ok, s} <- grow(s, extra) do
      {:ok, %{s | calls: [%{call | arguments_json: args} | rest]}, nil}
    else
      {:error, :result_limit} -> {:error, :result_limit}
      _ -> {:error, :malformed_response}
    end
  end

  defp grow(s, n) do
    if s.size + n > s.limit,
      do: {:error, :result_limit},
      else: {:ok, %{s | size: s.size + n}}
  end

  # The last report that names a counter counts; null names nothing.
  defp usage(s, %{"usage" => %{} = u}) do
    Enum.reduce_while(@counters, {:ok, s}, fn {key, counter}, {:ok, s} ->
      case Map.get(u, key) do
        nil ->
          {:cont, {:ok, s}}

        n when is_integer(n) and n >= 0 ->
          {:cont, {:ok, %{s | counters: Map.put(s.counters, counter, n)}}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp usage(s, m) when not is_map_key(m, "usage"), do: {:ok, s}
  defp usage(_, _), do: :error

  def result(%{phase: :stopped} = s, model, request_id) do
    c = s.counters

    {:ok, usage} =
      Usage.from_provider(
        %{
          input: Map.get(c, :input, :unknown),
          output: Map.get(c, :output, :unknown),
          cache_read: Map.get(c, :cache_read, :unknown),
          cache_writes: [%{ttl: "provider_default", amount: Map.get(c, :cache_write, :unknown)}]
        },
        %{input_includes_cached: false},
        :provider_reported
      )

    {:ok, provenance} =
      Provenance.validate(%{
        model_ref: %{provider: "anthropic", model_id: model, wire_surface: "messages"},
        provider_model: s.model,
        response_id: s.id,
        request_id: request_id,
        provider_piece: "delivery/provider-stream"
      })

    %{
      content: s.content,
      tool_calls: Enum.reverse(s.calls),
      finish: finish(s.stop_reason),
      usage: usage,
      provenance: provenance
    }
  end

  # The mapping of Elzoo.AiText.Anthropic, kept equal to it.
  def finish("end_turn"), do: :stop
  def finish("stop_sequence"), do: :stop
  def finish("max_tokens"), do: :length
  def finish("tool_use"), do: :tool_calls
  def finish("refusal"), do: :refusal

  def finish(raw),
    do: if(Elzoo.AiModel.text?(raw, 64), do: {:other, raw}, else: {:other, "unrecognized"})
end
