# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PrincipalTest do
  use ExUnit.Case, async: true
  alias Elzoo.Principal

  @max 9_223_372_036_854_775_807

  defp fields(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :human,
        id: "alice",
        tenant: "acme",
        auth_epoch: 7,
        allowed_scopes: ["read", "write"],
        allowed_spaces: ["s1", "s2"]
      },
      overrides
    )
  end

  defp principal(overrides \\ %{}) do
    assert {:ok, p} = Principal.new(fields(overrides))
    p
  end

  defp agent(parent \\ principal(), overrides \\ %{}) do
    assert {:ok, a} =
             Principal.delegate(
               parent,
               Map.merge(%{id: "bot", allowed_scopes: ["read"], allowed_spaces: ["s1"]}, overrides)
             )

    a
  end

  defp ctx(overrides \\ %{}), do: Map.merge(%{current_epoch: 7, revoked_ids: []}, overrides)

  defp labels(n), do: for(i <- 1..n, do: "l" <> String.pad_leading(Integer.to_string(i), 4, "0"))

  # Text values on each side of every bound, with whether each is valid.
  defp texts do
    [
      {"", false},
      {"a", true},
      {String.duplicate("a", 128), true},
      {String.duplicate("a", 129), false},
      # 64 two-byte characters are 128 bytes; 43 three-byte characters are 129 bytes.
      {String.duplicate("é", 64), true},
      {String.duplicate("€", 43), false},
      {<<0xFF>>, false},
      {"a" <> <<0xC3>>, false},
      # An overlong NUL and an encoded surrogate are invalid UTF-8.
      {"a" <> <<0xC0, 0x80>>, false},
      {<<0xED, 0xA0, 0x80>>, false},
      {"a\0b", false},
      {"a\x01b", false},
      {"a\x1Fb", false},
      {"a b", true},
      {"a~b", true},
      {"a\x7Fb", false},
      {"a\u0080b", false},
      {"a\u0085b", false},
      {"a\u009Fb", false},
      {"a\u00A0b", true},
      {~c"abc", false},
      {:abc, false},
      {nil, false},
      {123, false}
    ]
  end

  defp epochs do
    [
      {-1, false},
      {0, true},
      {@max, true},
      {@max + 1, false},
      {1.0, false},
      {"1", false},
      {nil, false}
    ]
  end

  # Hand-built structs that break one field or invariant each.
  defp forged do
    p = principal()
    a = agent(p)

    [
      %{a | delegated_by: nil},
      %{a | delegated_by: ""},
      %{a | delegated_by: String.duplicate("a", 129)},
      %{a | delegated_by: "a\0"},
      %{p | delegated_by: "root"},
      %{principal(%{kind: :service}) | delegated_by: "root"},
      %{p | kind: :admin},
      %{p | kind: "human"},
      %{p | id: String.duplicate("a", 129)},
      %{p | id: ""},
      %{p | tenant: String.duplicate("a", 129)},
      %{p | tenant: "t\x7F"},
      %{p | auth_epoch: -1},
      %{p | auth_epoch: @max + 1},
      %{p | auth_epoch: 7.0},
      %{p | allowed_scopes: ["write", "read"]},
      %{p | allowed_scopes: ["read", "read"]},
      %{p | allowed_spaces: ["s2", "s1"]},
      %{p | allowed_spaces: ["s1", "s1"]},
      %{p | allowed_scopes: ["read" | "write"]},
      %{p | allowed_scopes: labels(257)},
      %{p | allowed_spaces: [""]},
      %{p | allowed_scopes: nil},
      Map.put(p, :extra, 1),
      Map.delete(p, :tenant),
      Map.from_struct(p),
      Map.put(Map.from_struct(p), :__struct__, URI)
    ]
  end

  describe "new: valid principals and canonical sets" do
    test "human and service principals" do
      for kind <- [:human, :service] do
        assert {:ok, p} = Principal.new(fields(%{kind: kind}))

        assert p == %Principal{
                 kind: kind,
                 id: "alice",
                 tenant: "acme",
                 auth_epoch: 7,
                 delegated_by: nil,
                 allowed_scopes: ["read", "write"],
                 allowed_spaces: ["s1", "s2"]
               }
      end
    end

    test "duplicate and unordered labels are coalesced and sorted by byte order" do
      p =
        principal(%{
          allowed_scopes: ["z", "é", "B", "a", "z", "a"],
          allowed_spaces: ["y", "x", "y"]
        })

      assert p.allowed_scopes == ["B", "a", "z", "é"]
      assert p.allowed_spaces == ["x", "y"]

      assert principal(%{allowed_scopes: ["write", "read", "read"]}) ==
               principal(%{allowed_scopes: ["read", "write"]})
    end

    test "empty lists are valid and hold no authority" do
      p = principal(%{allowed_scopes: [], allowed_spaces: []})
      assert {p.allowed_scopes, p.allowed_spaces} == {[], []}

      assert Principal.delegate(p, %{id: "bot", allowed_scopes: ["read"], allowed_spaces: []}) ==
               {:error, :escalation}
    end

    test "kind :agent and every other kind is refused :kind" do
      for kind <- [:agent, :admin, "human", nil, 1],
          do: assert(Principal.new(fields(%{kind: kind})) == {:error, :kind})
    end
  end

  describe "new: exact boundaries" do
    test "each text field at and beyond its bounds" do
      for {t, ok} <- texts() do
        assert match?({:ok, _}, Principal.new(fields(%{id: t}))) == ok
        assert match?({:ok, _}, Principal.new(fields(%{tenant: t}))) == ok
        assert match?({:ok, _}, Principal.new(fields(%{allowed_scopes: ["read", t]}))) == ok
        assert match?({:ok, _}, Principal.new(fields(%{allowed_spaces: [t]}))) == ok

        unless ok do
          assert Principal.new(fields(%{id: t})) == {:error, :id}
          assert Principal.new(fields(%{tenant: t})) == {:error, :tenant}
          assert Principal.new(fields(%{allowed_scopes: [t]})) == {:error, :scopes}
          assert Principal.new(fields(%{allowed_spaces: [t]})) == {:error, :spaces}
        end
      end
    end

    test "auth_epoch at and beyond its bounds" do
      for {e, ok} <- epochs() do
        if ok,
          do: assert({:ok, %{auth_epoch: ^e}} = Principal.new(fields(%{auth_epoch: e}))),
          else: assert(Principal.new(fields(%{auth_epoch: e})) == {:error, :auth_epoch})
      end
    end

    test "list sizes are counted before coalescing" do
      assert principal(%{allowed_scopes: labels(256)}).allowed_scopes == labels(256)
      assert principal(%{allowed_spaces: List.duplicate("x", 256)}).allowed_spaces == ["x"]
      assert Principal.new(fields(%{allowed_scopes: labels(257)})) == {:error, :scopes}
      assert Principal.new(fields(%{allowed_spaces: labels(257)})) == {:error, :spaces}

      with_dups = labels(256) ++ ["l0001"]
      assert length(with_dups) == 257 and length(Enum.uniq(with_dups)) == 256
      assert Principal.new(fields(%{allowed_scopes: with_dups})) == {:error, :scopes}
      assert Principal.new(fields(%{allowed_spaces: List.duplicate("x", 257)})) == {:error, :spaces}
    end

    test "improper lists and non-lists are refused" do
      for bad <- [["read" | "write"], [["read"]], "read", nil, %{}, {"read"}] do
        assert Principal.new(fields(%{allowed_scopes: bad})) == {:error, :scopes}
        assert Principal.new(fields(%{allowed_spaces: bad})) == {:error, :spaces}
      end
    end

    test "map shape: missing, extra and string keys, non-maps and structs" do
      good = fields()

      for bad <- [
            Map.delete(good, :tenant),
            Map.delete(good, :allowed_spaces),
            Map.put(good, :delegated_by, nil),
            Map.put(good, :extra, 1),
            Map.new(good, fn {k, v} -> {Atom.to_string(k), v} end),
            good |> Map.delete(:id) |> Map.put("id", "alice"),
            Map.to_list(good),
            nil,
            "alice",
            principal(),
            struct(URI, %{}),
            Map.put(good, :__struct__, URI)
          ],
          do: assert(Principal.new(bad) == {:error, :shape})
    end

    test "the first failing field decides the reason, in the stated order" do
      assert Principal.new(fields(%{kind: :agent, id: ""})) == {:error, :kind}
      assert Principal.new(fields(%{id: "", tenant: ""})) == {:error, :id}
      assert Principal.new(fields(%{tenant: "", auth_epoch: -1})) == {:error, :tenant}
      assert Principal.new(fields(%{auth_epoch: -1, allowed_scopes: nil})) == {:error, :auth_epoch}
      assert Principal.new(fields(%{allowed_scopes: nil, allowed_spaces: nil})) == {:error, :scopes}
    end
  end

  describe "delegate" do
    test "from a human with a subset and from a service with an equal set" do
      for {kind, scopes, spaces} <- [
            {:human, ["read"], ["s2"]},
            {:service, ["write", "read"], ["s1", "s2"]}
          ] do
        parent = principal(%{kind: kind})

        assert Principal.delegate(parent, %{
                 id: "bot",
                 allowed_scopes: scopes,
                 allowed_spaces: spaces
               }) ==
                 {:ok,
                  %Principal{
                    kind: :agent,
                    id: "bot",
                    tenant: "acme",
                    auth_epoch: 7,
                    delegated_by: "alice",
                    allowed_scopes: Enum.sort(scopes),
                    allowed_spaces: Enum.sort(spaces)
                  }}
      end
    end

    test "tenant and epoch always equal the parent's" do
      for {tenant, epoch} <- [{"t", 0}, {String.duplicate("t", 128), @max}, {"é", 12}] do
        a = agent(principal(%{tenant: tenant, auth_epoch: epoch}))
        assert {a.tenant, a.auth_epoch, a.delegated_by} == {tenant, epoch, "alice"}
      end
    end

    test "an empty, duplicated or unordered subset request is granted in canonical form" do
      assert agent(principal(), %{allowed_scopes: [], allowed_spaces: []}).allowed_scopes == []

      a =
        agent(principal(), %{
          allowed_scopes: ["write", "read", "write"],
          allowed_spaces: ["s2", "s2"]
        })

      assert {a.allowed_scopes, a.allowed_spaces} == {["read", "write"], ["s2"]}
    end

    test "one extra scope, and separately one extra space, is refused whole" do
      parent = principal()

      assert Principal.delegate(parent, %{
               id: "bot",
               allowed_scopes: ["read", "admin"],
               allowed_spaces: ["s1"]
             }) ==
               {:error, :escalation}

      assert Principal.delegate(parent, %{
               id: "bot",
               allowed_scopes: ["read"],
               allowed_spaces: ["s1", "s3"]
             }) ==
               {:error, :escalation}
    end

    test "labels compare by exact bytes: no case folding, normalization, prefix or wildcard" do
      parent = principal(%{allowed_scopes: ["read", "é"], allowed_spaces: ["org/a"]})

      for {scopes, spaces} <- [
            {["Read"], []},
            {["read "], []},
            {["rea"], []},
            {["read:all"], []},
            {["*"], []},
            {["e\u0301"], []},
            {[], ["org"]},
            {[], ["org/a/b"]},
            {[], ["org/*"]}
          ] do
        assert Principal.delegate(parent, %{
                 id: "bot",
                 allowed_scopes: scopes,
                 allowed_spaces: spaces
               }) ==
                 {:error, :escalation}
      end
    end

    test "every request over a small universe is granted exactly when it is a subset" do
      parent = principal(%{allowed_scopes: ["a", "c"], allowed_spaces: ["x"]})
      universe = ["a", "b", "c", "d"]

      requests =
        for mask <- 0..15,
            do:
              for(
                {l, i} <- Enum.with_index(universe),
                Bitwise.band(Bitwise.bsr(mask, i), 1) == 1,
                do: l
              )

      for scopes <- requests, spaces <- [[], ["x"], ["y"], ["x", "y"]] do
        result =
          Principal.delegate(parent, %{id: "bot", allowed_scopes: scopes, allowed_spaces: spaces})

        held? = Enum.all?(scopes, &(&1 in ["a", "c"])) and Enum.all?(spaces, &(&1 == "x"))

        if held?,
          do: assert({:ok, %{allowed_scopes: ^scopes, allowed_spaces: ^spaces}} = result),
          else: assert(result == {:error, :escalation})
      end
    end

    test "an agent parent is :nested_delegation" do
      a = agent()

      assert Principal.delegate(a, %{id: "bot2", allowed_scopes: [], allowed_spaces: []}) ==
               {:error, :nested_delegation}

      assert Principal.delegate(a, %{id: "bot2", allowed_scopes: ["read"], allowed_spaces: ["s1"]}) ==
               {:error, :nested_delegation}

      assert Principal.delegate(a, :not_fields) == {:error, :nested_delegation}
    end

    test "an agent id equal to the parent's is :self_delegation" do
      assert Principal.delegate(principal(), %{id: "alice", allowed_scopes: [], allowed_spaces: []}) ==
               {:error, :self_delegation}

      assert {:ok, _} =
               Principal.delegate(principal(), %{
                 id: "Alice",
                 allowed_scopes: [],
                 allowed_spaces: []
               })

      assert {:ok, _} =
               Principal.delegate(principal(), %{
                 id: "alice ",
                 allowed_scopes: [],
                 allowed_spaces: []
               })
    end

    test "tenant, auth_epoch or kind in fields, and any other bad shape, is :shape" do
      good = %{id: "bot", allowed_scopes: ["read"], allowed_spaces: ["s1"]}

      for bad <- [
            Map.put(good, :tenant, "acme"),
            Map.put(good, :auth_epoch, 7),
            Map.put(good, :kind, :agent),
            Map.put(good, :delegated_by, "alice"),
            Map.delete(good, :allowed_spaces),
            Map.new(good, fn {k, v} -> {Atom.to_string(k), v} end),
            Map.to_list(good),
            Map.put(good, :__struct__, URI),
            agent(),
            nil
          ],
          do: assert(Principal.delegate(principal(), bad) == {:error, :shape})
    end

    test "bounds of the agent id and the requested lists" do
      parent = principal(%{allowed_scopes: labels(256), allowed_spaces: labels(256)})

      for {t, ok} <- texts() do
        result = Principal.delegate(parent, %{id: t, allowed_scopes: [], allowed_spaces: []})
        if ok, do: assert({:ok, %{id: ^t}} = result), else: assert(result == {:error, :id})

        unless ok do
          assert Principal.delegate(parent, %{id: "bot", allowed_scopes: [t], allowed_spaces: []}) ==
                   {:error, :scopes}

          assert Principal.delegate(parent, %{id: "bot", allowed_scopes: [], allowed_spaces: [t]}) ==
                   {:error, :spaces}
        end
      end

      assert {:ok, _} =
               Principal.delegate(parent, %{
                 id: "bot",
                 allowed_scopes: labels(256),
                 allowed_spaces: labels(256)
               })

      for bad <- [labels(257), labels(256) ++ ["l0001"], ["l0001" | "l0002"]] do
        assert Principal.delegate(parent, %{id: "bot", allowed_scopes: bad, allowed_spaces: []}) ==
                 {:error, :scopes}

        assert Principal.delegate(parent, %{id: "bot", allowed_scopes: [], allowed_spaces: bad}) ==
                 {:error, :spaces}
      end
    end

    test "a forged parent is :parent, before any other reason" do
      p = principal()

      for parent <- [
            %{principal(%{kind: :service}) | delegated_by: "root"},
            %{p | tenant: String.duplicate("t", 129)},
            %{p | allowed_scopes: ["write", "read"]}
            | forged()
          ] do
        assert Principal.delegate(parent, %{
                 id: "bot",
                 allowed_scopes: ["read"],
                 allowed_spaces: ["s1"]
               }) == {:error, :parent}

        assert Principal.delegate(parent, %{id: "alice", allowed_scopes: ["x"]}) ==
                 {:error, :parent}
      end

      assert Principal.delegate(fields(), %{id: "bot", allowed_scopes: [], allowed_spaces: []}) ==
               {:error, :parent}
    end

    test "reasons follow the stated order" do
      p = principal()
      assert Principal.delegate(p, %{id: "", allowed_scopes: nil}) == {:error, :shape}

      assert Principal.delegate(p, %{id: "", allowed_scopes: nil, allowed_spaces: nil}) ==
               {:error, :id}

      assert Principal.delegate(p, %{id: "alice", allowed_scopes: nil, allowed_spaces: nil}) ==
               {:error, :self_delegation}

      assert Principal.delegate(p, %{id: "bot", allowed_scopes: [""], allowed_spaces: nil}) ==
               {:error, :scopes}

      assert Principal.delegate(p, %{id: "bot", allowed_scopes: ["admin"], allowed_spaces: nil}) ==
               {:error, :spaces}

      assert Principal.delegate(p, %{id: "bot", allowed_scopes: ["admin"], allowed_spaces: ["s9"]}) ==
               {:error, :escalation}
    end
  end

  describe "check" do
    test "an older epoch is stale; equal and newer pass" do
      p = principal(%{auth_epoch: 7})
      assert Principal.check(p, ctx(%{current_epoch: 8})) == {:error, :stale}
      assert Principal.check(p, ctx(%{current_epoch: @max})) == {:error, :stale}
      assert Principal.check(p, ctx(%{current_epoch: 7})) == :ok
      assert Principal.check(p, ctx(%{current_epoch: 6})) == :ok
      assert Principal.check(p, ctx(%{current_epoch: 0})) == :ok
      assert Principal.check(principal(%{auth_epoch: @max}), ctx(%{current_epoch: @max})) == :ok

      assert Principal.check(principal(%{auth_epoch: 0}), ctx(%{current_epoch: 1})) ==
               {:error, :stale}
    end

    test "a revoked id is revoked, by exact bytes" do
      p = principal()
      assert Principal.check(p, ctx(%{revoked_ids: ["alice"]})) == {:error, :revoked}
      assert Principal.check(p, ctx(%{revoked_ids: ["x", "alice", "y"]})) == {:error, :revoked}
      assert Principal.check(p, ctx(%{revoked_ids: ["Alice", "alic", "alice ", "acme"]})) == :ok
    end

    test "an agent whose parent is revoked is revoked, although its own id is not" do
      a = agent()
      assert Principal.check(a, ctx(%{revoked_ids: ["alice"]})) == {:error, :revoked}
      assert Principal.check(a, ctx(%{revoked_ids: ["bot"]})) == {:error, :revoked}
      assert Principal.check(a, ctx(%{revoked_ids: ["other"]})) == :ok
      assert Principal.check(a, ctx(%{current_epoch: 8})) == {:error, :stale}
    end

    test "a revoked principal or parent is revoked before stale" do
      assert Principal.check(principal(), ctx(%{current_epoch: 99, revoked_ids: ["alice"]})) ==
               {:error, :revoked}

      assert Principal.check(agent(), ctx(%{current_epoch: 99, revoked_ids: ["alice"]})) ==
               {:error, :revoked}
    end

    test "a malformed context is malformed" do
      p = principal()

      bad =
        [
          %{current_epoch: 7},
          %{revoked_ids: []},
          Map.put(ctx(), :extra, 1),
          %{"current_epoch" => 7, "revoked_ids" => []},
          Map.put(ctx(), :__struct__, URI),
          [current_epoch: 7, revoked_ids: []],
          nil,
          ctx(%{revoked_ids: labels(1025)}),
          ctx(%{revoked_ids: ["a" | "b"]}),
          ctx(%{revoked_ids: nil}),
          ctx(%{revoked_ids: "alice"})
        ] ++
          for({e, false} <- epochs(), do: ctx(%{current_epoch: e})) ++
          for({t, false} <- texts(), do: ctx(%{revoked_ids: ["x", t]}))

      for c <- bad, do: assert(Principal.check(p, c) == {:error, :malformed})

      for {e, true} <- epochs(),
          do:
            assert(Principal.check(principal(%{auth_epoch: @max}), ctx(%{current_epoch: e})) == :ok)

      for {t, true} <- texts(), do: assert(Principal.check(p, ctx(%{revoked_ids: [t]})) == :ok)
      assert Principal.check(p, ctx(%{revoked_ids: labels(1024)})) == :ok

      assert Principal.check(p, ctx(%{revoked_ids: labels(1023) ++ ["alice"]})) ==
               {:error, :revoked}
    end

    test "a malformed principal or context is malformed before revoked and stale" do
      p = principal()

      assert Principal.check(p, %{current_epoch: 99, revoked_ids: ["alice", ""]}) ==
               {:error, :malformed}

      assert Principal.check(p, %{current_epoch: -1, revoked_ids: ["alice"]}) ==
               {:error, :malformed}

      for f <- forged() do
        assert Principal.check(f, ctx(%{current_epoch: 99, revoked_ids: ["alice", "bot"]})) ==
                 {:error, :malformed}

        assert Principal.check(f, ctx()) == {:error, :malformed}
      end
    end
  end

  describe "require_human" do
    test "accepts a human and refuses a service and an agent" do
      assert Principal.require_human(principal()) == :ok
      assert Principal.require_human(principal(%{kind: :service})) == {:error, :not_human}
      assert Principal.require_human(agent()) == {:error, :not_human}
      assert Principal.require_human(agent(principal(%{kind: :service}))) == {:error, :not_human}
    end

    test "a forged struct or a non-principal is malformed" do
      for f <- forged() ++ [fields(), nil, :human],
          do: assert(Principal.require_human(f) == {:error, :malformed})
    end
  end

  describe "forged structs" do
    test "every function refuses each hand-built struct that breaks an invariant" do
      for f <- forged() do
        assert Principal.delegate(f, %{id: "bot", allowed_scopes: [], allowed_spaces: []}) ==
                 {:error, :parent}

        assert Principal.check(f, ctx(%{current_epoch: 0})) == {:error, :malformed}
        assert Principal.require_human(f) == {:error, :malformed}
        assert Principal.new(f) == {:error, :shape}
      end
    end

    test "the controls are valid before they are broken" do
      p = principal()
      a = agent(p)
      assert Principal.check(p, ctx(%{current_epoch: 0})) == :ok
      assert Principal.check(a, ctx(%{current_epoch: 0})) == :ok
      assert Principal.check(%{p | auth_epoch: @max}, ctx(%{current_epoch: 0})) == :ok
      assert Principal.check(%{a | delegated_by: String.duplicate("a", 128)}, ctx()) == :ok
    end
  end

  describe "cure" do
    test "selected Cure laws, a clean audit and the checked example" do
      source = File.read!(Path.expand("../../cure/elzoo/principal.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
      assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      {result, _} = Code.eval_file(Path.expand("../../examples/principal.exs", __DIR__))

      assert result == [
               :ok,
               {:error, :escalation},
               {:error, :nested_delegation},
               {:error, :revoked},
               {:error, :not_human}
             ]
    end
  end
end
