defmodule Elzoo.SkillTest do
  use ExUnit.Case, async: true

  alias Elzoo.{AgentLoop, RecipePackage, Skill, ToolRegistry, ToolResultLimit, UntrustedContent}

  @fm "name: s\ndescription: d\n"
  @max_file 1_048_576

  defp md(frontmatter, body), do: "---\n" <> frontmatter <> "---\n" <> body
  defp folder(extra \\ %{}), do: Map.put(extra, "SKILL.md", md(@fm, "body\n"))
  defp read(files), do: Skill.read("s", "1", [], files)
  defp read_md(skill_md), do: read(%{"SKILL.md" => skill_md})

  # The package of the checked example of `domain/recipe-package` (copied), with
  # `entries` as its skills and the identity computed as that example does.
  defp package(entries) do
    typed = fn direction ->
      %{
        "port" => %{
          "id" => direction,
          "direction" => direction,
          "schema_id" => "value",
          "schema_version" => 1
        },
        "schema" => %{"type" => "object"}
      }
    end

    package = %{
      "format_version" => 1,
      "name" => "example",
      "version" => "opaque-revision",
      "needs" => [],
      "permissions" => [],
      "skills" => entries,
      "graph" => %{
        "version" => 1,
        "id" => "graph",
        "revision" => 1,
        "root" => "main",
        "callables" => [
          %{
            "name" => "main",
            "kind" => "graph",
            "input" => typed.("input"),
            "output" => typed.("output"),
            "nodes" => [],
            "links" => [],
            "input_slots" => []
          }
        ],
        "bindings" => [],
        "rules" => []
      },
      "settings" => %{
        "version" => 1,
        "id" => "independent-settings",
        "revision" => 1,
        "port" => typed.("input")["port"],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        "secrets" => []
      }
    }

    Map.put(package, "identity", identity(package))
  end

  # A package that holds bytes that are not UTF-8 has no canonical JSON; the
  # package check refuses it as invalid_shape before it looks at the identity,
  # so a zero digest stands for it.
  defp identity(package) do
    digest = :crypto.hash(:sha256, canonical(package))
    "recipe-package-v1:sha256:" <> Base.encode16(digest, case: :lower)
  rescue
    Jason.EncodeError -> "recipe-package-v1:sha256:" <> String.duplicate("0", 64)
  end

  defp canonical(value) when is_map(value) do
    fields = for {key, child} <- Enum.sort(value), do: [Jason.encode!(key), ?:, canonical(child)]
    [?{, Enum.intersperse(fields, ?,), ?}]
  end

  defp canonical(value) when is_list(value),
    do: [?[, Enum.intersperse(Enum.map(value, &canonical/1), ?,), ?]]

  defp canonical(value), do: Jason.encode!(value)

  defp decode(entries), do: RecipePackage.decode(package(entries))

  # The entry of `read/4` for one literal folder; `read/4` itself must succeed.
  defp entry!(name, frontmatter, body \\ "body\n") do
    assert {:ok, %{entry: entry}} =
             Skill.read(name, "1", [], %{"SKILL.md" => md(frontmatter, body)})

    entry
  end

  # The result of the package check for a skill that `read/4` accepted.
  defp checked(name, frontmatter, body \\ "body\n"),
    do: decode([entry!(name, frontmatter, body)])

  # A frontmatter of exactly `size` bytes that holds one long plain value.
  defp frontmatter_of(size, eol) do
    head = "name: s" <> eol <> "description: "
    pad = size - byte_size(head) - byte_size(eol)
    head <> :binary.copy("a", pad) <> eol
  end

  # One skill of a package: the entry and the other files, both from `read/4`.
  defp skill!(name, opts \\ []) do
    description = Keyword.get(opts, :description, "Use " <> name)
    body = Keyword.get(opts, :body, "Instructions of " <> name <> "\n")
    frontmatter = "name: #{name}\ndescription: #{description}\n" <> Keyword.get(opts, :extra, "")
    files = Map.put(Keyword.get(opts, :files, %{}), "SKILL.md", md(frontmatter, body))

    assert {:ok, %{entry: entry, files: rest}} =
             Skill.read(
               name,
               Keyword.get(opts, :version, "1"),
               Keyword.get(opts, :tools, []),
               files
             )

    {entry, rest}
  end

  # The checked package and the files by skill name of the given skills.
  defp pinned!(skills) do
    assert {:ok, checked} = decode(Enum.map(skills, &elem(&1, 0)))
    {checked, Map.new(skills, fn {entry, rest} -> {entry["name"], rest} end)}
  end

  defp source!(id, checked) do
    assert {:ok, source} = Skill.source(id, checked)
    source
  end

  describe "skill_md_split" do
    test "an LF file and a CR LF file give the same map and the body bytes after the closing line" do
      lf = "---\nname: s\ndescription: d\n---\nline one\nline two\n"
      crlf = "---\r\nname: s\r\ndescription: d\r\n---\r\nline one\r\nline two\r\n"

      assert {:ok, %{entry: lf_entry}} = read_md(lf)
      assert {:ok, %{entry: crlf_entry}} = read_md(crlf)

      assert lf_entry["frontmatter"] == %{"name" => "s", "description" => "d"}
      assert crlf_entry["frontmatter"] == lf_entry["frontmatter"]
      assert lf_entry["body"] == "line one\nline two\n"
      assert crlf_entry["body"] == "line one\r\nline two\r\n"
    end

    test "the entry holds the operands, the frontmatter and the body, and the rest is the other files" do
      files = %{"SKILL.md" => md(@fm, "body"), "scripts/run.sh" => "echo", "a.txt" => ""}

      assert {:ok, %{entry: entry, files: rest}} = Skill.read("s", "v1", ["t1", "t2"], files)

      assert entry == %{
               "name" => "s",
               "version" => "v1",
               "tools" => ["t1", "t2"],
               "frontmatter" => %{"name" => "s", "description" => "d"},
               "body" => "body"
             }

      assert rest == %{"scripts/run.sh" => "echo", "a.txt" => ""}
    end

    test "a closing line may end at the end of the file and the body keeps every later byte" do
      assert {:ok, %{entry: %{"body" => "x\n---\n\n"}}} =
               read_md("---\n" <> @fm <> "---\nx\n---\n\n")

      assert {:error, :empty_body} = read_md("---\n" <> @fm <> "---")
    end

    test "the first later line that is exactly --- closes the frontmatter" do
      assert {:ok, %{entry: entry}} = read_md("---\n" <> @fm <> "---\n---\nlast\n")
      assert entry["body"] == "---\nlast\n"
    end

    test "a --- with a trailing space, a lone CR or more bytes is not a closing line" do
      for closing <- ["--- \n", "---\t\n", "----\n", "---x\n", "--- #c\n", "---\r"] do
        assert {:error, :missing_frontmatter} = read_md("---\n" <> @fm <> closing <> "body\n"),
               inspect(closing)
      end

      assert {:error, :missing_frontmatter} = read_md("---\n" <> @fm <> "---\r")
      assert {:error, :missing_frontmatter} = read_md("---\n" <> @fm <> "--- ")
    end

    test "each missing_frontmatter case: no opening line, a byte-order mark, no closing line" do
      no_open = [
        "",
        "name: s\n---\nbody\n",
        "\n---\n" <> @fm <> "---\nbody\n",
        " ---\n" <> @fm <> "---\nbody\n",
        "--- \n" <> @fm <> "---\nbody\n",
        "---",
        "---\r",
        "----\n" <> @fm <> "---\nbody\n",
        "﻿---\n" <> @fm <> "---\nbody\n"
      ]

      for text <- no_open do
        assert {:error, :missing_frontmatter} = read_md(text), inspect(text)
      end

      assert {:error, :missing_frontmatter} = read_md("---\n" <> @fm <> "body\n")
      assert {:error, :missing_frontmatter} = read_md("---\n")
      assert {:error, :missing_frontmatter} = read_md("---\n---x\n")
    end

    test "frontmatter of exactly 16,384 bytes reads and 16,385 bytes is too large" do
      exact = frontmatter_of(16_384, "\n")
      assert byte_size(exact) == 16_384
      assert {:ok, %{entry: %{"frontmatter" => %{"name" => "s"}}}} = read_md(md(exact, "b\n"))

      over = frontmatter_of(16_385, "\n")
      assert byte_size(over) == 16_385
      assert {:error, :frontmatter_too_large} = read_md(md(over, "b\n"))
    end

    test "the frontmatter is measured as written, before CR LF becomes LF" do
      crlf = frontmatter_of(16_385, "\r\n")
      assert byte_size(crlf) == 16_385
      assert byte_size(String.replace(crlf, "\r\n", "\n")) < 16_384

      assert {:error, :frontmatter_too_large} =
               read_md("---\r\n" <> crlf <> "---\r\nb\r\n")

      assert {:ok, _} = read_md("---\r\n" <> frontmatter_of(16_384, "\r\n") <> "---\r\nb\r\n")
    end

    test "invalid_utf8 is checked before the split" do
      assert {:error, :invalid_utf8} = read_md(<<255>>)
      assert {:error, :invalid_utf8} = read_md(md(@fm, <<"body", 255>>))
      assert {:error, :invalid_utf8} = read_md("---\n" <> @fm <> <<0xC3>> <> "---\nb\n")
    end

    test "missing_skill_md: no key that is exactly SKILL.md" do
      assert {:error, :missing_skill_md} = read(%{})
      assert {:error, :missing_skill_md} = read(%{"skill.md" => md(@fm, "b\n")})
      assert {:error, :missing_skill_md} = read(%{"Skill.md" => md(@fm, "b\n")})
      assert {:error, :missing_skill_md} = read(%{"sub/SKILL.md" => md(@fm, "b\n")})
      assert {:error, :missing_skill_md} = read(%{"SKILL.md " => md(@fm, "b\n")})
    end

    test "empty_body for a file that ends at the closing line, with LF, CR LF or neither" do
      assert {:error, :empty_body} = read_md("---\n" <> @fm <> "---\n")

      assert {:error, :empty_body} =
               read_md("---\r\n" <> "name: s\r\ndescription: d\r\n" <> "---\r\n")

      assert {:error, :empty_body} = read_md("---\n" <> @fm <> "---")
    end

    test "a blank frontmatter is not a map, also directly between the two lines" do
      assert {:error, :not_a_map} = read_md("---\n---\nbody\n")
      assert {:error, :not_a_map} = read_md("---\r\n---\r\nbody\r\n")
      assert {:error, :not_a_map} = read_md(md("  \n", "body\n"))
      assert {:error, :not_a_map} = read_md(md(" \t \n\n", "body\n"))
    end

    test "text that the reader gives as a list or a scalar is not a map" do
      assert {:error, :not_a_map} = read_md(md("- a\n- b\n", "body\n"))
      assert {:error, :not_a_map} = read_md(md("just text\n", "body\n"))
    end

    test "text that the reader refuses, and a lone CR, is invalid_yaml" do
      assert {:error, :invalid_yaml} = read_md(md("a: [\n", "body\n"))
      assert {:error, :invalid_yaml} = read_md(md("name: a\rdescription: b\n", "body\n"))
      assert {:error, :invalid_yaml} = read_md(md("name: a\r\r\ndescription: b\n", "body\n"))
    end

    test "the reader is checked before the body" do
      assert {:error, :not_a_map} = read_md("---\n---\n")
      assert {:error, :invalid_yaml} = read_md(md("a: [\n", ""))
    end
  end

  describe "folder_bounds_and_paths" do
    test "an invalid path is invalid_path" do
      long = :binary.copy("a", 1_025)

      for path <- [
            "/a",
            "a/",
            "a//b",
            "./a",
            "a/./b",
            "a/../b",
            "..",
            ".",
            "a/..",
            "a\\b",
            "a\0b",
            <<255>>,
            "a/" <> <<0xC3>>,
            "",
            long,
            "/"
          ] do
        assert {:error, :invalid_path} = read(folder(%{path => "x"})), inspect(path)
      end
    end

    test "an invalid path is checked also when SKILL.md is missing" do
      assert {:error, :invalid_path} = read(%{"/a" => "x"})
    end

    test "a path of 1,024 bytes passes, also with segments and multibyte text" do
      assert {:ok, %{files: rest}} = read(folder(%{:binary.copy("a", 1_024) => "x"}))
      assert map_size(rest) == 1

      segmented = Enum.join(List.duplicate(String.duplicate("b", 31), 32), "/")
      assert byte_size(segmented) == 1_023
      assert {:ok, _} = read(folder(%{segmented => "x"}))

      assert {:ok, _} = read(folder(%{"é/..a/.b/c..d/ü.txt" => "x", ".hidden" => "y"}))
    end

    test "256 files pass and 257 do not, SKILL.md included" do
      others = fn n -> Map.new(1..n, &{"f#{&1}", ""}) end

      assert {:ok, %{files: rest}} = read(folder(others.(255)))
      assert map_size(rest) == 255
      assert {:error, :folder_too_large} = read(folder(others.(256)))
      assert {:error, :folder_too_large} = read(Map.put(others.(257), "SKILL.md", "x"))
    end

    test "a file of 1,048,576 bytes passes and one more byte does not" do
      assert {:ok, _} = read(folder(%{"big" => :binary.copy("a", @max_file)}))

      assert {:error, :folder_too_large} =
               read(folder(%{"big" => :binary.copy("a", @max_file + 1)}))

      head = md(@fm, "")
      skill_md = fn size -> head <> :binary.copy("b", size - byte_size(head)) end

      assert {:ok, _} = read(%{"SKILL.md" => skill_md.(@max_file)})
      assert {:error, :folder_too_large} = read(%{"SKILL.md" => skill_md.(@max_file + 1)})
    end

    test "8,388,608 bytes in all pass and one more byte does not, SKILL.md included" do
      chunk = :binary.copy("c", @max_file)
      head = md(@fm, "")
      skill_md = head <> :binary.copy("b", @max_file - byte_size(head))

      seven = Map.new(1..7, &{"f#{&1}", chunk})
      full = Map.put(seven, "SKILL.md", skill_md)

      assert Enum.sum(for {_, b} <- full, do: byte_size(b)) == 8_388_608
      assert {:ok, %{files: rest}} = read(full)
      assert map_size(rest) == 7

      assert {:error, :folder_too_large} = read(Map.put(full, "extra", "x"))
      assert {:error, :folder_too_large} = read(Map.put(full, "f1", chunk <> "x"))
    end

    test "invalid_input for each operand rule" do
      ok = folder()

      assert {:error, :invalid_input} = Skill.read(:s, "1", [], ok)
      assert {:error, :invalid_input} = Skill.read(nil, "1", [], ok)
      assert {:error, :invalid_input} = Skill.read("s", 1, [], ok)
      assert {:error, :invalid_input} = Skill.read("s", nil, [], ok)
      assert {:error, :invalid_input} = Skill.read("s", "1", "t", ok)
      assert {:error, :invalid_input} = Skill.read("s", "1", %{}, ok)
      assert {:error, :invalid_input} = Skill.read("s", "1", nil, ok)
      assert {:error, :invalid_input} = Skill.read("s", "1", [], [])
      assert {:error, :invalid_input} = Skill.read("s", "1", [], nil)
      assert {:error, :invalid_input} = Skill.read("s", "1", [], [{"SKILL.md", "x"}])
      assert {:error, :invalid_input} = Skill.read("s", "1", [], Map.put(ok, :atom, "x"))
      assert {:error, :invalid_input} = Skill.read("s", "1", [], Map.put(ok, 1, "x"))
      assert {:error, :invalid_input} = Skill.read("s", "1", [], Map.put(ok, "a", nil))
      assert {:error, :invalid_input} = Skill.read("s", "1", [], Map.put(ok, "a", 1))
      assert {:error, :invalid_input} = Skill.read("s", "1", [], Map.put(ok, "a", ["x"]))
      assert {:error, :invalid_input} = Skill.read("s", "1", [], %{"SKILL.md" => nil})
    end

    test "invalid_input comes before every other check" do
      assert {:error, :invalid_input} = Skill.read(:s, "1", [], %{"/a" => "x"})
      assert {:error, :invalid_input} = Skill.read("s", "1", [], %{"/a" => 1})
      assert {:error, :invalid_input} = Skill.read("s", "1", [], %{1 => "x", "/a" => "x"})
    end

    test "a folder with both an invalid path and too many files is invalid_path" do
      many = Map.new(1..300, &{"f#{&1}", ""})

      assert {:error, :invalid_path} = read(folder(Map.put(many, "../x", "")))
      assert {:error, :invalid_path} = read(folder(Map.merge(many, %{"a//b" => "x"})))

      big = :binary.copy("a", @max_file + 1)
      assert {:error, :invalid_path} = read(folder(%{"a/" => "x", "big" => big}))
    end

    test "folder_too_large comes before missing_skill_md and the file checks" do
      assert {:error, :folder_too_large} = read(Map.new(1..257, &{"f#{&1}", ""}))

      assert {:error, :folder_too_large} =
               read(%{"SKILL.md" => <<255>>, "b" => :binary.copy("a", @max_file + 1)})
    end
  end

  describe "yaml_refusals" do
    @p "name: s\ndescription: d\n"

    defp fm(frontmatter), do: read_md(md(frontmatter, "body\n"))

    test "2.1 an anchor in a value" do
      assert {:error, :yaml_alias} = fm("base: &b\n  x: 1\nuse: *b\n")
    end

    test "2.2 an alias after a sequence indicator" do
      assert {:error, :yaml_alias} = fm("- *b\n")
    end

    test "2.3 a node text that begins with an anchor" do
      assert {:error, :yaml_alias} = fm("&k name: x\n")
    end

    test "2.4 the tag is dropped before the node text is scanned" do
      assert {:error, :yaml_alias} = fm("a: !!str &x y\n")
    end

    test "2.5 an alias after a comma in a flow region" do
      assert {:error, :yaml_alias} = fm("b: x\na: [c, *b]\n")
    end

    test "2.6 an alias on a later line of a flow region" do
      assert {:error, :yaml_alias} = fm("metadata: {k: v,\n  j: *b}\n")
    end

    test "2.7 the key <<, plain, in a flow region and quoted" do
      assert {:error, :yaml_alias} = fm("<<: x\n")
      assert {:error, :yaml_alias} = fm("m: {<<: x}\n")
      assert {:error, :yaml_alias} = fm("\"<<\": x\n")
    end

    test "2.8 a block region opened after an indicator ends at an equal indentation" do
      assert {:error, :yaml_alias} = fm("- a: |\n    t\n  b: *x\n")
    end

    test "2.9 texts that are not aliases read" do
      assert {:ok, %{entry: %{"frontmatter" => %{"license" => "MIT"}}}} =
               fm(@p <> "license: MIT # see: name\n")

      assert {:ok, _} = fm("name: s\ndescription: Use for *.xlsx files, R&D, a & b, 5 * 3\n")

      assert {:ok, _} =
               fm(@p <> "license: '*x'\ncompatibility: \"&x\"\nallowed-tools: \"<<\"\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"metadata" => %{"k" => "a"}}}}} =
               fm(@p <> "metadata:\n  k: a\n  k: b\n")

      for indicator <- ["|", ">"] do
        assert {:ok, %{entry: %{"frontmatter" => %{"license" => "x"}}}} =
                 fm(
                   "name: s\ndescription: " <>
                     indicator <> "\n  * one\n  & two\n  \tthree\n# c\nlicense: x\n"
                 )
      end
    end

    test "2.10 a top-level key twice; the key is checked before its value" do
      assert {:error, :duplicate_key} = fm("name: a\nname: b\n")
      assert {:error, :duplicate_key} = fm("name: a\n'name': b\n")
      assert {:error, :duplicate_key} = fm("name: a\nname: *x\n")
      assert {:error, :yaml_alias} = fm("name: *x\nname: y\n")
    end

    test "2.11 a tab where the indentation is" do
      assert {:error, :tab_indentation} = fm("a:\n\tb: 1\n")
    end

    test "2.12 a document marker is checked in pass 2, before a duplicate of the first document" do
      assert {:error, :not_a_map} = fm("name: a\n...\nname: b\n")
      assert {:error, :not_a_map} = fm(@p <> "--- # c\n")
      assert {:error, :not_a_map} = fm(@p <> "--- x\n")
    end

    test "2.13 a lone CR" do
      assert {:error, :invalid_yaml} = fm("name: a\rdescription: b\n")
    end

    test "2.14 blank and non-map frontmatter" do
      assert {:error, :not_a_map} = fm("  \n")
      assert {:error, :not_a_map} = fm("- a\n- b\n")
      assert {:error, :not_a_map} = fm("just text\n")
    end

    test "2.15 an unreadable text is invalid_yaml and runs nothing" do
      assert {:error, :invalid_yaml} = fm("a: [\n")
      assert {:error, :invalid_yaml} = fm("a: !ruby/object:Foo {x: 1}\n")

      assert {:error, :invalid_yaml} =
               fm("a: !<tag:yamerl,2012:fun> persistent_term:put(elz_skill, ran).\n")

      assert :persistent_term.get(:elz_skill, :absent) == :absent
    end

    test "2.16 a tab separates a value from its colon, its tag or a flow indicator like a space" do
      for frontmatter <- [
            "b:\t&a x\nc:\t*a\n",
            "b: \t&a x\nc: \t*a\n",
            "b:\t&a x\nc: [y,\t*a]\n",
            "b:\t&a x\nc: {k:\t*a}\n",
            "b:\t&a x\nc: [\t*a]\n",
            "b: !!str\t&a x\nc: !!str\t*a\n"
          ] do
        assert {:error, :yaml_alias} = fm(frontmatter)
      end
    end

    test "2.17 an explicit key is invalid_yaml, where a node starts, and a ? that is text is read" do
      # Each row of the review of the pull request, and probes of the pinned
      # reader: each of these texts reads as a key, a merge key or an alias.
      for frontmatter <- [
            "? <<\n: v\n",
            "? \"<<\"\n: v\n",
            "?\t<<\n: v\n",
            "? \t<<\n: v\n",
            "k:\n  ? <<\n  : v\n",
            "m: {? &a k : v, ? *a : w}\n",
            "m: {k: !!str &x y, ? *x : w}\n",
            "m: {?\t&a k: v, ? *a : w}\n",
            "m: {a: 1,\n  ? &x k : v,\n  ? *x : w}\n",
            "- ? a\n  : b\n",
            "- - ? a\n",
            "?\n",
            "m:\n  ? a\n",
            "m: {a: 1}\n? b\n",
            "a: ? x\n",
            "a: ?\n",
            "m: {? a : b}\n",
            "m: [? a : b]\n",
            "m: [a,\n  ? b : c]\n",
            "m: [{?\n a : b}]\n",
            "m: {?\ta : b}\n",
            "m: {k: ? x : v}\n",
            "m: {!!str ? x : v}\n",
            "m: [a,\nb, ? c : d]\n"
          ] do
        assert {:error, :invalid_yaml} = fm(frontmatter)
      end
    end

    test "2.18 a ? that is not an indicator is text" do
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "what?"}}}} = fm("a: what?\n")
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "?x"}}}} = fm("a: ?x\n")
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "? x"}}}} = fm("a: '? x'\n")
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "? x"}}}} = fm("a: \"? x\"\n")
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "? x\ny\n"}}}} = fm("a: |\n  ? x\n  y\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["?a", "what?", "? x", "a ? b", "?"]}}}} =
               fm("m: [?a, what?, '? x', a ? b, ?]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => %{"a ?" => "b"}}}}} =
               fm("m: {a ? : b}\n")

      # The scan does not know a plain scalar that goes on in the next line.
      assert {:error, :invalid_yaml} = fm("a: foo\n  ? bar\n")
    end

    test "2.19 in a flow region an anchor or alias after a tag, a colon or a comma is yaml_alias" do
      for frontmatter <- [
            "m: {k: !!str &x y, z: *x}\n",
            "m: [!!str *x]\n",
            "m: [!!str\n  *x]\n",
            "m: [!<tag:yaml.org,2002:str> *x]\n",
            "m: [!!str,*x]\n",
            "m: {\"a\":*x}\n",
            "m: [a:*x]\n",
            "m: {a: !!str\n  *x}\n",
            "a: !!str\n  &x y\nb: *x\n",
            "m: [a,\nb, &x c, *x]\n",
            "m: [a,\n'b', &x c, *x]\n",
            "m: [\na, &x b,\n*x]\n"
          ] do
        assert {:error, :yaml_alias} = fm(frontmatter)
      end
    end

    test "2.20 in a flow region a quote opens only at a token start and a comment hides a quote" do
      for frontmatter <- [
            "m: [it's, *x]\n",
            "m: [a, # it's\n  *x]\n",
            "m: [a, 'b''c', *x]\n",
            "m: [a, \"b\\\"\", *x]\n",
            "m: [\"a\\\\\", *x]\n",
            "m: ['a\n  b', *x]\n",
            "m: [\"a #\", *x]\n",
            "m: [a#b, *x]\n"
          ] do
        assert {:error, :yaml_alias} = fm(frontmatter)
      end
    end

    test "2.21 in a flow region quoted and plain text with & or * is read, << is refused" do
      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["&x", "*y"]}}}} =
               fm("m: ['&x', \"*y\"]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["R&D", "a & b", "5 * 3"]}}}} =
               fm("m: [R&D, a & b, 5 * 3]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["a *x"]}}}} = fm("m: [a\n  *x]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["a &x", "b"]}}}} =
               fm("m: ['a\n  &x', b]\n")

      assert {:error, :yaml_alias} = fm("m: [\"<<\"]\n")
      assert {:error, :yaml_alias} = fm("m: [a, # <<\n b]\n")
    end

    test "2.22 in a flow region an anchor or alias after a closing bracket or a comment is yaml_alias" do
      for frontmatter <- [
            "b: [x] &y\nc: [a # c\n  *y]\n",
            "b: [x] &y\n",
            "b: [x]&y\n",
            "c: [a # c\n  *y]\n",
            "c: {a: x # c\n  *y}\n",
            "b: {k: v} *y\n",
            "b: [x] *y\n",
            "b: [[x]&y]\n",
            "m: [[a]\n &y b]\n",
            "m: [{a: b} &y]\n",
            "m: {a: [b] *y}\n",
            "m: {k: v}&y\n",
            "c: [a # c\n  &y b]\n",
            "c: [\"a\" # c\n  *y]\n",
            "c: [a # c\n  # d\n  *y]\n"
          ] do
        assert {:error, :yaml_alias} = fm(frontmatter)
      end

      # A comment ends the token, so a ? that follows it is an explicit key;
      # a ? after a closing bracket is text or a reader error.
      for frontmatter <- ["c: {a: x # c\n  ? k : v}\n", "c: [a, # c\n  ? b : d]\n"] do
        assert {:error, :invalid_yaml} = fm(frontmatter)
      end

      assert {:error, :invalid_yaml} = fm("m: [{a: b} ? c]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["R&D", "a & b", "5 * 3"]}}}} =
               fm("m: [R&D, a & b, 5 * 3]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["&x", "*y"]}}}} =
               fm("m: ['&x', \"*y\"]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"c" => ["a#c *y"]}}}} = fm("c: [a#c\n  *y]\n")
    end

    test "2.23 after a closing quote only blanks, a comment or a colon and a blank may follow" do
      # The four texts of the rule, and the rows of the second review pass: a
      # flow collection or a key glued on to a closing quote reached the reader.
      for frontmatter <- [
            "'a':[x]\n",
            "'a':{k: v}\n",
            "'k' ? x\n",
            "\"a\"b\n",
            "'a':[&x z, *x]\n",
            "'a':{<<: v}\n",
            "'<<':{a: 1}\n",
            "a: 'k':[&x z, *x]\n",
            "'k' ? << :v\n"
          ] do
        assert {:error, :invalid_yaml} = fm(frontmatter)
      end

      # The same rule after a value, an indicator and a tag, with an anchor or
      # alias glued on (found by the differential test), and without a blank
      # before a comment.
      for frontmatter <- [
            "''& :\n",
            "''&a :\n",
            "'a'& :\n",
            "a: 'b'&x c\n",
            "- \"a\"*x\n",
            "a: !!str 'b'c\n",
            "'a'#c\n",
            "'a' b: c\n",
            "\"a\"\\\n"
          ] do
        assert {:error, :invalid_yaml} = fm(frontmatter)
      end

      # A quoted scalar of a block region ends on its line.
      assert {:error, :invalid_yaml} = fm("a: 'b\n  c'\n")
      assert {:error, :invalid_yaml} = fm("\"a\nb\": c\n")

      # What may follow: blanks, the end of the line, a comment, a colon and a
      # blank, a tab or the end of the line.
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "b", "c" => "d", "e" => "f", "g" => "h"}}}} =
               fm("'a': b # c\n\"c\"\t:\td\n'e' \t:\n  f\ng: 'h' \t\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "b"}}}} = fm("a: 'b'\n")
      assert {:ok, %{entry: %{"frontmatter" => %{"a" => "b"}}}} = fm("a: \"b\" # c *x\n")
    end

    test "2.24 in a flow region only a comma, a colon, a bracket, a blank or a comment follows a closing quote" do
      for frontmatter <- [
            "m: ['a'b]\n",
            "m: ['a'[x]]\n",
            "m: ['a'{x: y}]\n",
            "m: [\"a\"&x, *x]\n",
            "m: [\"a\"#c\n]\n",
            "m: {'a'? x}\n",
            "m: ['a'\n  b]\n",
            "m: ['a\n  b'c]\n",
            "m: [a, 'b'\n&x]\n"
          ] do
        assert {:error, :invalid_yaml} = fm(frontmatter)
      end

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => ["a", "b", "c"]}}}} =
               fm("m: [ 'a' , \"b\"\t,\n  'c' # d\n  ]\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => %{"a" => "b", "c" => "d"}}}}} =
               fm("m: {'a': 'b', \"c\" : \"d\"}\n")

      assert {:ok, %{entry: %{"frontmatter" => %{"m" => [["a"], %{"b" => "c"}]}}}} =
               fm("m: [['a'], {'b': 'c'}]\n")
    end

    # Extra cases that pin a rule that a written case does not reach.

    test "a comment line does not end a flow region, and a block region ends at a comment line at its column" do
      assert {:error, :yaml_alias} = fm("m: [a,\n# c\n  , *x]\n")
      assert {:ok, _} = fm(@p <> "k: |+\n  *x\n# c\nl: >2- # c\n  &x\n")
    end

    test "a region that follows an indicator opens at the column of that indicator" do
      assert {:ok, _} = fm("k:\n  - |\n    *x\n  - b: 1\n")
      assert {:error, :yaml_alias} = fm("k:\n  - |\n    *x\n  - *y\n")
    end

    test "a quoted scalar that is not followed by a colon scans nothing more" do
      assert {:ok, _} = fm(@p <> "a: \"x\" # *y\n")
      assert {:error, :yaml_alias} = fm("\"a\\\"b\": *c\n")
      assert {:error, :yaml_alias} = fm("'it''s': *c\n")
    end

    test "spaces and tabs separate a key from its colon, and a tab separates an alias from its indicator" do
      # Probes of the pinned reader: each of these text reads as an alias or as a
      # key equal to an earlier key, and each is refused.
      assert {:error, :yaml_alias} = fm("\"c\" \t:\t*a\n")
      assert {:error, :yaml_alias} = fm("c\t: *a\n")
      assert {:error, :yaml_alias} = fm("c: {k\t: *a}\n")
      assert {:error, :yaml_alias} = fm("c: [k\n  ,\t*a]\n")
      assert {:error, :yaml_alias} = fm("c: [k,\n  \t*a]\n")
      assert {:error, :duplicate_key} = fm("b: 1\nb\t: 2\n")
      assert {:error, :duplicate_key} = fm("b: 1\nb \t: 2\n")
      assert {:error, :duplicate_key} = fm("b: 1\n\"b\"\t: 2\n")
      assert {:error, :duplicate_key} = fm("'b': 1\n'b' \t:\t2\n")
    end

    test "top-level keys: quotes are read, a later key and an indicator key are not top-level" do
      assert {:error, :duplicate_key} = fm("a'b: 1\n'a''b': 2\n")
      assert {:error, :duplicate_key} = fm("\"a\\nb\": 1\n\"a\\nb\": 2\n")
      # Double-quoted keys are compared as written: the escape is not decoded.
      assert {:ok, _} = fm("\"a\\x41\": 1\naA: 2\n")
      assert {:ok, _} = fm(@p <> "k: x # a: 1\na: 2\n")
      assert {:error, :not_a_map} = fm("- a: 1\n- a: 2\n")
    end
  end

  describe "package_checks_fields" do
    test "an entry of read/4 passes the package check and encode/1 gives the package back" do
      entry = entry!("s", @fm)
      assert {:ok, checked} = decode([entry])
      assert RecipePackage.encode(checked) == package([entry])

      files = %{
        "SKILL.md" =>
          md(
            "name: other-skill\ndescription: Use it\nlicense: MIT\ncompatibility: any\n" <>
              "metadata:\n  k: v\nallowed-tools: a b\n",
            "text\n"
          )
      }

      assert {:ok, %{entry: other}} = Skill.read("other-skill", "v2", ["t1", "t2"], files)
      assert {:ok, checked} = decode([entry, other])
      assert RecipePackage.encode(checked) == package([entry, other])
    end

    test "a frontmatter name that differs from the folder name is invalid_skill" do
      assert {:error, :invalid_skill} = checked("s", "name: t\ndescription: d\n")
      assert {:error, :invalid_skill} = checked("s", "name: S\ndescription: d\n")
    end

    test "each name rule, with the same text as folder name and frontmatter name" do
      for name <- ["Abc", "-a", "a-", "a--b"] do
        assert {:error, :invalid_skill} = checked(name, "name: #{name}\ndescription: d\n"),
               inspect(name)
      end
    end

    test "a missing and an empty description are invalid_skill" do
      assert {:error, :invalid_skill} = checked("s", "name: s\n")
      assert {:error, :invalid_skill} = checked("s", "name: s\ndescription: \"\"\n")
    end

    test "an unknown field is invalid_skill" do
      assert {:error, :invalid_skill} = checked("s", @fm <> "extra: x\n")
    end

    test "a description that YAML typed as true, 12 or null is invalid_skill" do
      for value <- ["true", "12", "null"] do
        assert {:error, :invalid_skill} = checked("s", "name: s\ndescription: " <> value <> "\n"),
               value
      end
    end

    test "1.5 as a metadata value is invalid_skill" do
      assert {:error, :invalid_skill} = checked("s", @fm <> "metadata:\n  k: 1.5\n")
    end

    test "a value that is not UTF-8 and a key that is not a string are invalid_shape" do
      entry = entry!("s", "name: s\ndescription: !!binary //4=\n")
      assert entry["frontmatter"]["description"] == <<255, 254>>
      assert {:error, :invalid_shape} = decode([entry])

      entry = entry!("s", @fm <> "1: x\n")
      assert %{1 => "x"} = entry["frontmatter"]
      assert {:error, :invalid_shape} = decode([entry])
    end

    test "a 65-byte name is too_large and 64 bytes pass" do
      name = String.duplicate("a", 65)
      assert {:error, :too_large} = checked(name, "name: #{name}\ndescription: d\n")

      name = String.duplicate("a", 64)
      assert {:ok, _} = checked(name, "name: #{name}\ndescription: d\n")
    end

    test "a description of 1,025 code points is too_large and 1,024 pass, counted as code points" do
      assert {:ok, _} =
               checked("s", "name: s\ndescription: " <> String.duplicate("é", 1_024) <> "\n")

      assert {:error, :too_large} =
               checked("s", "name: s\ndescription: " <> String.duplicate("é", 1_025) <> "\n")
    end

    test "a body of 16,385 bytes is too_large and 16,384 pass" do
      assert {:ok, _} = checked("s", @fm, String.duplicate("b", 16_384))
      assert {:error, :too_large} = checked("s", @fm, String.duplicate("b", 16_385))
    end
  end

  describe "pinned_skill_source" do
    @secret_tools ["tool-identity-alpha", "tool-identity-beta"]

    test "the source equals the literal map for a package with two skills" do
      {checked, _files} =
        pinned!([
          skill!("alpha", description: "Alpha does a"),
          skill!("beta", description: "Beta does b")
        ])

      listing = "alpha: Alpha does a\nbeta: Beta does b"

      assert Skill.source("sk", checked) ==
               {:ok,
                %{
                  "id" => "sk",
                  "kind" => "pinned_skill",
                  "callable" => "adapter",
                  "tools" => [
                    %{
                      "trust" => "untrusted",
                      "name" => "load_skill",
                      "description" => "Load the instructions of one skill by its name.",
                      "annotations" => nil,
                      "input_schema" => %{
                        "type" => "object",
                        "properties" => %{
                          "name" => %{
                            "type" => "string",
                            "enum" => ["alpha", "beta"],
                            "description" => listing
                          }
                        },
                        "required" => ["name"],
                        "additionalProperties" => false
                      }
                    },
                    %{
                      "trust" => "untrusted",
                      "name" => "read_skill_file",
                      "description" => "Read one file of a skill by its relative path.",
                      "annotations" => nil,
                      "input_schema" => %{
                        "type" => "object",
                        "properties" => %{
                          "skill" => %{"type" => "string", "enum" => ["alpha", "beta"]},
                          "path" => %{"type" => "string", "minLength" => 1}
                        },
                        "required" => ["skill", "path"],
                        "additionalProperties" => false
                      }
                    }
                  ]
                }}
    end

    test "the registry accepts the source and lists both aliases with the whole descriptions" do
      {checked, _files} =
        pinned!([skill!("beta", description: "Beta b"), skill!("alpha", description: "Alpha a")])

      assert {:ok, snapshot} = ToolRegistry.snapshot([source!("sk", checked)])
      assert [load, read] = ToolRegistry.tools(snapshot)
      assert load["name"] == "sk_load_skill"
      assert read["name"] == "sk_read_skill_file"
      assert load["description"] == "Load the instructions of one skill by its name."

      # The names are in the order of the package, not sorted.
      assert load["input_schema"]["properties"]["name"]["enum"] == ["beta", "alpha"]
      assert read["input_schema"]["properties"]["skill"]["enum"] == ["beta", "alpha"]

      assert load["input_schema"]["properties"]["name"]["description"] ==
               "beta: Beta b\nalpha: Alpha a"
    end

    test "a description of 1,024 four-byte code points is kept whole in the input schema" do
      long = String.duplicate("\u{1D11E}", 1_024)
      assert byte_size(long) == 4_096

      {checked, _files} = pinned!([skill!("alpha", description: ~s("#{long}"))])
      assert {:ok, snapshot} = ToolRegistry.snapshot([source!("sk", checked)])
      assert [load, _read] = ToolRegistry.tools(snapshot)
      assert load["input_schema"]["properties"]["name"]["description"] == "alpha: " <> long
    end

    test "a package with no skill is no_skills" do
      {checked, _files} = pinned!([])
      assert Skill.source("sk", checked) == {:error, :no_skills}
    end

    test "an id of 1 to 32 bytes of the id characters passes; 33 bytes, a dot or no text do not" do
      {checked, _files} = pinned!([skill!("alpha")])

      for id <- ["a", "A_b-9", String.duplicate("a", 32)],
          do: assert({:ok, %{"id" => ^id}} = Skill.source(id, checked))

      for id <- [String.duplicate("a", 33), "a.b", "", "a b", "a\n", :sk, nil, 1],
          do: assert(Skill.source(id, checked) == {:error, :invalid_input}, inspect(id))

      assert Skill.source("a.b", pinned!([]) |> elem(0)) == {:error, :invalid_input}
    end

    test "the source holds no allowed-tools text and no tool identity of a skill" do
      {checked, _files} =
        pinned!([
          skill!("alpha",
            tools: @secret_tools,
            extra: "allowed-tools: Bash(secret-grant:*) Read\n"
          ),
          skill!("beta", tools: ["tool-identity-gamma"], extra: "allowed-tools: Write\n")
        ])

      source = source!("sk", checked)
      encoded = :erlang.term_to_binary(source) <> inspect(source, limit: :infinity)

      for text <- @secret_tools ++ ["tool-identity-gamma", "allowed-tools", "secret-grant", "Bash"],
          do: refute(String.contains?(encoded, text), text)
    end
  end

  describe "load_gives_declaration" do
    test "the payload equals the literal form for each skill of the package" do
      body = "# Alpha\n\nDo a.\r\n---\nkeep\n"
      {checked, _files} = pinned!([skill!("alpha", body: body), skill!("beta-two")])

      assert Skill.load(checked, %{"name" => "alpha"}) ==
               {:ok,
                %{
                  "declaration" => %{
                    "skill" => %{"name" => "alpha", "instructions" => body},
                    "listing" => nil
                  }
                }}

      assert Skill.load(checked, %{"name" => "beta-two"}) ==
               {:ok,
                %{
                  "declaration" => %{
                    "skill" => %{
                      "name" => "beta-two",
                      "instructions" => "Instructions of beta-two\n"
                    },
                    "listing" => nil
                  }
                }}
    end

    test "an unknown skill is unknown_skill" do
      {checked, _files} = pinned!([skill!("alpha")])
      assert Skill.load(checked, %{"name" => "gamma"}) == {:error, :unknown_skill}
      assert Skill.load(checked, %{"name" => "Alpha"}) == {:error, :unknown_skill}
      assert Skill.load(pinned!([]) |> elem(0), %{"name" => "alpha"}) == {:error, :unknown_skill}
    end

    test "a missing key, an extra key and a non-text name are invalid_arguments" do
      {checked, _files} = pinned!([skill!("alpha")])

      for arguments <- [
            %{},
            %{"skill" => "alpha"},
            %{"name" => "alpha", "path" => "x"},
            %{"name" => 1},
            %{"name" => nil},
            %{"name" => ["alpha"]},
            %{name: "alpha"},
            nil,
            "alpha",
            [%{"name" => "alpha"}]
          ],
          do:
            assert(
              Skill.load(checked, arguments) == {:error, :invalid_arguments},
              inspect(arguments)
            )
    end

    test "an invalid_arguments is given before an unknown skill" do
      {checked, _files} = pinned!([skill!("alpha")])
      assert Skill.load(checked, %{"name" => "gamma", "x" => 1}) == {:error, :invalid_arguments}
    end

    test "a package entry with an empty body is empty_body" do
      {entry, _rest} = skill!("alpha")
      assert {:ok, checked} = decode([%{entry | "body" => ""}])
      assert Skill.load(checked, %{"name" => "alpha"}) == {:error, :empty_body}
    end
  end

  describe "file_read_is_marked_content" do
    @limits %{max_bytes: 1_024, artifact_max_bytes: 1_048_576}

    defp pinned_files(files) do
      {checked, by_name} = pinned!([skill!("alpha", files: files)])
      {checked, by_name}
    end

    test "a text file gives text/plain, utf8 and a marked map that decode/1 accepts" do
      {checked, by_name} = pinned_files(%{"notes/a.md" => "héllo\n", "empty" => ""})
      args = fn path -> %{"skill" => "alpha", "path" => path} end

      assert {:ok,
              %{"media_type" => "text/plain", "encoding" => "utf8", "content" => content} = result} =
               Skill.read_file(checked, by_name, args.("notes/a.md"))

      assert content == %{
               "schema_id" => "elzoo.untrusted-content.marked",
               "schema_version" => 1,
               "sources" => ["skill:alpha"],
               "trust" => "untrusted",
               "max_bytes" => byte_size("héllo\n"),
               "content" => "héllo\n"
             }

      assert Map.keys(result) |> Enum.sort() == ["content", "encoding", "media_type"]
      assert {:ok, marked} = UntrustedContent.decode(content)
      assert UntrustedContent.encode(marked) == content
    end

    test "a binary file gives application/octet-stream, base64 and the padded text" do
      {checked, by_name} = pinned_files(%{"bin" => <<255, 254, 0, 1>>, "pad" => <<255>>})

      assert {:ok,
              %{
                "media_type" => "application/octet-stream",
                "encoding" => "base64",
                "content" => %{"content" => text, "max_bytes" => max, "sources" => ["skill:alpha"]}
              }} = Skill.read_file(checked, by_name, %{"skill" => "alpha", "path" => "bin"})

      assert text == Base.encode64(<<255, 254, 0, 1>>)
      assert max == byte_size(text)

      assert {:ok, %{"content" => %{"content" => "/w=="}}} =
               Skill.read_file(checked, by_name, %{"skill" => "alpha", "path" => "pad"})
    end

    test "an empty file gives max_bytes 1 and decode/1 accepts it" do
      {checked, by_name} = pinned_files(%{"empty" => ""})

      assert {:ok,
              %{"encoding" => "utf8", "content" => %{"max_bytes" => 1, "content" => ""} = content}} =
               Skill.read_file(checked, by_name, %{"skill" => "alpha", "path" => "empty"})

      assert {:ok, _marked} = UntrustedContent.decode(content)
    end

    test "decide/3 stores a text file of 2,000 bytes and passes one of 1,000 bytes" do
      {checked, by_name} =
        pinned_files(%{
          "big" => String.duplicate("x", 2_000),
          "small" => String.duplicate("y", 1_000)
        })

      assert {:ok, big} = Skill.read_file(checked, by_name, %{"skill" => "alpha", "path" => "big"})
      assert {:store, _pending, _payload} = ToolResultLimit.decide(big, @limits, "action-1")

      assert {:ok, small} =
               Skill.read_file(checked, by_name, %{"skill" => "alpha", "path" => "small"})

      assert {:ok, %{"cut" => nil, "content" => content}} =
               ToolResultLimit.decide(small, @limits, "action-1")

      assert content == small["content"]
    end

    test "decide/3 of a result whose content is the body text is unmarked" do
      {checked, _by_name} = pinned!([skill!("alpha")])

      assert {:ok, %{"declaration" => %{"skill" => %{"instructions" => body}}}} =
               Skill.load(checked, %{"name" => "alpha"})

      result = %{"content" => body, "media_type" => "text/plain", "encoding" => "utf8"}
      assert ToolResultLimit.decide(result, @limits, "action-1") == {:error, :unmarked}
    end

    test "SKILL.md, an unknown path and a skill missing from files are unknown_file" do
      {checked, by_name} = pinned_files(%{"a.txt" => "a"})
      args = fn skill, path -> %{"skill" => skill, "path" => path} end

      assert Skill.read_file(checked, by_name, args.("alpha", "SKILL.md")) ==
               {:error, :unknown_file}

      assert Skill.read_file(checked, by_name, args.("alpha", "b.txt")) == {:error, :unknown_file}
      assert Skill.read_file(checked, by_name, args.("alpha", "A.txt")) == {:error, :unknown_file}
      assert Skill.read_file(checked, by_name, args.("alpha", "./a.txt")) == {:error, :unknown_file}
      assert Skill.read_file(checked, %{}, args.("alpha", "a.txt")) == {:error, :unknown_file}

      assert Skill.read_file(checked, %{"alpha" => %{}}, args.("alpha", "a.txt")) ==
               {:error, :unknown_file}
    end

    test "each refusal in its order" do
      {checked, _by_name} = pinned_files(%{})
      good = %{"skill" => "alpha", "path" => "a"}
      big = String.duplicate("z", 1_048_577)

      # 1: arguments come first, before a files value that is wrong too.
      for bad <- [
            %{},
            %{"skill" => "alpha"},
            Map.put(good, "x", 1),
            %{good | "path" => 1},
            %{good | "skill" => nil},
            nil,
            "alpha"
          ],
          do: assert(Skill.read_file(checked, :nope, bad) == {:error, :invalid_arguments})

      # 2: the skill, before SKILL.md and before the files operand.
      unknown = %{good | "skill" => "gamma", "path" => "SKILL.md"}
      assert Skill.read_file(checked, :nope, unknown) == {:error, :unknown_skill}

      # 3: SKILL.md, before the files operand.
      assert Skill.read_file(checked, :nope, %{good | "path" => "SKILL.md"}) ==
               {:error, :unknown_file}

      # 4: the files operand, before a missing file.
      assert Skill.read_file(checked, :nope, good) == {:error, :invalid_input}
      assert Skill.read_file(checked, %{"alpha" => "text"}, good) == {:error, :invalid_input}
      assert Skill.read_file(checked, %{"alpha" => %{"a" => 1}}, good) == {:error, :invalid_input}
      assert Skill.read_file(checked, %{"alpha" => %{"a" => nil}}, good) == {:error, :invalid_input}

      # 5: a missing file.
      assert Skill.read_file(checked, %{"alpha" => %{"b" => "x"}}, good) == {:error, :unknown_file}

      # 6: the size; 1,048,576 bytes pass.
      assert Skill.read_file(checked, %{"alpha" => %{"a" => big}}, good) ==
               {:error, :file_too_large}

      assert {:ok, _} =
               Skill.read_file(
                 checked,
                 %{"alpha" => %{"a" => binary_part(big, 0, 1_048_576)}},
                 good
               )
    end
  end

  describe "scripts_never_run" do
    test "read/4 and read_file/3 give the bytes of a script unchanged and run nothing" do
      unique = System.unique_integer([:positive])
      sentinel = Path.join(System.tmp_dir!(), "elz_skill_sentinel_#{unique}")
      key = {:elz_skill_ran, unique}
      on_exit(fn -> File.rm(sentinel) end)

      sh = "#!/bin/sh\necho ran > #{sentinel}\n"

      exs =
        "File.write!(#{inspect(sentinel)}, \"ran\")\n:persistent_term.put(#{inspect(key)}, true)\n"

      files = %{"SKILL.md" => md(@fm, "body\n"), "scripts/run.sh" => sh, "scripts/run.exs" => exs}

      assert {:ok, %{entry: entry, files: rest}} = Skill.read("s", "1", [], files)
      assert rest == %{"scripts/run.sh" => sh, "scripts/run.exs" => exs}
      refute File.exists?(sentinel)
      assert :persistent_term.get(key, :unset) == :unset

      assert {:ok, checked} = decode([entry])
      by_name = %{"s" => rest}

      for {path, text} <- [{"scripts/run.sh", sh}, {"scripts/run.exs", exs}] do
        assert {:ok, %{"media_type" => "text/plain", "content" => %{"content" => ^text}}} =
                 Skill.read_file(checked, by_name, %{"skill" => "s", "path" => path})
      end

      refute File.exists?(sentinel)
      assert :persistent_term.get(key, :unset) == :unset
    end
  end

  describe "agent_loop_accepts" do
    @model "claude-sonnet-4-5"
    @role "You are a test agent."
    @loop_window %{
      provider_id: "test",
      model_id: "test",
      size: 1_000_000,
      unit: :tokens,
      estimator_id: "bytes",
      estimator_version: 1
    }

    # The input forms of the tests of workflow/agent-loop, as small builders.
    defp loop_input(kind, fields),
      do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)

    defp start_input do
      loop_input("start", %{
        "schema_id" => "elzoo.agent-loop.message",
        "schema_version" => 1,
        "payload" => %{"text" => "go"}
      })
    end

    defp outcome(id, class, schema, payload),
      do:
        loop_input("action_outcome", %{
          "action_id" => id,
          "outcome" => class,
          "schema_id" => schema,
          "schema_version" => 1,
          "payload" => payload
        })

    defp model_outcome(n, proposals),
      do:
        outcome("run:m:#{n}", "completed", "elzoo.ai-text.result", %{
          "content" => "",
          "finish" => "tool_calls",
          "tool_proposals" => proposals,
          "structured" => nil,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
          "provenance" => %{"response_id" => "r"}
        })

    defp proposal(id, name, arguments),
      do: %{
        "id" => id,
        "name" => name,
        "raw_arguments" => "{}",
        "arguments" => arguments,
        "malformed" => nil
      }

    defp tool_result_outcome(id, payload),
      do: outcome(id, "completed", "elzoo.agent-loop.tool-result", payload)

    defp estimate(bytes),
      do:
        {:ok,
         %{
           size: byte_size(bytes),
           unit: :tokens,
           direction: :upper_bound,
           estimator_id: "bytes",
           estimator_version: 1
         }}

    defp loop_state(source) do
      assert {:ok, state} =
               AgentLoop.new(%{
                 id: "run",
                 model: @model,
                 max_output_tokens: 256,
                 role_instructions: [@role],
                 window: @loop_window,
                 max_request_bytes: 65_536,
                 max_image_refs: 4,
                 sources: [source],
                 result_limits: %{max_bytes: 1_024, artifact_max_bytes: 1_000_000},
                 ask: nil,
                 turn_limit: 12
               })

      state
    end

    defp block(sources, text, max_bytes) do
      assert {:ok, marked} =
               UntrustedContent.decode(%{
                 "schema_id" => "elzoo.untrusted-content.marked",
                 "schema_version" => 1,
                 "sources" => sources,
                 "trust" => "untrusted",
                 "max_bytes" => max_bytes,
                 "content" => text
               })

      assert {:ok, rendered} = UntrustedContent.render(marked)
      rendered
    end

    defp notice(text), do: block(["agent-loop"], text, 65_536)
    defp tool_text(id, text), do: %{"role" => "tool_result", "tool_use_id" => id, "text" => text}
    defp messages(%{"actions" => [%{"kind" => "model_call", "payload" => p}]}), do: p["messages"]
    defp request_tools(%{"actions" => [%{"payload" => p}]}), do: p["tools"]

    defp trace_scenario do
      big_a = String.duplicate("a", 10_000)
      big_b = String.duplicate("b", 8_000)

      {checked, files} =
        pinned!([
          skill!("alpha", body: "Alpha instructions\n", files: %{"notes.txt" => "Alpha notes\n"}),
          skill!("tooly",
            body: "Tooly instructions\n",
            tools: ["tool-identity-one", "tool-identity-two"],
            extra: "allowed-tools: Bash(git:*) Read\n"
          ),
          skill!("big-a", body: big_a),
          skill!("big-b", body: big_b)
        ])

      source = source!("sk", checked)
      {:ok, snapshot} = ToolRegistry.snapshot([source])
      {:resolved, load_tool} = ToolRegistry.resolve(snapshot, "sk_load_skill")
      {:resolved, read_tool} = ToolRegistry.resolve(snapshot, "sk_read_skill_file")
      payload = fn name -> elem(Skill.load(checked, %{"name" => name}), 1) end
      {:error, unknown} = Skill.load(checked, %{"name" => "gamma"})
      assert unknown == :unknown_skill

      read_payload =
        elem(Skill.read_file(checked, files, %{"skill" => "alpha", "path" => "notes.txt"}), 1)

      inputs = [
        start_input(),
        model_outcome(1, [proposal("c1", "sk_load_skill", %{"name" => "alpha"})]),
        tool_result_outcome("run:t:1:1", payload.("alpha")),
        model_outcome(2, [proposal("c2", "sk_load_skill", %{"name" => "alpha"})]),
        tool_result_outcome("run:t:2:1", payload.("alpha")),
        model_outcome(3, [proposal("c3", "sk_load_skill", %{"name" => "big-a"})]),
        tool_result_outcome("run:t:3:1", payload.("big-a")),
        model_outcome(4, [proposal("c4", "sk_load_skill", %{"name" => "big-b"})]),
        tool_result_outcome("run:t:4:1", payload.("big-b")),
        model_outcome(5, [
          proposal("c5", "sk_read_skill_file", %{"skill" => "alpha", "path" => "notes.txt"})
        ]),
        tool_result_outcome("run:t:5:1", read_payload),
        model_outcome(6, [
          proposal("c6", "sk_read_skill_file", %{"skill" => "alpha", "path" => "x"})
        ]),
        # The host binds `{:error, reason}` of the tool to a refused outcome (here, as
        # for a pin that no longer holds the skill).
        outcome("run:t:6:1", "refused", "elzoo.run-engine.refusal", %{
          "reason" => Atom.to_string(unknown)
        }),
        model_outcome(7, [proposal("c7", "sk_load_skill", %{"name" => "tooly"})]),
        tool_result_outcome("run:t:7:1", payload.("tooly"))
      ]

      %{
        source: source,
        snapshot: snapshot,
        load_tool: load_tool,
        read_tool: read_tool,
        inputs: inputs,
        read_payload: read_payload,
        bodies: %{"big-a" => big_a, "big-b" => big_b}
      }
    end

    defp tool_call(id, tool, source_tool, arguments),
      do: %{
        "id" => id,
        "kind" => "tool_call",
        "schema_id" => "elzoo.agent-loop.tool-call",
        "schema_version" => 1,
        "payload" => %{
          "alias" => "sk_" <> source_tool,
          "source" => "sk",
          "tool" => source_tool,
          "version" => tool.version,
          "arguments" => arguments
        }
      }

    # The request after input `n` (0-based), where `n` indexes the trace.
    defp requests(scenario) do
      Enum.scan(scenario.inputs, {loop_state(scenario.source), nil}, fn input, {state, _} ->
        assert {:Transition, next, {:some, request}} = AgentLoop.step(state, input, &estimate/1)
        {next, request}
      end)
    end

    test "a load is one tool action; its payload is accepted and the body is in the system message" do
      scenario = trace_scenario()
      requests = requests(scenario)

      assert {_, %{"actions" => [action]}} = Enum.at(requests, 1)

      assert action ==
               tool_call("run:t:1:1", scenario.load_tool, "load_skill", %{"name" => "alpha"})

      assert {_, accepted} = Enum.at(requests, 2)
      [system | rest] = messages(accepted)
      assert List.last(rest) == tool_text("c1", notice("[declaration accepted]"))
      assert system == %{"role" => "system", "text" => @role <> "\n\n" <> "Alpha instructions\n"}
      assert String.ends_with?(system["text"], "\n\nAlpha instructions\n")

      # The body is outside every marked block.
      refute Enum.any?(rest, &String.contains?(&1["text"] || "", "Alpha instructions"))
    end

    test "a second load is refused as already_loaded and the body stays in the system message once" do
      scenario = trace_scenario()
      requests = requests(scenario)

      assert {_, again} = Enum.at(requests, 4)
      [system | rest] = messages(again)
      assert system == %{"role" => "system", "text" => @role <> "\n\n" <> "Alpha instructions\n"}
      assert length(String.split(system["text"], "Alpha instructions")) == 2
      assert List.last(rest) == tool_text("c2", notice("[declaration refused: already_loaded]"))
    end

    test "a load past 16,384 bytes of instructions is refused and changes nothing" do
      scenario = trace_scenario()
      requests = requests(scenario)

      assert {before_state, accepted} = Enum.at(requests, 6)
      [system | _] = messages(accepted)
      assert system["text"] == @role <> "\n\nAlpha instructions\n\n\n" <> scenario.bodies["big-a"]

      assert {refused_state, refused} = Enum.at(requests, 8)

      assert List.last(messages(refused)) ==
               tool_text("c4", notice("[declaration refused: instructions_over_bound]"))

      assert hd(messages(refused)) == system
      assert refused_state.skills == before_state.skills
      refute String.contains?(inspect(refused_state, limit: :infinity), "bbbbbbbbbb")
    end

    test "a read_skill_file outcome is a tool result inside a marked block" do
      scenario = trace_scenario()
      assert {_, action_request} = Enum.at(requests(scenario), 9)

      assert %{"actions" => [action]} = action_request

      assert action ==
               tool_call("run:t:5:1", scenario.read_tool, "read_skill_file", %{
                 "skill" => "alpha",
                 "path" => "notes.txt"
               })

      assert {_, read} = Enum.at(requests(scenario), 10)

      assert List.last(messages(read)) ==
               tool_text("c5", block(["skill:alpha"], "Alpha notes\n", byte_size("Alpha notes\n")))
    end

    test "a refused outcome with unknown_skill is a notice" do
      scenario = trace_scenario()
      assert {_, refused} = Enum.at(requests(scenario), 12)

      assert List.last(messages(refused)) ==
               tool_text("c6", notice("[tool call not completed: refused: unknown_skill]"))
    end

    test "the tools of each model request are the same before and after a load of a skill with tools" do
      scenario = trace_scenario()
      requests = requests(scenario)
      expected = ToolRegistry.tools(scenario.snapshot)

      model_requests =
        for {_, %{"actions" => [%{"kind" => "model_call"}]} = request} <- requests,
            do: request_tools(request)

      assert length(model_requests) == 8
      assert Enum.all?(model_requests, &(&1 == expected))

      # Before the load of "tooly" (input 13 asks for it), and after it (input 14).
      assert {_, %{"actions" => [%{"kind" => "model_call"}]} = after_load} = Enum.at(requests, 14)
      [system | _] = messages(after_load)
      assert String.contains?(system["text"], "Tooly instructions")
      assert request_tools(after_load) == expected
      refute String.contains?(Jason.encode!(request_tools(after_load)), "tool-identity")
      refute String.contains?(Jason.encode!(request_tools(after_load)), "allowed-tools")
    end

    test "the trace cut after each input and folded again gives the same states and requests" do
      scenario = trace_scenario()
      full = requests(scenario)

      for n <- 1..length(scenario.inputs) do
        cut = requests(%{scenario | inputs: Enum.take(scenario.inputs, n)})
        assert cut == Enum.take(full, n)
      end

      # The load action identity appears in one request only.
      requested = for {_, request} <- full, do: Jason.encode!(request)
      assert Enum.count(requested, &String.contains?(&1, ~s("run:t:1:1"))) == 1
    end
  end

  describe "pinned_version_answers" do
    test "load/2 and read_file/3 given P1 and its files answer P1 after P2 exists" do
      one = [
        skill!("alpha", body: "Old body\n", version: "1", files: %{"a.txt" => "old bytes"}),
        skill!("beta")
      ]

      two = [
        skill!("alpha", body: "New body\n", version: "2", files: %{"a.txt" => "new bytes"}),
        skill!("beta")
      ]

      {p1, files1} = pinned!(one)
      {p2, files2} = pinned!(two)

      assert RecipePackage.encode(p1)["identity"] != RecipePackage.encode(p2)["identity"]
      assert RecipePackage.encode(p1)["skills"] != RecipePackage.encode(p2)["skills"]

      assert {:ok, %{"declaration" => %{"skill" => %{"instructions" => "Old body\n"}}}} =
               Skill.load(p1, %{"name" => "alpha"})

      assert {:ok, %{"declaration" => %{"skill" => %{"instructions" => "New body\n"}}}} =
               Skill.load(p2, %{"name" => "alpha"})

      args = %{"skill" => "alpha", "path" => "a.txt"}
      assert {:ok, %{"content" => %{"content" => "old bytes"}}} = Skill.read_file(p1, files1, args)
      assert {:ok, %{"content" => %{"content" => "new bytes"}}} = Skill.read_file(p2, files2, args)

      # The sources of the two packages differ only where a skill differs: none here.
      assert Skill.source("sk", p1) == Skill.source("sk", p2)
    end

    test "the checked example reads a folder, builds a package and answers a load and a file read" do
      {result, _binding} =
        Code.eval_file(Path.expand("../../examples/skill.exs", __DIR__))

      assert %{text: "Amounts match to the cent.\n", identity: "recipe-package-v1:sha256:" <> hex} =
               result

      assert byte_size(hex) == 64
    end
  end
end
