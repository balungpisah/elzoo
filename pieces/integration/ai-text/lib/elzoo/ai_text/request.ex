# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Request do
  @moduledoc """
  The text request carried as the Effect command payload (schema
  `elzoo/ai-text-request` version 1): a JSON object with exactly these members.

  - `"version"`: `1`.
  - `"model"`: model identifier, 1..256 bytes.
  - `"messages"`: 1..256 ordered messages. Each is `{"role": "system" | "user" |
    "assistant", "text": string}`, an assistant message may add `"tool_calls":
    [{"id", "name", "arguments": object}]` (earlier proposals echoed back), or
    `{"role": "tool_result", "tool_use_id": id, "text": string, "is_error"?:
    boolean}`. A user message may instead be `{"role": "user", "parts":
    parts}` (Contract amendment 2): 1..64 parts, each `{"type": "text", "text":
    string}` or `{"type": "image", "artifact": {"id": artifact_id, "version":
    1..2^31-1}, "media_type": "image/png" | "image/jpeg" | "image/webp" |
    "image/gif"}`, at least one an image, at most 8 image parts in the request
    (a ninth is `:too_large`). An `artifact_id` is 1..64 bytes of letters,
    digits and `-_.`, never `.` or `..`. A part of another type, `"parts"` on
    another role, an `"image"` or `"document"` member, and a media type outside
    the set are `:unsupported_feature`; `"text"` with `"parts"`, text parts
    only, more than 64 parts or a part with a missing or extra member are
    `:invalid_request`. Normalized, a part is `%{type: :text, text: t}` or
    `%{type: :image, artifact_id: id, version: v, media_type: m}` and the
    message `%{role: :user, parts: parts}`. The request holds references only;
    `Elzoo.AiText.check/2` resolves them.
  - `"tools"` (optional): up to 64 `{"name", "description", "input_schema"}`.
    A tool with a `"type"` member (a provider-executed tool) is refused
    `:unsupported_feature`.
  - `"tool_choice"` (optional): `{"type": "auto" | "none" | "any"}` or
    `{"type": "tool", "name": name}`.
  - `"output_schema"` (optional): a JSON Schema object for structured output.
  - `"max_output_tokens"`: 1..1_000_000.
  - `"stop_sequences"` (optional): up to 16 strings of 1..256 bytes.
  - `"sampling"` (optional): `{"temperature"?: 0..2, "top_p"?: 0..1}`, an
    optional neutral feature (providers declare it or refuse it).
  - `"reasoning"` (optional): `"none" | "low" | "medium" | "high" | "max"`.
  - `"cache_hint"` (optional): `{"tenant", "local_key", "ttl", "breakpoints":
    ["tools" | "system" | {"message": index}]}`.
  - `"provider_options"` (optional): an object, validated by the provider.

  `decode/2` refuses duplicate keys, unknown members, invalid UTF-8 and
  payloads over the byte bound, and returns the normalized request (atom keys)
  and the canonical encoding (sorted keys, no whitespace), which is the
  EffectIntent argument bytes. Errors are fixed atoms; nothing is echoed.
  """
  @max_bytes 65_536
  @top ~w(version model messages tools tool_choice output_schema max_output_tokens stop_sequences sampling reasoning cache_hint provider_options)
  @required ~w(version model messages max_output_tokens)
  @reasoning %{"none" => :none, "low" => :low, "medium" => :medium, "high" => :high, "max" => :max}
  @unsupported_members ~w(image document)
  @media_types ~w(image/png image/jpeg image/webp image/gif)
  @max_parts 64
  @max_images 8
  @max_version 2_147_483_647

  def max_bytes, do: @max_bytes

  @doc "Decodes and normalizes payload bytes; `{:ok, request, canonical}` or `{:error, reason}`."
  def decode(bytes, max \\ @max_bytes)

  def decode(bytes, max) when is_binary(bytes) and is_integer(max) do
    cond do
      byte_size(bytes) > max ->
        {:error, :too_large}

      not String.valid?(bytes) ->
        {:error, :invalid_request}

      true ->
        with {:ok, ordered} <- json(bytes),
             {:ok, value} <- plain(ordered),
             {:ok, request} <- normalize(value) do
          canonical = canonical(value)

          if byte_size(canonical) > max,
            do: {:error, :too_large},
            else: {:ok, request, canonical}
        end
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def decode(_, _), do: {:error, :invalid_request}

  defp json(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, v} -> {:ok, v}
      _ -> {:error, :invalid_request}
    end
  end

  # Ordered objects to maps, refusing duplicate keys at any depth.
  defp plain(%Jason.OrderedObject{values: kvs}) do
    keys = Enum.map(kvs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(kvs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case plain(v) do
          {:ok, pv} -> {:cont, {:ok, Map.put(acc, k, pv)}}
          e -> {:halt, e}
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  defp plain(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case plain(v) do
        {:ok, pv} -> {:cont, {:ok, [pv | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp plain(v), do: {:ok, v}

  @doc "Canonical JSON: object keys sorted, no insignificant whitespace."
  def canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  def canonical(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"
  def canonical(v), do: Jason.encode!(v)

  defp normalize(%{} = v) do
    cond do
      not Enum.all?(Map.keys(v), &(&1 in @top)) -> {:error, :invalid_request}
      not Enum.all?(@required, &Map.has_key?(v, &1)) -> {:error, :invalid_request}
      v["version"] != 1 -> {:error, :invalid_request}
      not text?(v["model"], 256) -> {:error, :invalid_request}
      true -> build(v)
    end
  end

  defp normalize(_), do: {:error, :invalid_request}

  defp build(v) do
    with {:ok, messages} <- messages(v["messages"]),
         :ok <- image_count(messages),
         {:ok, tools} <- tools(Map.get(v, "tools", [])),
         {:ok, choice} <- tool_choice(Map.get(v, "tool_choice")),
         {:ok, output} <- object_or_nil(Map.get(v, "output_schema")),
         {:ok, max} <- max_tokens(v["max_output_tokens"]),
         {:ok, stops} <- stops(Map.get(v, "stop_sequences", [])),
         {:ok, sampling} <- sampling(Map.get(v, "sampling")),
         {:ok, reasoning} <- Map.fetch(@reasoning, Map.get(v, "reasoning", "none")),
         {:ok, hint} <- cache_hint(Map.get(v, "cache_hint")),
         {:ok, options} <- object_or_empty(Map.get(v, "provider_options")) do
      {:ok,
       %{
         model: v["model"],
         messages: messages,
         tools: tools,
         tool_choice: choice,
         output_schema: output,
         max_output_tokens: max,
         stop_sequences: stops,
         sampling: sampling,
         reasoning: reasoning,
         cache_hint: hint,
         provider_options: options
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  defp messages(list) when is_list(list) and length(list) in 1..256 do
    collect(list, &message/1)
  end

  defp messages(_), do: {:error, :invalid_request}

  defp message(%{} = m) do
    cond do
      Enum.any?(@unsupported_members, &Map.has_key?(m, &1)) ->
        {:error, :unsupported_feature}

      Map.has_key?(m, "parts") and m["role"] != "user" ->
        {:error, :unsupported_feature}

      Map.has_key?(m, "parts") ->
        parts_message(m)

      m["role"] in ["system", "user"] and keys?(m, ~w(role text)) and text_body?(m["text"]) ->
        {:ok, %{role: String.to_existing_atom(m["role"]), text: m["text"]}}

      m["role"] == "assistant" and keys?(m, ~w(role text), ~w(tool_calls)) and
          text_body?(m["text"]) ->
        with {:ok, calls} <- collect(Map.get(m, "tool_calls", []), &echoed_call/1),
             true <- length(calls) <= 64 do
          {:ok, %{role: :assistant, text: m["text"], tool_calls: calls}}
        else
          _ -> {:error, :invalid_request}
        end

      m["role"] == "tool_result" and keys?(m, ~w(role tool_use_id text), ~w(is_error)) and
        text?(m["tool_use_id"], 256) and text_body?(m["text"]) and
          is_boolean(Map.get(m, "is_error", false)) ->
        {:ok,
         %{
           role: :tool_result,
           tool_use_id: m["tool_use_id"],
           text: m["text"],
           is_error: Map.get(m, "is_error", false)
         }}

      true ->
        {:error, :invalid_request}
    end
  end

  defp message(_), do: {:error, :invalid_request}

  defp parts_message(m) do
    with true <- keys?(m, ~w(role parts)),
         list when is_list(list) and length(list) in 1..@max_parts <- m["parts"],
         {:ok, parts} <- collect(list, &part/1),
         true <- Enum.any?(parts, &(&1.type == :image)) do
      {:ok, %{role: :user, parts: parts}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  defp part(%{"type" => "text"} = p) do
    if keys?(p, ~w(type text)) and text_body?(p["text"]),
      do: {:ok, %{type: :text, text: p["text"]}},
      else: {:error, :invalid_request}
  end

  defp part(%{"type" => "image"} = p) do
    with true <- keys?(p, ~w(type artifact media_type)),
         %{"id" => id, "version" => v} = a when map_size(a) == 2 <- p["artifact"],
         true <- artifact_id?(id) and is_integer(v) and v in 1..@max_version,
         m when is_binary(m) <- p["media_type"] do
      if m in @media_types,
        do: {:ok, %{type: :image, artifact_id: id, version: v, media_type: m}},
        else: {:error, :unsupported_feature}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp part(%{"type" => t}) when is_binary(t), do: {:error, :unsupported_feature}
  defp part(_), do: {:error, :invalid_request}

  defp image_count(messages) do
    n =
      messages
      |> Enum.flat_map(&Map.get(&1, :parts, []))
      |> Enum.count(&(&1.type == :image))

    if n <= @max_images, do: :ok, else: {:error, :too_large}
  end

  defp artifact_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, id) and
        id not in [".", ".."]

  defp echoed_call(%{"id" => id, "name" => name, "arguments" => args} = c)
       when map_size(c) == 3 and is_map(args) do
    if text?(id, 256) and tool_name?(name),
      do: {:ok, %{id: id, name: name, arguments: args}},
      else: {:error, :invalid_request}
  end

  defp echoed_call(_), do: {:error, :invalid_request}

  defp tools(list) when is_list(list) and length(list) <= 64 do
    with {:ok, tools} <- collect(list, &tool/1),
         names = Enum.map(tools, & &1.name),
         true <- length(Enum.uniq(names)) == length(names) do
      {:ok, tools}
    else
      {:error, r} -> {:error, r}
      _ -> {:error, :invalid_request}
    end
  end

  defp tools(_), do: {:error, :invalid_request}

  defp tool(%{"type" => _}), do: {:error, :unsupported_feature}

  defp tool(%{"name" => n, "description" => d, "input_schema" => s} = t)
       when map_size(t) == 3 and is_map(s) do
    if tool_name?(n) and text_body?(d) and byte_size(d) <= 4096,
      do: {:ok, %{name: n, description: d, input_schema: s}},
      else: {:error, :invalid_request}
  end

  defp tool(_), do: {:error, :invalid_request}

  defp tool_choice(nil), do: {:ok, :auto}
  defp tool_choice(%{"type" => "auto"} = c) when map_size(c) == 1, do: {:ok, :auto}
  defp tool_choice(%{"type" => "none"} = c) when map_size(c) == 1, do: {:ok, :none}
  defp tool_choice(%{"type" => "any"} = c) when map_size(c) == 1, do: {:ok, :any}

  defp tool_choice(%{"type" => "tool", "name" => n} = c) when map_size(c) == 2,
    do: if(tool_name?(n), do: {:ok, {:tool, n}}, else: {:error, :invalid_request})

  defp tool_choice(_), do: {:error, :invalid_request}

  defp max_tokens(n) when is_integer(n) and n in 1..1_000_000, do: {:ok, n}
  defp max_tokens(_), do: {:error, :invalid_request}

  defp stops(list) when is_list(list) and length(list) <= 16 do
    if Enum.all?(list, &(is_binary(&1) and byte_size(&1) in 1..256)),
      do: {:ok, list},
      else: {:error, :invalid_request}
  end

  defp stops(_), do: {:error, :invalid_request}

  defp sampling(nil), do: {:ok, nil}

  defp sampling(%{} = s) when map_size(s) in 1..2 do
    ok =
      Enum.all?(s, fn
        {"temperature", t} -> is_number(t) and t >= 0 and t <= 2
        {"top_p", p} -> is_number(p) and p >= 0 and p <= 1
        _ -> false
      end)

    if ok,
      do: {:ok, %{temperature: s["temperature"], top_p: s["top_p"]}},
      else: {:error, :invalid_request}
  end

  defp sampling(_), do: {:error, :invalid_request}

  defp cache_hint(nil), do: {:ok, nil}

  defp cache_hint(%{"tenant" => t, "local_key" => k, "ttl" => ttl, "breakpoints" => bps} = h)
       when map_size(h) == 4 and is_list(bps) do
    with {:ok, points} <- collect(bps, &breakpoint/1) do
      {:ok, %{tenant: t, local_key: k, ttl: ttl, breakpoints: points}}
    end
  end

  defp cache_hint(_), do: {:error, :invalid_request}

  defp breakpoint("tools"), do: {:ok, :tools}
  defp breakpoint("system"), do: {:ok, :system}

  defp breakpoint(%{"message" => i} = b) when map_size(b) == 1 and is_integer(i) and i >= 0,
    do: {:ok, {:message, i}}

  defp breakpoint(_), do: {:error, :invalid_request}

  defp object_or_nil(nil), do: {:ok, nil}
  defp object_or_nil(%{} = o), do: {:ok, o}
  defp object_or_nil(_), do: {:error, :invalid_request}

  defp object_or_empty(nil), do: {:ok, %{}}
  defp object_or_empty(%{} = o) when map_size(o) <= 32, do: {:ok, o}
  defp object_or_empty(_), do: {:error, :invalid_request}

  defp collect(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp collect(_, _), do: {:error, :invalid_request}

  defp keys?(m, required, optional \\ []) do
    keys = Map.keys(m)
    Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in required or &1 in optional))
  end

  defp text?(v, max), do: Elzoo.AiModel.text?(v, max)

  # Message bodies: valid UTF-8, may contain newlines and tabs, at most the payload bound.
  defp text_body?(v), do: is_binary(v) and String.valid?(v) and byte_size(v) <= @max_bytes

  defp tool_name?(n), do: is_binary(n) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, n)
end
