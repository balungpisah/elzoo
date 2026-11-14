defmodule Elzoo.SkillTest do
  use ExUnit.Case, async: true

  alias Elzoo.RecipePackage
  alias Elzoo.Skill

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
      assert {:error, :missing_skill_md} = read(%{"docs/SKILL.md" => md(@fm, "b\n")})
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
end
