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

  # Pass 1: each CR LF becomes LF; a CR that is left is not valid YAML here.
  defp scan(frontmatter) do
    text = String.replace(frontmatter, "\r\n", "\n")

    if String.contains?(text, "\r"), do: {:error, :invalid_yaml}, else: {:ok, text}
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
