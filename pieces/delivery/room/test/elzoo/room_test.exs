# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/room_test_helper.exs", __DIR__)

defmodule Elzoo.RoomTest do
  use ExUnit.Case, async: false
  import Elzoo.Room.TestHelper
  alias Elzoo.{DurableMailbox, RecipeStore, Room}

  @moduletag timeout: 300_000
  @moduletag capture_log: false

  setup_all do
    {:ok, role: services!()}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp open!(w, chain_id, start, pin \\ nil) do
    assert {:ok, %{run_id: run_id}} =
             Room.open(w.room, w.tenant, %{
               chain_id: chain_id,
               start: start,
               pin: pin || hd(w.versions)
             })

    run_id
  end

  defp deliver(w, chain_id), do: Room.deliver(w.room, w.tenant, %{chain_id: chain_id})

  describe "case 1: a room of one person and two bots" do
    test "turns post their answers, mail waits during a turn, a 128-byte member starts", %{
      role: role
    } do
      w = world(role)
      long = String.duplicate("b", 128)
      run = open!(w, "c1", start(bots: ["bot-a", "bot-b", long]))
      settle_engine(w, run)
      script(w, "bot-a", %{plan: [{:hold, 1}], text: "answer a"})

      assert {:ok, :applied} = put(w, "c1", "m-1", mentions: ["bot-a"])
      assert {:ok, :delivered} = deliver(w, "c1")
      assert_receive {:held, worker, _}, 10_000

      # A message put during the turn waits; the tip is busy.
      assert {:ok, :applied} = put(w, "c1", "m-2", mentions: ["bot-b", long])
      assert {:ok, :busy} = deliver(w, "c1")
      assert status(w, "c1", "m-2").state == :pending
      refute "mail:m-2" in inputs(w, run)

      send(worker, :release)
      settle_engine(w, run)
      assert {:ok, :delivered} = deliver(w, "c1")
      settle_engine(w, run)
      assert {:ok, :empty} = deliver(w, "c1")

      assert_settled(w, "c1", "m-1", :consumed)
      assert_settled(w, "c1", "m-2", :consumed)
      assert room_inputs(w, run) == ["start:" <> run, "mail:m-1", "mail:m-2"]

      assert for(p <- posts(w), do: {p["turn_id"], p["member"], p["text"]}) == [
               {"t/1/1", "bot-a", "answer a"},
               {"t/1/2", "bot-b", "ok"},
               {"t/1/3", long, "ok"}
             ]
    end
  end

  defp unknown_chain?(w, chain_id),
    do:
      DurableMailbox.chain(w.mailbox, w.tenant, %{chain_id: chain_id, after_seq: nil, limit: 1}) ==
        {:error, :unknown_chain}

  defp reserve(turn, decision \\ {0, 0}),
    do: %{
      turn: %{actions: elem(turn, 0), requests: elem(turn, 1)},
      decision: %{actions: elem(decision, 0), requests: elem(decision, 1)},
      deadline_margin_ms: 1_000
    }

  # The tip's Run ends out_of_time: the host's timer wakes it at its Run deadline.
  defp end_by_deadline(w, chain_id, run) do
    clock(w, view_deadline(w, run))

    assert {:ok, _} =
             Room.wake(w.room, w.tenant, %{chain_id: chain_id, wake_id: "deadline/" <> run})

    assert view(w, run).phase == :terminal
  end

  defp view_deadline(w, run), do: Agent.get(w.engines, & &1[run].run_deadline)

  describe "case 2: open/3" do
    test "each refused start writes nothing; the reserve edge opens at 256 and refuses 257", %{
      role: role
    } do
      w = world(role)
      before = records(w)

      bad_carry = %{
        "window" => [],
        "bot_turns" => 1,
        "default_member" => nil,
        "rule_state" => nil,
        "awaiting_person" => false,
        "queue" => [%{"member" => "alice", "message_id" => "m-1"}],
        "seq" => %{"turn" => 0, "notice" => 0, "decision" => 0},
        "notes" => []
      }

      good_carry = %{bad_carry | "queue" => [%{"member" => "bot-a", "message_id" => "m-1"}]}

      refusals = [
        {Map.delete(start(), "summary"), {:invalid_start, :malformed}},
        {start(rule: "nope"), {:invalid_start, :unknown_rule}},
        {start(default_member: "ghost"), {:invalid_start, :default_member}},
        {start(rule: "everyone", bots: ["bot-a", "bot-b", "bot-c"]),
         {:invalid_start, :too_many_bots}},
        {%{start() | "carry" => bad_carry}, {:invalid_start, :carry}},
        {%{start() | "link" => 2}, {:invalid_start, :link}},
        {%{start() | "carry" => good_carry}, {:invalid_start, :carry}}
      ]

      for {start, reason} <- refusals do
        assert Room.open(w.room, w.tenant, %{chain_id: "r", start: start, pin: hd(w.versions)}) ==
                 {:error, reason}
      end

      # The reserve edge: B = 1 and d = 0, so A + 2 = turn.actions + 5 and R + 2 = turn.requests + 5.
      one = start(bots: ["bot-a"], max_bot_turns: 1)
      edge = fn turn, cap -> room(w, w.turn_policy, reserve: reserve(turn), request_cap: cap) end

      open = fn room, id ->
        Room.open(room, w.tenant, %{chain_id: id, start: one, pin: hd(w.versions)})
      end

      assert open.(edge.({252, 0}, 256), "r") == {:error, :reserve}
      assert open.(edge.({0, 96}, 100), "r") == {:error, :reserve}
      assert records(w) == before
      assert unknown_chain?(w, "r")

      assert {:ok, _} = open.(edge.({251, 0}, 256), "a256")
      assert {:ok, _} = open.(edge.({0, 95}, 100), "r100")
      assert pins_of(w, ids(w, "a256", 1)) == [hd(w.versions)]
      assert pins_of(w, ids(w, "r100", 1)) == [hd(w.versions)]
    end

    test "a pin error writes no chain; repeats are equal; a conflict pins nothing", %{role: role} do
      w = world(role)
      unknown = "recipe-package-v1:sha256:" <> String.duplicate("0", 64)

      assert Room.open(w.room, w.tenant, %{chain_id: "c", start: start(), pin: unknown}) ==
               {:error, {:pin, :not_found}}

      assert unknown_chain?(w, "c")
      run = open!(w, "c", start())
      first = %{run_id: run, unit_identity: run}
      assert run == ids(w, "c", 1)
      before = records(w)

      assert Room.open(w.room, w.tenant, %{chain_id: "c", start: start(), pin: hd(w.versions)}) ==
               {:ok, first}

      assert Room.open(w.room, w.tenant, %{
               chain_id: "c",
               start: start(),
               pin: Enum.at(w.versions, 1)
             }) ==
               {:error, {:mailbox, :conflict}}

      assert records(w) == before
      assert inputs(w, run) == ["start:" <> run]
    end

    test "a chain created between the read and the open: the room's own pin is removed only when it differs",
         %{role: role} do
      w = world(role)
      [v1, v2 | _] = w.versions

      for {chain_id, their_pin, kept} <- [{"differ", v2, []}, {"equal", v1, [v1]}] do
        run = ids(w, chain_id, 1)

        hook(w, fn _stream, _expected, records ->
          if kind?(records, "recipe_pinned") do
            hook(w, nil)

            assert {:ok, :applied} =
                     DurableMailbox.open(w.mailbox, w.tenant, %{
                       chain_id: chain_id,
                       run_id: run,
                       unit_identity: run,
                       pin: their_pin,
                       carry: %{"other" => true}
                     })
          end

          :pass
        end)

        assert Room.open(w.room, w.tenant, %{chain_id: chain_id, start: start(), pin: v1}) ==
                 {:error, {:mailbox, :conflict}}

        assert pins_of(w, run) == kept
      end
    end

    test "an equal open/3 after the first rollover returns link 1's IDs and pins nothing", %{
      role: role
    } do
      w = world(role)
      run = open!(w, "c", start())
      end_by_deadline(w, "c", run)

      assert {:ok, %{seq: 2, carry_kind: :restarted}} =
               Room.rollover(w.room, w.tenant, %{chain_id: "c", change: nil})

      assert pins_of(w, run) == []
      before = records(w)

      assert Room.open(w.room, w.tenant, %{chain_id: "c", start: start(), pin: hd(w.versions)}) ==
               {:ok, %{run_id: run, unit_identity: run}}

      assert records(w) == before and pins_of(w, run) == []
    end
  end

  describe "case 12: shapes" do
    test "every function refuses a bad shape, a tenant outside the recipe-store rule and a reserved wake_id before any call",
         %{role: role} do
      w = world(role)
      me = self()

      need = fn name ->
        fn _, _ ->
          send(me, {:need, name})
          {:error, :not_started}
        end
      end

      {:ok, room} =
        Room.new(
          mailbox: w.mailbox,
          recipes: w.recipes,
          principal: "room",
          turn_policy: w.turn_policy,
          start: need.(:start),
          engine: need.(:engine),
          clock: fn ->
            send(me, {:need, :clock})
            1
          end,
          request_cap: 256,
          reserve: reserve({1, 1}),
          read_limits: %{max_records: 10, max_bytes: 10}
        )

      before = records(w)
      ok = %{chain_id: "c"}
      pin = hd(w.versions)

      calls = [
        &Room.open(room, &1, %{chain_id: "c", start: start(), pin: pin}),
        &Room.deliver(room, &1, ok),
        &Room.wake(room, &1, %{chain_id: "c", wake_id: "w"}),
        &Room.rollover(room, &1, %{chain_id: "c", change: nil}),
        &Room.resume(room, &1, ok)
      ]

      for tenant <- ["", ".", "..", "a/b", "a b", String.duplicate("t", 65), "é", nil],
          call <- calls,
          do: assert(call.(tenant) == {:error, :invalid})

      t = w.tenant

      bad = [
        Room.open(room, t, %{chain_id: "c", start: start()}),
        Room.open(room, t, %{chain_id: "c", start: start(), pin: "pin"}),
        Room.open(room, t, %{chain_id: "", start: start(), pin: pin}),
        Room.open(room, t, %{chain_id: "c\n", start: start(), pin: pin}),
        Room.open(room, t, %{chain_id: "c", start: [], pin: pin}),
        Room.open(room, t, %{chain_id: "c", start: start(), pin: pin, extra: 1}),
        Room.deliver(room, t, %{chain_id: String.duplicate("c", 129)}),
        Room.deliver(room, t, %{}),
        Room.wake(room, t, %{chain_id: "c", wake_id: ""}),
        Room.wake(room, t, %{chain_id: "c", wake_id: String.duplicate("w", 161)}),
        Room.wake(room, t, %{chain_id: "c", wake_id: "w\u0085"}),
        Room.rollover(room, t, %{chain_id: "c", change: %{pin: pin}}),
        Room.rollover(room, t, %{chain_id: "c", change: %{pin: "x", ref: "r"}}),
        Room.rollover(room, t, %{chain_id: "c", change: %{pin: pin, ref: ""}}),
        Room.rollover(room, t, %{chain_id: "c"}),
        Room.resume(room, t, %{chain_id: "c", more: 1}),
        Room.deliver(:room, t, ok)
      ]

      reserved =
        for p <- ["mail:", "start:", "rollover:"],
            do: Room.wake(room, t, %{chain_id: "c", wake_id: p <> "x"})

      for result <- bad ++ reserved, do: assert(result == {:error, :invalid})
      refute_received {:need, _}
      assert records(w) == before
      assert unknown_chain?(w, "c")

      assert Room.new(Keyword.delete(w.room |> Map.from_struct() |> Map.to_list(), :clock)) ==
               {:error, :invalid_binding}

      for opts <- [[:x], [{"a", 1}], [{:clock, 1} | [:x]]],
          do: assert(Room.new(opts) == {:error, :invalid_binding})

      assert Room.new(
               w.room
               |> Map.from_struct()
               |> Map.to_list()
               |> Keyword.put(:request_cap, 257)
             ) == {:error, :invalid_binding}
    end
  end

  defp rollover(w, chain_id, change \\ nil),
    do: Room.rollover(w.room, w.tenant, %{chain_id: chain_id, change: change})

  defp resume(w, chain_id), do: Room.resume(w.room, w.tenant, %{chain_id: chain_id})

  defp claim!(w, chain_id) do
    assert {:ok, %{message: message}} =
             DurableMailbox.claim(w.mailbox, w.tenant, %{chain_id: chain_id})

    message
  end

  defp tip(w, chain_id), do: chain(w, chain_id).tip
  defp die, do: Process.exit(self(), :kill)

  # Ends the process that runs the first mailbox query containing `fragment`, once the query
  # has run inside its transaction, which the crash then rolls back.
  defp crash_at_query(fragment) do
    id = {__MODULE__, make_ref()}
    event = [:elzoo, :durable_mailbox, :app_repo, :query]
    :ok = :telemetry.attach(id, event, &__MODULE__.crash_query/4, {id, fragment})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def crash_query(_event, _measurements, %{query: query}, {id, fragment}) do
    if String.contains?(query, fragment) and :telemetry.detach(id) == :ok,
      do: Process.exit(self(), :kill)
  end

  defp assert_one_successor(w, chain_id, run1, run2, pin, pinned \\ 1) do
    assert {:ok, :live} = resume(w, chain_id)
    assert %{seq: 2, state: :live} = tip(w, chain_id)
    assert Enum.filter(inputs(w, run2), &String.starts_with?(&1, "start:")) == ["start:" <> run2]
    assert pins_of(w, run1) == []
    assert pinned_rows(w, run2) == List.duplicate(run2, pinned)
    assert pins_of(w, run2) == [pin]
  end

  defp pinned_rows(w, run_id) do
    for {"recipe_pinned", %{"run_id" => ^run_id}} <-
          Elzoo.RecipeStore.TestHelper.rows(w.store, "recipe-store/" <> w.tenant),
        do: run_id
  end

  defp publish!(w, version) do
    assert {:ok, _} =
             RecipeStore.check(w.plain, w.caller, version, Elzoo.RecipeStore.TestHelper.facts())

    assert {:ok, _} = RecipeStore.publish(w.plain, w.caller, version)
  end

  describe "case 4: rollover :finished" do
    test "at rollover.max_turns the tip carries; one successor runs the carried turns first and gets the mail once",
         %{role: role} do
      w = world(role)
      run1 = open!(w, "c", start(bots: ["bot-a", "bot-b", "bot-c"], max_bot_turns: 3, max_turns: 2))
      run2 = ids(w, "c", 2)
      settle_engine(w, run1)
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a", "bot-b", "bot-c"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run1)
      assert view(w, run1).phase == :terminal
      assert actions(w, run1) == ~w(t/1/1/turn t/1/1/post t/1/2/turn t/1/2/post c/1/1 f/1)
      assert {:ok, :terminal} = deliver(w, "c")

      # Mail to the old Run ID while the rollover runs (between the atomic step and the start).
      start_hook(w, fn
        :before, ^run2 ->
          start_hook(w, nil)
          assert {:ok, :applied} = put(w, "c", "m-2", address: {:run, run1})

        _, _ ->
          :ok
      end)

      # The fixture hosts one engine at a time: link 1's record is read before its successor starts.
      assert room_inputs(w, run1) == ["start:" <> run1, "mail:m-1"]
      assert {:ok, %{seq: 2, carry_kind: :finished}} = rollover(w, "c")
      assert {:ok, :applied} = put(w, "c", "m-3", address: {:run, run1})
      settle_engine(w, run2)
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run2)
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run2)
      assert {:ok, :empty} = deliver(w, "c")

      for id <- ["m-2", "m-3"],
          do: assert(status(w, "c", id) == %{state: :consumed, link_seq: 2, reason: nil})

      assert room_inputs(w, run2) == ["start:" <> run2, "mail:m-2", "mail:m-3"]

      # The successor ran the carried queued turn of bot-c first.
      assert hd(actions(w, run2)) == "t/2/3/turn"
      assert List.last(posts(w))["member"] == "bot-c"

      %{links: links, tip: tip} = chain(w, "c")

      assert for(
               l <- links,
               do: {l.seq, l.run_id, l.predecessor_seq, l.state, l.outcome, l.carry_kind}
             ) == [
               {1, run1, nil, :closed, "completed", :opened},
               {2, run2, 1, :live, nil, :finished}
             ]

      assert tip.carry["link"] == 2
      assert tip.carry["carry"]["queue"] == [%{"member" => "bot-c", "message_id" => "m-1"}]
      assert pins_of(w, run1) == [] and pins_of(w, run2) == [hd(w.versions)]
    end
  end

  describe "case 5: rollover :restarted" do
    test "a tip ended out_of_time by wake/3 at its Run deadline restarts from its own start", %{
      role: role
    } do
      w = world(role)
      run1 = open!(w, "c", start())
      end_by_deadline(w, "c", run1)
      assert {:ok, %{seq: 2, carry_kind: :restarted}} = rollover(w, "c")
      %{links: [first, _], tip: tip} = chain(w, "c")
      assert {first.outcome, first.state} == {"out_of_time", :closed}
      assert tip.carry == %{start() | "link" => 2}
      assert room_inputs(w, ids(w, "c", 2)) == ["start:" <> ids(w, "c", 2)]
    end

    test "a link that started with queued turns, ran one and ended out_of_time restarts idle", %{
      role: role
    } do
      w = world(role)
      run1 = open!(w, "c", start(bots: ["bot-a", "bot-b", "bot-c"], max_bot_turns: 3, max_turns: 1))
      {run2, run3} = {ids(w, "c", 2), ids(w, "c", 3)}
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a", "bot-b", "bot-c"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run1)
      script(w, "bot-b", %{plan: [{:hold, 1}]})
      assert {:ok, %{carry_kind: :finished}} = rollover(w, "c")
      assert_receive {:held, worker, _}, 10_000
      assert {:ok, :busy} = deliver(w, "c")
      end_by_deadline(w, "c", run2)
      send(worker, :release)
      assert actions(w, run2) == ["t/2/2/turn"]

      assert {:ok, %{seq: 3, carry_kind: :restarted}} = rollover(w, "c")
      settle_engine(w, run3)
      carry = tip(w, "c").carry["carry"]
      assert carry["queue"] == []
      assert hd(carry["notes"]) == %{"code" => "restarted_queue_dropped", "ref" => nil}
      assert inputs(w, run3) == ["start:" <> run3]
      assert actions(w, run3) == []
      assert {:ok, :empty} = deliver(w, "c")
    end

    test "a completed tip whose outcome names another link restarts", %{role: role} do
      w = world(role, carry_link: 1)
      run1 = open!(w, "c", start(max_turns: 1))
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run1)
      assert view(w, run1).outcome == :completed
      assert {:ok, %{seq: 2, carry_kind: :restarted}} = rollover(w, "c")
      %{links: [first, _], tip: tip} = chain(w, "c")
      assert first.outcome == "completed"
      assert tip.carry == %{start(max_turns: 1) | "link" => 2}
    end

    test "a restarted carry that fails the reserve check under a larger turn reserve changes nothing",
         %{role: role} do
      w = world(role)
      run1 = open!(w, "c", start())
      end_by_deadline(w, "c", run1)
      before = {chain(w, "c"), pins(w), records(w)}
      larger = room(w, w.turn_policy, reserve: reserve({200, 1}))

      assert Room.rollover(larger, w.tenant, %{chain_id: "c", change: nil}) ==
               {:error, {:invalid_start, :reserve}}

      assert {chain(w, "c"), pins(w), records(w)} == before
    end
  end

  describe "case 7: settlement at step 2" do
    test "a delivering message is settled from the terminal tip's transcript", %{role: role} do
      w = world(role)

      # Not given: absent from the transcript, so it goes to the successor.
      run1 = open!(w, "absent", start())
      assert {:ok, :applied} = put(w, "absent", "m-1", mentions: ["bot-a"])
      claim!(w, "absent")
      clock(w, view_deadline(w, run1))
      assert {:ok, :applied} = raw_wake(w, run1, "w1")
      assert {:ok, %{seq: 2}} = rollover(w, "absent")
      assert status(w, "absent", "m-1").state == :pending
      settle_engine(w, ids(w, "absent", 2))
      assert {:ok, :delivered} = deliver(w, "absent")
      settle_engine(w, ids(w, "absent", 2))
      assert status(w, "absent", "m-1") == %{state: :consumed, link_seq: 2, reason: nil}

      # Given (the reply was lost) and its turn ran: applied.
      run1 = open!(w, "ran", start())
      assert {:ok, :applied} = put(w, "ran", "m-1", mentions: ["bot-a"])
      assert {:ok, :applied} = raw_mail(w, run1, claim!(w, "ran"))
      settle_engine(w, run1)
      clock(w, view_deadline(w, run1))
      assert {:ok, :applied} = raw_wake(w, run1, "w1")
      assert {:ok, %{seq: 2}} = rollover(w, "ran")
      assert status(w, "ran", "m-1") == %{state: :consumed, link_seq: 1, reason: nil}

      # Given with no turn or decision naming it (mention-only, unaddressed): refused, and a
      # transcript error first leaves it delivering and the tip unchanged.
      run1 = open!(w, "none", start())
      assert {:ok, :applied} = put(w, "none", "m-1")
      assert {:ok, :applied} = raw_mail(w, run1, claim!(w, "none"))
      clock(w, view_deadline(w, run1))
      assert {:ok, :applied} = raw_wake(w, run1, "w1")
      before = chain(w, "none")
      tiny = room(w, w.turn_policy, read_limits: %{max_records: 1, max_bytes: 1})

      assert Room.rollover(tiny, w.tenant, %{chain_id: "none", change: nil}) ==
               {:error, {:transcript, :read_limit}}

      assert status(w, "none", "m-1").state == :delivering
      assert chain(w, "none") == before
      assert {:ok, %{seq: 2}} = rollover(w, "none")
      assert status(w, "none", "m-1") == %{state: :refused, link_seq: 1, reason: :unacknowledged}
      settle_engine(w, ids(w, "none", 2))
      assert {:ok, :empty} = deliver(w, "none")
    end

    test "a result/3 error changes nothing", %{role: role} do
      w = world(role, result_reader: :none)
      run1 = open!(w, "c", start())
      end_by_deadline(w, "c", run1)
      before = {chain(w, "c"), pins(w), records(w)}
      assert rollover(w, "c") == {:error, {:result, :reader_unconfigured}}
      assert {chain(w, "c"), pins(w), records(w)} == before
    end
  end

  describe "case 8: pin results at step 3" do
    test "a deleted change version is {:pin, :deleted}; rollover/3 without a change then succeeds",
         %{role: role} do
      w = world(role)
      [v1, _, v3] = w.versions
      assert {:ok, _} = RecipeStore.delete(w.plain, w.caller, v3)
      run1 = open!(w, "c", start())
      assert {:ok, :applied} = put(w, "c", "m-1")
      end_by_deadline(w, "c", run1)
      pins = pins(w)
      assert rollover(w, "c", %{pin: v3, ref: "change-1"}) == {:error, {:pin, :deleted}}
      assert pins(w) == pins
      assert %{seq: 1, state: :live, planned_pin: ^v3} = tip(w, "c")
      assert status(w, "c", "m-1").state == :pending
      assert {:ok, %{seq: 2}} = rollover(w, "c")
      assert pins_of(w, ids(w, "c", 2)) == [v1]
    end

    test "an indeterminate pin, then the repeat, leaves one pin record", %{role: role} do
      w = world(role)
      run1 = open!(w, "c", start())
      run2 = ids(w, "c", 2)
      end_by_deadline(w, "c", run1)
      {module, _} = w.store

      hook(w, fn stream, expected, records ->
        if kind?(records, "recipe_pinned", run2) do
          hook(w, nil)
          {:committed, _} = module.append(w.store, stream, expected, records, [])
          {:reply, {:indeterminate, %{cause: :timeout}}}
        else
          :pass
        end
      end)

      assert rollover(w, "c") == {:error, {:pin, :indeterminate}}
      assert {:ok, %{seq: 2}} = rollover(w, "c")
      assert pinned_rows(w, run2) == [run2]
    end

    test "a full stream is {:pin, :stream_full}: the tip stays terminal with its mail pending", %{
      role: role
    } do
      w = world(role)
      run1 = open!(w, "c", start())
      assert {:ok, :applied} = put(w, "c", "m-1")
      end_by_deadline(w, "c", run1)
      stream = "recipe-store/" <> w.tenant

      filler =
        for n <- 1..(10_000 - records(w)),
            do: Jason.encode!(%{"v" => 1, "identity" => hd(w.versions), "run_id" => "f-#{n}"})

      for chunk <- Enum.chunk_every(filler, 500),
          do: :ok = Elzoo.RecipeStore.TestHelper.append!(w.store, stream, "recipe_unpinned", chunk)

      assert records(w) == 10_000
      assert rollover(w, "c") == {:error, {:pin, :stream_full}}
      assert %{seq: 1, state: :live} = tip(w, "c")
      assert view(w, run1).phase == :terminal
      assert status(w, "c", "m-1").state == :pending
    end

    test "plan review M2: a stopped rollover with change B, then change C, leaves one pin record",
         %{role: role} do
      w = world(role)
      [_, b, c] = w.versions
      run1 = open!(w, "c", start())
      run2 = ids(w, "c", 2)
      end_by_deadline(w, "c", run1)
      hook(w, crash_on(w, &kind?(&1, "recipe_pinned", run2), :after))
      assert {:crashed, _} = isolated(fn -> rollover(w, "c", %{pin: b, ref: "change-b"}) end)
      assert pins_of(w, run2) == [b]
      assert {:ok, %{seq: 2}} = rollover(w, "c", %{pin: c, ref: "change-c"})
      assert pins_of(w, run2) == [c]
      assert tip(w, "c").change_ref == "change-c"
    end

    test "plan review M3: a plan replaced after the room's pin is :plan_mismatch and leaves no pin of the room",
         %{role: role} do
      w = world(role)
      [_, _, other] = w.versions
      run1 = open!(w, "c", start())
      run2 = ids(w, "c", 2)
      end_by_deadline(w, "c", run1)

      hook(w, fn stream, expected, records ->
        if kind?(records, "recipe_pinned", run2) do
          hook(w, nil)
          {module, _} = w.store
          {:committed, _} = module.append(w.store, stream, expected, records, [])

          {:ok, _} =
            DurableMailbox.plan_rollover(w.mailbox, w.tenant, %{
              chain_id: "c",
              link_seq: 1,
              change: %{pin: other, ref: "elsewhere"}
            })

          {:reply, {:committed, expected + length(records)}}
        else
          :pass
        end
      end)

      assert rollover(w, "c") == {:error, {:mailbox, :plan_mismatch}}
      assert pins_of(w, run2) == []
      assert %{seq: 1, state: :live} = tip(w, "c")
      assert chain(w, "c").links |> length() == 1
    end
  end

  describe "case 9: a crash after each step" do
    test "resume/3 and rollover/3 with the same request give one live successor", %{role: role} do
      w = world(role)

      kill_once = fn match ->
        fn run ->
          if match.(run),
            do:
              (
                engine_hook(w, nil)
                die()
              )
        end
      end

      points = [
        {"step-1", fn run1, _ -> engine_hook(w, kill_once.(&(&1 == run1))) end},
        {"step-3b", fn _, run2 -> hook(w, crash_on(w, &kind?(&1, "recipe_pinned", run2))) end},
        {"step-3",
         fn _, run2 -> hook(w, crash_on(w, &kind?(&1, "recipe_pinned", run2), :after)) end},
        {"step-4",
         fn _, run2 ->
           start_hook(w, fn phase, run ->
             if phase == :before and run == run2,
               do:
                 (
                   start_hook(w, nil)
                   die()
                 )
           end)
         end},
        {"step-5", fn run1, _ -> hook(w, crash_on(w, &kind?(&1, "recipe_unpinned", run1))) end},
        {"step-6",
         fn run1, _ -> hook(w, crash_on(w, &kind?(&1, "recipe_unpinned", run1), :after)) end}
      ]

      for {chain_id, arm} <- points do
        run1 = open!(w, chain_id, start())
        run2 = ids(w, chain_id, 2)
        end_by_deadline(w, chain_id, run1)
        arm.(run1, run2)
        assert {:crashed, _} = isolated(fn -> rollover(w, chain_id) end), chain_id

        case resume(w, chain_id) do
          {:ok, :terminal} -> assert {:ok, %{seq: 2}} = rollover(w, chain_id)
          {:ok, :live} -> :ok
        end

        assert {:ok, :live} = resume(w, chain_id)
        assert %{seq: 2, state: :live} = tip(w, chain_id)

        assert Enum.filter(inputs(w, run2), &String.starts_with?(&1, "start:")) == [
                 "start:" <> run2
               ],
               chain_id

        assert pins_of(w, run1) == [], chain_id
        assert pinned_rows(w, run2) == [run2], chain_id
        assert pins_of(w, run2) == [hd(w.versions)], chain_id
      end
    end

    test "a crash after step 1, after step 2's settle and between 3(a) and 3(b)", %{role: role} do
      w = world(role)
      [v1, b, _] = w.versions

      # After step 1: inside the claim's transaction, so result/3 ran and nothing of step 2 is
      # committed. A pending message stays pending.
      run1 = open!(w, "s1", start())
      run2 = ids(w, "s1", 2)
      end_by_deadline(w, "s1", run1)
      assert {:ok, :applied} = put(w, "s1", "m-1", mentions: ["bot-a"])
      crash_at_query("SELECT run_id, unit_identity, stopped FROM")
      assert {:crashed, _} = isolated(fn -> rollover(w, "s1") end)
      assert status(w, "s1", "m-1").state == :pending
      assert %{seq: 1, state: :live} = tip(w, "s1")
      assert {:ok, :terminal} = resume(w, "s1")
      assert {:ok, %{seq: 2}} = rollover(w, "s1")
      settle_engine(w, run2)
      assert {:ok, :delivered} = deliver(w, "s1")
      assert status(w, "s1", "m-1") == %{state: :consumed, link_seq: 2, reason: nil}
      assert_one_successor(w, "s1", run1, run2, v1)

      # After step 2: inside plan_rollover's transaction. The delivering message was settled
      # refused before the crash and is not claimed again; the repeat claims the pending one
      # and settles it :not_applied, so it goes to the successor.
      run1 = open!(w, "s2", start())
      run2 = ids(w, "s2", 2)
      assert {:ok, :applied} = put(w, "s2", "m-0")
      assert {:ok, :applied} = raw_mail(w, run1, claim!(w, "s2"))
      clock(w, view_deadline(w, run1))
      assert {:ok, :applied} = raw_wake(w, run1, "w1")
      assert {:ok, :applied} = put(w, "s2", "m-1", mentions: ["bot-a"])
      crash_at_query("SELECT pin, planned_pin, state FROM")
      assert {:crashed, _} = isolated(fn -> rollover(w, "s2") end)
      assert status(w, "s2", "m-0") == %{state: :refused, link_seq: 1, reason: :unacknowledged}
      assert status(w, "s2", "m-1").state == :pending
      assert %{seq: 1, state: :live, planned_pin: nil} = tip(w, "s2")
      assert {:ok, :terminal} = resume(w, "s2")
      assert {:ok, %{seq: 2}} = rollover(w, "s2")
      assert status(w, "s2", "m-0") == %{state: :refused, link_seq: 1, reason: :unacknowledged}
      settle_engine(w, run2)
      assert {:ok, :delivered} = deliver(w, "s2")
      assert status(w, "s2", "m-1") == %{state: :consumed, link_seq: 2, reason: nil}
      refute "mail:m-0" in inputs(w, run2)
      assert_one_successor(w, "s2", run1, run2, v1)

      # Between 3(a) and 3(b): the old plan stays; the repeat unpins it again (a no-op) and
      # plans and pins the inherited version.
      run1 = open!(w, "s3", start())
      run2 = ids(w, "s3", 2)
      end_by_deadline(w, "s3", run1)
      hook(w, crash_on(w, &kind?(&1, "recipe_pinned", run2), :after))
      assert {:crashed, _} = isolated(fn -> rollover(w, "s3", %{pin: b, ref: "change-b"}) end)
      assert pins_of(w, run2) == [b]
      hook(w, crash_on(w, &kind?(&1, "recipe_unpinned", run2), :after))
      assert {:crashed, _} = isolated(fn -> rollover(w, "s3") end)
      assert pins_of(w, run2) == []
      assert %{seq: 1, planned_pin: ^b} = tip(w, "s3")
      assert {:ok, :terminal} = resume(w, "s3")
      assert {:ok, %{seq: 2}} = rollover(w, "s3")
      assert tip(w, "s3").change_ref == nil
      # Two pin appends for the successor's Run ID: B's, since unpinned, and the inherited one.
      assert_one_successor(w, "s3", run1, run2, v1, 2)
    end

    test "a crash after the start Need of open/3, before its start input: deliver/3 is :not_started",
         %{role: role} do
      w = world(role)
      run1 = ids(w, "c", 1)

      start_hook(w, fn phase, _ ->
        if phase == :after,
          do:
            (
              start_hook(w, nil)
              die()
            )
      end)

      assert {:crashed, _} =
               isolated(fn ->
                 Room.open(w.room, w.tenant, %{chain_id: "c", start: start(), pin: hd(w.versions)})
               end)

      assert deliver(w, "c") == {:error, :not_started}
      assert {:ok, :live} = resume(w, "c")
      assert inputs(w, run1) == ["start:" <> run1]
      assert pinned_rows(w, run1) == [run1]
      assert {:ok, :empty} = deliver(w, "c")
    end
  end

  describe "case 10: pins" do
    test "a successor keeps its version; a change moves it; the inherited version cannot be deleted",
         %{role: role} do
      w = world(role)
      [v1, v2, _] = w.versions
      publish!(w, v1)
      run1 = open!(w, "c", start())
      run2 = ids(w, "c", 2)
      publish!(w, v2)
      end_by_deadline(w, "c", run1)
      {:ok, deletes} = Agent.start_link(fn -> [] end)

      delete = fn point ->
        Agent.update(deletes, &[{point, RecipeStore.delete(w.plain, w.caller, v1)} | &1])
      end

      hook(w, fn _stream, _expected, records ->
        cond do
          kind?(records, "recipe_pinned", run2) -> delete.(:before_pin)
          kind?(records, "recipe_unpinned", run1) -> delete.(:before_unpin)
          true -> :ok
        end

        :pass
      end)

      start_hook(w, fn phase, run ->
        if phase == :before and run == run2, do: delete.(:start_need)
      end)

      assert {:ok, %{seq: 2}} = rollover(w, "c")
      hook(w, nil)
      start_hook(w, nil)

      assert Enum.sort(Agent.get(deletes, & &1)) == [
               before_pin: {:error, :pinned},
               before_unpin: {:error, :pinned},
               start_need: {:error, :pinned}
             ]

      assert %{pin: ^v1, change_ref: nil} = tip(w, "c")
      end_by_deadline(w, "c", run2)
      assert {:ok, %{seq: 3}} = rollover(w, "c", %{pin: v2, ref: "change-1"})
      assert %{pin: ^v2, change_ref: "change-1"} = tip(w, "c")
      assert pins_of(w, ids(w, "c", 3)) == [v2]
      assert pins_of(w, run2) == []
    end
  end

  defp stand_in(run_id, deadline) do
    {:ok, pid} = Elzoo.Room.StandIn.start(%{run_id: run_id})

    %{
      engine: pid,
      scope: %{tenant: "tenant", principal: "principal", run_id: run_id},
      run_deadline: deadline
    }
  end

  defp mail_inputs(pid),
    do: for({"mail:" <> _ = id, _, _} <- Elzoo.Room.StandIn.inputs(pid), do: id)

  describe "case 11: delivery replies (engine stand-in)" do
    test "record_size, late and the definite refusals settle refused; record_size stops the link",
         %{role: role} do
      w = world(role, engine_override: &stand_in/2)
      run = open!(w, "c", start())
      pid = engine(w, run)
      alias Elzoo.Room.StandIn

      replies = [
        {"m-1", {{:ok, :applied}, %{classification: :late}}, {:refused, :unacknowledged}},
        {"m-2", {{:ok, :duplicate}, %{classification: {:request_outcome, :out_of_time}}},
         {:refused, :unacknowledged}},
        {"m-3", {{:error, :invalid_input}, %{}}, {:refused, :invalid_input}},
        {"m-4", {{:error, :input_too_large}, %{}}, {:refused, :invalid_input}},
        {"m-5", {{:error, :invalid_payload}, %{}}, {:refused, :invalid_input}},
        {"m-6", {{:error, :input_id_conflict}, %{}}, {:refused, :input_id_conflict}},
        {"m-7", {{:ok, :applied}, %{classification: :incompatible}}, :delivered},
        {"m-8", {{:ok, :applied}, %{classification: {:request, 3}}}, :delivered},
        {"m-9", {{:ok, :applied}, %{classification: :record_size}}, {:refused, :record_size}}
      ]

      for {id, step, result} <- replies do
        StandIn.script(pid, "mail:" <> id, [step])
        assert {:ok, :applied} = put(w, "c", id)
        assert deliver(w, "c") == {:ok, result}, id
      end

      for {id, _, result} <- replies do
        expected = if result == :delivered, do: {:consumed, nil}, else: {:refused, elem(result, 1)}
        assert {status(w, "c", id).state, status(w, "c", id).reason} == expected, id
      end

      assert tip(w, "c").stopped
      assert {:ok, :applied} = put(w, "c", "m-10")
      assert {:ok, :rollover} = deliver(w, "c")
      assert {:ok, :rollover} = deliver(w, "c")
      assert DurableMailbox.claim(w.mailbox, w.tenant, %{chain_id: "c"}) == {:ok, :stopped}
      assert status(w, "c", "m-10").state == :pending
      assert List.last(StandIn.inputs(pid)) |> elem(0) == "rollover:" <> run
      assert mail_inputs(pid) == for({id, _, _} <- replies, do: "mail:" <> id)
    end

    test "an indeterminate reply, an exit and a halt leave the message delivering; the next call gives the same ID",
         %{role: role} do
      w = world(role, engine_override: &stand_in/2)
      alias Elzoo.Room.StandIn

      cases = [
        {"indeterminate", [{{:indeterminate, :delivery}, %{}}], {:engine, :indeterminate}, false},
        {"exit", [:die], {:engine, :no_reply}, true},
        {"halt", [{{:indeterminate, :delivery}, %{reconciliation: :delivery_unknown}}],
         {:engine, :indeterminate}, true}
      ]

      for {chain_id, steps, error, restart} <- cases do
        run = open!(w, chain_id, start())
        pid = engine(w, run)
        StandIn.script(pid, "mail:m-1", steps)
        assert {:ok, :applied} = put(w, chain_id, "m-1")
        assert deliver(w, chain_id) == {:error, error}, chain_id
        assert status(w, chain_id, "m-1").state == :delivering

        pid =
          if restart do
            if chain_id == "halt" do
              assert deliver(w, chain_id) == {:error, {:engine, :delivery_unknown}}
              # rollover/3 calls nothing else on a halted engine: no result/3 read.
              assert rollover(w, chain_id) == {:error, {:engine, :delivery_unknown}}
            end

            if chain_id == "exit", do: assert(deliver(w, chain_id) == {:error, :not_started})
            # The host reconciles and starts the engine again under the same Run ID.
            replace_engine(w, run, %{run_id: run, classification: :permit_new_work})
          else
            pid
          end

        assert {:ok, :delivered} = deliver(w, chain_id)
        assert List.last(mail_inputs(pid)) == "mail:m-1"
        assert status(w, chain_id, "m-1").state == :consumed
      end
    end

    test "a lost reply of a record_size message, then wake/3: settled record_size before the wake",
         %{role: role} do
      w = world(role, engine_override: &stand_in/2)
      alias Elzoo.Room.StandIn
      run = open!(w, "c", start())
      pid = engine(w, run)

      StandIn.script(pid, "mail:m-1", [
        {{:error, :timeout}, %{classification: :record_size}},
        {{:ok, :duplicate}, %{}}
      ])

      assert {:ok, :applied} = put(w, "c", "m-1")
      assert deliver(w, "c") == {:error, {:engine, :timeout}}

      assert Room.wake(w.room, w.tenant, %{chain_id: "c", wake_id: "w"}) ==
               {:ok, {:refused, :record_size}}

      assert status(w, "c", "m-1") == %{state: :refused, link_seq: 1, reason: :record_size}

      assert for({id, _, _} <- StandIn.inputs(pid), do: id) == [
               "start:" <> run,
               "mail:m-1",
               "mail:m-1",
               "w"
             ]
    end
  end

  describe "case 11: delivery replies (real engine)" do
    test "a mail name missing from the engine's schemas is refused invalid_input; the next message is delivered",
         %{role: role} do
      w = world(role, messages: %{"x.extra" => %{schema_version: 1, schema: %{"type" => "object"}}})
      run = open!(w, "c", start())
      assert {:ok, :applied} = put(w, "c", "m-1", name: "x.extra", payload: %{})
      assert {:ok, :applied} = put(w, "c", "m-2", mentions: ["bot-a"])
      assert deliver(w, "c") == {:ok, {:refused, :invalid_input}}
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run)
      assert status(w, "c", "m-1") == %{state: :refused, link_seq: 1, reason: :invalid_input}
      assert room_inputs(w, run) == ["start:" <> run, "mail:m-2"]
    end

    test "a lost reply of a message whose turn ran and posted: deliver/3 settles it applied", %{
      role: role
    } do
      w = world(role)
      run = open!(w, "c", start())
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert {:ok, :applied} = raw_mail(w, run, claim!(w, "c"))
      settle_engine(w, run)
      assert [%{"turn_id" => "t/1/1"}] = posts(w)
      assert {:ok, :delivered} = deliver(w, "c")
      assert status(w, "c", "m-1") == %{state: :consumed, link_seq: 1, reason: nil}
      assert Enum.count(inputs(w, run), &(&1 == "mail:m-1")) == 1
    end

    test "a lost reply whose turns took the tip past the threshold: rollover/3 settles it applied",
         %{role: role} do
      w = world(role, request_cap: 20)
      run = open!(w, "c", start())
      script(w, "bot-a", %{plan: [1, 1, 1, 1, 1, 1, 1, 1]})
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert {:ok, :applied} = raw_mail(w, run, claim!(w, "c"))
      settle_engine(w, run)
      assert view(w, run).request_count == 11
      assert {:ok, :rollover} = deliver(w, "c")
      assert status(w, "c", "m-1").state == :delivering
      settle_engine(w, run)
      assert view(w, run).outcome == :completed
      assert {:ok, %{seq: 2, carry_kind: :finished}} = rollover(w, "c")
      assert status(w, "c", "m-1") == %{state: :consumed, link_seq: 1, reason: nil}
    end

    test "the engine's clock at run_deadline and the room's before the margin: committed, refused unacknowledged",
         %{role: role} do
      w = world(role)
      run = open!(w, "c", start())
      room_clock(w, 2_000)
      clock(w, view_deadline(w, run))
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert deliver(w, "c") == {:ok, {:refused, :unacknowledged}}
      assert "mail:m-1" in inputs(w, run)
      assert %{phase: :terminal, outcome: :out_of_time} = view(w, run)
      assert {:ok, %{seq: 2, carry_kind: :restarted}} = rollover(w, "c")
      assert status(w, "c", "m-1") == %{state: :refused, link_seq: 1, reason: :unacknowledged}
      assert posts(w) == []
    end

    test "mail named elzoo.room.rollover, a turn-ID message_id and a payload naming another message are refused",
         %{role: role} do
      w =
        world(role,
          messages: %{"elzoo.room.rollover" => %{schema_version: 1, schema: %{"type" => "object"}}}
        )

      run = open!(w, "c", start())
      assert {:ok, :applied} = put(w, "c", "m-r", name: "elzoo.room.rollover", payload: %{})
      assert {:ok, :applied} = put(w, "c", "t/1/1")
      assert {:ok, :applied} = put(w, "c", "m-1")

      assert {:ok, :applied} =
               put(w, "c", "m-2",
                 payload: %{
                   "message_id" => "m-1",
                   "from" => "alice",
                   "text" => "x",
                   "mentions" => ["bot-a"]
                 }
               )

      assert deliver(w, "c") == {:ok, {:refused, :invalid_input}}
      assert deliver(w, "c") == {:ok, {:refused, :invalid_input}}
      assert {:ok, :delivered} = deliver(w, "c")
      assert deliver(w, "c") == {:ok, {:refused, :invalid_input}}

      for id <- ["m-r", "t/1/1", "m-2"],
          do: assert(status(w, "c", id) == %{state: :refused, link_seq: 1, reason: :invalid_input})

      assert room_inputs(w, run) == ["start:" <> run, "mail:m-1"]
      assert view(w, run).phase == :active
      assert posts(w) == []
    end
  end

  describe "case 3: the threshold (requests and time)" do
    # B = 2, d = 0, turn.requests = 2: R = 2 × (2 + 2) + 1 = 9, so a message is given while
    # request_count + 9 + 2 <= 20. A turn of plan [1] asks 4 requests, of plan [1, 1] 5.
    test "request_count at its edge delivers; one more request gives the rollover message", %{
      role: role
    } do
      for {chain_id, plans, expected} <- [
            {"edge", [[1], [1, 1]], :delivered},
            {"over", [[1, 1], [1, 1]], :rollover}
          ] do
        w = world(role, request_cap: 20)
        run = open!(w, chain_id, start())

        for {plan, n} <- Enum.with_index(plans) do
          script(w, "bot-a", %{plan: plan})
          assert {:ok, :applied} = put(w, chain_id, "pre-#{n}", mentions: ["bot-a"])
          assert {:ok, :delivered} = deliver(w, chain_id)
          settle_engine(w, run)
        end

        script(w, "bot-a", %{plan: [1]})
        assert view(w, run).request_count == Enum.sum(for p <- plans, do: 3 + length(p))
        assert {:ok, :applied} = put(w, chain_id, "m", mentions: ["bot-a", "bot-b"])
        assert {:ok, ^expected} = deliver(w, chain_id)
        settle_engine(w, run)

        if expected == :delivered do
          assert %{phase: :active, request_count: 17} = view(w, run)
          assert Enum.take(posts(w), -2) |> Enum.map(& &1["member"]) == ["bot-a", "bot-b"]
        else
          assert status(w, chain_id, "m").state == :pending
          assert %{phase: :terminal, outcome: :completed, request_count: 12} = view(w, run)
        end

        Process.unregister(:room_observer)
      end
    end

    test "clock + deadline_margin_ms one ms before run_deadline delivers, at it gives the rollover message",
         %{role: role} do
      w = world(role)
      run = open!(w, "c", start())
      deadline = view_deadline(w, run)
      assert {:ok, :applied} = put(w, "c", "m-1")
      assert {:ok, :applied} = put(w, "c", "m-2")
      room_clock(w, deadline - 1_000 - 1)
      assert {:ok, :delivered} = deliver(w, "c")
      room_clock(w, deadline - 1_000)
      assert {:ok, :rollover} = deliver(w, "c")
      settle_engine(w, run)
      assert status(w, "c", "m-2").state == :pending
      assert view(w, run).outcome == :completed
    end
  end

  # The inputs the room gave: its start, mail and rollover inputs (not the action outcomes).
  defp room_inputs(w, run),
    do: Enum.filter(inputs(w, run), &String.starts_with?(&1, ["start:", "mail:", "rollover:"]))
end
