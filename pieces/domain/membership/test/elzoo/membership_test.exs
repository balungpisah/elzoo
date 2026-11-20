# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MembershipTest do
  use ExUnit.Case, async: true
  alias Elzoo.{Membership, Principal}

  @max 9_223_372_036_854_775_807

  defmodule FakeFacts, do: defstruct([:spaces, :roles, :memberships, :non_inheriting])
  defmodule FakeSpace, do: defstruct([:id, :tenant, :parent, :block_inheritance])
  defmodule FakeRole, do: defstruct([:id, :permissions])

  defmodule FakeMembership,
    do: defstruct([:principal, :space, :role, :valid_from, :valid_to, :revoked_at])

  # ---------------------------------------------------------------- builders

  defp principal(overrides \\ %{}) do
    fields =
      Map.merge(
        %{
          kind: :human,
          id: "alice",
          tenant: "t1",
          auth_epoch: 0,
          allowed_scopes: [],
          allowed_spaces: []
        },
        overrides
      )

    assert {:ok, p} = Principal.new(fields)
    p
  end

  defp agent(parent, scopes, spaces) do
    assert {:ok, a} =
             Principal.delegate(parent, %{id: "bot", allowed_scopes: scopes, allowed_spaces: spaces})

    a
  end

  defp space(id, parent \\ nil, overrides \\ %{}),
    do: Map.merge(%{id: id, tenant: "t1", parent: parent, block_inheritance: false}, overrides)

  defp role(id, permissions), do: %{id: id, permissions: permissions}

  defp m(principal, space, role, overrides \\ %{}) do
    Map.merge(
      %{
        principal: principal,
        space: space,
        role: role,
        valid_from: 0,
        valid_to: nil,
        revoked_at: nil
      },
      overrides
    )
  end

  defp facts(spaces, roles, memberships, non_inheriting \\ []),
    do: %{spaces: spaces, roles: roles, memberships: memberships, non_inheriting: non_inheriting}

  defp perms(p, space, facts, now \\ 100), do: Membership.permissions(p, space, facts, now)
  defp spaces(p, permission, facts, now \\ 100), do: Membership.spaces(p, permission, facts, now)

  # A chain of n spaces: "d1" is the root, "d<n>" the deepest.
  defp chain(n),
    do: for(i <- 1..n, do: space("d#{i}", if(i == 1, do: nil, else: "d#{i - 1}")))

  defp labels(prefix, n), do: for(i <- 1..n, do: prefix <> Integer.to_string(i))

  # ---------------------------------------------------------------- fixtures

  # Group 2: one flat space.
  defp flat(memberships) do
    facts(
      [space("home")],
      [role("reader", ["read"]), role("writer", ["write", "read"]), role("admin", ["admin"])],
      memberships
    )
  end

  # Group 3 and 4: root R, child A that blocks inheritance, grandchild B under A, sibling C.
  defp tree(memberships, non_inheriting \\ []) do
    facts(
      [
        space("R"),
        space("A", "R", %{block_inheritance: true}),
        space("B", "A"),
        space("C", "R")
      ],
      [role("viewer", ["view"]), role("payer", ["money.pay", "money", "Money.pay", "read"])],
      memberships,
      non_inheriting
    )
  end

  # Group 5: the same principal ID holds memberships in tenants t1 and t2.
  defp tenants do
    facts(
      [
        space("r1"),
        space("c1", "r1"),
        space("r2", nil, %{tenant: "t2"}),
        space("c2", "r2", %{tenant: "t2"})
      ],
      [role("reader", ["read"]), role("admin", ["admin", "read"])],
      [m("alice", "r1", "reader"), m("alice", "r2", "admin")]
    )
  end

  # Group 6: alice delegates to an agent that may act only in "home" with "read" and "delete".
  defp delegation(memberships) do
    facts(
      [space("home"), space("c", "home"), space("other")],
      [role("writer", ["read", "write", "admin"]), role("owner", ["delete", "read"])],
      memberships
    )
  end

  defp at_all(f, p \\ principal()),
    do: for(s <- ~w(R A B C), into: %{}, do: {s, elem(perms(p, s, f), 1)})

  defp alice,
    do: principal(%{allowed_scopes: ["delete", "read", "write"], allowed_spaces: ["c", "home"]})

  defp bot, do: agent(alice(), ["delete", "read"], ["home"])

  defp forged do
    p = principal()
    a = bot()

    [
      %{a | delegated_by: nil},
      %{p | allowed_scopes: ["b", "a"]},
      %{p | tenant: String.duplicate("a", 129)},
      Map.from_struct(p),
      nil
    ]
  end

  # ---------------------------------------------------------------- 1: fact validation

  # Text values on each side of every bound, with whether each is valid.
  defp texts do
    [
      {"", false},
      {"a", true},
      {String.duplicate("a", 128), true},
      {String.duplicate("a", 129), false},
      {String.duplicate("é", 64), true},
      {String.duplicate("€", 43), false},
      {<<0xFF>>, false},
      {"a" <> <<0xC3>>, false},
      {"a\0b", false},
      {"a\x1Fb", false},
      {"a\x7Fb", false},
      {"a\u0085b", false},
      {"a\u00A0b", true},
      {~c"abc", false},
      {:abc, false},
      {123, false}
    ]
  end

  defp times do
    [{-1, false}, {0, true}, {@max, true}, {@max + 1, false}, {1.0, false}, {"1", false}]
  end

  defp valid_facts do
    facts(
      [space("R"), space("C", "R")],
      [role("viewer", ["view"])],
      [m("alice", "C", "viewer")],
      ["money."]
    )
  end

  defp facts_result(facts), do: perms(principal(), "R", facts)

  defp assert_facts(facts), do: assert(facts_result(facts) == {:error, :facts})
  defp assert_accepted(facts), do: assert({:ok, _} = facts_result(facts))

  describe "fact validation" do
    test "the base facts are accepted" do
      assert perms(principal(), "C", valid_facts()) == {:ok, ["view"]}
    end

    test "wrong shape or key set of facts, space, role and membership" do
      f = valid_facts()
      [s, c] = f.spaces
      [r] = f.roles
      [mm] = f.memberships

      for bad <- [
            nil,
            [],
            struct(FakeFacts, Map.to_list(f)),
            Map.new(f, fn {k, v} -> {Atom.to_string(k), v} end),
            Map.delete(f, :non_inheriting),
            Map.put(f, :extra, []),
            %{f | spaces: Map.new(f.spaces, &{&1.id, &1})},
            %{f | roles: nil},
            %{f | memberships: %{}},
            %{f | non_inheriting: "money."},
            %{f | spaces: [s, struct(FakeSpace, Map.to_list(c))]},
            %{f | spaces: [s, Map.new(c, fn {k, v} -> {Atom.to_string(k), v} end)]},
            %{f | spaces: [s, Map.delete(c, :block_inheritance)]},
            %{f | spaces: [s, Map.put(c, :extra, 1)]},
            %{f | spaces: [s, %{c | block_inheritance: nil}]},
            %{f | spaces: [s, %{c | block_inheritance: "true"}]},
            %{f | roles: [struct(FakeRole, Map.to_list(r))]},
            %{f | roles: [Map.new(r, fn {k, v} -> {Atom.to_string(k), v} end)]},
            %{f | roles: [Map.delete(r, :permissions)]},
            %{f | roles: [%{r | permissions: "view"}]},
            %{f | memberships: [struct(FakeMembership, Map.to_list(mm))]},
            %{f | memberships: [Map.new(mm, fn {k, v} -> {Atom.to_string(k), v} end)]},
            %{f | memberships: [Map.delete(mm, :revoked_at)]},
            %{f | memberships: [Map.put(mm, :tenant, "t1")]}
          ],
          do: assert_facts(bad)
    end

    test "improper lists" do
      f = valid_facts()
      [s, c] = f.spaces
      [r] = f.roles
      [mm] = f.memberships

      for bad <- [
            %{f | spaces: [s | c]},
            %{f | spaces: [s, c | :x]},
            %{f | roles: [r | :x]},
            %{f | roles: [%{r | permissions: ["view" | "x"]}]},
            %{f | memberships: [mm | :x]},
            %{f | non_inheriting: ["money." | "x"]}
          ],
          do: assert_facts(bad)
    end

    test "space count 1..1024" do
      assert_facts(%{valid_facts() | spaces: [], memberships: []})
      many = for i <- 1..1023, do: space("s#{i}", "R")
      assert_accepted(%{valid_facts() | spaces: [space("R") | many], memberships: []})
      more = for i <- 1..1024, do: space("s#{i}", "R")
      assert_facts(%{valid_facts() | spaces: [space("R") | more], memberships: []})
    end

    test "role count 0..256" do
      assert_accepted(%{valid_facts() | roles: [], memberships: []})

      assert_accepted(%{
        valid_facts()
        | roles: for(id <- labels("r", 256), do: role(id, [])),
          memberships: []
      })

      assert_accepted(%{
        valid_facts()
        | roles: [role("viewer", []) | for(id <- labels("r", 255), do: role(id, []))]
      })

      assert_facts(%{
        valid_facts()
        | roles: [role("viewer", []) | for(id <- labels("r", 256), do: role(id, []))]
      })
    end

    test "permissions per role 0..256, counted before coalescing" do
      f = valid_facts()
      assert_accepted(%{f | roles: [role("viewer", labels("p", 256))]})
      assert_facts(%{f | roles: [role("viewer", labels("p", 257))]})
      # 257 entries with duplicates: two distinct labels.
      assert_facts(%{f | roles: [role("viewer", List.duplicate("view", 256) ++ ["read"])]})
      assert_accepted(%{f | roles: [role("viewer", List.duplicate("view", 255) ++ ["read"])]})
    end

    test "membership count 0..1024, counted before coalescing; identical entries coalesce" do
      f = valid_facts()
      assert_accepted(%{f | memberships: []})
      same = List.duplicate(m("alice", "R", "viewer"), 1024)
      assert perms(principal(), "R", %{f | memberships: same}) == {:ok, ["view"]}
      assert_facts(%{f | memberships: [m("alice", "R", "viewer") | same]})
      distinct = for i <- 1..1024, do: m("p#{i}", "R", "viewer")
      assert_accepted(%{f | memberships: distinct})
      assert_facts(%{f | memberships: [m("alice", "R", "viewer") | distinct]})
    end

    test "non-inheriting prefixes 0..16" do
      f = valid_facts()
      assert_accepted(%{f | non_inheriting: []})
      assert_accepted(%{f | non_inheriting: labels("x", 16)})
      assert_facts(%{f | non_inheriting: labels("x", 17)})
    end

    test "duplicate space or role ID, even for identical entries" do
      f = valid_facts()
      assert_facts(%{f | spaces: f.spaces ++ [space("C", "R")]})
      assert_facts(%{f | spaces: f.spaces ++ [space("C", nil)]})
      assert_facts(%{f | roles: f.roles ++ [role("viewer", ["view"])]})
      assert_facts(%{f | roles: f.roles ++ [role("viewer", ["other"])]})
    end

    test "parent absent or in another tenant" do
      f = valid_facts()
      assert_facts(%{f | spaces: [space("R"), space("C", "X")]})
      assert_facts(%{f | spaces: [space("R"), space("C", "R", %{tenant: "t2"})]})
      assert_facts(%{f | spaces: [space("R", nil, %{tenant: "t2"}), space("C", "R")]})
      # A root of another tenant is valid when its children share its tenant.
      assert_accepted(%{
        f
        | spaces:
            f.spaces ++ [space("R2", nil, %{tenant: "t2"}), space("C2", "R2", %{tenant: "t2"})]
      })
    end

    test "cycles, including a self-parent" do
      f = valid_facts()
      assert_facts(%{f | spaces: f.spaces ++ [space("S", "S")]})
      assert_facts(%{f | spaces: f.spaces ++ [space("X", "Y"), space("Y", "X")]})
      assert_facts(%{f | spaces: f.spaces ++ [space("X", "Y"), space("Y", "Z"), space("Z", "X")]})
      # A cycle hanging below a valid root is still a cycle.
      assert_facts(%{f | spaces: [space("R", "C"), space("C", "R")]})
    end

    test "depth: a path of 32 spaces is accepted, 33 refused" do
      f = %{valid_facts() | memberships: [m("alice", "d1", "viewer")]}
      ok = %{f | spaces: chain(32)}
      assert perms(principal(), "d32", ok) == {:ok, ["view"]}
      assert perms(principal(), "d33", %{f | spaces: chain(33)}) == {:error, :facts}
      assert perms(principal(), "d1", %{f | spaces: chain(33)}) == {:error, :facts}
    end

    test "a membership naming an absent space or role" do
      f = valid_facts()
      assert_facts(%{f | memberships: [m("alice", "X", "viewer")]})
      assert_facts(%{f | memberships: [m("alice", "C", "editor")]})
      # A space ID is not a role ID.
      assert_facts(%{f | memberships: [m("alice", "C", "C")]})
    end

    test "valid_to <= valid_from" do
      f = valid_facts()
      assert_facts(%{f | memberships: [m("alice", "C", "viewer", %{valid_from: 5, valid_to: 5})]})
      assert_facts(%{f | memberships: [m("alice", "C", "viewer", %{valid_from: 5, valid_to: 4})]})

      assert_accepted(%{
        f
        | memberships: [m("alice", "C", "viewer", %{valid_from: 5, valid_to: 6})]
      })

      # A revocation before valid_from is not a fault: the membership is never active.
      assert_accepted(%{
        f
        | memberships: [m("alice", "C", "viewer", %{valid_from: 5, revoked_at: 0})]
      })
    end

    test "text bounds in every text field" do
      f = valid_facts()

      for {t, ok?} <- texts() do
        owner = if ok?, do: principal(%{id: t}), else: principal()

        # {principal, target, facts, result when t is valid}
        cases = [
          {principal(), t,
           %{f | spaces: [space("R"), space(t, "R")], memberships: [m("alice", t, "viewer")]},
           {:ok, ["view"]}},
          {principal(), "R",
           %{
             f
             | spaces: [space("R", nil, %{tenant: t}), space("C", "R", %{tenant: t})],
               memberships: []
           }, {:error, :cross_tenant}},
          {principal(), "C", %{f | spaces: [space(t), space("C", t)]}, {:ok, ["view"]}},
          {principal(), "C", %{f | roles: [role(t, ["view"])], memberships: [m("alice", "C", t)]},
           {:ok, ["view"]}},
          {principal(), "C", %{f | roles: [role("viewer", [t])]}, {:ok, [t]}},
          {owner, "C", %{f | memberships: [m(t, "C", "viewer")]}, {:ok, ["view"]}},
          {principal(), "C", %{f | non_inheriting: [t], memberships: [m("alice", "R", "viewer")]},
           {:ok, ["view"]}}
        ]

        for {p, target, c, expected} <- cases do
          result = perms(p, target, c)

          if ok?,
            do: assert(result == expected, inspect({t, c})),
            else: assert(result == {:error, :facts}, inspect({t, c}))
        end
      end
    end

    test "time bounds in every time field" do
      f = valid_facts()

      for {t, ok?} <- times() do
        cases = [
          m("alice", "C", "viewer", %{valid_from: t}),
          m("alice", "C", "viewer", %{valid_from: 0, valid_to: t}),
          m("alice", "C", "viewer", %{revoked_at: t})
        ]

        for mm <- cases do
          # valid_to == valid_from == 0 is a separate fault; shift valid_to's lower edge.
          mm = if mm.valid_to == 0, do: %{mm | valid_from: 0, valid_to: 1}, else: mm
          result = facts_result(%{f | memberships: [mm]})
          if ok?, do: assert({:ok, _} = result), else: assert(result == {:error, :facts})
        end
      end

      assert_facts(%{f | memberships: [m("alice", "C", "viewer", %{valid_from: nil})]})
    end
  end

  # ---------------------------------------------------------------- 2: flat tenant

  describe "flat tenant" do
    test "a member gets its role's permissions; a non-member gets nothing" do
      f = flat([m("alice", "home", "reader")])
      assert perms(principal(), "home", f) == {:ok, ["read"]}
      assert perms(principal(%{id: "bob"}), "home", f) == {:ok, []}
    end

    test "two roles at one space give their union, sorted and duplicate-free" do
      f =
        flat([
          m("alice", "home", "writer"),
          m("alice", "home", "reader"),
          m("alice", "home", "admin")
        ])

      assert perms(principal(), "home", f) == {:ok, ["admin", "read", "write"]}
    end

    test "a service principal is its own authority owner" do
      f = flat([m("svc", "home", "writer")])
      assert perms(principal(%{kind: :service, id: "svc"}), "home", f) == {:ok, ["read", "write"]}
    end

    test "a human's own allowed_scopes and allowed_spaces do not cap its memberships" do
      f = flat([m("alice", "home", "writer")])
      capped = principal(%{allowed_scopes: ["other"], allowed_spaces: ["elsewhere"]})
      assert perms(capped, "home", f) == {:ok, ["read", "write"]}
    end

    test "valid_from edge" do
      now = 1000

      assert perms(
               principal(),
               "home",
               flat([m("alice", "home", "reader", %{valid_from: now})]),
               now
             ) == {:ok, ["read"]}

      assert perms(
               principal(),
               "home",
               flat([m("alice", "home", "reader", %{valid_from: now + 1})]),
               now
             ) == {:ok, []}
    end

    test "valid_to edge" do
      now = 1000

      assert perms(principal(), "home", flat([m("alice", "home", "reader", %{valid_to: now})]), now) ==
               {:ok, []}

      assert perms(
               principal(),
               "home",
               flat([m("alice", "home", "reader", %{valid_to: now + 1})]),
               now
             ) == {:ok, ["read"]}
    end

    test "revoked_at edge" do
      now = 1000

      assert perms(
               principal(),
               "home",
               flat([m("alice", "home", "reader", %{revoked_at: now})]),
               now
             ) == {:ok, []}

      assert perms(
               principal(),
               "home",
               flat([m("alice", "home", "reader", %{revoked_at: now + 1})]),
               now
             ) == {:ok, ["read"]}
    end

    test "time edges at the ends of the range" do
      f = flat([m("alice", "home", "reader", %{valid_from: @max - 1, valid_to: @max})])
      assert perms(principal(), "home", f, @max - 1) == {:ok, ["read"]}
      assert perms(principal(), "home", f, @max) == {:ok, []}
      assert perms(principal(), "home", flat([m("alice", "home", "reader")]), 0) == {:ok, ["read"]}

      assert perms(principal(), "home", flat([m("alice", "home", "reader", %{revoked_at: 0})]), 0) ==
               {:ok, []}
    end

    test "only the inactive one of two memberships drops out" do
      f = flat([m("alice", "home", "reader"), m("alice", "home", "writer", %{revoked_at: 50})])
      assert perms(principal(), "home", f) == {:ok, ["read"]}
      assert perms(principal(), "home", f, 49) == {:ok, ["read", "write"]}
    end
  end

  # ---------------------------------------------------------------- 3: hierarchy

  describe "hierarchy" do
    test "a membership at R grants at R and C but not past A's barrier" do
      assert at_all(tree([m("alice", "R", "viewer")])) ==
               %{"R" => ["view"], "A" => [], "B" => [], "C" => ["view"]}
    end

    test "a membership at A grants at A and B" do
      assert at_all(tree([m("alice", "A", "viewer")])) ==
               %{"R" => [], "A" => ["view"], "B" => ["view"], "C" => []}
    end

    test "a membership at B grants at B only, never at A or R" do
      assert at_all(tree([m("alice", "B", "viewer")])) ==
               %{"R" => [], "A" => [], "B" => ["view"], "C" => []}
    end

    test "a membership at C never reaches its sibling branch or its parent" do
      assert at_all(tree([m("alice", "C", "viewer")])) ==
               %{"R" => [], "A" => [], "B" => [], "C" => ["view"]}
    end

    test "a barrier deeper on the path also blocks, and the flag of M itself does not" do
      f =
        facts(
          [
            space("R", nil, %{block_inheritance: true}),
            space("X", "R"),
            space("Y", "X", %{block_inheritance: true}),
            space("Z", "Y"),
            space("W", "Z")
          ],
          [role("viewer", ["view"])],
          [m("alice", "R", "viewer")]
        )

      assert for(s <- ~w(R X Y Z W), do: perms(principal(), s, f)) ==
               [{:ok, ["view"]}, {:ok, ["view"]}, {:ok, []}, {:ok, []}, {:ok, []}]

      g = %{f | memberships: [m("alice", "Y", "viewer")]}

      assert for(s <- ~w(R X Y Z W), do: perms(principal(), s, g)) ==
               [{:ok, []}, {:ok, []}, {:ok, ["view"]}, {:ok, ["view"]}, {:ok, ["view"]}]
    end

    test "inheritance reaches the 32nd space of a path" do
      f = facts(chain(32), [role("viewer", ["view"])], [m("alice", "d1", "viewer")])
      assert perms(principal(), "d32", f) == {:ok, ["view"]}
      assert spaces(principal(), "view", f) == {:ok, Enum.sort(for i <- 1..32, do: "d#{i}")}
    end
  end

  # ---------------------------------------------------------------- 4: non-inheriting prefixes

  describe "non-inheriting prefixes" do
    test "a prefixed permission stays at its membership space; the match is exact bytes" do
      f = tree([m("alice", "R", "payer")], ["money."])
      assert perms(principal(), "R", f) == {:ok, ["Money.pay", "money", "money.pay", "read"]}
      assert perms(principal(), "C", f) == {:ok, ["Money.pay", "money", "read"]}
      assert perms(principal(), "A", f) == {:ok, []}
    end

    test "a membership at C gives C the prefixed permission again" do
      f = tree([m("alice", "R", "payer"), m("alice", "C", "payer")], ["money."])
      assert perms(principal(), "C", f) == {:ok, ["Money.pay", "money", "money.pay", "read"]}
    end

    test "a prefix equal to a whole permission matches it" do
      f = tree([m("alice", "R", "payer")], ["money"])
      assert perms(principal(), "C", f) == {:ok, ["Money.pay", "read"]}
    end

    test "a prefixed permission at A stays at A, below a barrier as everywhere" do
      f = tree([m("alice", "A", "payer")], ["money.", "read"])
      assert perms(principal(), "A", f) == {:ok, ["Money.pay", "money", "money.pay", "read"]}
      assert perms(principal(), "B", f) == {:ok, ["Money.pay", "money"]}
    end
  end

  # ---------------------------------------------------------------- 5: tenancy

  describe "tenancy" do
    test "a target space of another tenant is cross_tenant" do
      assert perms(principal(), "r2", tenants()) == {:error, :cross_tenant}
      assert perms(principal(), "c2", tenants()) == {:error, :cross_tenant}
    end

    test "permissions at a t1 space ignore the t2 membership of the same principal ID" do
      assert perms(principal(), "r1", tenants()) == {:ok, ["read"]}
      assert perms(principal(), "c1", tenants()) == {:ok, ["read"]}
    end

    test "spaces/4 never lists a space of t2" do
      assert spaces(principal(), "admin", tenants()) == {:ok, []}
      assert spaces(principal(), "read", tenants()) == {:ok, ["c1", "r1"]}
    end

    test "the t2 principal of the same ID sees only t2" do
      p2 = principal(%{tenant: "t2"})
      assert perms(p2, "r2", tenants()) == {:ok, ["admin", "read"]}
      assert perms(p2, "r1", tenants()) == {:error, :cross_tenant}
      assert spaces(p2, "admin", tenants()) == {:ok, ["c2", "r2"]}
      assert spaces(p2, "read", tenants()) == {:ok, ["c2", "r2"]}
    end
  end

  # ---------------------------------------------------------------- 6: agent

  describe "agent" do
    test "an agent resolves its parent's memberships intersected with its allowed_scopes" do
      f = delegation([m("alice", "home", "writer")])
      assert perms(alice(), "home", f) == {:ok, ["admin", "read", "write"]}
      assert perms(bot(), "home", f) == {:ok, ["read"]}

      assert perms(bot(), "home", delegation([m("alice", "home", "owner")])) ==
               {:ok, ["delete", "read"]}
    end

    test "a target outside allowed_spaces is empty, also where the parent inherits" do
      f = delegation([m("alice", "home", "writer")])
      assert perms(alice(), "c", f) == {:ok, ["admin", "read", "write"]}
      assert perms(bot(), "c", f) == {:ok, []}
      assert perms(bot(), "other", delegation([m("alice", "other", "writer")])) == {:ok, []}
    end

    test "a membership naming the agent's own id grants nothing" do
      f = delegation([m("bot", "home", "owner")])
      assert perms(bot(), "home", f) == {:ok, []}
      assert spaces(bot(), "read", f) == {:ok, []}
    end

    test "a parent membership revoked at now removes the agent's permissions with it" do
      f = delegation([m("alice", "home", "writer", %{revoked_at: 100})])
      assert perms(bot(), "home", f, 99) == {:ok, ["read"]}
      assert perms(bot(), "home", f, 100) == {:ok, []}
      assert perms(alice(), "home", f, 100) == {:ok, []}
    end

    test "an agent of a service resolves the service's memberships" do
      svc =
        principal(%{kind: :service, id: "svc", allowed_scopes: ["read"], allowed_spaces: ["home"]})

      a = agent(svc, ["read"], ["home"])
      assert perms(a, "home", delegation([m("svc", "home", "writer")])) == {:ok, ["read"]}
      assert perms(a, "home", delegation([m("alice", "home", "writer")])) == {:ok, []}
    end
  end

  # ---------------------------------------------------------------- 7: agreement and order

  defp fixtures do
    payer = [
      m("alice", "R", "payer"),
      m("alice", "A", "viewer"),
      m("alice", "B", "payer", %{revoked_at: 100})
    ]

    [
      {flat([
         m("alice", "home", "writer"),
         m("alice", "home", "reader", %{valid_from: 101}),
         m("bob", "home", "admin")
       ]), [principal(), principal(%{id: "bob"}), principal(%{id: "carol"})]},
      {tree([m("alice", "R", "viewer"), m("alice", "A", "viewer"), m("alice", "B", "viewer")]),
       [principal()]},
      {tree([m("alice", "R", "viewer")]), [principal()]},
      {tree(payer, ["money."]), [principal()]},
      {tree([m("alice", "C", "payer"), m("alice", "R", "payer")], ["money."]), [principal()]},
      {tenants(), [principal(), principal(%{tenant: "t2"})]},
      {delegation([
         m("alice", "home", "writer"),
         m("alice", "home", "owner"),
         m("bot", "home", "owner")
       ]), [alice(), bot()]},
      {delegation([m("alice", "home", "writer", %{revoked_at: 100})]), [alice(), bot()]}
    ]
  end

  describe "spaces/4 and permissions/4 agree" do
    test "on every space and permission of the fixtures" do
      for {f, principals} <- fixtures(), p <- principals do
        known = f.roles |> Enum.flat_map(& &1.permissions) |> Enum.uniq()

        for permission <- ["unknown" | known] do
          assert {:ok, ids} = spaces(p, permission, f)
          assert ids == Enum.sort(ids)

          expected =
            for %{id: id, tenant: tenant} <- f.spaces,
                tenant == p.tenant,
                {:ok, held} = perms(p, id, f),
                permission in held,
                do: id

          assert ids == Enum.sort(expected), inspect({p.id, p.tenant, permission})
        end
      end
    end

    test "an unknown permission gives an empty list" do
      for {f, principals} <- fixtures(),
          p <- principals,
          do: assert(spaces(p, "unknown", f) == {:ok, []})
    end
  end

  describe "errors and their order" do
    test "an unknown or malformed space_id is unknown_space" do
      f = flat([m("alice", "home", "reader")])

      for s <- ["nowhere", "", String.duplicate("a", 129), nil, :home, "Home"],
          do: assert(perms(principal(), s, f) == {:error, :unknown_space})
    end

    test "a malformed permission is :permission; an unknown one is not an error" do
      f = flat([m("alice", "home", "reader")])

      for t <- ["", String.duplicate("a", 129), nil, :read, "a\0b"],
          do: assert(spaces(principal(), t, f) == {:error, :permission})

      assert spaces(principal(), "nope", f) == {:ok, []}
    end

    test "a forged principal is :principal before any now, fact or target error" do
      for p <- forged() do
        assert perms(p, "home", flat([])) == {:error, :principal}
        assert perms(p, "nowhere", :bad, -1) == {:error, :principal}
        assert spaces(p, "read", flat([])) == {:error, :principal}
        assert spaces(p, nil, :bad, 1.0) == {:error, :principal}
      end
    end

    test "a malformed now is :now, also before a fact error" do
      f = flat([m("alice", "home", "reader")])

      for {t, false} <- times() ++ [{nil, false}] do
        assert perms(principal(), "home", f, t) == {:error, :now}
        assert spaces(principal(), "read", f, t) == {:error, :now}
        assert perms(principal(), "nowhere", :bad, t) == {:error, :now}
        assert spaces(principal(), nil, :bad, t) == {:error, :now}
      end
    end

    test "facts are checked before the target" do
      assert perms(principal(), "nowhere", :bad) == {:error, :facts}
      assert spaces(principal(), nil, :bad) == {:error, :facts}
      assert perms(principal(), "r2", %{tenants() | roles: nil}) == {:error, :facts}
    end

    test "existence is checked before tenant" do
      assert perms(principal(), "nowhere", tenants()) == {:error, :unknown_space}
    end
  end

  # ---------------------------------------------------------------- Cure

  describe "cure" do
    test "selected Cure laws, a clean audit and the checked example" do
      source = File.read!(Path.expand("../../cure/elzoo/membership.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
      assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      {result, _} = Code.eval_file(Path.expand("../../examples/membership.exs", __DIR__))

      assert result == [
               {:ok, ["approve", "money.pay", "read"]},
               {:ok, ["approve", "read"]},
               {:ok, []},
               {:ok, ["read"]},
               {:ok, ["finance", "finance/eu"]},
               {:error, :cross_tenant}
             ]
    end
  end
end
