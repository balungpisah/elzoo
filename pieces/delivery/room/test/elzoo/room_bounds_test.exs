# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/room_test_helper.exs", __DIR__)

defmodule Elzoo.RoomBoundsTest do
  @moduledoc """
  The threshold at the engine's 256 lifetime actions, on the real engine. Each turn of the
  scripted bots asks one `nested_callable`, the local work of its plan, its finish and one
  post: a plan of n actions adds n + 3 slots. The declared turn reserve is 20 actions and 2
  requests (a plan [19] and its finish), so with B = 2 and d = 0, A = 2 × (2 + 20) + 1 = 45,
  and a message is given while slots + 45 + 2 <= 256, that is slots <= 209.
  """
  use ExUnit.Case, async: false
  import Elzoo.Room.TestHelper
  alias Elzoo.Room

  @moduletag timeout: 600_000

  @reserve %{
    turn: %{actions: 20, requests: 2},
    decision: %{actions: 3, requests: 2},
    deadline_margin_ms: 1_000
  }

  setup_all do
    {:ok, role: services!()}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # A turn plan of n local work actions in batches of at most 63 (the open turn slot is the
  # 64th active action).
  defp plan(n), do: List.duplicate(63, div(n, 63)) ++ if(rem(n, 63) > 0, do: [rem(n, 63)], else: [])

  defp open!(w, chain_id, start) do
    assert {:ok, %{run_id: run}} =
             Room.open(w.room, w.tenant, %{chain_id: chain_id, start: start, pin: hd(w.versions)})

    run
  end

  defp deliver(w, chain_id), do: Room.deliver(w.room, w.tenant, %{chain_id: chain_id})

  # One addressed message whose bot-a turn takes the tip to exactly `slots`.
  defp fill(w, chain_id, run, slots) do
    before = map_size(view(w, run).slots)
    script(w, "bot-a", %{plan: plan(slots - before - 3)})
    assert {:ok, :applied} = put(w, chain_id, "filler-#{slots}", mentions: ["bot-a"])
    assert {:ok, :delivered} = deliver(w, chain_id)
    settle_engine(w, run)
    assert map_size(view(w, run).slots) == slots
    script(w, "bot-a", %{plan: [19]})
    script(w, "bot-b", %{plan: [19]})
  end

  defp posted(w, message_turns),
    do: for(p <- posts(w), p["turn_id"] in message_turns, do: p["member"])

  describe "case 3: the slot edge" do
    test "a message that mentions B bots is delivered at slots + A + 2 = 256 and all its turns fit",
         %{role: role} do
      w = world(role, reserve: @reserve)
      run = open!(w, "c", start())
      fill(w, "c", run, 209)
      assert {:ok, :applied} = put(w, "c", "m", mentions: ["bot-a", "bot-b"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run)
      assert %{phase: :active} = view = view(w, run)
      assert map_size(view.slots) == 253
      assert Enum.all?(view.slots, fn {_, slot} -> slot.outcome == "completed" end)
      assert posted(w, ["t/1/2", "t/1/3"]) == ["bot-a", "bot-b"]
    end

    test "with one more slot used the tip gets the rollover message first", %{role: role} do
      w = world(role, reserve: @reserve)
      run = open!(w, "c", start())
      fill(w, "c", run, 210)
      assert {:ok, :applied} = put(w, "c", "m", mentions: ["bot-a", "bot-b"])
      assert {:ok, :rollover} = deliver(w, "c")
      settle_engine(w, run)
      assert %{phase: :terminal, outcome: :completed} = view = view(w, run)
      assert map_size(view.slots) == 212
      assert status(w, "c", "m").state == :pending

      assert {:ok, %{seq: 2, carry_kind: :finished}} =
               Room.rollover(w.room, w.tenant, %{chain_id: "c", link_seq: 1, change: nil})
    end
  end

  # Under "decided" with decision.actions = 3: A = 45 + 1 + 3 = 49, so slots <= 205. Without
  # the decision part the room would admit up to 209, and a worst-case message (decision 4,
  # turns 44) from 209 reaches 257.
  describe "case 3: the decision reserve" do
    test "an unaddressed message just inside the reserve fits its decision and every picked turn",
         %{role: role} do
      w = world(role, reserve: @reserve)
      run = open!(w, "c", start(rule: "decided"))
      fill(w, "c", run, 205)
      script(w, :decide, %{plan: [2], pick: "several"})
      assert {:ok, :applied} = put(w, "c", "m")
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run)
      assert %{phase: :active} = view = view(w, run)
      assert map_size(view.slots) == 253
      assert Enum.all?(view.slots, fn {_, slot} -> slot.outcome == "completed" end)
      assert posted(w, ["t/1/2", "t/1/3"]) == ["bot-a", "bot-b"]
    end

    test "where a reserve without the decision part would admit the message, the tip gets the rollover message",
         %{role: role} do
      w = world(role, reserve: @reserve)
      run = open!(w, "c", start(rule: "decided"))
      fill(w, "c", run, 209)
      script(w, :decide, %{plan: [2], pick: "several"})
      assert {:ok, :applied} = put(w, "c", "m")
      assert {:ok, :rollover} = deliver(w, "c")
      settle_engine(w, run)
      assert %{phase: :terminal, outcome: :completed} = view(w, run)
      assert status(w, "c", "m").state == :pending
    end
  end

  describe "case 4: the slot edge on the successor" do
    test "a successor on a fresh Unit takes a message at the edge and all its turns fit", %{
      role: role
    } do
      w = world(role, reserve: @reserve)
      run1 = open!(w, "c", start())
      run2 = ids(w, "c", 2)
      script(w, "bot-a", %{plan: [10]})
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run1)
      room_clock(w, Agent.get(w.engines, & &1[run1].run_deadline) - 1_000)
      assert {:ok, :rollover} = deliver(w, "c")
      settle_engine(w, run1)
      assert map_size(view(w, run1).slots) == 15
      room_clock(w, nil)

      assert {:ok, %{seq: 2, carry_kind: :finished}} =
               Room.rollover(w.room, w.tenant, %{chain_id: "c", link_seq: 1, change: nil})

      settle_engine(w, run2)
      fill(w, "c", run2, 209)
      assert {:ok, :applied} = put(w, "c", "m", mentions: ["bot-a", "bot-b"])
      assert {:ok, :delivered} = deliver(w, "c")
      settle_engine(w, run2)
      assert %{phase: :active} = view = view(w, run2)
      assert map_size(view.slots) == 253
      assert Enum.all?(view.slots, fn {_, slot} -> slot.outcome == "completed" end)
      assert posted(w, ["t/2/3", "t/2/4"]) == ["bot-a", "bot-b"]
    end
  end

  describe "case 6: a turn past 256 lifetime actions" do
    test "the engine refuses its request; wakes at the slot and Run deadlines end the tip; it restarts",
         %{role: role} do
      w = world(role, reserve: %{@reserve | turn: %{actions: 2, requests: 2}})
      run = open!(w, "c", start())
      script(w, "bot-a", %{plan: [63, 63, 63, 63, 63]})
      assert {:ok, :applied} = put(w, "c", "m-1", mentions: ["bot-a"])
      assert {:ok, :delivered} = deliver(w, "c")

      # 1 + 252 actions are admitted; the fifth batch would pass the 256th: invalid_request.
      view =
        Elzoo.RunEngine.TestHelper.wait_for(
          engine(w, run),
          &(map_size(&1.slots) == 253 and &1.classification == :invalid_request),
          20_000
        )

      assert view.slots[{1, 0}].phase == :running
      wake = fn id -> Room.wake(w.room, w.tenant, %{chain_id: "c", wake_id: id}) end
      clock(w, 2_000 + 40_000)
      assert {:ok, _} = wake.("slot-deadline")
      assert %{phase: :active, slots: %{{1, 0} => %{outcome: "expired"}}} = view(w, run)
      clock(w, Agent.get(w.engines, & &1[run].run_deadline))
      assert {:ok, _} = wake.("run-deadline")
      assert %{phase: :terminal, outcome: :out_of_time} = view(w, run)

      assert {:ok, %{seq: 2, carry_kind: :restarted}} =
               Room.rollover(w.room, w.tenant, %{chain_id: "c", link_seq: 1, change: nil})

      assert posts(w) == []
    end
  end
end
