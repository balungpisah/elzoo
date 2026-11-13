# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.UntrustedContent do
  @moduledoc "One mark for content that must not give orders, and its one rendered form."

  @schema_id "elzoo.untrusted-content.marked"
  @keys ~w(schema_id schema_version sources trust max_bytes content)
  @max_bytes 16_777_216
  @max_sources 16
  @trust %{"untrusted" => :Untrusted, "derived" => :Derived}
  @names %{Untrusted: "untrusted", Derived: "derived"}
  @source ~r/\A[A-Za-z0-9._:\/@-]{1,256}\z/

  @opaque marked :: {:UntrustedContent, map()}

  @doc "Checks a neutral map; the only way to make a marked value."
  def decode(%{} = map) when map_size(map) == 6 do
    with true <- Enum.all?(@keys, &Map.has_key?(map, &1)),
         %{"schema_id" => @schema_id, "schema_version" => 1} <- map,
         true <- sources?(map["sources"]) and is_map_key(@trust, map["trust"]),
         bound when is_integer(bound) and bound in 1..@max_bytes <- map["max_bytes"],
         content when is_binary(content) <- map["content"],
         true <- byte_size(content) <= bound and String.valid?(content) do
      {:ok, {:UntrustedContent, map}}
    else
      _ -> {:error, :invalid_shape}
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  @doc "Returns the neutral map of a marked value."
  def encode({:UntrustedContent, map}), do: map

  @doc "Joins two marked values: content and sources in order, least trusted class, summed bound."
  def concat(a, b) do
    with {:ok, a} <- checked(a),
         {:ok, b} <- checked(b),
         {:ok, sources} <- sources(a["sources"], b["sources"]) do
      bound = a["max_bytes"] + b["max_bytes"]

      if bound > @max_bytes,
        do: {:error, :too_large},
        else:
          decode(%{
            a
            | "sources" => sources,
              "trust" => least_trusted(a["trust"], b["trust"]),
              "max_bytes" => bound,
              "content" => a["content"] <> b["content"]
          })
    end
  end

  @doc "Puts the mark of a second source around a marked value."
  def wrap(marked, source, trust) do
    with {:ok, inner} <- checked(marked),
         :ok <-
           if(source?(source) and is_map_key(@trust, trust),
             do: :ok,
             else: {:error, :invalid_shape}
           ),
         {:ok, sources} <- sources([source], inner["sources"]) do
      decode(%{inner | "sources" => sources, "trust" => least_trusted(trust, inner["trust"])})
    end
  end

  @doc "The one format of a marked value in a model request."
  def render(marked) do
    with {:ok, %{"content" => content} = map} <- checked(marked) do
      tag = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 32)

      label =
        "trust=#{map["trust"]} bytes=#{byte_size(content)} sources=#{Enum.join(map["sources"], ",")}"

      {:ok,
       "<<<untrusted-content #{tag} #{label}>>>\n#{content}\n<<<end untrusted-content #{tag}>>>"}
    end
  end

  defp checked({:UntrustedContent, map}) do
    case decode(map) do
      {:ok, _} -> {:ok, map}
      _ -> {:error, :unmarked}
    end
  end

  defp checked(_), do: {:error, :unmarked}

  defp sources(first, second) do
    joined = first ++ Enum.reject(second, &(&1 in first))
    if length(joined) > @max_sources, do: {:error, :too_many_sources}, else: {:ok, joined}
  end

  # Cure owns the class decision; Elixir only translates the two texts.
  defp least_trusted(a, b),
    do: @names[apply(:"Cure.Elzoo.UntrustedContent", :least_trusted, [@trust[a], @trust[b]])]

  defp sources?(list) when is_list(list) and list != [] and length(list) <= @max_sources,
    do: Enum.all?(list, &source?/1) and length(Enum.uniq(list)) == length(list)

  defp sources?(_), do: false

  defp source?(source), do: is_binary(source) and Regex.match?(@source, source)
end
