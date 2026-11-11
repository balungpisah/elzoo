# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Protocol do
  @moduledoc false
  alias Elzoo.DataStream.{JSON, Usage}

  @finishes %{
    "end_turn" => :stop,
    "max_tokens" => :length,
    "refusal" => :refusal,
    "model_context_window_exceeded" => :context_limit
  }
  @errors %{
    "invalid_request_error" => :invalid_request_error,
    "authentication_error" => :authentication_error,
    "billing_error" => :billing_error,
    "permission_error" => :permission_error,
    "not_found_error" => :not_found_error,
    "conflict_error" => :conflict_error,
    "request_too_large" => :request_too_large,
    "rate_limit_error" => :rate_limit_error,
    "api_error" => :api_error,
    "timeout_error" => :timeout_error,
    "overloaded_error" => :overloaded_error
  }
  defstruct [
    :model,
    :request_id,
    :usage,
    parser: nil,
    phase: :start,
    open: nil,
    next: 0,
    finish: nil,
    index: 0,
    last_usage: :absent,
    incurred_usage: :unknown,
    provenance: :absent,
    delta_output: false,
    provider_reason: :absent
  ]

  def new(model, request_id),
    do: %__MODULE__{
      model: model,
      request_id: request_id,
      usage: Usage.new(),
      parser: ServerSentEvents.Parser.new()
    }

  def block(bytes, s) do
    case ServerSentEvents.Parser.parse(s.parser, bytes) do
      {[], parser} ->
        {:ok, %{s | parser: parser}}

      {[%{event: name, data: data}], parser} ->
        with {:ok, m} when is_map(m) <- JSON.decode(data),
             {:ok, s, action} <- event(%{s | parser: parser}, name, m) do
          {:ok, s, action}
        else
          {:error, r} -> {:error, r, s}
          _ -> {:error, :malformed_response, s}
        end

      _ ->
        {:error, :malformed_response, s}
    end
  rescue
    _ -> {:error, :malformed_response, s}
  end

  def event(s, name, m) do
    with true <- is_map(m) and m["type"] == name,
         {:ok, next, action} <- transition(s, name, m) do
      {:ok, %{next | index: s.index + 1}, action}
    else
      false -> {:error, :malformed_response}
      e -> e
    end
  end

  defp transition(%{phase: phase}, _, _) when phase == :stopped, do: {:error, :malformed_response}
  defp transition(s, "ping", m), do: with(:ok <- shape(m, ["type"], []), do: {:ok, s, :none})

  defp transition(s, "error", m) do
    with :ok <- shape(m, ~w(type error), ["request_id"]),
         e when is_map(e) <- m["error"],
         :ok <- shape(e, ~w(type message), []),
         true <- is_binary(e["type"]) and Regex.match?(~r/\A[\x21-\x7e]{1,64}\z/, e["type"]),
         true <- text?(e["message"], 16_384),
         true <- not Map.has_key?(m, "request_id") or id?(m["request_id"]) do
      {:ok, %{s | provider_reason: Map.get(@errors, e["type"], :provider_error)}, :stream_error}
    else
      false -> {:error, :malformed_response}
      {:error, _} = e -> e
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: :start} = s, "message_start", m) do
    with :ok <- shape(m, ~w(type message), []),
         a when is_map(a) <- m["message"],
         :ok <- shape(a, ~w(id type role model content stop_reason stop_sequence), ["usage"]),
         true <- id?(a["id"]) and model?(a["model"]),
         true <-
           a["type"] == "message" and a["role"] == "assistant" and a["content"] == [] and
             is_nil(a["stop_reason"]) and is_nil(a["stop_sequence"]),
         {:ok, s} <- observe_usage(s, a, :message_start),
         {:ok, p} <-
           Elzoo.AiModel.Provenance.validate(%{
             model_ref: %{provider: "anthropic", model_id: s.model, wire_surface: "messages"},
             provider_model: :binary.copy(a["model"]),
             response_id: :binary.copy(a["id"]),
             request_id: s.request_id,
             provider_piece: "delivery/data-stream"
           }) do
      {:ok, %{s | phase: :content, provenance: p}, :none}
    else
      {:error, r} -> {:error, r}
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: :content, open: nil, next: n} = s, "content_block_start", m)
       when n < 64 do
    with :ok <- shape(m, ~w(type index content_block), []),
         true <- is_integer(m["index"]) and m["index"] == n,
         b when is_map(b) <- m["content_block"],
         :ok <- shape(b, ~w(type text), []),
         :ok <- variant(b["type"], "text"),
         true <- text?(b["text"], 65_536) do
      action = if b["text"] == "", do: :none, else: {:text, :binary.copy(b["text"])}
      {:ok, %{s | open: n, next: n + 1}, action}
    else
      {:error, _} = e -> e
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: :content, open: n} = s, "content_block_delta", m) when is_integer(n) do
    with :ok <- shape(m, ~w(type index delta), []),
         true <- is_integer(m["index"]) and m["index"] == n,
         d when is_map(d) <- m["delta"],
         :ok <- shape(d, ~w(type text), []),
         :ok <- variant(d["type"], "text_delta"),
         true <- text?(d["text"], 65_536) do
      {:ok, s, {:text, :binary.copy(d["text"])}}
    else
      {:error, _} = e -> e
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: :content, open: n} = s, "content_block_stop", m) when is_integer(n) do
    with :ok <- shape(m, ~w(type index), []), true <- is_integer(m["index"]) and m["index"] == n do
      {:ok, %{s | open: nil}, :none}
    else
      {:error, _} = e -> e
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: p, open: nil} = s, "message_delta", m) when p in [:content, :delta] do
    with :ok <- shape(m, ~w(type delta), ["usage"]),
         d when is_map(d) <- m["delta"],
         :ok <- shape(d, [], ~w(stop_reason stop_sequence)),
         true <- is_nil(d["stop_sequence"]),
         {:ok, finish} <- finish(s.finish, Map.get(d, "stop_reason")),
         {:ok, s} <- observe_usage(s, m, :message_delta) do
      {:ok, %{s | phase: :delta, finish: finish}, :none}
    else
      false -> {:error, :unsupported_response}
      {:error, _} = e -> e
      _ -> {:error, :malformed_response}
    end
  end

  defp transition(%{phase: :delta, finish: f} = s, "message_stop", m) when not is_nil(f) do
    with :ok <- shape(m, ["type"], []),
         {:ok, u} <-
           Usage.value(if(s.delta_output, do: s.usage, else: %{s.usage | output: :unknown})) do
      {:ok, %{s | phase: :stopped, incurred_usage: {:provider_reported, u}}, :stop}
    end
  end

  defp transition(_, name, _)
       when name in ~w(message_start content_block_start content_block_delta content_block_stop message_delta message_stop),
       do: {:error, :malformed_response}

  defp transition(_, _, _), do: {:error, :unsupported_response}

  defp observe_usage(s, m, stage) do
    case Map.fetch(m, "usage") do
      :error ->
        {:ok, s}

      {:ok, raw} ->
        with {:ok, r} <- Usage.merge(s.usage, raw), {:ok, u} <- Usage.value(r) do
          output =
            stage == :message_delta and
              (is_nil(raw) or Map.has_key?(raw, "output_tokens"))

          {:ok,
           %{
             s
             | usage: r,
               last_usage: %{usage: u, event_index: s.index, stage: stage},
               delta_output: s.delta_output or output
           }}
        end
    end
  end

  defp finish(old, nil), do: {:ok, old}

  defp finish(nil, value) do
    case Map.fetch(@finishes, value) do
      {:ok, f} -> {:ok, f}
      _ -> {:error, :unsupported_response}
    end
  end

  defp finish(_, _), do: {:error, :malformed_response}
  defp variant(a, a), do: :ok
  defp variant(_, _), do: {:error, :unsupported_response}

  def shape(m, req, opt) do
    cond do
      not is_map(m) -> {:error, :malformed_response}
      not Enum.all?(Map.keys(m), &(&1 in req or &1 in opt)) -> {:error, :unsupported_response}
      not Enum.all?(req, &Map.has_key?(m, &1)) -> {:error, :malformed_response}
      true -> :ok
    end
  end

  def text?(b, max), do: is_binary(b) and byte_size(b) <= max and String.valid?(b)
  def id?(b), do: is_binary(b) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, b)
  def model?(b), do: is_binary(b) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,128}\z/, b)
end
