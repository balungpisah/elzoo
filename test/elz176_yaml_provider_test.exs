# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Elz176YamlProviderTest do
  # Not async: group 5 compares the VM-wide atom count, so no other test may run.
  use ExUnit.Case, async: false

  # ELZ-176: finite behaviour of yaml_elixir 2.12.2 over yamerl 0.10.0 on literal
  # documents. Every assertion below is the term that the pinned versions give.

  @yaml_elixir_version "2.12.2"
  @yamerl_version "0.10.0"
  @read_options []

  defp read(document, options \\ @read_options),
    do: YamlElixir.read_from_string(document, options)

  test "plain_frontmatter" do
    document = ~S"""
    plain: abc def
    single: 'a b'
    double: "c\td"
    literal: |
      one
      two
    folded: >
      three
      four

      five
    nested:
      k1: v1
      k2: "v2"
    """

    # The call needs no option for string keys: `@read_options` is `[]`.
    assert @read_options == []

    assert read(document) ==
             {:ok,
              %{
                "plain" => "abc def",
                "single" => "a b",
                "double" => "c\td",
                "literal" => "one\ntwo\n",
                "folded" => "three four\nfive\n",
                "nested" => %{"k1" => "v1", "k2" => "v2"}
              }}
  end

  test "typed_scalars_are_visible" do
    # {text, term of the plain scalar, term of the same text quoted}
    scalars = [
      {"true", true, "true"},
      {"no", "no", "no"},
      {"on", "on", "on"},
      {"null", nil, "null"},
      {"~", nil, "~"},
      {"12", 12, "12"},
      {"1.5", 1.5, "1.5"},
      {"0x10", 16, "0x10"},
      {"2026-11-14", "2026-11-14", "2026-11-14"}
    ]

    for {text, plain, quoted} <- scalars do
      assert read("k: #{text}\n") == {:ok, %{"k" => plain}}, "plain #{text}"
      assert read("k: '#{text}'\n") == {:ok, %{"k" => quoted}}, "single-quoted #{text}"
      assert read(~s(k: "#{text}"\n)) == {:ok, %{"k" => quoted}}, "double-quoted #{text}"
    end

    # An empty value is nil; an empty quoted value is the empty string.
    assert read("k:\n") == {:ok, %{"k" => nil}}
    assert read("k: ''\n") == {:ok, %{"k" => ""}}
    assert read(~s(k: ""\n)) == {:ok, %{"k" => ""}}
  end

  test "aliases_and_merges" do
    # Alias in block style: expanded to the anchored value; no marker, no error.
    alias_document = "base: &b\n  x: 1\nuse: *b\n"
    expanded = {:ok, %{"base" => %{"x" => 1}, "use" => %{"x" => 1}}}
    assert read(alias_document) == expanded
    # The only alias-related option, `merge_anchors`, does not make an alias an error.
    assert read(alias_document, merge_anchors: true) == expanded

    # Merge key without the option: kept as an extra key `<<N` (N is a counter).
    merge_document = "base: &b\n  x: 1\nuse:\n  <<: *b\n  y: 2\n"

    assert {:ok, %{"base" => %{"x" => 1}, "use" => use}} = read(merge_document)
    assert [{"y", 2}] = Enum.reject(use, fn {key, _} -> key =~ ~r/\A<<\d+\z/ end)
    assert [{marker, %{"x" => 1}}] = Enum.filter(use, fn {key, _} -> key =~ ~r/\A<<\d+\z/ end)
    assert marker =~ ~r/\A<<\d+\z/

    # With `merge_anchors: true` the merge is applied.
    assert read(merge_document, merge_anchors: true) ==
             {:ok, %{"base" => %{"x" => 1}, "use" => %{"x" => 1, "y" => 2}}}

    # An alias with no anchor is an error struct.
    assert {:error,
            %YamlElixir.ParsingError{
              line: 1,
              column: 4,
              type: :no_matching_anchor,
              message: ~s(No anchor corresponds to alias "nope")
            }} == read("a: *nope\n")

    # Depth-6 chain, block style: expands to the nested values (3 leaves here).
    block_chain =
      "a0: &a0\n  - x\n  - x\na1: &a1\n  - *a0\n  - *a0\na2: &a2\n  - *a1\n  - *a1\n" <>
        "a3: &a3\n  - *a2\n  - *a2\na4: &a4\n  - *a3\n  - *a3\na5: &a5\n  - *a4\n  - *a4\n" <>
        "a6:\n  - *a5\n  - *a5\n"

    assert {:ok, %{"a1" => [["x", "x"], ["x", "x"]], "a6" => a6}} = read(block_chain)
    assert length(List.flatten(a6)) == 2 * 2 * 2 * 2 * 2 * 2 * 2

    # Depth-6 chain, flow style: the pinned version does not give the anchored
    # value. Every level from a2 on is three copies of its own key name. This is
    # a wrong result, not an error and not a marker.
    flow_chain =
      "a0: &a0 [x, x, x]\na1: &a1 [*a0, *a0, *a0]\na2: &a2 [*a1, *a1, *a1]\n" <>
        "a3: &a3 [*a2, *a2, *a2]\na4: &a4 [*a3, *a3, *a3]\na5: &a5 [*a4, *a4, *a4]\n" <>
        "a6: [*a5, *a5, *a5]\n"

    assert read(flow_chain) ==
             {:ok,
              %{
                "a0" => ["x", "x", "x"],
                "a1" => ["x", "x", "x"],
                "a2" => ["a2", "a2", "a2"],
                "a3" => ["a3", "a3", "a3"],
                "a4" => ["a4", "a4", "a4"],
                "a5" => ["a5", "a5", "a5"],
                "a6" => ["a6", "a6", "a6"]
              }}

    # No option and no result form refuses an alias or leaves it detectable, so a
    # caller must refuse `&`, `*` and `<<` before the call. Quoted markers stay text.
    assert read("a: '&x'\nb: '*x'\nc: \"<<\"\n") ==
             {:ok, %{"a" => "&x", "b" => "*x", "c" => "<<"}}
  end

  test "not_one_plain_map" do
    assert read("- a\n- b\n") == {:ok, ["a", "b"]}
    assert read("just text\n") == {:ok, "just text"}
    assert read("") == {:ok, %{}}
    assert read("   \n") == {:ok, %{}}

    # Two documents: read_from_string/2 gives the last one and drops the first.
    two = "---\na: 1\n---\nb: 2\n"
    assert read(two) == {:ok, %{"b" => 2}}
    assert YamlElixir.read_all_from_string(two) == {:ok, [%{"a" => 1}, %{"b" => 2}]}

    # Duplicate key: no error; the first value wins.
    assert read("a: 1\na: 2\n") == {:ok, %{"a" => 1}}

    # Tab indentation: no error; the tab line is read as a nested key of an empty value.
    assert read("a:\n\tb: 1\n") == {:ok, %{"a" => nil, "b" => 1}}

    # Invalid UTF-8 inside a document.
    assert {:error,
            %YamlElixir.ParsingError{
              line: :undefined,
              column: :undefined,
              type: :invalid_unicode,
              message: "Invalid Unicode character at byte #5"
            }} == read("a: x" <> <<0xFF, 0xFE>> <> "y\n")

    assert {:error,
            %YamlElixir.ParsingError{
              line: 1,
              column: 6,
              type: :unexpected_eos,
              message: "Unexpected end-of-stream while parsing flow scalar"
            }} == read("a: \"x" <> <<0xFF, 0xFE>> <> "y\"\n")

    # The bytes FF FE at the start are read as a UTF-16 byte-order mark: the rest
    # of the document is decoded as UTF-16 text, so the result is a scalar.
    assert read(<<0xFF, 0xFE>> <> "a: 1\n") == {:ok, <<14_945::utf8, 12_576::utf8>>}

    # Tags: `!!binary` is decoded; unknown tags are an error.
    assert read("a: !!binary aGVsbG8=\n") == {:ok, %{"a" => "hello"}}

    assert {:error,
            %YamlElixir.ParsingError{
              line: 1,
              column: 4,
              type: :unrecognized_node,
              message: ~s(Tag "!ruby/object:Foo" unrecognized by any module)
            }} == read("a: !ruby/object:Foo {x: 1}\n")

    # Malformed flow collection: the catch-all error.
    assert {:error,
            %YamlElixir.ParsingError{line: nil, column: nil, type: nil, message: "malformed yaml"}} ==
             read("a: [")

    # No input raised or killed this process.
    assert Process.alive?(self())
  end

  test "no_atoms_no_code" do
    on_exit(fn -> :persistent_term.erase(:elz176_effect) end)
    :persistent_term.erase(:elz176_effect)

    # Option set of group 1: no `atoms: true`.
    assert @read_options == []

    documents = for n <- 1..2_000, do: "elz176_key_#{n}_#{System.unique_integer([:positive])}: v\n"
    assert documents |> Enum.uniq() |> length() == 2_000

    # Warm-up: loads yamerl state, error structs and the ordinary paths.
    assert {:ok, %{"warm" => "up"}} = read("warm: up\n")
    assert {:error, %YamlElixir.ParsingError{}} = read("a: [")

    before_count = :erlang.system_info(:atom_count)
    results = Enum.map(documents, &read/1)
    after_count = :erlang.system_info(:atom_count)

    for {document, result} <- Enum.zip(documents, results) do
      key = String.trim_trailing(document, ": v\n")
      assert result == {:ok, %{key => "v"}}
    end

    assert after_count == before_count

    # No code: node modules for Erlang terms are off by default, so the tag that
    # would evaluate Erlang text is an unknown tag and the effect never happens.
    assert :yamerl_app.get_param(:node_mods) == []
    code = "a: !<tag:yamerl,2012:fun> persistent_term:put(elz176_effect, ran).\n"

    assert {:error,
            %YamlElixir.ParsingError{
              line: 1,
              column: 4,
              type: :unrecognized_node,
              message: ~s(Tag "tag:yamerl,2012:fun" unrecognized by any module)
            }} == read(code)

    assert {:error, %YamlElixir.ParsingError{type: :unrecognized_node}} =
             read("a: !<tag:yamerl,2012:atom> foo\n")

    assert :persistent_term.get(:elz176_effect, :not_run) == :not_run

    # Control: the detector works. Only a caller that turns the node module on
    # (global yamerl parameter, restored here) makes the same document run code.
    try do
      :yamerl_app.set_param(:node_mods, [:yamerl_node_erlang_fun])
      assert {:error, %YamlElixir.ParsingError{message: "malformed yaml"}} = read(code)
      assert :persistent_term.get(:elz176_effect, :not_run) == :ran
    after
      :yamerl_app.set_param(:node_mods, [])
    end

    assert :yamerl_app.get_param(:node_mods) == []
  end

  test "bounded_time" do
    for size <- [16_384, 1_048_576] do
      document = nested_document(size)
      # Exactly the stated size in bytes.
      assert byte_size(document) == size

      task = Task.async(fn -> :timer.tc(fn -> read(document) end) end)
      result = Task.yield(task, 5_000) || Task.shutdown(task)

      assert {:ok, {microseconds, {:ok, map}}} = result
      assert is_map(map) and map_size(map) > 1
      assert map["k0"] == %{"a" => %{"b" => %{"c" => "v0"}}}

      IO.puts("ELZ-176: bounded_time bytes=#{size} microseconds=#{microseconds}")
    end
  end

  test "hosted_check_runs_it" do
    # Pins agree across mix.exs, the lock, the loaded applications and the providers.
    deps = Mix.Project.config()[:deps]
    assert {:yaml_elixir, "== " <> @yaml_elixir_version} in deps
    assert {:yamerl, "== " <> @yamerl_version} in deps

    lock = Mix.Dep.Lock.read()
    assert {:hex, :yaml_elixir, @yaml_elixir_version, _, _, _, "hexpm", _} = lock.yaml_elixir
    assert {:hex, :yamerl, @yamerl_version, _, _, _, "hexpm", _} = lock.yamerl

    assert Application.spec(:yaml_elixir, :vsn) == String.to_charlist(@yaml_elixir_version)
    assert Application.spec(:yamerl, :vsn) == String.to_charlist(@yamerl_version)

    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    assert :yaml_elixir in started
    assert :yamerl in started

    providers = Jason.decode!(File.read!("registry/providers.json"))["providers"]

    for {id, version, license, hex_license} <- [
          {"yaml_elixir", @yaml_elixir_version, "MIT", "MIT"},
          {"yamerl", @yamerl_version, "BSD-2-Clause", "BSD 2-Clause"}
        ] do
      provider = providers[id]
      assert provider["source"] == "hex"
      assert provider["package"] == id
      assert provider["version"] == version
      assert provider["license"] == license
      assert String.starts_with?(provider["reference"], "https://hexdocs.pm/#{id}/#{version}/")

      path = Path.join(Mix.Project.deps_paths()[String.to_atom(id)], "hex_metadata.config")
      {:ok, metadata} = :file.consult(String.to_charlist(path))
      assert {"licenses", [hex_license]} == List.keyfind(metadata, "licenses", 0)
    end
  end

  # Nested plain maps, four levels per entry, padded to exactly `size` bytes.
  defp nested_document(size) do
    {chunks, used} =
      Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), {[], 0}, fn n, {chunks, used} ->
        chunk = "k#{n}:\n  a:\n    b:\n      c: v#{n}\n"

        if used + byte_size(chunk) + 64 > size,
          do: {:halt, {chunks, used}},
          else: {:cont, {[chunk | chunks], used + byte_size(chunk)}}
      end)

    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    body <> "pad: " <> String.duplicate("x", size - used - 6) <> "\n"
  end
end
