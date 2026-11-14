defmodule Elzoo.Skill do
  @moduledoc """
  Pure reader of a skill folder that the caller gives as data.

  `read/4` turns a map of relative paths to file bytes into the skill entry of a
  recipe package and the other files of the folder. It reads no file system,
  starts no process and checks nothing of the entry that `Elzoo.RecipePackage`
  checks. Refusals are fixed atoms that hold no path, file byte, frontmatter
  value or body.
  """

  @max_files 256
  @max_file_bytes 1_048_576
  @max_folder_bytes 8_388_608
  @max_path_bytes 1_024
  @max_frontmatter_bytes 16_384

  @type reason ::
          :invalid_input
          | :invalid_path
          | :folder_too_large
          | :missing_skill_md
          | :invalid_utf8
          | :missing_frontmatter
          | :frontmatter_too_large
          | :invalid_yaml
          | :not_a_map
          | :tab_indentation
          | :yaml_alias
          | :duplicate_key
          | :empty_body

  @doc """
  Reads the skill folder `files` (relative path to bytes) of the skill `name`.

  `version` and `tools` are what the caller declares for the skill. Gives
  `{:ok, %{entry: entry, files: rest}}`, where `entry` has the members `"name"`,
  `"version"`, `"tools"`, `"frontmatter"` and `"body"` and `rest` is `files`
  without `"SKILL.md"`, or `{:error, reason}`. The first failing check, in the
  order of the Contract, is the result.
  """
  @spec read(term(), term(), term(), term()) ::
          {:ok,
           %{entry: %{optional(String.t()) => term()}, files: %{optional(binary()) => binary()}}}
          | {:error, reason()}
  def read(name, version, tools, files) do
    with :ok <- check_input(name, version, tools, files),
         :ok <- check_paths(files),
         :ok <- check_bounds(files),
         {:ok, skill_md} <- fetch_skill_md(files),
         :ok <- check_utf8(skill_md),
         {:ok, frontmatter, body} <- split(skill_md),
         :ok <- check_frontmatter_size(frontmatter),
         {:ok, text} <- scan(frontmatter),
         :ok <- check_not_blank(text),
         {:ok, map} <- parse(text),
         :ok <- check_body(body) do
      entry = %{
        "name" => name,
        "version" => version,
        "tools" => tools,
        "frontmatter" => map,
        "body" => body
      }

      {:ok, %{entry: entry, files: Map.delete(files, "SKILL.md")}}
    end
  end

  defp check_input(name, version, tools, files)
       when is_binary(name) and is_binary(version) and is_list(tools) and is_map(files) do
    if Enum.all?(files, fn {path, bytes} -> is_binary(path) and is_binary(bytes) end) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp check_input(_name, _version, _tools, _files), do: {:error, :invalid_input}

  defp check_paths(files) do
    if Enum.all?(files, fn {path, _bytes} -> valid_path?(path) end) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  defp valid_path?(path) do
    byte_size(path) in 1..@max_path_bytes and String.valid?(path) and
      not String.contains?(path, [<<0>>, "\\"]) and
      not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."]))
  end

  defp check_bounds(files) do
    sizes = Enum.map(files, fn {_path, bytes} -> byte_size(bytes) end)

    if map_size(files) > @max_files or Enum.any?(sizes, &(&1 > @max_file_bytes)) or
         Enum.sum(sizes) > @max_folder_bytes do
      {:error, :folder_too_large}
    else
      :ok
    end
  end

  defp fetch_skill_md(%{"SKILL.md" => skill_md}), do: {:ok, skill_md}
  defp fetch_skill_md(_files), do: {:error, :missing_skill_md}

  defp check_utf8(skill_md) do
    if String.valid?(skill_md), do: :ok, else: {:error, :invalid_utf8}
  end

  defp split("---\n" <> rest), do: find_closing(rest, rest, 0)
  defp split("---\r\n" <> rest), do: find_closing(rest, rest, 0)
  defp split(_skill_md), do: {:error, :missing_frontmatter}

  defp find_closing(all, rest, offset) do
    case :binary.split(rest, "\n") do
      [line, remaining] ->
        if line in ["---", "---\r"] do
          {:ok, binary_part(all, 0, offset), remaining}
        else
          find_closing(all, remaining, offset + byte_size(line) + 1)
        end

      ["---"] ->
        {:ok, binary_part(all, 0, offset), ""}

      _other ->
        {:error, :missing_frontmatter}
    end
  end

  defp check_frontmatter_size(frontmatter) do
    if byte_size(frontmatter) > @max_frontmatter_bytes do
      {:error, :frontmatter_too_large}
    else
      :ok
    end
  end

  # The scan finds the places where a YAML node can begin; it is not a YAML
  # reader. Pass 1 makes the text `T`, pass 2 looks at every line for a
  # document marker, pass 3 reads the lines in order. The first refusal ends it.
  defp scan(frontmatter) do
    text = String.replace(frontmatter, "\r\n", "\n")
    lines = String.split(text, "\n")

    cond do
      String.contains?(text, "\r") -> {:error, :invalid_yaml}
      Enum.any?(lines, &document_marker?/1) -> {:error, :not_a_map}
      true -> scan_lines(lines, nil, MapSet.new(), text)
    end
  end

  defp document_marker?(line) do
    line in ["---", "..."] or String.starts_with?(line, ["--- ", "---\t", "... ", "...\t"])
  end

  # `region` is nil or `{:block | :flow, opening_column}`; `seen` holds the
  # top-level keys of the earlier lines.
  defp scan_lines([], _region, _seen, text), do: {:ok, text}

  defp scan_lines([line | lines], region, seen, text) do
    {indent, rest} = drop_spaces(line)

    if region_line?(region, indent, rest) do
      with :ok <- scan_region_line(region, line), do: scan_lines(lines, region, seen, text)
    else
      case scan_line(indent, rest, seen) do
        {:ok, region, seen} -> scan_lines(lines, region, seen, text)
        {:error, _reason} = error -> error
      end
    end
  end

  defp region_line?(nil, _indent, _rest), do: false

  defp region_line?({kind, column}, indent, rest) do
    blank?(rest) or indent > column or (kind == :flow and comment?(rest))
  end

  # Block text is not scanned. In a flow region `<<` is an alias anywhere, and
  # so is `&` or `*` first on the line or after `[`, `{`, `,` or `:` and spaces
  # or tabs. Quotes are not tracked.
  defp scan_region_line({:block, _column}, _line), do: :ok
  defp scan_region_line({:flow, _column}, line), do: flow_text(line)

  defp flow_text(text) do
    if Regex.match?(~r/<<|\A[ \t]*[&*]|[\[{,:][ \t]*[&*]/, text),
      do: {:error, :yaml_alias},
      else: :ok
  end

  defp scan_line(indent, rest, seen) do
    cond do
      blank?(rest) or comment?(rest) ->
        {:ok, nil, seen}

      String.starts_with?(rest, "\t") ->
        {:error, :tab_indentation}

      true ->
        {text, column, indicator} = drop_indicators(rest, indent, nil)
        # A node text with no key and no indicator opens its region at the
        # column of the node text itself, which is `indent`: the line is the
        # key's own line.
        scan_node(text, column, indicator || indent, indent == 0 and indicator == nil, seen)
    end
  end

  defp blank?(text), do: Regex.match?(~r/\A[ \t]*\z/, text)
  defp comment?(text), do: String.starts_with?(text, "#")

  # Drops each leading `- `, `? ` or `: ` with its spaces and a last lone `-`;
  # `indicator` is the column of the last one dropped.
  defp drop_indicators(<<c, " ", more::binary>>, column, _indicator) when c in [?-, ??, ?:] do
    {spaces, rest} = drop_spaces(more)
    drop_indicators(rest, column + 2 + spaces, column)
  end

  defp drop_indicators("-", column, _indicator), do: {"", column + 1, column}
  defp drop_indicators(text, column, indicator), do: {text, column, indicator}

  defp drop_spaces(text), do: drop_spaces(text, 0)
  defp drop_spaces(<<" ", rest::binary>>, count), do: drop_spaces(rest, count + 1)
  defp drop_spaces(rest, count), do: {count, rest}

  # Spaces and tabs: the separation around a `:` and after a tag.
  defp drop_blanks(text), do: drop_blanks(text, 0)

  defp drop_blanks(<<c, rest::binary>>, count) when c in [?\s, ?\t],
    do: drop_blanks(rest, count + 1)

  defp drop_blanks(rest, count), do: {count, rest}

  # Scans the node text `text`, which starts at `column`. `region` is the
  # opening column of a region that starts here, `top?` tells that a key found
  # here is a top-level key.
  defp scan_node("", _column, _region, _top?, seen), do: {:ok, nil, seen}

  defp scan_node(<<c, _::binary>>, _column, _region, _top?, _seen) when c in [?&, ?*],
    do: {:error, :yaml_alias}

  defp scan_node("!" <> _ = text, column, region, top?, seen) do
    case :binary.split(text, [" ", "\t"]) do
      [_tag] ->
        {:ok, nil, seen}

      [tag, more] ->
        {blanks, rest} = drop_blanks(more)
        scan_node(rest, column + byte_size(tag) + 1 + blanks, region, top?, seen)
    end
  end

  defp scan_node(<<c, _::binary>> = text, _column, region, _top?, seen) when c in [?[, ?{] do
    with :ok <- flow_text(text), do: {:ok, {:flow, region}, seen}
  end

  defp scan_node(<<q, _::binary>> = text, column, _region, top?, seen) when q in [?', ?"] do
    scan_quoted(text, column, top?, seen)
  end

  defp scan_node(text, column, region, top?, seen) do
    if block_indicator?(text) do
      {:ok, {:block, region}, seen}
    else
      scan_plain(text, column, top?, seen)
    end
  end

  defp block_indicator?(text), do: Regex.match?(~r/\A[|>][+\-1-9]{0,2}(?: +(?:#.*)?)?\z/, text)

  defp scan_quoted(<<q, body::binary>>, column, top?, seen) do
    case quote_end(q, body, 0) do
      nil ->
        {:ok, nil, seen}

      length ->
        inner = binary_part(body, 0, length)
        closing = binary_part(body, length + 1, byte_size(body) - length - 1)
        {spaces, after_quote} = drop_blanks(closing)
        key = if q == ?', do: String.replace(inner, "''", "'"), else: inner

        case after_quote do
          ":" <> value when value == "" or binary_part(value, 0, 1) in [" ", "\t"] ->
            {more, value} = drop_blanks(value)
            value_at = column + length + 2 + spaces + 1 + more
            key_value(key, value, value_at, column, top?, seen)

          _other ->
            {:ok, nil, seen}
        end
    end
  end

  defp quote_end(?', <<"''", rest::binary>>, i), do: quote_end(?', rest, i + 2)
  defp quote_end(?', <<"'", _::binary>>, i), do: i
  defp quote_end(?", <<"\\", _, rest::binary>>, i), do: quote_end(?", rest, i + 2)
  defp quote_end(?", <<"\"", _::binary>>, i), do: i
  defp quote_end(q, <<_, rest::binary>>, i), do: quote_end(q, rest, i + 1)
  defp quote_end(_q, "", _i), do: nil

  defp scan_plain(text, column, top?, seen) do
    case key_end(text, 0) do
      nil ->
        {:ok, nil, seen}

      length ->
        key = text |> binary_part(0, length) |> String.replace(~r/[ \t]+\z/, "")
        {blanks, value} = drop_blanks(binary_part(text, length + 1, byte_size(text) - length - 1))
        key_value(key, value, column + length + 1 + blanks, column, top?, seen)
    end
  end

  # The first `:` that is followed by a space, a tab or the end of the text.
  defp key_end(<<":", c, _::binary>>, i) when c in [?\s, ?\t], do: i
  defp key_end(":", i), do: i
  defp key_end(<<_, rest::binary>>, i), do: key_end(rest, i + 1)
  defp key_end("", _i), do: nil

  # A key is checked before its value; the value opens its regions at the
  # column of the key.
  defp key_value("<<", _value, _value_at, _column, _top?, _seen), do: {:error, :yaml_alias}

  defp key_value(key, value, value_at, column, top?, seen) do
    if top? and MapSet.member?(seen, key) do
      {:error, :duplicate_key}
    else
      seen = if top?, do: MapSet.put(seen, key), else: seen
      scan_node(value, value_at, column, false, seen)
    end
  end

  defp check_not_blank(text) do
    if text =~ ~r/\A[ \t\n]*\z/, do: {:error, :not_a_map}, else: :ok
  end

  defp parse(text) do
    case YamlElixir.read_from_string(text, []) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :not_a_map}
      {:error, _error} -> {:error, :invalid_yaml}
    end
  end

  defp check_body(""), do: {:error, :empty_body}
  defp check_body(_body), do: :ok
end
