# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ToolRegistry do
  @moduledoc """
  Pure resolution of a model-proposed tool name to one callable over a caller-supplied
  snapshot of tool listings. Owns the alias, the descriptor version and the resolution;
  lists, dispatches and authorizes nothing. See the bundle README for the snapshot form.
  """
  alias Elzoo.AiText.Request
  alias Elzoo.PayloadSchema

  @kinds ~w(pinned_skill host_listing other)
  @callables %{"adapter" => :adapter, "nested" => :nested}
  @source_keys ~w(callable id kind tools)
  @descriptor_keys ~w(annotations description input_schema name trust)
  @max_tools 64
  @max_description 4096

  @doc "Validates the declared sources; `{:ok, snapshot}` or `{:error, reason}`."
  def snapshot(sources) do
    with {:ok, entries} <- index(sources), do: {:ok, {:ToolRegistry, sources, entries, %{}}}
  end

  @doc "Replaces the listing of one declared source and records its removed aliases."
  def refresh({:ToolRegistry, sources, entries, removed}, source_id, descriptors) do
    case Enum.find_index(sources, &(&1["id"] == source_id)) do
      nil ->
        {:error, :unknown_source}

      at ->
        fresh = List.update_at(sources, at, &Map.put(&1, "tools", descriptors))

        with {:ok, fresh_entries} <- index(fresh) do
          gone = aliases(entries, source_id) -- aliases(fresh_entries, source_id)
          {:ok, {:ToolRegistry, fresh, fresh_entries, Map.put(removed, source_id, gone)}}
        end
    end
  end

  @doc "Listed tools in the ai-text tool shape, sorted by alias."
  def tools({:ToolRegistry, _, entries, _}) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, {tool, description}} ->
      %{"name" => name, "description" => description, "input_schema" => tool.input_schema}
    end)
  end

  @doc "Resolves a proposed name to one listed tool, or to an explicit non-resolution."
  def resolve(snapshot, name), do: decide(snapshot, name, false, nil)

  @doc "As `resolve/2`, comparing the version that the caller holds for the name."
  def resolve(snapshot, name, version), do: decide(snapshot, name, true, version)

  @doc "The one argument check before dispatch, with the argument Port of the tool."
  def check(%{alias: name, version: version, input_schema: schema}, arguments) do
    port = port(name, version)

    with {:ok, checked} <- PayloadSchema.build(port, schema),
         :ok <- PayloadSchema.check(checked, port, arguments) do
      :ok
    else
      {:error, reason} -> {:error, {:validator_disagreement, reason}}
    end
  end

  @doc "Names a local mcp-client argument refusal after `check/2` passed."
  def outcome_note({:refused, :invalid_arguments}), do: :validator_disagreement
  def outcome_note(_outcome), do: :none

  defp decide({:ToolRegistry, _, entries, removed}, name, given, version) do
    listed = Map.get(entries, name)
    owners = for {_, {%{tool: ^name} = tool, _}} <- entries, do: tool.alias

    decision =
      apply(:"Cure.Elzoo.ToolRegistry", :decide, [
        listed != nil,
        given and listed != nil and elem(listed, 0).version != version,
        Enum.any?(removed, fn {_, gone} -> name in gone end),
        length(owners) >= 2
      ])

    case decision do
      :Resolved -> {:resolved, elem(listed, 0)}
      :Changed -> {:changed, elem(listed, 0).version}
      :Removed -> :removed
      :Ambiguous -> {:ambiguous, Enum.sort(owners)}
      :Unknown -> :unknown
    end
  end

  defp aliases(entries, source_id),
    do: for({name, {%{source: ^source_id}, _}} <- entries, do: name) |> Enum.sort()

  # The first failing check in this order gives the reason.
  defp index(sources) do
    cond do
      not sources?(sources) ->
        {:error, :invalid_source}

      not Enum.all?(sources, &descriptors?(&1["id"], &1["tools"])) ->
        {:error, :invalid_descriptor}

      not Enum.all?(sources, fn s -> Enum.all?(s["tools"], &(&1["trust"] == "untrusted")) end) ->
        {:error, :invalid_trust}

      Enum.sum_by(sources, &length(&1["tools"])) > @max_tools ->
        {:error, :too_many_tools}

      true ->
        entries = for source <- sources, descriptor <- source["tools"], do: entry(source, descriptor)
        index = Map.new(entries, &{elem(&1, 0).alias, &1})

        if map_size(index) == length(entries),
          do: {:ok, index},
          else: {:error, :alias_collision}
    end
  end

  defp sources?(sources) do
    proper?(sources) and
      Enum.all?(sources, fn source ->
        plain_map?(source) and Enum.sort(Map.keys(source)) == @source_keys and
          is_binary(source["id"]) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,32}\z/, source["id"]) and
          source["kind"] in @kinds and Map.has_key?(@callables, source["callable"]) and
          proper?(source["tools"])
      end) and
      length(Enum.uniq_by(sources, & &1["id"])) == length(sources)
  end

  defp descriptors?(id, descriptors) do
    Enum.all?(descriptors, &descriptor?(id, &1)) and
      length(Enum.uniq_by(descriptors, & &1["name"])) == length(descriptors)
  end

  defp descriptor?(id, d) do
    plain_map?(d) and Enum.sort(Map.keys(d)) == @descriptor_keys and is_binary(d["name"]) and
      Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, d["name"]) and
      (is_nil(d["description"]) or (is_binary(d["description"]) and String.valid?(d["description"]))) and
      (is_nil(d["annotations"]) or (plain_map?(d["annotations"]) and json?(d["annotations"]))) and
      plain_map?(d["input_schema"]) and json?(d["input_schema"]) and
      match?({:ok, _}, PayloadSchema.build(port(alias_of(id, d["name"]), version(d)), d["input_schema"]))
  end

  defp entry(source, d) do
    name = alias_of(source["id"], d["name"])
    version = version(d)

    tool = %{
      alias: name,
      source: source["id"],
      source_kind: source["kind"],
      callable: {Map.fetch!(@callables, source["callable"]), source["id"], d["name"]},
      tool: d["name"],
      version: version,
      input_schema: d["input_schema"]
    }

    {tool, description(d["description"], d["name"])}
  end

  defp alias_of(id, name) do
    plain = id <> "_" <> name

    if Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, plain) do
      plain
    else
      kept = for <<byte <- binary_part(plain, 0, min(55, byte_size(plain)))>>, into: "", do: safe(byte)
      digest = :crypto.hash(:sha256, id <> <<0>> <> name) |> Base.encode16(case: :lower)
      kept <> "_" <> binary_part(digest, 0, 8)
    end
  end

  defp safe(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-],
    do: <<byte>>

  defp safe(_), do: "_"

  defp version(d) do
    :crypto.hash(:sha256, Request.canonical(Map.delete(d, "trust"))) |> Base.encode16(case: :lower)
  end

  defp description(text, name) when text in [nil, ""], do: name
  defp description(text, _) when byte_size(text) <= @max_description, do: text
  defp description(text, _), do: whole(binary_part(text, 0, @max_description))

  defp whole(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: whole(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  defp port(name, version) do
    %{
      "id" => name,
      "direction" => "input",
      "schema_id" => "elzoo.tool-registry.arguments." <> version,
      "schema_version" => 1
    }
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?([]), do: true
  defp json?([head | rest]), do: json?(head) and is_list(rest) and json?(rest)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(_), do: false
end
