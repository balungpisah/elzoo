# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ToolRegistryTest do
  use ExUnit.Case, async: true
  alias Elzoo.{PayloadSchema, ToolRegistry}

  @schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
    "required" => ["query"]
  }

  defp tool(name, overrides \\ %{}) do
    Map.merge(
      %{
        "trust" => "untrusted",
        "name" => name,
        "description" => "Run " <> name,
        "input_schema" => @schema,
        "annotations" => nil
      },
      overrides
    )
  end

  defp source(id, kind, tools, callable \\ "adapter"),
    do: %{"id" => id, "kind" => kind, "callable" => callable, "tools" => tools}

  defp names(snapshot), do: Enum.map(ToolRegistry.tools(snapshot), & &1["name"])

  test "unknown_and_source_kind" do
    skill = tool("search", %{"annotations" => %{"readOnlyHint" => true}})
    copied = Map.put(skill, "annotations", %{"readOnlyHint" => true, "kind" => "pinned_skill"})

    {:ok, snapshot} =
      ToolRegistry.snapshot([
        source("skills", "pinned_skill", [skill], "nested"),
        source("mcp", "host_listing", [tool("fetch")]),
        source("misc", "other", [skill])
      ])

    assert ToolRegistry.resolve(snapshot, "nothing_here") == :unknown
    assert ToolRegistry.resolve(snapshot, "fetch") == :unknown

    for {name, kind, callable} <- [
          {"skills_search", "pinned_skill", {:nested, "skills", "search"}},
          {"mcp_fetch", "host_listing", {:adapter, "mcp", "fetch"}},
          {"misc_search", "other", {:adapter, "misc", "search"}}
        ] do
      assert {:resolved, %{source_kind: ^kind, callable: ^callable, alias: ^name}} =
               ToolRegistry.resolve(snapshot, name)
    end

    assert ToolRegistry.snapshot([
             source("x", "other", [Map.put(tool("t"), "kind", "pinned_skill")])
           ]) ==
             {:error, :invalid_descriptor}

    assert ToolRegistry.refresh(snapshot, "misc", [Map.put(tool("t"), "kind", "pinned_skill")]) ==
             {:error, :invalid_descriptor}

    {:ok, fresh} = ToolRegistry.refresh(snapshot, "misc", [copied, tool("other_tool")])
    assert {:resolved, %{source_kind: "other"}} = ToolRegistry.resolve(fresh, "misc_search")
    assert {:resolved, %{source_kind: "other"}} = ToolRegistry.resolve(fresh, "misc_other_tool")

    for bad <- [
          [source("bad id", "other", [])],
          [source("x", "skill", [])],
          [source("x", "other", [], "lua")],
          [source("x", "other", []), source("x", "host_listing", [])],
          [Map.put(source("x", "other", []), "extra", 1)],
          [source(String.duplicate("a", 33), "other", [])],
          [source("x", "other", :not_a_list)],
          :not_a_list
        ],
        do: assert(ToolRegistry.snapshot(bad) == {:error, :invalid_source})
  end

  test "same_name_two_sources" do
    {:ok, snapshot} =
      ToolRegistry.snapshot([
        source("left", "host_listing", [tool("search")]),
        source("right", "pinned_skill", [tool("search")], "nested")
      ])

    assert {:resolved, %{source: "left", callable: {:adapter, "left", "search"}}} =
             ToolRegistry.resolve(snapshot, "left_search")

    assert {:resolved, %{source: "right", callable: {:nested, "right", "search"}}} =
             ToolRegistry.resolve(snapshot, "right_search")

    assert ToolRegistry.resolve(snapshot, "search") == {:ambiguous, ["left_search", "right_search"]}

    assert ToolRegistry.snapshot([
             source("a", "other", [tool("b_c")]),
             source("a_b", "other", [tool("c")])
           ]) == {:error, :alias_collision}

    {:ok, before} =
      ToolRegistry.snapshot([source("a", "other", []), source("a_b", "other", [tool("c")])])

    assert ToolRegistry.refresh(before, "a", [tool("b_c")]) == {:error, :alias_collision}
    assert {:resolved, %{source: "a_b"}} = ToolRegistry.resolve(before, "a_b_c")
  end

  test "alias_grammar_and_bound" do
    long = String.duplicate("n", 128)
    listing = [tool("repo.search"), tool("repo_search"), tool(long)]
    {:ok, snapshot} = ToolRegistry.snapshot([source("src", "host_listing", listing)])
    aliases = names(snapshot)

    assert length(Enum.uniq(aliases)) == 3
    assert "src_repo_search" in aliases

    # Body rule: cleaned "src_repo.search", "_", first 8 hex of SHA-256 of "src" <> <<0>> <> "repo.search".
    assert "src_repo_search_e1b6c559" in aliases
    assert Enum.all?(aliases, &Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, &1))
    assert Enum.any?(aliases, &(byte_size(&1) == 64 and String.starts_with?(&1, "src_nnn")))

    {:ok, reordered} =
      ToolRegistry.snapshot([
        source("other", "other", [tool("x")]),
        source("src", "host_listing", Enum.reverse(listing))
      ])

    assert names(snapshot) -- names(reordered) == []

    many = for i <- 1..64, do: tool("t#{i}")

    {:ok, full} =
      ToolRegistry.snapshot([
        source("a", "other", Enum.take(many, 40)),
        source("b", "other", Enum.drop(many, 40))
      ])

    assert length(ToolRegistry.tools(full)) == 64

    request = %{
      "version" => 1,
      "model" => "model-1",
      "messages" => [%{"role" => "user", "text" => "hello"}],
      "max_output_tokens" => 16,
      "tools" => ToolRegistry.tools(full)
    }

    assert {:ok, %{tools: decoded}, _} = Elzoo.AiText.Request.decode(Jason.encode!(request))
    assert length(decoded) == 64

    request = Map.put(request, "tools", ToolRegistry.tools(snapshot))
    assert {:ok, _, _} = Elzoo.AiText.Request.decode(Jason.encode!(request))

    extra = tool("t65")

    assert ToolRegistry.snapshot([source("a", "other", [extra | many])]) ==
             {:error, :too_many_tools}

    assert ToolRegistry.refresh(full, "b", [extra | Enum.drop(many, 40)]) ==
             {:error, :too_many_tools}
  end

  test "fresh_listing" do
    {:ok, snapshot} =
      ToolRegistry.snapshot([
        source("mcp", "host_listing", [tool("fetch"), tool("drop")]),
        source("skills", "pinned_skill", [tool("plan")], "nested")
      ])

    {:resolved, old} = ToolRegistry.resolve(snapshot, "mcp_fetch")
    {:ok, fresh} = ToolRegistry.refresh(snapshot, "mcp", [tool("fetch", %{"description" => "New"})])
    {:resolved, new} = ToolRegistry.resolve(fresh, "mcp_fetch")

    assert new.version != old.version
    assert ToolRegistry.resolve(fresh, "mcp_fetch", old.version) == {:changed, new.version}
    assert ToolRegistry.resolve(fresh, "mcp_fetch", new.version) == {:resolved, new}
    assert ToolRegistry.resolve(fresh, "mcp_drop") == :removed
    assert ToolRegistry.resolve(fresh, "mcp_drop", old.version) == :removed
    assert {:resolved, _} = ToolRegistry.resolve(fresh, "skills_plan")

    {:ok, again} = ToolRegistry.refresh(fresh, "mcp", [tool("fetch"), tool("drop")])
    assert {:resolved, _} = ToolRegistry.resolve(again, "mcp_drop")
    assert ToolRegistry.resolve(again, "mcp_fetch", old.version) == {:resolved, old}

    {:ok, later} = ToolRegistry.refresh(fresh, "mcp", [])
    assert ToolRegistry.resolve(later, "mcp_fetch") == :removed
    assert ToolRegistry.resolve(later, "mcp_drop") == :unknown

    assert ToolRegistry.refresh(snapshot, "nowhere", []) == {:error, :unknown_source}
    assert ToolRegistry.refresh(snapshot, "mcp", :not_a_list) == {:error, :invalid_source}

    # A removal at the server after the last listing is not detected.
    assert {:resolved, _} = ToolRegistry.resolve(snapshot, "mcp_drop")
    assert ToolRegistry.outcome_note({:unknown, {:server_error, :other}}) == :none
  end

  test "one_validation_result" do
    {:ok, snapshot} = ToolRegistry.snapshot([source("mcp", "host_listing", [tool("fetch")])])
    {:resolved, held} = ToolRegistry.resolve(snapshot, "mcp_fetch")

    assert ToolRegistry.check(held, %{"query" => "x"}) == :ok

    port = %{
      "id" => "mcp_fetch",
      "direction" => "input",
      "schema_id" => "elzoo.tool-registry.arguments." <> held.version,
      "schema_version" => 1
    }

    {:ok, checked} = PayloadSchema.build(port, @schema)
    invalid = %{"query" => 7}
    assert {:error, {:violations, list}} = PayloadSchema.check(checked, port, invalid)

    assert ToolRegistry.check(held, invalid) ==
             {:error, {:validator_disagreement, {:violations, list}}}

    assert ToolRegistry.check(held, %{"query" => String.duplicate("a", 65_536)}) ==
             {:error, {:validator_disagreement, :too_large}}

    assert ToolRegistry.outcome_note({:refused, :invalid_arguments}) == :validator_disagreement

    others =
      [{:completed, %{content: [], is_error: false, structured: nil}}] ++
        for(
          reason <-
            ~w(unknown_tool too_large target_refused credentials_unavailable not_connected invalid_request authentication_failed)a,
          do: {:refused, reason}
        ) ++
        for(
          sub <- ~w(invalid_arguments invalid_request protocol_error other)a,
          do: {:unknown, {:server_error, sub}}
        ) ++
        for(
          reason <-
            ~w(input_required malformed_response timeout connection_lost adapter_error settlement_unconfirmed)a,
          do: {:unknown, reason}
        )

    for outcome <- others, do: assert(ToolRegistry.outcome_note(outcome) == :none)
  end

  test "descriptor_rules" do
    fixed = tool("echo", %{"description" => "Echo", "input_schema" => %{"type" => "object"}})
    assert {:ok, snapshot} = ToolRegistry.snapshot([source("s", "host_listing", [fixed])])

    canonical =
      ~s({"annotations":null,"description":"Echo","input_schema":{"type":"object"},"name":"echo"})

    expected = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    assert {:resolved, %{version: ^expected}} = ToolRegistry.resolve(snapshot, "s_echo")

    for trust <- ["trusted", nil] do
      assert ToolRegistry.snapshot([source("s", "other", [Map.put(fixed, "trust", trust)])]) ==
               {:error, :invalid_trust}
    end

    assert ToolRegistry.snapshot([source("s", "other", [Map.delete(fixed, "trust")])]) ==
             {:error, :invalid_descriptor}

    for bad <- [
          Map.put(fixed, "name", "has space"),
          Map.put(fixed, "name", String.duplicate("n", 129)),
          Map.put(fixed, "description", <<255>>),
          Map.put(fixed, "annotations", [1]),
          Map.put(fixed, "annotations", %{"a" => :atom}),
          Map.put(fixed, "input_schema", %{"$ref" => "https://example.test/schema"}),
          Map.put(fixed, "input_schema", %{"type" => {:tuple}})
        ] do
      assert ToolRegistry.snapshot([source("s", "other", [bad])]) == {:error, :invalid_descriptor}
    end

    assert ToolRegistry.snapshot([source("s", "other", [fixed, fixed])]) ==
             {:error, :invalid_descriptor}

    version = fn d ->
      {:ok, snap} = ToolRegistry.snapshot([source("s", "other", [d])])
      {:resolved, %{version: v}} = ToolRegistry.resolve(snap, "s_" <> d["name"])
      v
    end

    for changed <- [
          Map.put(fixed, "name", "echo2"),
          Map.put(fixed, "description", "Echo!"),
          Map.put(fixed, "input_schema", %{"type" => "object", "required" => ["a"]}),
          Map.put(fixed, "annotations", %{"readOnlyHint" => true})
        ],
        do: assert(version.(changed) != expected)

    description = fn d ->
      {:ok, snap} = ToolRegistry.snapshot([source("s", "other", [d])])
      [%{"description" => text}] = ToolRegistry.tools(snap)
      text
    end

    assert description.(Map.put(fixed, "description", nil)) == "echo"
    assert description.(Map.put(fixed, "description", "")) == "echo"
    exact = String.duplicate("a", 4096)
    assert description.(Map.put(fixed, "description", exact)) == exact
    boundary = String.duplicate("a", 4095) <> "é"
    assert byte_size(boundary) == 4097
    assert description.(Map.put(fixed, "description", boundary)) == String.duplicate("a", 4095)

    left = Map.put(fixed, "description", exact <> "x")
    right = Map.put(fixed, "description", exact <> "y")
    assert description.(left) == description.(right)
    assert version.(left) != version.(right)
  end

  test "laws_and_example" do
    source = File.read!(Path.expand("../../cure/elzoo/tool_registry.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
    {result, _} = Code.eval_file(Path.expand("../../examples/tool_registry.exs", __DIR__))
    assert result == %{callable: {:adapter, "issues", "search"}, changed: true}
  end
end
