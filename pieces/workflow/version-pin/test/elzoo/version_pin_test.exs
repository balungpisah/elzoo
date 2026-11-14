# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.VersionPinTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Elzoo.VersionPin

  @prefix "recipe-package-v1:sha256:"
  @old @prefix <> String.duplicate("a", 64)
  @new @prefix <> String.duplicate("b", 64)
  @other @prefix <> String.duplicate("c", 64)
  @sentinel "SENTINEL-4d1f9c"

  defp tool(name),
    do: %{
      "trust" => "untrusted",
      "name" => name,
      "description" => "Run " <> name,
      "input_schema" => %{"type" => "object"},
      "annotations" => nil
    }

  defp source(id, kind, callable, tools),
    do: %{"id" => id, "kind" => kind, "callable" => callable, "tools" => tools}

  defp sources,
    do: [
      source("guide", "pinned_skill", "nested", [tool("search"), tool("open")]),
      source("issues", "host_listing", "adapter", [tool("search")])
    ]

  defp captured,
    do: [
      %{"id" => "guide", "kind" => "pinned_skill", "callable" => "nested"},
      %{"id" => "issues", "kind" => "host_listing", "callable" => "adapter"}
    ]

  defp pin do
    assert {:ok, pin} = VersionPin.new(@old, sources())
    pin
  end

  defp step(pin, input) do
    assert {:Transition, next, {:some, result}} = VersionPin.step(pin, input)
    {next, result}
  end

  defp same_set?(pin), do: VersionPin.sources(pin) == captured()

  describe "pin_at_start" do
    test "keeps the version and the sources without tool lists" do
      pin = pin()
      assert VersionPin.version(pin) == @old
      assert VersionPin.sources(pin) == captured()
      refute inspect(pin) =~ "search"
      refute inspect(pin) =~ "input_schema"
    end

    test "an empty source list is a valid start" do
      assert {:ok, pin} = VersionPin.new(@old, [])
      assert VersionPin.sources(pin) == []
    end

    test "each malformed identity is invalid_input" do
      for bad <- [
            "",
            @old <> "0",
            binary_part(@old, 0, 88),
            @prefix <> String.duplicate("A", 64),
            @prefix <> String.duplicate("g", 64),
            "recipe-package-v2:sha256:" <> String.duplicate("a", 64),
            "recipe-package-v1:sha512:" <> String.duplicate("a", 64),
            @old <> "\n",
            nil,
            :atom,
            123,
            %{},
            [@old],
            {@old}
          ] do
        assert VersionPin.new(bad, sources()) == {:error, :invalid_input}
      end
    end

    test "each refusal of snapshot/1 is invalid_input" do
      good = source("guide", "pinned_skill", "nested", [])

      for bad <- [
            nil,
            :sources,
            [:source],
            [%{}],
            [Map.delete(good, "tools")],
            [Map.put(good, "extra", 1)],
            [Map.put(good, "id", "")],
            [Map.put(good, "id", String.duplicate("a", 33))],
            [Map.put(good, "id", "bad id")],
            [Map.put(good, "kind", "skill")],
            [Map.put(good, "callable", "native")],
            [Map.put(good, "tools", :none)],
            [good, good],
            [Map.put(good, "tools", [Map.put(tool("t"), "trust", "trusted")])],
            [Map.put(good, "tools", [tool("t"), tool("t")])],
            [Map.put(good, "tools", Enum.map(1..65, &tool("t#{&1}")))]
          ] do
        assert VersionPin.new(@old, bad) == {:error, :invalid_input}
      end
    end
  end

  describe "publish_changes_no_running_run" do
    test "published inputs leave version and sources equal" do
      start = pin()

      {results, last} =
        Enum.map_reduce(List.flatten(List.duplicate([@new, @other, @old, @new], 5)), start, fn id,
                                                                                               pin ->
          {next, result} = step(pin, {:published, id})
          {result, next}
        end)

      assert Enum.all?(results, &(&1 == :unchanged))
      assert last == start
      assert VersionPin.version(last) == @old
      assert same_set?(last)
    end
  end

  describe "explicit_change_only" do
    test "a new identity gives changed and the new version" do
      start = pin()
      {next, result} = step(start, {:change_version, @new})
      assert result == {:changed, @old, @new}
      assert VersionPin.version(next) == @new
      assert VersionPin.sources(next) == VersionPin.sources(start)

      {again, result} = step(next, {:change_version, @other})
      assert result == {:changed, @new, @other}
      assert VersionPin.version(again) == @other
      assert same_set?(again)
    end

    test "the same identity is unchanged" do
      start = pin()
      assert {^start, :unchanged} = step(start, {:change_version, @old})
    end

    test "a malformed identity is refused and changes nothing" do
      start = pin()

      for bad <- [@sentinel, @new <> "0", String.upcase(@new), nil, 7, :new, [@new]] do
        assert {^start, {:refused, :invalid_input}} = step(start, {:change_version, bad})
      end
    end

    test "only a change input moves the version" do
      start = pin()

      for input <- [
            {:published, @new},
            :settings_changed,
            {:listing, "guide"},
            {:listing, "nobody"},
            {:add_source, @new},
            {:change_version, @old},
            {:change_version, :bad},
            :other
          ] do
        {next, _} = step(start, input)
        assert VersionPin.version(next) == @old
      end
    end
  end

  describe "settings_affect_next_run" do
    test "settings_changed changes nothing in a pin" do
      start = pin()
      assert {^start, :unchanged} = step(start, :settings_changed)

      {changed, _} = step(start, {:change_version, @new})
      assert {^changed, :unchanged} = step(changed, :settings_changed)
    end

    test "a second new/2 with other sources gives the other set" do
      start = pin()
      later = [source("wiki", "other", "adapter", [tool("read")])]
      assert {:ok, next_run} = VersionPin.new(@old, later)

      assert VersionPin.sources(next_run) == [
               %{"id" => "wiki", "kind" => "other", "callable" => "adapter"}
             ]

      assert VersionPin.sources(start) == captured()
      assert {^start, :unchanged} = step(start, :settings_changed)
    end
  end

  describe "source_set_closed" do
    test "add_source is refused for a well-formed and a malformed source" do
      start = pin()
      well_formed = source("wiki", "other", "adapter", [tool("read")])

      for term <- [
            well_formed,
            %{"id" => "guide"},
            Map.delete(well_formed, "tools"),
            @sentinel,
            nil,
            [],
            {:x, 1}
          ] do
        assert {next, {:refused, :source_set_closed}} = step(start, {:add_source, term})
        assert next == start
        assert same_set?(next)
      end
    end

    test "listing is known for each captured id and outside for another" do
      start = pin()

      for %{"id" => id} <- captured() do
        assert {^start, :known_source} = step(start, {:listing, id})
      end

      for id <- ["wiki", "Guide", "guide2", "gui", String.duplicate("a", 32)] do
        assert {^start, {:refused, :outside_source}} = step(start, {:listing, id})
      end

      for id <- ["", String.duplicate("a", 33), "bad id", "guide\n", nil, :guide, 1, <<255>>] do
        assert {^start, {:refused, :invalid_input}} = step(start, {:listing, id})
      end
    end

    test "the set is equal after every kind of input in sequence" do
      inputs = [
        {:add_source, %{"id" => "wiki"}},
        {:change_version, @new},
        {:listing, "wiki"},
        {:published, @other},
        {:add_source, captured()},
        :settings_changed
      ]

      final =
        Enum.reduce(inputs, pin(), fn input, pin ->
          {next, _} = step(pin, input)
          assert same_set?(next)
          next
        end)

      assert VersionPin.version(final) == @new
    end
  end

  describe "total_and_redacted" do
    defp inputs do
      secret = @sentinel
      source_term = %{"id" => secret, "kind" => "other", "callable" => "adapter", "tools" => []}

      [
        {:change_version, @new},
        {:change_version, @old},
        {:change_version, @new <> secret},
        {:change_version, secret},
        {:change_version, String.upcase(@new)},
        {:change_version, @prefix <> String.duplicate("a", 63)},
        {:change_version, "recipe-package-v2:sha256:" <> String.duplicate("a", 64)},
        {:change_version, <<255, 254>> <> secret},
        {:change_version, nil},
        {:change_version, [secret]},
        {:published, @new},
        {:published, @old},
        {:published, @other},
        {:published, secret},
        {:published, @prefix <> secret},
        {:published, String.upcase(@old)},
        {:published, %{"x" => secret}},
        :settings_changed,
        {:settings_changed, secret},
        {:listing, "guide"},
        {:listing, "issues"},
        {:listing, "wiki"},
        {:listing, secret <> " bad id"},
        {:listing, secret <> String.duplicate("x", 40)},
        {:listing, secret <> <<255>>},
        {:listing, ""},
        {:listing, :guide},
        {:listing, {secret}},
        {:add_source, source_term},
        {:add_source, secret},
        {:add_source, nil},
        {:add_source, [source_term, secret]},
        {:add_source, %{secret => secret}},
        {:add_source},
        {:add_source, secret, secret},
        {:published},
        {:change_version},
        {:listing, "guide", secret},
        {:unknown_tag, secret},
        :unknown_atom,
        secret,
        nil,
        42,
        1.5,
        [secret],
        %{"type" => secret},
        {},
        {secret, secret, secret, secret},
        fn -> secret end
      ]
    end

    defp redacted?(text), do: not String.contains?(text, @sentinel)

    test "each result is one of the forms of the table" do
      start = pin()

      assert length(inputs()) >= 40

      for input <- inputs() do
        assert {:Transition, next, {:some, result}} = VersionPin.step(start, input)

        assert result in [
                 :unchanged,
                 :known_source,
                 {:refused, :outside_source},
                 {:refused, :source_set_closed},
                 {:refused, :invalid_input}
               ] or match?({:changed, @old, @new}, result)

        assert VersionPin.sources(next) == captured()
        assert VersionPin.version(next) in [@old, @new]
      end
    end

    test "a sentinel in a refused input never appears in a result or a log" do
      start = pin()

      log =
        capture_log(fn ->
          for input <- inputs() do
            {:Transition, next, {:some, result}} = VersionPin.step(start, input)

            if String.contains?(inspect(input, limit: :infinity), @sentinel) do
              assert redacted?(inspect(result))
              assert redacted?(inspect(next))
            end
          end
        end)

      assert redacted?(log)
    end

    test "equal inputs give equal results" do
      for input <- inputs() do
        assert VersionPin.step(pin(), input) == VersionPin.step(pin(), input)
      end
    end

    test "new/2 over junk operands is refused without a trace of them" do
      log =
        capture_log(fn ->
          for {version, sources} <- [
                {@sentinel, sources()},
                {@old, @sentinel},
                {@old, [@sentinel]},
                {@old, [%{@sentinel => @sentinel}]},
                {@old, [source(@sentinel <> " x", "other", "adapter", [])]}
              ] do
            assert {:error, :invalid_input} = VersionPin.new(version, sources)
          end
        end)

      assert redacted?(log)
    end

    test "selected Cure laws and the checked example" do
      source = File.read!(Path.expand("../../cure/elzoo/version_pin.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
      assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      assert audit.absurd == 0

      {result, _} = Code.eval_file(Path.expand("../../examples/version_pin.exs", __DIR__))

      assert result == [
               :known_source,
               {:refused, :source_set_closed},
               :unchanged,
               {:changed, @old, @new}
             ]
    end
  end
end
