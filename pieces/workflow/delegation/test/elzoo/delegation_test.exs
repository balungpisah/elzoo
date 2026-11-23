# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DelegationTest do
  use ExUnit.Case, async: true
  alias Elzoo.{Authorization, Delegation, Principal}

  @sentinel "SENTINEL-6b2e0d"

  defp human(
         id \\ "root",
         tenant \\ "t1",
         scopes \\ ["admin", "read", "write"],
         spaces \\ ["s1", "s2"]
       ) do
    {:ok, p} =
      Principal.new(%{
        kind: :human,
        id: id,
        tenant: tenant,
        auth_epoch: 3,
        allowed_scopes: scopes,
        allowed_spaces: spaces
      })

    p
  end

  defp service do
    {:ok, p} =
      Principal.new(%{
        kind: :service,
        id: "svc",
        tenant: "t1",
        auth_epoch: 0,
        allowed_scopes: ["read"],
        allowed_spaces: ["s1"]
      })

    p
  end

  # An agent of `root`: what the host built for an earlier child of the lineage.
  defp agent(id, root \\ human(), scopes \\ ["read", "write"], spaces \\ ["s1"]) do
    {:ok, a} = Principal.delegate(root, %{id: id, allowed_scopes: scopes, allowed_spaces: spaces})
    a
  end

  defp w(target, field, value), do: %{target: target, field: field, value: value}
  defp post(n), do: w("post:#{n}", "state", {:text, "published"})

  # Default: an agent parent "bot-c" at depth 3 under the human root.
  defp facts(opts \\ []) do
    Map.merge(
      %{
        root: human(),
        parent: agent("bot-c"),
        authority: [post(1)],
        budget_remaining: 10,
        max_depth: 8,
        lineage: ["bot-a", "bot-b", "bot-c"],
        revoked_ids: [],
        pin: "pin-v1"
      },
      Map.new(opts)
    )
  end

  defp root_facts(opts \\ []), do: facts([parent: human(), lineage: []] ++ opts)

  defp request(opts \\ []) do
    Map.merge(
      %{
        child_bot: "bot-d",
        scopes: ["read"],
        spaces: ["s1"],
        budget: 4,
        parent_close: nil,
        change: nil
      },
      Map.new(opts)
    )
  end

  defp grant(f \\ facts(), r \\ request()), do: Delegation.grant(f, r)

  defp ids(n), do: Enum.map(1..n, &"bot-#{&1}")

  # Facts of an agent parent whose lineage is `lineage`.
  defp chain(lineage, opts \\ []),
    do: facts([parent: agent(List.last(lineage)), lineage: lineage] ++ opts)

  describe "rule edges" do
    test "depth at max_depth and one over, with max_depth 1 and 8" do
      assert {:ok, %{depth: 1}} = grant(root_facts(max_depth: 1))
      assert {:error, :depth} = grant(chain(["bot-a"], max_depth: 1))

      assert {:ok, %{depth: 8, lineage: lineage}} = grant(chain(ids(7), max_depth: 8))
      assert lineage == ids(7) ++ ["bot-d"]
      assert {:error, :depth} = grant(chain(ids(8), max_depth: 8))

      assert {:ok, %{depth: 4}} = grant(facts(max_depth: 4))
      assert {:error, :depth} = grant(facts(max_depth: 3))
    end

    test "a cycle through the root's ID, a middle bot and the parent" do
      assert {:error, :cycle} = grant(facts(), request(child_bot: "root"))
      assert {:error, :cycle} = grant(facts(), request(child_bot: "bot-b"))
      assert {:error, :cycle} = grant(facts(), request(child_bot: "bot-c"))
      # A root parent asking for its own ID: :cycle, so :self_delegation is never reached.
      assert {:error, :cycle} = grant(root_facts(), request(child_bot: "root"))
      assert {:ok, _} = grant(facts(), request(child_bot: "bot-e"))
    end

    test "a revoked root, middle bot, parent or child_bot" do
      for id <- ["root", "bot-b", "bot-c", "bot-d"] do
        assert {:error, :revoked} = grant(facts(revoked_ids: ["x", id])), id
      end

      assert {:error, :revoked} = grant(facts(revoked_ids: ["bot-a"]))
      assert {:error, :revoked} = grant(root_facts(revoked_ids: ["root"]))
      assert {:ok, _} = grant(facts(revoked_ids: ["bot-z", "other-root"]))
    end

    test "a scope or a space the parent does not hold, with the others held" do
      # The root holds "admin" and "s2"; the agent parent does not.
      assert {:error, :escalation} = grant(facts(), request(scopes: ["read", "admin"]))
      assert {:error, :escalation} = grant(facts(), request(spaces: ["s1", "s2"]))
      assert {:ok, _} = grant(facts(), request(scopes: ["write", "read"], spaces: ["s1"]))
      assert {:ok, _} = grant(facts(), request(scopes: [], spaces: []))

      # A root parent: its own scopes and spaces.
      assert {:ok, _} = grant(root_facts(), request(scopes: ["admin"], spaces: ["s2"]))
      assert {:error, :escalation} = grant(root_facts(), request(scopes: ["admin", "owner"]))
      assert {:error, :escalation} = grant(root_facts(), request(spaces: ["s1", "s3"]))
      # Exact bytes: no case folding.
      assert {:error, :escalation} = grant(facts(), request(scopes: ["Read"]))
    end

    test "budget 0, 1, the remaining amount and one over" do
      assert {:error, :budget} = grant(facts(), request(budget: 0))
      assert {:error, :budget} = grant(facts(), request(budget: -1))
      assert {:ok, %{budget: 1}} = grant(facts(), request(budget: 1))
      assert {:ok, %{budget: 10}} = grant(facts(), request(budget: 10))
      assert {:error, :budget} = grant(facts(), request(budget: 11))
      assert {:error, :budget} = grant(facts(budget_remaining: 0), request(budget: 1))
    end

    test "a version change needs a ref; without the ref key it is malformed" do
      assert {:ok, %{pin: "pin-v2", change_ref: "act-9"}} =
               grant(facts(), request(change: %{pin: "pin-v2", ref: "act-9"}))

      ref256 = String.duplicate("r", 256)

      assert {:ok, %{change_ref: ^ref256}} =
               grant(facts(), request(change: %{pin: "p", ref: ref256}))

      for ref <- [nil, String.duplicate("r", 257), "", "a\nb", "a\u0085b", <<0xFF>>, :ref] do
        assert {:error, :version_change} = grant(facts(), request(change: %{pin: "p", ref: ref})),
               inspect(ref)
      end

      assert {:error, :malformed} = grant(facts(), request(change: %{pin: "pin-v2"}))
      assert {:error, :malformed} = grant(facts(), request(change: %{pin: "p", ref: "r", x: 1}))
      assert {:error, :malformed} = grant(facts(), request(change: %{pin: "", ref: "r"}))

      assert {:error, :malformed} =
               grant(facts(), request(change: %{pin: String.duplicate("p", 129), ref: "r"}))

      assert {:ok, %{pin: pin}} =
               grant(facts(), request(change: %{pin: String.duplicate("p", 128), ref: "r"}))

      assert byte_size(pin) == 128
    end
  end

  describe "order" do
    test "each input with two faults gives the earlier reason" do
      # malformed before revoked
      assert {:error, :malformed} = grant(facts(revoked_ids: ["bot-b"], max_depth: 0))
      # revoked middle bot in a too-deep request
      assert {:error, :revoked} = grant(facts(revoked_ids: ["bot-b"], max_depth: 3))
      # too deep with a cycle
      assert {:error, :depth} = grant(facts(max_depth: 3), request(child_bot: "bot-a"))
      # cycle with an escalated scope
      assert {:error, :cycle} = grant(facts(), request(child_bot: "bot-b", scopes: ["admin"]))
      # escalated scope over budget
      assert {:error, :escalation} = grant(facts(), request(scopes: ["admin"], budget: 11))
      # over budget with a change without a ref
      assert {:error, :budget} = grant(facts(), request(budget: 0, change: %{pin: "p", ref: nil}))
    end
  end

  describe "the grant" do
    test "an agent parent's child is delegated from the root, inside the agent's scopes" do
      assert {:ok, grant} = grant()

      assert grant == %{
               principal: %Principal{
                 kind: :agent,
                 id: "bot-d",
                 tenant: "t1",
                 auth_epoch: 3,
                 delegated_by: "root",
                 allowed_scopes: ["read"],
                 allowed_spaces: ["s1"]
               },
               parent_authority: [post(1)],
               budget: 4,
               depth: 4,
               lineage: ["bot-a", "bot-b", "bot-c", "bot-d"],
               pin: "pin-v1",
               change_ref: nil,
               parent_close: :request_cancel
             }
    end

    test "a human or service root parent's child has the lineage of the child alone" do
      assert {:ok, %{lineage: ["bot-d"], depth: 1, principal: %{delegated_by: "root"}}} =
               grant(root_facts(), request(scopes: ["admin"], spaces: ["s2"]))

      assert {:ok, %{lineage: ["bot-d"], depth: 1, principal: p}} =
               grant(root_facts(root: service(), parent: service()))

      assert %Principal{kind: :agent, delegated_by: "svc", tenant: "t1", auth_epoch: 0} = p
    end

    test "the pin is the parent's without a change and the changed one with it" do
      assert {:ok, %{pin: "pin-v1", change_ref: nil}} = grant()

      assert {:ok, %{pin: "pin-v2", change_ref: "act-9"}} =
               grant(facts(), request(change: %{pin: "pin-v2", ref: "act-9"}))
    end

    test "the parent authority is the validated, normalized set" do
      assert {:ok, %{parent_authority: [p1, p2]}} =
               grant(facts(authority: [post(2), post(1), post(2)]))

      assert {p1, p2} == {post(1), post(2)}
      assert {:ok, %{parent_authority: []}} = grant(facts(authority: []))
    end

    test "the child never holds more than its parent: scopes, spaces and authority" do
      labels = ["a", "b", "c", "d"]
      root = human("root", "t1", labels, labels)
      parent = agent("bot-c", root, ["a", "b"], ["b", "c"])
      f = facts(root: root, parent: parent)

      subsets =
        for n <- 0..15,
            do:
              for({l, i} <- Enum.with_index(labels), Bitwise.band(n, Bitwise.bsl(1, i)) != 0, do: l)

      for scopes <- subsets, spaces <- subsets do
        held = Enum.all?(scopes, &(&1 in ["a", "b"])) and Enum.all?(spaces, &(&1 in ["b", "c"]))

        case grant(f, request(scopes: scopes, spaces: spaces)) do
          {:ok, %{principal: p}} ->
            assert held
            assert p.allowed_scopes == Enum.sort(scopes)
            assert p.allowed_spaces == Enum.sort(spaces)

          {:error, :escalation} ->
            refute held
        end
      end

      # The host gives parent_authority as `parent` in the child's authorization
      # context: a write the parent does not hold is refused even if the child's
      # own authority holds it.
      assert {:ok, %{parent_authority: parent_authority}} = grant(facts(authority: [post(1)]))

      policy = %{
        id: "pol",
        version: 1,
        content_hash: :binary.copy(<<7>>, 32),
        effect_classes: ["publish"],
        rules: [%{id: "a", effect_class: "publish", verdict: :allow}]
      }

      ctx = %{
        proposer: "bot-d",
        effect_class: "publish",
        own: [post(1), post(2)],
        parent: parent_authority
      }

      proposal = fn writes ->
        %{
          tenant: "t1",
          resource: "post:1",
          action_id: "act-1",
          payload: {:record, []},
          writes: writes
        }
      end

      assert {:ok, %{verdict: :deny, reason: :authority_exceeded}} =
               Authorization.decide(policy, proposal.([post(1), post(2)]), ctx)

      assert {:ok, %{verdict: :allow}} = Authorization.decide(policy, proposal.([post(1)]), ctx)
    end

    test "domain/principal reasons after rules 1-7: only escalation from the root remains" do
      # The host built the agent parent from a root that then held "admin";
      # the root of the facts no longer holds it. Rule 5 passes on the parent's
      # scopes, and delegation from the root refuses it.
      wider = human("root", "t1", ["admin", "read"], ["s1"])
      parent = agent("bot-c", wider, ["admin", "read"], ["s1"])
      root = human("root", "t1", ["read"], ["s1"])

      assert {:error, {:principal, :escalation}} =
               grant(facts(root: root, parent: parent), request(scopes: ["admin"]))

      assert {:error, {:principal, :escalation}} =
               grant(
                 facts(root: root, parent: parent),
                 request(spaces: ["s1"], scopes: ["admin", "read"])
               )

      assert {:ok, _} = grant(facts(root: root, parent: parent), request(scopes: ["read"]))
    end
  end

  describe "parent_close" do
    test "nil gives :request_cancel; each explicit rule is kept" do
      assert {:ok, %{parent_close: :request_cancel}} = grant(facts(), request(parent_close: nil))

      for rule <- [:abandon, :request_cancel, :cancel] do
        assert {:ok, %{parent_close: ^rule}} = grant(facts(), request(parent_close: rule))
      end

      assert {:error, :malformed} = grant(facts(), request(parent_close: :stop))
      assert {:error, :malformed} = grant(facts(), request(parent_close: "cancel"))
    end
  end

  describe "malformed" do
    test "inconsistent parent, lineage, depth bound and authority" do
      other_root = human("other-root")
      other_tenant = human("root", "t2")

      cases = [
        {"parent delegated by another root", facts(parent: agent("bot-c", other_root))},
        {"parent of another tenant", facts(parent: agent("bot-c", other_tenant))},
        {"lineage not ending with the parent", facts(lineage: ["bot-a", "bot-c", "bot-b"])},
        {"non-empty lineage for a root parent", root_facts(lineage: ["bot-a"])},
        {"empty lineage for an agent parent", facts(lineage: [])},
        {"9 lineage entries", chain(ids(9))},
        {"repeated lineage ID", facts(lineage: ["bot-a", "bot-a", "bot-c"])},
        {"repeated parent ID", facts(lineage: ["bot-c", "bot-b", "bot-c"])},
        {"max_depth 0", facts(max_depth: 0)},
        {"max_depth 9", facts(max_depth: 9)},
        {"max_depth nil", facts(max_depth: nil)},
        {"conflicting authority",
         facts(authority: [post(1), w("post:1", "state", {:text, "draft"})])},
        {"authority not a list", facts(authority: :all)},
        {"root an agent", facts(root: agent("bot-x"))},
        {"root and parent one agent",
         facts(root: agent("bot-x"), parent: agent("bot-x"), lineage: [])},
        {"parent a human other than root", facts(parent: human("bot-c"), lineage: ["bot-c"])},
        {"forged root", facts(root: %{human() | allowed_scopes: ["write", "read"]})},
        {"root a plain map", facts(root: Map.from_struct(human()))},
        {"forged parent", facts(parent: %{agent("bot-c") | delegated_by: nil})},
        {"budget_remaining -1", facts(budget_remaining: -1)},
        {"budget_remaining float", facts(budget_remaining: 10.0)},
        {"1025 revoked IDs", facts(revoked_ids: ids(1025))},
        {"revoked ID not text", facts(revoked_ids: [""])},
        {"pin empty", facts(pin: "")},
        {"pin 129 bytes", facts(pin: String.duplicate("p", 129))},
        {"lineage ID with a control char", facts(lineage: ["bot-a", "bot\tb", "bot-c"])},
        {"improper lineage", facts(lineage: ["bot-a" | "bot-c"])},
        {"extra facts key", facts(depth: 3)},
        {"missing facts key", Map.delete(facts(), :pin)},
        {"facts a struct", struct(URI, %{})},
        {"facts nil", nil}
      ]

      for {name, f} <- cases do
        assert {:error, :malformed} = Delegation.grant(f, request()), name
      end

      assert {:ok, _} = grant(facts(revoked_ids: ids(1024)), request())
      assert {:ok, %{pin: pin}} = grant(facts(pin: String.duplicate("p", 128)))
      assert byte_size(pin) == 128
    end

    test "malformed requests" do
      cases = [
        {"child_bot empty", request(child_bot: "")},
        {"child_bot 129 bytes", request(child_bot: String.duplicate("b", 129))},
        {"child_bot invalid UTF-8", request(child_bot: <<0xC3>>)},
        {"child_bot NUL", request(child_bot: "a\0b")},
        {"child_bot DEL", request(child_bot: "a\x7Fb")},
        {"257 scopes", request(scopes: ids(257))},
        {"scope empty", request(scopes: [""])},
        {"spaces not a list", request(spaces: "s1")},
        {"budget float", request(budget: 1.0)},
        {"budget nil", request(budget: nil)},
        {"change a list", request(change: [pin: "p", ref: "r"])},
        {"extra request key", Map.put(request(), :depth, 1)},
        {"missing request key", Map.delete(request(), :change)},
        {"request nil", nil}
      ]

      for {name, r} <- cases do
        assert {:error, :malformed} = Delegation.grant(facts(), r), name
      end

      assert {:ok, %{principal: %{id: id}}} =
               grant(facts(), request(child_bot: String.duplicate("b", 128)))

      assert byte_size(id) == 128
    end

    test "errors are fixed atoms that echo no ID, scope or space" do
      results = [
        grant(facts(), request(child_bot: @sentinel <> "\n")),
        grant(facts(revoked_ids: [@sentinel]), request(child_bot: @sentinel)),
        grant(facts(), request(child_bot: "root", scopes: [@sentinel])),
        grant(facts(), request(scopes: [@sentinel])),
        grant(facts(), request(spaces: [@sentinel])),
        grant(facts(), request(change: %{pin: @sentinel, ref: nil})),
        grant(facts(authority: [w(@sentinel, @sentinel, 1), w(@sentinel, @sentinel, 2)]))
      ]

      for result <- results do
        assert {:error, reason} = result
        assert is_atom(reason)
        refute inspect(result) =~ @sentinel
      end
    end
  end

  describe "on_parent_close/1" do
    test "each rule, written out by hand" do
      assert {:ok, [%{child_run_id: "run-1", action: :abandon}]} =
               Delegation.on_parent_close([%{child_run_id: "run-1", parent_close: :abandon}])

      assert {:ok, [%{child_run_id: "run-1", action: :cancel}]} =
               Delegation.on_parent_close([%{child_run_id: "run-1", parent_close: :cancel}])

      assert {:ok, [action]} =
               Delegation.on_parent_close([%{child_run_id: "run-1", parent_close: :request_cancel}])

      assert action == %{
               child_run_id: "run-1",
               action: :request_cancel,
               message: %{"child_run_id" => "run-1", "reason" => "parent_closed"}
             }
    end

    test "a mixed list in order" do
      children = [
        %{child_run_id: "run-c", parent_close: :cancel},
        %{child_run_id: "run-a", parent_close: :request_cancel},
        %{child_run_id: "run-b", parent_close: :abandon}
      ]

      assert Delegation.on_parent_close(children) ==
               {:ok,
                [
                  %{child_run_id: "run-c", action: :cancel},
                  %{
                    child_run_id: "run-a",
                    action: :request_cancel,
                    message: %{"child_run_id" => "run-a", "reason" => "parent_closed"}
                  },
                  %{child_run_id: "run-b", action: :abandon}
                ]}
    end

    test "0 and 256 entries; 257 entries and a repeated child_run_id are malformed" do
      children = fn n ->
        for i <- 1..n//1, do: %{child_run_id: "run-#{i}", parent_close: :cancel}
      end

      assert {:ok, []} = Delegation.on_parent_close([])
      assert {:ok, actions} = Delegation.on_parent_close(children.(256))
      assert Enum.map(actions, & &1.child_run_id) == Enum.map(1..256, &"run-#{&1}")
      assert {:error, :malformed} = Delegation.on_parent_close(children.(257))

      assert {:error, :malformed} =
               Delegation.on_parent_close([
                 %{child_run_id: "run-1", parent_close: :cancel},
                 %{child_run_id: "run-1", parent_close: :abandon}
               ])
    end

    test "the workflow/run ID rule and entry shape" do
      ok = fn id -> Delegation.on_parent_close([%{child_run_id: id, parent_close: :abandon}]) end

      assert {:ok, _} = ok.(String.duplicate("r", 200))
      assert {:ok, _} = ok.("run\t1")

      for id <- ["", String.duplicate("r", 201), "a\0b", <<0xFF>>, nil, :run] do
        assert {:error, :malformed} = ok.(id), inspect(id)
      end

      for bad <- [
            [%{child_run_id: "run-1", parent_close: nil}],
            [%{child_run_id: "run-1", parent_close: :stop}],
            [%{child_run_id: "run-1"}],
            [%{child_run_id: "run-1", parent_close: :cancel, x: 1}],
            [{"run-1", :cancel}],
            [%{child_run_id: "run-1", parent_close: :cancel} | :tail],
            nil
          ] do
        assert {:error, :malformed} = Delegation.on_parent_close(bad), inspect(bad)
      end
    end
  end
end
