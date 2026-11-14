defmodule Elzoo.SkillTest do
  use ExUnit.Case, async: true

  alias Elzoo.Skill

  @fm "name: s\ndescription: d\n"
  @max_file 1_048_576

  defp md(frontmatter, body), do: "---\n" <> frontmatter <> "---\n" <> body
  defp folder(extra \\ %{}), do: Map.put(extra, "SKILL.md", md(@fm, "body\n"))
  defp read(files), do: Skill.read("s", "1", [], files)
  defp read_md(skill_md), do: read(%{"SKILL.md" => skill_md})

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
end
