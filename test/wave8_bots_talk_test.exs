Code.require_file("support/wave8_bots_talk_helper.exs", __DIR__)

defmodule Elzoo.Wave8.BotsTalkTest do
  # ELZ-349: the Wave 8 Pieces together on real PostgreSQL 16 and MinIO, every application call
  # running as the fixed non-owner, non-bypass role of ELZ-285. Each test names its acceptance
  # group of the ELZ-349 task.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Elzoo.{DurableMailbox, RecipeStore, Room, VersionPin, WorkItem}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.Wave8.{AppRepo, Host, OwnerRepo}
  alias Elzoo.Wave8.Helper, as: H
  alias Elzoo.RecipeStore.TestHelper, as: RS

  setup_all do
    role = H.start_repos!()
    on_exit(fn -> for repo <- [OwnerRepo, AppRepo], do: H.stop!(repo) end)
    # Fails, never skips: the application connection must be the application role.
    facts = H.role_guard!(role)
    {:ok, engines} = Registry.start_link(keys: :unique, name: Elzoo.Wave8.EngineRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.Wave8.UnitRegistry)
    for pid <- [engines, units], do: Process.unlink(pid)

    on_exit(fn ->
      for pid <- [engines, units], Process.alive?(pid), do: Supervisor.stop(pid)
    end)

    %{role: role, facts: facts}
  end

  setup %{role: role} do
    Process.flag(:trap_exit, true)
    %{w: H.fixture!(role)}
  end

  # ------------------------------------------------------------ rooms of T1

  @r1_members [{"Ann", "human"}, {"A", "bot"}, {"B", "bot"}, {"R2", "peer"}]

  defp r1(policy \\ %{}),
    do:
      H.start_payload(
        "R1",
        @r1_members,
        Map.merge(
          %{
            "rule" => "addressed",
            "default_member" => "A",
            "max_bot_turns" => 3,
            "handoff" => "allowed",
            "post_to" => "R2"
          },
          policy
        )
      )

  defp r2,
    do:
      H.start_payload("R2", [{"D", "bot"}, {"R1", "peer"}], %{
        "max_bot_turns" => 3,
        "post_to" => "R1"
      })

  defp r3,
    do:
      H.start_payload("R3", [{"Ann", "human"}, {"A", "bot"}, {"B", "bot"}], %{
        "rule" => "decided",
        "default_member" => "A",
        "max_bot_turns" => 2,
        "post_to" => "channel-r3",
        "rollover" => %{"max_turns" => 3}
      })

  defp peers!(w),
    do:
      H.rooms(w, "T1", %{
        "R1" => %{name: "R1", peer_id: "R1"},
        "R2" => %{name: "R2", peer_id: "R2"}
      })

  # A's turn after its tool slots expired: running, no second model call, no new post.
  defp turn_waits!(w, run, posts) do
    view = H.view(w, run)
    assert [%{phase: :running}] = for({_, s} <- view.slots, s.action_id == "t/1/2/turn", do: s)
    refute Enum.any?(view.slots, fn {_, s} -> s.action_id == "t/1/2:m:2" end)
    refute Enum.any?(Host.get().calls, &match?({"R1/1", "t/1/2:m:2", _}, &1))
    assert H.posts("R1") == posts
  end

  defp clean!, do: assert(Host.get().errors == [])

  defp ann(w, chain, id, text, mentions),
    do: assert({:ok, :applied} = H.put(w, "T1", chain, id, "Ann", text, mentions))

  defp messages(w, tenant, chain),
    do:
      H.read_as(
        tenant,
        "SELECT message_id FROM #{w.prefix}.elzoo_mailbox_messages WHERE chain_id = $1 ORDER BY seq",
        [chain]
      )
      |> List.flatten()

  defp pins_record(w, tenant, kind, run_id),
    do:
      for(
        {^kind, %{"identity" => i, "run_id" => ^run_id}} <-
          RS.rows(w.rs_owner_store, RS.stream(tenant)),
        do: i
      )

  # ------------------------------------------------------------ setup

  describe "setup" do
    test "the application role, every Store on the application Repo and exactly the README grants",
         %{w: w, role: role, facts: facts} do
      assert %{
               current: "elzoo_app",
               super: false,
               bypass: false,
               login: false,
               inherit: false,
               createrole: false,
               createdb: false,
               inherits_owner: false
             } = facts

      assert facts.session != "elzoo_app"

      # The role guard fails, and does not skip, for an unset variable or another role.
      for value <- [nil, "elzoo_test", "postgres"] do
        old = System.get_env("ELZOO_TEST_APP_ROLE")

        if value,
          do: System.put_env("ELZOO_TEST_APP_ROLE", value),
          else: System.delete_env("ELZOO_TEST_APP_ROLE")

        try do
          assert_raise ExUnit.AssertionError, fn -> H.app_role!() end
        after
          System.put_env("ELZOO_TEST_APP_ROLE", old)
        end
      end

      # Each engine started checks its Stores (start_engine!/3); open two rooms to start two.
      peers!(w)
      run1 = H.open!(w, "T1", H.room!(w, "T1", "R1"), "R1", r1())
      run2 = H.open!(w, "T1", H.room!(w, "T1", "R2"), "R2", r2())
      for run <- [run1, run2], do: assert(H.view(w, run).classification != :configured)

      # As elzoo_app: verify/1 of each mailbox binding and of the work items.
      assert :ok = DurableMailbox.verify(w.mailbox)
      assert :ok = DurableMailbox.verify(w.child_mailbox)
      assert :ok = WorkItem.verify(w.items)

      p = w.prefix
      stores = [w.rs_prefix | for({_, t} <- w.tenants, do: t.prefix)]

      expected =
        Map.merge(
          %{
            "schema #{p}" => "USAGE",
            "#{p}.elzoo_mailbox_chains" => "INSERT,SELECT,UPDATE",
            "#{p}.elzoo_mailbox_links" => "INSERT,SELECT,UPDATE",
            "#{p}.elzoo_mailbox_messages" => "INSERT,SELECT,UPDATE",
            "#{p}.elzoo_work_items" => "INSERT,SELECT,UPDATE"
          },
          Map.new(
            for s <- stores,
                {k, v} <- [
                  {"schema #{s}", "USAGE"},
                  {"#{s}.elzoo_log_heads", "INSERT,SELECT,UPDATE"},
                  {"#{s}.elzoo_outbox", "INSERT,SELECT,UPDATE"},
                  {"#{s}.elzoo_log_records", "INSERT,SELECT"},
                  {"#{s}.elzoo_checkpoints", "INSERT,SELECT"}
                ],
                do: {k, v}
          )
        )

      assert H.grants([p | stores], role) == {expected, false}

      # The recipe store, both Run owners and every engine Store are on the application Repo.
      H.store_on_app!(w.rs_store, role)
      for {_, t} <- w.tenants, do: H.schema_owner_facts!(t.prefix, role)
      clean!()
    end
  end

  # ------------------------------------------------------------ group 1, and group 2's two rooms

  describe "group 1: mail in" do
    test "refusals leave no row; mail during a turn waits; Ann's messages and R2's posts reach R1",
         %{w: w} do
      room1 = H.room!(w, "T1", "R1")
      run = H.open!(w, "T1", room1, "R1", r1())

      # Refused before the write: an undeclared name and a payload that fails the schema.
      assert {:error, :undeclared_name} =
               H.put(w, "T1", "R1", "m-x", "Ann", "hi", [], name: "elzoo.room.shout")

      assert {:error, :invalid_payload} =
               H.put(w, "T1", "R1", "m-y", "Ann", "", ["A"])

      # Mid-turn: A's model call is held while Ann's second message is put.
      Host.script({"R1/1", "t/1/1:m:1"}, {:hold, H.say("on it")})
      ann(w, "R1", "m-1", "A, please look", ["A"])
      assert {:ok, :delivered} = H.deliver(w, "T1", room1, "R1")
      H.await_held!({"R1/1", "t/1/1:m:1"})
      ann(w, "R1", "m-2", "B, you too", ["B"])
      assert {:ok, :busy} = H.deliver(w, "T1", room1, "R1")
      assert H.status(w, "T1", "R1", "m-2").state == :pending
      refute "mail:m-2" in H.inputs(w, run)

      # A table read in T1's scope: no row of either refused message, the row of an accepted one.
      rows = messages(w, "T1", "R1")
      assert "m-2" in rows
      refute "m-x" in rows or "m-y" in rows

      Host.queue({"R1/1", "B"}, [H.say("b here")])
      :ok = Host.release({"R1/1", "t/1/1:m:1"})
      assert H.idle?(H.settle!(w, run))
      assert {:ok, :delivered} = H.deliver(w, "T1", room1, "R1")
      H.settle!(w, run)

      assert H.status(w, "T1", "R1", "m-2") |> Map.take([:state, :link_seq]) == %{
               state: :consumed,
               link_seq: 1
             }

      assert [{"t/1/1", "A", "m-1"}, {"t/1/2", "B", "m-2"}] = H.turns(w, run)

      # Two rooms, on a fresh R2 chain: A's answers go to R2, D's answers to R1.
      peers!(w)
      room2 = H.room!(w, "T1", "R2")
      run2 = H.open!(w, "T1", room2, "R2", r2())
      Host.queue({"R1/1", "A"}, for(n <- 1..3, do: H.say("A#{n} to D", ["D"])))
      Host.queue({"R2/1", "D"}, for(n <- 1..3, do: H.say("D#{n} to A", ["A"])))
      ann(w, "R1", "m-3", "A, ask room 2", ["A"])
      H.pump!(w, "T1", [{"R1", room1}, {"R2", room2}])

      after_ann = Enum.drop(H.turns(w, run), 2)
      assert [{_, "A", "m-3"}, {_, "A", p1}, {_, "A", p2}] = after_ann
      # The two later A turns answer R2's posts, which reached R1 through the mailbox.
      for id <- [p1, p2] do
        assert "p/" <> _ = id
        assert %{state: :consumed, link_seq: 1} = H.status(w, "T1", "R1", id)
      end

      # D's three turns fill R2's bound; the fourth A turn is left out in R1 with one notice.
      assert [{_, "D", _}, {_, "D", _}, {_, "D", _}] = H.turns(w, run2)
      assert [{"R1/1", _, %{"reason" => "bot_turn_bound", "members" => ["Ann"]}}] = H.notices("R1")
      assert H.notices("R2") == []
      # Only A's three answers were posted to R2.
      assert length(messages(w, "T1", "R2")) == 3
      assert {:ok, :empty} = H.deliver(w, "T1", room2, "R2")
      clean!()
    end
  end

  # ------------------------------------------------------------ group 2

  describe "group 2: turns" do
    test "mentions and a second turn, the bound, a person resumes, escalation and handoff",
         %{w: w} do
      peers!(w)
      room1 = H.room!(w, "T1", "R1")
      room2 = H.room!(w, "T1", "R2")
      run = H.open!(w, "T1", room1, "R1", r1())
      H.open!(w, "T1", room2, "R2", r2())
      pump = fn -> H.pump!(w, "T1", [{"R1", room1}]) end

      # Ann addresses A; A mentions B; B answers and mentions A; A's second turn.
      Host.queue({"R1/1", "A"}, [H.say("a1", ["B"]), H.say("a2")])
      Host.queue({"R1/1", "B"}, [H.say("b1", ["A"])])
      ann(w, "R1", "m-1", "hello A", ["A"])
      pump.()

      assert [{"t/1/1", "A", "m-1"}, {"t/1/2", "B", "t/1/1"}, {"t/1/3", "A", "t/1/2"}] =
               H.turns(w, run)

      all = H.all_actions(w, run)
      assert "t/1/1:m:1" in all and "t/1/3:m:1" in all
      # No action was refused (a reused identity would be).
      assert Enum.all?(H.view(w, run).slots, fn {_, s} -> s.outcome == "completed" end)

      assert for({_, _, p} <- H.posts("R1"), do: {p["turn_id"], p["text"]}) ==
               [{"t/1/1", "a1"}, {"t/1/2", "b1"}, {"t/1/3", "a2"}]

      # Three turns fill the bound: no notice.
      assert H.notices("R1") == []

      # An A-B exchange stops at max_bot_turns with one notice; Ann's next message resumes.
      Host.queue({"R1/1", "A"}, [H.say("x", ["B"]), H.say("z", ["B"]), H.say("back")])
      Host.queue({"R1/1", "B"}, [H.say("y", ["A"])])
      ann(w, "R1", "m-2", "again A", ["A"])
      pump.()
      assert [{_, "A", "m-2"}, {_, "B", _}, {_, "A", _}] = Enum.drop(H.turns(w, run), 3)
      assert [{_, _, %{"reason" => "bot_turn_bound", "members" => ["Ann"]}}] = H.notices("R1")
      ann(w, "R1", "m-3", "A, go on", ["A"])
      pump.()
      assert [{_, "A", "m-3"}] = Enum.drop(H.turns(w, run), 6)

      # Escalation: one notice, and no bot turn after a peer's message until Ann writes.
      Host.queue({"R1/1", "A"}, [H.say("I need a person", [], escalate: true), H.say("thanks")])
      ann(w, "R1", "m-4", "A, decide this", ["A"])
      pump.()

      assert {:ok, :applied} =
               H.put(w, "T1", "R1", "peer-1", "R2", "A, from room 2", ["A"],
                 sender: %{kind: :service, id: "R2"}
               )

      pump.()
      assert %{state: :consumed} = H.status(w, "T1", "R1", "peer-1")
      assert [{_, "A", "m-4"}] = Enum.drop(H.turns(w, run), 7)
      assert [_, {_, _, %{"reason" => "escalated", "members" => ["Ann"]}}] = H.notices("R1")
      ann(w, "R1", "m-5", "I am here, A", ["A"])
      pump.()
      assert [{_, "A", "m-5"}] = Enum.drop(H.turns(w, run), 8)

      # Handoff: Ann's next unaddressed message gives B the turn.
      Host.queue({"R1/1", "A"}, [H.say("B takes over", [], handoff_to: "B")])
      Host.queue({"R1/1", "B"}, [H.say("B here")])
      ann(w, "R1", "m-6", "A, hand this over", ["A"])
      ann(w, "R1", "m-7", "who is on it?", [])
      pump.()
      assert [{_, "A", "m-6"}, {_, "B", "m-7"}] = Enum.drop(H.turns(w, run), 9)
      assert length(H.notices("R1")) == 2
      clean!()
    end

    test ":decided: a valid pick, a pick of a non-member falls back, a mention asks no decision",
         %{w: w} do
      room3 = H.room!(w, "T1", "R3")
      run = H.open!(w, "T1", room3, "R3", r3())
      pump = fn -> H.pump!(w, "T1", [{"R3", room3}]) end

      Host.script({"R3/1", "d/1/1:call:0"}, H.pick(%{"pick" => ["B"]}))
      Host.script({"R3/1", "d/1/2:call:0"}, H.pick(%{"pick" => ["Z"]}))
      Host.queue({"R3/1", "B"}, [H.say("B picked"), H.say("B named")])
      Host.queue({"R3/1", "A"}, [H.say("A by default")])

      ann(w, "R3", "m-1", "anyone?", [])
      pump.()
      ann(w, "R3", "m-2", "anyone else?", [])
      pump.()
      ann(w, "R3", "m-3", "B, please", ["B"])
      pump.()

      assert [
               {"d/1/1", "elzoo.room.decide"},
               {"t/1/1/turn", "elzoo.room.turn"},
               {"t/1/1/post", "elzoo.room.post"},
               {"d/1/2", "elzoo.room.decide"},
               {"t/1/2/turn", "elzoo.room.turn"},
               {"t/1/2/post", "elzoo.room.post"},
               {"t/1/3/turn", "elzoo.room.turn"},
               {"t/1/3/post", "elzoo.room.post"},
               {"c/1/1", "elzoo.room.carry"},
               {"f/1", "elzoo.room.finish"}
             ] = H.actions(w, run)

      assert [{"t/1/1", "B", "m-1"}, {"t/1/2", "A", "m-2"}, {"t/1/3", "B", "m-3"}] =
               H.turns(w, run)

      # Each decision ran the real typed-decision step: its model call and its finish.
      all = H.all_actions(w, run)
      for d <- ["d/1/1", "d/1/2"], do: assert((d <> ":call:0") in all and (d <> ":finish") in all)
      refute Enum.any?(all, &String.starts_with?(&1, "d/1/3"))

      # Three turns reach rollover.max_turns: the tip carried and finished.
      assert {:ok, :terminal} = H.deliver(w, "T1", room3, "R3")
      assert {:ok, %{seq: 2, carry_kind: :finished}} = H.rollover(w, "T1", room3, "R3", 1)
      assert "decision_fallback" in H.notes(H.tip(w, "T1", "R3").carry)
      clean!()
    end
  end

  # ------------------------------------------------------------ groups 3 and 4

  describe "groups 3 and 4: delegation and parent close" do
    test "a granted child, each refusal whole, offered then accepted; each parent-close rule once",
         %{w: w} do
      peers!(w)
      room1 = H.room!(w, "T1", "R1")
      room2 = H.room!(w, "T1", "R2")
      run = H.open!(w, "T1", room1, "R1", r1())
      H.open!(w, "T1", room2, "R2", r2())
      [v1, v2 | _] = w.tenants["T1"].versions

      # A version published after A's Run started.
      H.publish!(w, "T1", v2)

      # A's turn t/1/1: C (granted), then refusals: escalation, cycle and stale; then budget and
      # depth with the acceptance of C's item.
      c_run = H.child_run_id(run, "t/1/1:t:1:1")
      c_item = H.item_id(run, "t/1/1:t:1:1")

      Host.script(
        {"R1/1", "t/1/1:m:1"},
        H.propose([
          H.delegate("C", ["files.read"], 100, nil, "Summarise the files"),
          H.delegate("E1", ["admin"], 10, nil, "Escalate"),
          H.delegate("A", ["files.read"], 10, nil, "Myself"),
          H.delegate("E4", ["files.read"], 10, nil, "Stale")
        ])
      )

      H.host_facts(w, {"R1/1", "t/1/1:t:1:4"}, %{root_epoch: 2})

      # C proposes E while A is revoked (the middle bot of lineage [A, C]).
      Host.script({"C", "C:m:1"}, H.propose([H.delegate("E", ["files.read"], 10, nil, "Deeper")]))
      H.host_facts(w, {"C", "C:t:1:1"}, %{revoked_ids: ["A"]})

      Host.script({"C", "C:m:2"}, %{
        "content" => "C's summary",
        "finish" => "stop",
        "tool_proposals" => []
      })

      Host.script(
        {"R1/1", "t/1/1:m:2"},
        {:hold,
         H.propose([
           {"accept_item", %{"item_id" => c_item}},
           H.delegate("E5", ["files.read"], 501, nil, "Over budget"),
           H.delegate("E6", ["files.read"], 100, nil, "Too deep")
         ])}
      )

      H.host_facts(w, {"R1/1", "t/1/1:t:2:3"}, %{max_depth: 1})
      Host.script({"R1/1", "t/1/1:m:3"}, H.say("C is done"))

      ann(w, "R1", "m-1", "A, get the files summarised", ["A"])
      assert {:ok, :delivered} = H.deliver(w, "T1", room1, "R1")
      H.await_held!({"R1/1", "t/1/1:m:2"})

      # C: delegated from the room service, the requested subset of A's scopes, the default rule.
      c = H.book(w, c_run)
      assert c.grant.principal.delegated_by == "room-service"
      assert c.grant.principal.allowed_scopes == ["files.read"]
      assert c.grant.parent_close == :request_cancel
      assert c.grant.lineage == ["A", "C"] and c.grant.depth == 2 and c.grant.budget == 100

      # The tip's version, not the published one, reaches C: pin record and capture.
      assert {:ok, ^v2} = RecipeStore.published(w.tenants["T1"].recipes, w.tenants["T1"].caller)
      assert pins_record(w, "T1", "recipe_pinned", c_run) == [v1]
      assert VersionPin.version(c.capture) == v1

      # Attached to the tip's Run, its result recorded; C's pin unpinned when it ended.
      t = w.tenants["T1"]

      assert {:ok, %{parent: %{run_id: ^run, attempt_id: "attempt"}, outcome: :completed}} =
               Run.status(t.run, c_run)

      assert {:ok, %{children: %{^c_run => %{settled: settled}}}} = Run.status(t.run, run)
      assert is_integer(settled)
      assert pins_record(w, "T1", "recipe_unpinned", c_run) == [v1]
      assert H.pins_of(w, "T1", c_run) == []

      # The item is offered, not accepted, until A's next model result.
      assert {:ok, %{state: :offered, evidence: "outcome:" <> ^c_run, decided_by: nil}} =
               WorkItem.get(w.items, "T1", c_item)

      :ok = Host.release({"R1/1", "t/1/1:m:2"})
      H.settle!(w, run)

      assert {:ok, %{state: :accepted, decided_by: "A"}} = WorkItem.get(w.items, "T1", c_item)

      # Each refusal is whole: no item, no pin record, no Run and no engine.
      refusals = Host.get().refusals

      assert Enum.sort(refusals) ==
               Enum.sort([
                 {"R1/1", "t/1/1:t:1:2", :escalation},
                 {"R1/1", "t/1/1:t:1:3", :cycle},
                 {"R1/1", "t/1/1:t:1:4", :stale},
                 {"C", "C:t:1:1", :revoked},
                 {"R1/1", "t/1/1:t:2:2", :budget},
                 {"R1/1", "t/1/1:t:2:3", :depth}
               ])

      for {label, id, _} <- refusals do
        parent = if label == "C", do: c_run, else: run
        assert {:error, :unknown_item} = WorkItem.get(w.items, "T1", H.item_id(parent, id))
        child = H.child_run_id(parent, id)
        assert {:error, :not_found} = Run.status(t.run, child)
        assert H.entry(w, child) == nil
        assert pins_record(w, "T1", "recipe_pinned", child) == []
      end

      # ---------------------------------------------------------------- group 4: parent close
      Host.script(
        {"R1/1", "t/1/2:m:1"},
        H.propose([
          H.delegate("K-abandon", ["files.read"], 50, "abandon", "Keep going"),
          H.delegate("K-request", ["files.read"], 50, "request_cancel", "Stop when asked"),
          H.delegate("K-cancel", ["files.read"], 50, "cancel", "Stop now")
        ])
      )

      ann(w, "R1", "m-2", "A, start three", ["A"])
      at = H.now(w)
      assert {:ok, :delivered} = H.deliver(w, "T1", room1, "R1")
      H.await_work!("K-abandon")
      H.await_work!("K-cancel")
      kids = for n <- 1..3, do: H.child_run_id(run, "t/1/2:t:1:#{n}")
      [ka, kr, kc] = kids
      H.settle!(w, kr)
      assert H.idle?(H.view(w, kr))
      H.settle!(w, run)

      # The wake at the three tool calls' deadline settles them expired, without a result: the
      # parent of each child ends. A's turn is not given the expired slots: it stays running
      # with no second model call and no post.
      H.clock(w, at + H.tool_ms())
      assert {:ok, :busy} = H.wake(w, "T1", room1, "R1", "deadline/t/1/2")
      view = H.view(w, run)

      for n <- 1..3 do
        assert [%{phase: :settled, outcome: "expired"}] =
                 for({_, s} <- view.slots, s.action_id == "t/1/2:t:1:#{n}", do: s)
      end

      posts_before = H.posts("R1")
      turn_waits!(w, run, posts_before)

      # The open items of the tip: the three children (C's item is final).
      {:ok, %{items: open}} =
        WorkItem.list_open(w.items, "T1", %{parent_run_id: run, after: nil, limit: 256})

      assert Enum.sort(for i <- open, do: {i.child_run_id, i.parent_close, i.state}) ==
               Enum.sort([
                 {ka, :abandon, :running},
                 {kr, :request_cancel, :running},
                 {kc, :cancel, :running}
               ])

      # Apply on_parent_close/1; the host restarts (its bookkeeping dropped) after two actions.
      assert [
               {:cancel, ^kc, {{:ok, :applied}, {:ok, %{revision: _}}}},
               {:request_cancel, ^kr, {{:ok, :applied}, {:ok, :applied}, {:ok, %{revision: _}}}}
             ] = H.parent_close!(w, "T1", run, 2)

      assert [
               {:request_cancel, ^kr, {{:ok, :duplicate}, {:ok, :duplicate}, {:ok, :unchanged}}},
               {:abandon, ^ka, {:ok, %{revision: _}}}
             ] = H.parent_close!(w, "T1", run)

      # :cancel: one cancel control, its open slot settled, a late outcome changes nothing.
      kc_view = H.view(w, kc)

      assert [%{phase: :settled, outcome: cancelled}] =
               for({_, s} <- kc_view.slots, s.action_id == "w1", do: s)

      assert cancelled != "completed"
      [{key, _}] = for {k, s} <- kc_view.slots, s.action_id == "w1", do: {k, s}

      assert {:ok, :applied} =
               H.input!(w, kc, "late:w1", H.outcome("w1", "completed", "result", %{}), %{
                 occurrence: key,
                 actual: 0,
                 dispatch: "dispatched"
               })

      assert [%{outcome: ^cancelled}] =
               for({_, s} <- H.view(w, kc).slots, s.action_id == "w1", do: s)

      assert Enum.count(H.inputs(w, kc), &String.starts_with?(&1, "cancel:")) == 1

      assert {:ok, %{state: :cancelled}} =
               WorkItem.get(w.items, "T1", H.item_id(run, "t/1/2:t:1:3"))

      H.child_ended(w, kc)

      # :request_cancel: given to the idle child once; it finishes; its item goes cancelled.
      assert {:ok, %{state: :cancel_requested}} =
               WorkItem.get(w.items, "T1", H.item_id(run, "t/1/2:t:1:2"))

      assert {:delivered, :applied} = H.deliver_child!(w, "T1", kr)
      assert H.view(w, kr).phase == :terminal
      assert Enum.count(H.inputs(w, kr), &String.starts_with?(&1, "mail:")) == 1

      assert {:ok, %{state: :cancelled}} =
               WorkItem.get(w.items, "T1", H.item_id(run, "t/1/2:t:1:2"))

      assert {:ok, :empty} = DurableMailbox.claim(w.child_mailbox, "T1", %{chain_id: kr})

      # :abandon: the child goes on and finishes; its item stays abandoned; its offer is refused.
      :ok = Host.release_work("K-abandon")
      H.await!(fn -> H.view(w, ka).phase == :terminal end)
      H.child_ended(w, ka)
      assert H.book(w, ka).offer == {:error, {:state, :abandoned}}

      assert {:ok, %{state: :abandoned}} =
               WorkItem.get(w.items, "T1", H.item_id(run, "t/1/2:t:1:1"))

      # No outcome reached the parent after its slots settled; its turn still waits. The wake at
      # the turn's own deadline settles it expired; then the tip is idle.
      turn_waits!(w, run, posts_before)
      H.clock(w, at + H.turn_ms())
      assert {:ok, :busy} = H.wake(w, "T1", room1, "R1", "deadline/t/1/2/turn")
      view = H.settle!(w, run)
      assert H.idle?(view)

      assert [%{phase: :settled, outcome: "expired"}] =
               for({_, s} <- view.slots, s.action_id == "t/1/2/turn", do: s)

      refute Enum.any?(view.slots, fn {_, s} -> s.action_id == "t/1/2:m:2" end)
      assert H.posts("R1") == posts_before

      assert {:ok, %{items: [], more: false}} =
               WorkItem.list_open(w.items, "T1", %{parent_run_id: run, after: nil, limit: 256})

      for child <- [ka, kr], do: assert(H.pins_of(w, "T1", child) == [])
      clean!()
    end
  end

  # ------------------------------------------------------------ group 5

  describe "group 5: rollover" do
    test "the request edge, one successor on a fresh Unit, mail once, concurrent rollovers, a crash, pins, a Run deadline",
         %{w: w} do
      # The request edge (Q8): R1's per-message reserve is R = 3 × (2 + 8) + 1 = 31, so with
      # request_cap 40 a message is given while request_count + 33 <= 40. A simple turn costs 4
      # requests (turn, model call, finish, post): after two messages 8 + 33 > 40.
      room1 = H.room!(w, "T1", "R1", request_cap: 40)
      [v1, v2 | _] = w.tenants["T1"].versions
      run1 = H.open!(w, "T1", room1, "R1", r1())
      two = fn n -> Host.queue({"R1/#{n}", "A"}, [H.say("one"), H.say("two")]) end

      two.(1)
      ann(w, "R1", "m-1", "A, one", ["A"])
      ann(w, "R1", "m-2", "A, two", ["A"])

      assert [{"R1", {:ok, :delivered}}, {"R1", {:ok, :delivered}}, {"R1", {:ok, :rollover}}] =
               H.pump!(w, "T1", [{"R1", room1}])

      assert %{phase: :terminal, outcome: :completed} = H.view(w, run1)
      assert {"c/1/1", "elzoo.room.carry"} in H.actions(w, run1)

      # Mail to link 1's Run ID before the rollover.
      assert {:ok, :applied} =
               H.put(w, "T1", "R1", "m-before", "Ann", "A, before", ["A"], address: {:run, run1})

      assert {:ok, :terminal} = H.deliver(w, "T1", room1, "R1")
      assert {:ok, %{seq: 2, carry_kind: :finished}} = H.rollover(w, "T1", room1, "R1", 1)
      run2 = H.ids("T1", "R1", 2)

      assert [
               %{seq: 1, state: :closed, run_id: ^run1, unit_identity: ^run1},
               %{seq: 2, state: :live, run_id: ^run2, unit_identity: ^run2, predecessor_seq: 1}
             ] = H.chain(w, "T1", "R1").links

      assert H.entry(w, run2).unit == run2
      assert {:error, {:not_tip, 2}} = H.rollover(w, "T1", room1, "R1", 1)

      # Mail to link 1's Run ID after the rollover; both are given once, to the successor.
      assert {:ok, :applied} =
               H.put(w, "T1", "R1", "m-after", "Ann", "A, after", ["A"], address: {:run, run1})

      two.(2)

      assert [{"R1", {:ok, :delivered}}, {"R1", {:ok, :delivered}}, {"R1", {:ok, :rollover}}] =
               H.pump!(w, "T1", [{"R1", room1}])

      for id <- ["m-before", "m-after"] do
        assert %{state: :consumed, link_seq: 2} = H.status(w, "T1", "R1", id)
        assert Enum.count(H.inputs(w, run2), &(&1 == "mail:" <> id)) == 1
        refute ("mail:" <> id) in H.inputs(w, run1)
      end

      # The successor keeps the pinned version after a newer version is published.
      H.publish!(w, "T1", v2)
      assert H.pins_of(w, "T1", run2) == [v1]
      assert H.pins_of(w, "T1", run1) == []
      assert H.tip(w, "T1", "R1").pin == v1

      # A crash after the mailbox step: the start Need fails once; resume/3 gives one start.
      run3 = H.ids("T1", "R1", 3)
      H.fail_start_once(w, run3, :host_crash)
      assert {:error, {:start, :host_crash}} = H.rollover(w, "T1", room1, "R1", 2)
      assert %{seq: 3} = H.tip(w, "T1", "R1")
      assert H.entry(w, run3) == nil
      assert {:ok, :live} = H.resume(w, "T1", room1, "R1")
      assert H.inputs(w, run3) == ["start:" <> run3]
      assert H.pins_of(w, "T1", run3) == [v1] and H.pins_of(w, "T1", run2) == []

      two.(3)
      ann(w, "R1", "m-3", "A, three", ["A"])
      ann(w, "R1", "m-4", "A, four", ["A"])
      H.pump!(w, "T1", [{"R1", room1}])
      assert {:ok, :terminal} = H.deliver(w, "T1", room1, "R1")

      # Outside the one-deliverer Need, on purpose: two rollovers of link 3, released together
      # after both wait on the chain row that the harness holds as elzoo_app in T1's scope.
      parent = self()

      holder =
        spawn(fn ->
          Elzoo.TenantIsolation.transact(AppRepo, %{tenant: "T1"}, fn ->
            H.q!(
              AppRepo,
              "SELECT 1 FROM #{w.prefix}.elzoo_mailbox_chains WHERE chain_id = 'R1' FOR UPDATE"
            )

            send(parent, :held)
            receive do: (:go -> {:ok, :released})
          end)
        end)

      assert_receive :held, 10_000
      request = %{chain_id: "R1", link_seq: 3, change: nil}
      racers = for _ <- 1..2, do: Task.async(fn -> Room.rollover(room1, "T1", request) end)

      H.await!(fn ->
        [[n]] =
          H.owner!(
            "SELECT count(DISTINCT l.pid)::int FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE NOT l.granted AND a.datname = current_database() AND l.pid <> pg_backend_pid()"
          )

        n == 2
      end)

      send(holder, :go)

      # Both answer the one successor: the later one replays the committed step.
      assert [{:ok, %{seq: 4, carry_kind: :finished}}, {:ok, %{seq: 4, carry_kind: :finished}}] =
               Task.await_many(racers, 60_000)

      assert {:ok, :live} = H.resume(w, "T1", room1, "R1")
      run4 = H.ids("T1", "R1", 4)
      links = H.chain(w, "T1", "R1").links
      assert [%{seq: 4, run_id: ^run4}] = for(l <- links, l.predecessor_seq == 3, do: l)
      assert length(links) == 4
      assert H.pins_of(w, "T1", run4) == [v1]
      assert H.pins_of(w, "T1", run3) == []
      assert Enum.count(H.inputs(w, run4), &(&1 == "start:" <> run4)) == 1

      # A tip that started with a queued turn from its carry and reaches its Run deadline
      # without a carry of its own rolls over :restarted; no turn of it runs again.
      room_r = H.room!(w, "T1", "R1r")
      runr1 = H.open!(w, "T1", room_r, "R1r", r1(%{"rollover" => %{"max_turns" => 1}}))
      Host.queue({"R1r/1", "A"}, [H.say("A first")])
      ann(w, "R1r", "m-1", "A and B", ["A", "B"])
      H.pump!(w, "T1", [{"R1r", room_r}])
      assert [{"t/1/1", "A", "m-1"}] = H.turns(w, runr1)
      assert {:ok, :terminal} = H.deliver(w, "T1", room_r, "R1r")
      # Link 2 runs the queued B turn first; its model call stalls.
      Host.script({"R1r/2", "t/2/2:m:1"}, :hold)
      assert {:ok, %{seq: 2, carry_kind: :finished}} = H.rollover(w, "T1", room_r, "R1r", 1)
      runr2 = H.ids("T1", "R1r", 2)
      assert [%{"member" => "B"}] = H.tip(w, "T1", "R1r").carry["carry"]["queue"]
      H.await_held!({"R1r/2", "t/2/2:m:1"})
      assert [{"t/2/2", "B", "m-1"}] = H.turns(w, runr2)
      H.clock(w, H.entry(w, runr2).run_deadline)
      assert {:ok, _} = H.wake(w, "T1", room_r, "R1r", "deadline/" <> runr2)
      assert %{phase: :terminal, outcome: :out_of_time} = H.view(w, runr2)
      assert {:ok, :terminal} = H.deliver(w, "T1", room_r, "R1r")
      assert {:ok, %{seq: 3, carry_kind: :restarted}} = H.rollover(w, "T1", room_r, "R1r", 2)
      runr3 = H.ids("T1", "R1r", 3)
      tip = H.tip(w, "T1", "R1r")
      assert tip.carry["carry"]["queue"] == []
      assert "restarted_queue_dropped" in H.notes(tip.carry)
      H.settle!(w, runr3)
      assert H.turns(w, runr3) == []
      assert H.inputs(w, runr3) == ["start:" <> runr3]
      clean!()
    end
  end

  # ------------------------------------------------------------ group 6

  describe "group 6: isolation" do
    test "owner-only DDL is refused; each tenant's scope reads its own rows; a T2 row cannot be written in T1's scope",
         %{w: w} do
      # T1: R1, where A starts a child; T2: one room with one delivered message, one rollover
      # and one child item.
      room1 = H.room!(w, "T1", "R1")
      run1 = H.open!(w, "T1", room1, "R1", r1())

      Host.script(
        {"R1/1", "t/1/1:m:1"},
        H.propose([H.delegate("Q", ["files.read"], 50, nil, "T1 child")])
      )

      Host.script({"R1/1", "t/1/1:m:2"}, H.say("ok"))
      ann(w, "R1", "m-1", "A, start a child", ["A"])
      assert {:ok, :delivered} = H.deliver(w, "T1", room1, "R1")
      q1 = H.child_run_id(run1, "t/1/1:t:1:1")
      H.await!(fn -> H.entry(w, q1) != nil and H.view(w, q1).phase == :terminal end)
      H.child_ended(w, q1)
      H.settle!(w, run1)

      room_s = H.room!(w, "T2", "S")

      start =
        H.start_payload("S", [{"Cara", "human"}, {"T", "bot"}], %{
          "default_member" => "T",
          "post_to" => "channel-t2",
          "rollover" => %{"max_turns" => 1}
        })

      runs = H.open!(w, "T2", room_s, "S", start)

      Host.script(
        {"S/1", "t/1/1:m:1"},
        H.propose([H.delegate("Q", ["files.read"], 50, nil, "T2 child")])
      )

      Host.script({"S/1", "t/1/1:m:2"}, H.say("done"))
      assert {:ok, :applied} = H.put(w, "T2", "S", "c-1", "Cara", "T, a child please", [])
      assert {:ok, :delivered} = H.deliver(w, "T2", room_s, "S")
      q2 = H.child_run_id(runs, "t/1/1:t:1:1")
      H.await!(fn -> H.entry(w, q2) != nil and H.view(w, q2).phase == :terminal end)
      H.child_ended(w, q2)
      H.settle!(w, runs)
      assert {:ok, :terminal} = H.deliver(w, "T2", room_s, "S")
      assert {:ok, %{seq: 2}} = H.rollover(w, "T2", room_s, "S", 1)

      p = w.prefix

      # Owner only, as elzoo_app.
      for table <- ["elzoo_mailbox_messages", "elzoo_work_items"] do
        assert H.denied?(H.try_app("ALTER TABLE #{p}.#{table} NO FORCE ROW LEVEL SECURITY"))
        assert H.denied?(H.try_app("DROP POLICY elzoo_tenant_floor ON #{p}.#{table}"))
      end

      # Reads without a tenant predicate, in T2's scope and then in T1's.
      for table <-
            ~w(elzoo_mailbox_chains elzoo_mailbox_links elzoo_mailbox_messages elzoo_work_items) do
        tenants = fn tenant ->
          H.read_as(tenant, "SELECT DISTINCT tenant FROM #{p}.#{table}") |> List.flatten()
        end

        assert tenants.("T2") == ["T2"], table
        assert tenants.("T1") == ["T1"], table

        # In T1's scope, a T2 row is refused (SQLSTATE 42501).
        insert =
          "INSERT INTO #{p}.#{table} SELECT (jsonb_populate_record(NULL::#{p}.#{table}, to_jsonb(t) || '{\"tenant\": \"T2\"}')).* FROM #{p}.#{table} t LIMIT 1"

        assert H.rls_denied?(H.try_as("T1", insert)), table
      end

      assert [["c-1", "consumed"]] =
               H.read_as("T2", "SELECT message_id, state FROM #{p}.elzoo_mailbox_messages")

      assert [[2]] = H.read_as("T2", "SELECT count(*)::int FROM #{p}.elzoo_mailbox_links")
      assert [[1]] = H.read_as("T2", "SELECT count(*)::int FROM #{p}.elzoo_work_items")
      clean!()
    end
  end
end
