# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AggregationTest do
  use ExUnit.Case, async: true

  alias Elzoo.Aggregation

  defp clock(start \\ 1_000) do
    {:ok, agent} = Agent.start_link(fn -> start end)
    now = fn -> Agent.get(agent, & &1) end
    set = fn ms -> Agent.update(agent, fn _ -> ms end) end
    {now, set}
  end

  defp config(overrides \\ []) do
    [branch_key: {:field, ["correlation_id"]}, max_result_bytes: 65_536, max_branches: 8]
    |> Keyword.merge(overrides)
  end

  defp new_join(ids, overrides \\ []) do
    {now, set} = clock()

    case Aggregation.new(ids, config(overrides) |> Keyword.put(:now, now)) do
      {:ok, join} -> {:ok, join, set}
      error -> error
    end
  end

  defp completed(id, value \\ %{"ok" => true}) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => value,
      "value_schema_id" => "test/result",
      "value_schema_version" => 1
    }
  end

  defp rejected(id) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "rejected",
      "dispatch" => "not_dispatched",
      "error_class" => "permanent"
    }
  end

  defp failed_result(id, error_class \\ "unclassified") do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "failed",
      "dispatch" => "dispatched",
      "error_class" => error_class
    }
  end

  defp timed_out_result(id) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "timed_out",
      "dispatch" => "unknown",
      "error_class" => "unclassified"
    }
  end

  defp unknown_result(id) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "unknown",
      "dispatch" => "unknown",
      "error_class" => "unavailable"
    }
  end

  defp statuses(join) do
    {:ok, map} = Aggregation.status(join)
    Map.new(map, fn {id, record} -> {id, record.status} end)
  end

  describe "new/2" do
    test "builds a bounded join over declared identities" do
      assert {:ok, join, _set} = new_join(["a", "b"])
      assert Aggregation.valid_state?(join)
      assert join.declared == ["a", "b"]
      assert map_size(join.branches) == 2
    end

    test "refuses duplicate, empty, oversized or non-list declarations" do
      assert {:error, :invalid_declaration} =
               Aggregation.new(["a", "a"], config() |> Keyword.put(:now, fn -> 0 end))

      assert {:error, :invalid_declaration} =
               Aggregation.new([], config() |> Keyword.put(:now, fn -> 0 end))

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a", "b", "c"],
                 config(max_branches: 2) |> Keyword.put(:now, fn -> 0 end)
               )

      assert {:error, :invalid_declaration} = Aggregation.new("ab", config())
      assert {:error, :invalid_declaration} = Aggregation.new(["a"], nil)
    end

    test "refuses missing or malformed configuration" do
      base = [max_result_bytes: 100, max_branches: 4, now: fn -> 0 end]

      assert {:error, :invalid_declaration} = Aggregation.new(["a"], base)

      for bad_key <- [
            nil,
            :correlation_id,
            {:field, []},
            {:field, ["bogus"]},
            {:field, ["correlation_id", "extra"]},
            {:field, ["value"]},
            {:field, ["value", 1]},
            {:path, ["correlation_id"]}
          ] do
        assert {:error, :invalid_declaration} =
                 Aggregation.new(["a"], Keyword.put(base, :branch_key, bad_key)),
               "expected refusal for #{inspect(bad_key)}"
      end

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a"],
                 Keyword.put(base, :branch_key, {:field, ["value", "k"]})
                 |> Keyword.delete(:max_result_bytes)
               )

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a"],
                 Keyword.put(base, :branch_key, {:field, ["value", "k"]})
                 |> Keyword.put(:deadline_unix_ms, -1)
               )

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a"],
                 Keyword.put(base, :branch_key, {:field, ["value", "k"]})
                 |> Keyword.put(:deadline_unix_ms, "soon")
               )

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a"],
                 Keyword.put(base, :branch_key, {:field, ["value", "k"]})
                 |> Keyword.put(:now, :os.system_time())
               )

      assert {:error, :invalid_declaration} =
               Aggregation.new(
                 ["a"],
                 Keyword.put(base, :branch_key, {:field, ["value", "k"]})
                 |> Keyword.put(:max_result_bytes, 0)
               )
    end

    test "declaration identity bytes are bounded, including the encoded boundary" do
      oversized = String.duplicate("i", 1_000_000)

      assert {:error, :invalid_declaration} =
               Aggregation.new([oversized], config(max_branches: 1, max_result_bytes: 64))

      # ETF encodes this binary with six overhead bytes; the full encoded
      # identity, not just its raw byte count, must fit the per-branch cap.
      at_boundary = String.duplicate("i", 58)
      assert byte_size(:erlang.term_to_binary(at_boundary)) == 64

      assert {:ok, join} =
               Aggregation.new([at_boundary], config(max_branches: 1, max_result_bytes: 64))

      assert Aggregation.valid_state?(join)

      assert {:error, :invalid_declaration} =
               Aggregation.new([at_boundary <> "i"], config(max_result_bytes: 64))

      # Value-carried structured identities have the same encoded bound.
      structured = %{"id" => String.duplicate("s", 64)}
      bytes = byte_size(:erlang.term_to_binary(structured))
      opts = config(branch_key: {:field, ["value", "branch"]}, max_result_bytes: bytes)
      assert {:ok, _} = Aggregation.new([structured], opts)

      assert {:error, :invalid_declaration} =
               Aggregation.new([structured], Keyword.put(opts, :max_result_bytes, bytes - 1))

      refute Aggregation.valid_state?(%{join | max_result_bytes: 63})
      refute Aggregation.valid_state?(%{join | max_branches: 0})
    end

    test "accepts value-field and attempt-id branch keys" do
      {:ok, join} =
        Aggregation.new(["x"],
          branch_key: {:field, ["value", "meta", "branch"]},
          max_result_bytes: 100,
          max_branches: 2,
          now: fn -> 0 end
        )

      assert Aggregation.valid_state?(join)

      {:ok, join2} =
        Aggregation.new(["x"],
          branch_key: {:field, ["attempt_id"]},
          max_result_bytes: 100,
          max_branches: 2,
          now: fn -> 0 end
        )

      assert Aggregation.valid_state?(join2)
    end
  end

  describe "accept/2 and decision/2" do
    test "pending while declared branches remain unresolved" do
      {:ok, join, _} = new_join(["a", "b"])
      {:ok, join} = Aggregation.accept(join, completed("a"))

      assert statuses(join) == %{"a" => :fulfilled, "b" => :pending}
      {^join, %{decision: :pending}} = Aggregation.decision(join, 1_000)
    end

    test "all fulfilled decides :all and closes" do
      {:ok, join, _} = new_join(["a", "b"])
      {:ok, join} = Aggregation.accept(join, completed("a", %{"v" => 1}))
      {:ok, join} = Aggregation.accept(join, completed("b", %{"v" => 2}))

      {closed, %{decision: :all, branches: branches}} = Aggregation.decision(join, 1_000)
      assert closed.closed
      assert closed.outcome == :all
      assert branches["a"].status == :fulfilled
      assert branches["a"].outcome == "completed"
      assert branches["a"].dispatch == "dispatched"
      refute Map.has_key?(branches["a"], :value)
    end

    test "maps every envelope outcome to its branch status" do
      {:ok, join, _} = new_join(["a", "b", "c", "d", "e"])

      {:ok, join} = Aggregation.accept(join, completed("a"))
      {:ok, join} = Aggregation.accept(join, rejected("b"))
      {:ok, join} = Aggregation.accept(join, failed_result("c"))
      {:ok, join} = Aggregation.accept(join, timed_out_result("d"))
      {:ok, join} = Aggregation.accept(join, unknown_result("e"))

      assert statuses(join) == %{
               "a" => :fulfilled,
               "b" => :failed,
               "c" => :failed,
               "d" => :timed_out,
               "e" => :unavailable
             }

      {_closed, %{decision: :partial}} = Aggregation.decision(join, 1_000)
    end

    test "preserves dispatch and error class in the public record" do
      {:ok, join, _} = new_join(["a"])
      {:ok, join} = Aggregation.accept(join, failed_result("a", "retryable"))

      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :failed
      assert record.outcome == "failed"
      assert record.dispatch == "dispatched"
      assert record.error_class == "retryable"
      assert record.loss == nil
    end

    test ":partial needs a fulfillment alongside a terminal failure" do
      {:ok, join, _} = new_join(["a", "b", "c"])
      {:ok, join} = Aggregation.accept(join, completed("a"))
      {:ok, join} = Aggregation.accept(join, failed_result("b"))
      {:ok, join} = Aggregation.mark_lost(join, "c", :killed)

      {_closed, %{decision: :partial}} = Aggregation.decision(join, 1_000)
    end

    test ":failed when nothing fulfilled and at least one branch is terminal" do
      {:ok, join, _} = new_join(["a", "b"])
      {:ok, join} = Aggregation.accept(join, rejected("a"))
      {:ok, join} = Aggregation.mark_lost(join, "b", :unavailable)

      {_closed, %{decision: :failed}} = Aggregation.decision(join, 1_000)
    end

    test "mixed terminal-with-pending stays pending before the deadline" do
      {:ok, join, _} = new_join(["a", "b"], deadline_unix_ms: 5_000)
      {:ok, join} = Aggregation.accept(join, failed_result("a"))

      {^join, %{decision: :pending}} = Aggregation.decision(join, 1_000)
    end

    test "decision is independent of arrival order" do
      inputs = [
        completed("a", %{"n" => 1}),
        completed("b", %{"n" => 2}),
        failed_result("c"),
        timed_out_result("d")
      ]

      orders = [
        inputs,
        Enum.reverse(inputs),
        Enum.sort_by(inputs, &:erlang.phash2/1)
      ]

      results =
        Enum.map(orders, fn order ->
          {:ok, join, _} = new_join(["a", "b", "c", "d"])

          join =
            Enum.reduce(order, join, fn input, j ->
              {:ok, j} = Aggregation.accept(j, input)
              j
            end)

          {join, Aggregation.decision(join, 1_000)}
        end)

      assert Enum.uniq(
               Enum.map(results, fn {join, {_, outcome}} ->
                 {statuses(join), outcome.decision}
               end)
             )
             |> length() == 1
    end
  end

  describe "identity carriers" do
    test "correlation_id carries identity by default" do
      {:ok, join, _} = new_join(["a"])
      other = completed("a") |> Map.put("correlation_id", "a")
      {:ok, join} = Aggregation.accept(join, other)
      assert statuses(join)["a"] == :fulfilled
    end

    test "attempt_id carries identity when configured" do
      {:ok, join, _} =
        new_join(["att-1"], branch_key: {:field, ["attempt_id"]})

      result =
        completed("corr-shared")
        |> Map.put("attempt_id", "att-1")

      {:ok, join} = Aggregation.accept(join, result)
      assert statuses(join) == %{"att-1" => :fulfilled}
    end

    test "a declared value field carries identity, never position" do
      {:ok, join, _} =
        new_join(["north", "south"], branch_key: {:field, ["value", "route", "id"]})

      north =
        completed("m1", %{"route" => %{"id" => "north"}, "payload" => "x"})

      south =
        completed("m2", %{"route" => %{"id" => "south"}, "payload" => "y"})

      # Arrival order is irrelevant: south first still lands on south.
      {:ok, join} = Aggregation.accept(join, south)
      {:ok, join} = Aggregation.accept(join, north)

      assert statuses(join) == %{"north" => :fulfilled, "south" => :fulfilled}
      {_closed, %{decision: :all}} = Aggregation.decision(join, 1_000)
    end

    test "undeclared identity is refused, not stored" do
      {:ok, join, _} = new_join(["a"])
      assert {:error, :unknown_branch} = Aggregation.accept(join, completed("zzz"))
      assert statuses(join) == %{"a" => :pending}
    end

    test "missing configured carrier is :invalid_branch_key" do
      {:ok, join, _} = new_join(["att-1"], branch_key: {:field, ["attempt_id"]})

      assert {:error, :invalid_branch_key} =
               Aggregation.accept(join, completed("corr-only"))

      {:ok, join2, _} =
        new_join(["n"], branch_key: {:field, ["value", "route", "id"]})

      assert {:error, :invalid_branch_key} =
               Aggregation.accept(join2, completed("m", %{"other" => 1}))

      assert {:error, :invalid_branch_key} =
               Aggregation.accept(join2, failed_result("m"))
    end
  end

  describe "input refusal without mutation" do
    test "malformed results are :invalid_result and change nothing" do
      {:ok, join, _} = new_join(["a"])
      before = join

      for bad <- [
            nil,
            "not-a-map",
            %{},
            completed("a") |> Map.delete("outcome"),
            completed("a") |> Map.put("outcome", "bogus"),
            completed("a") |> Map.put("version", 2),
            completed("a") |> Map.put("extra_key", "nope"),
            completed("a") |> Map.put("dispatch", "not_dispatched"),
            rejected("a") |> Map.put("value", %{" sneaky" => true}),
            failed_result("a") |> Map.delete("error_class")
          ] do
        assert {:error, :invalid_result} = Aggregation.accept(join, bad)
      end

      assert join == before
    end

    test "oversized encoded result is :too_large and branch stays pending" do
      {:ok, join, _} = new_join(["a"], max_result_bytes: 200)
      big = completed("a", %{"blob" => String.duplicate("x", 500)})

      assert {:error, :too_large} = Aggregation.accept(join, big)
      assert statuses(join) == %{"a" => :pending}

      # Loss records carry no payload and are never size-bound.
      {:ok, join} = Aggregation.mark_lost(join, "a", :unavailable)
      assert statuses(join) == %{"a" => :unavailable}
    end

    test "non-integer clock readings are refused" do
      {:ok, join} =
        Aggregation.new(["a"],
          branch_key: {:field, ["correlation_id"]},
          max_result_bytes: 100,
          max_branches: 2,
          now: fn -> :not_a_number end
        )

      assert {:error, :invalid_clock} = Aggregation.accept(join, completed("a"))
      assert {:error, :invalid_clock} = Aggregation.mark_lost(join, "a", :killed)
      assert {:error, :invalid_now} = Aggregation.decision(join, :soon)
      assert {:error, :invalid_now} = Aggregation.decision(join, 1.5)
    end
  end

  describe "duplicates, conflicts and losses" do
    test "identical duplicate is recorded, first result stands" do
      {:ok, join, _} = new_join(["a"])
      result = completed("a", %{"v" => 1})

      {:ok, join} = Aggregation.accept(join, result)
      {:ok, join} = Aggregation.accept(join, result)

      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :fulfilled
      assert record.duplicate_count == 1
      assert record.conflicted == false
    end

    test "differing duplicate value marks the branch conflicted" do
      {:ok, join, _} = new_join(["a"])

      {:ok, join} = Aggregation.accept(join, completed("a", %{"v" => 1}))
      {:ok, join} = Aggregation.accept(join, completed("a", %{"v" => 2}))

      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :conflicted
      assert record.conflicted == true
      assert record.duplicate_count == 1
      # The first accepted result still stands as the retained evidence.
      assert record.outcome == "completed"
    end

    test "differing outcome marks conflicted; consistent loss duplicates do not" do
      {:ok, join, _} = new_join(["a", "b"])

      {:ok, join} = Aggregation.accept(join, completed("a"))
      {:ok, join} = Aggregation.accept(join, failed_result("a"))
      assert statuses(join)["a"] == :conflicted

      {:ok, join} = Aggregation.mark_lost(join, "b", :timed_out)
      {:ok, join} = Aggregation.mark_lost(join, "b", :timed_out)
      {:ok, %{"b" => b}} = Aggregation.status(join)
      assert b.status == :timed_out
      assert b.duplicate_count == 1
      assert b.conflicted == false

      {:ok, join} = Aggregation.mark_lost(join, "b", :killed)
      {:ok, %{"b" => b}} = Aggregation.status(join)
      assert b.status == :conflicted
    end

    test "result contradicting a recorded loss marks conflicted" do
      {:ok, join, _} = new_join(["a"])
      {:ok, join} = Aggregation.mark_lost(join, "a", :timed_out)

      # A timed_out envelope result agrees with the timed_out loss: consistent.
      {:ok, join} = Aggregation.accept(join, timed_out_result("a"))
      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :timed_out
      assert record.duplicate_count == 1
      assert record.conflicted == false

      # A completed result contradicts it.
      {:ok, join} = Aggregation.accept(join, completed("a"))
      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :conflicted
    end

    test "mark_lost validates kind and branch" do
      {:ok, join, _} = new_join(["a"])

      assert {:error, :invalid_loss_kind} = Aggregation.mark_lost(join, "a", :expired)
      assert {:error, :invalid_loss_kind} = Aggregation.mark_lost(join, "a", "timed_out")
      assert {:error, :unknown_branch} = Aggregation.mark_lost(join, "zzz", :killed)
      assert statuses(join) == %{"a" => :pending}
    end

    test "loss records expose kind without payload or fabricated dispatch" do
      {:ok, join, _} = new_join(["a"])
      {:ok, join} = Aggregation.mark_lost(join, "a", :killed)

      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :killed
      assert record.loss == :killed
      assert record.outcome == nil
      assert record.dispatch == nil
      assert record.error_class == nil
    end
  end

  describe "deadline and closure" do
    test "result at or after deadline is recorded late immediately" do
      {now, set} = clock(1_000)

      {:ok, join} =
        Aggregation.new(["a", "b"],
          branch_key: {:field, ["correlation_id"]},
          deadline_unix_ms: 2_000,
          max_result_bytes: 1_000,
          max_branches: 4,
          now: now
        )

      {:ok, join} = Aggregation.accept(join, completed("a"))
      set.(1_999)
      {:ok, join} = Aggregation.accept(join, completed("b"))
      assert statuses(join)["b"] == :fulfilled

      set.(2_000)
      {:ok, join} = Aggregation.accept(join, completed("a", %{"v" => "late"}))

      {:ok, %{"a" => a, "b" => _b}} = Aggregation.status(join)
      assert a.status == :fulfilled
      assert a.late_count == 1
      assert a.duplicate_count == 0
    end

    test "post-deadline first input marks the branch :late, not merged" do
      {now, set} = clock(1_000)

      {:ok, join} =
        Aggregation.new(["a"],
          branch_key: {:field, ["correlation_id"]},
          deadline_unix_ms: 2_000,
          max_result_bytes: 1_000,
          max_branches: 2,
          now: now
        )

      set.(2_500)
      {:ok, join} = Aggregation.accept(join, completed("a"))

      {:ok, %{"a" => record}} = Aggregation.status(join)
      assert record.status == :late
      assert record.late_count == 1
      assert record.outcome == nil
      assert record.first_seen_unix_ms == 2_500
    end

    test "expiry converts pending to :missing and late to :timed_out, then closes" do
      {now, set} = clock(1_000)

      {:ok, join} =
        Aggregation.new(["a", "b", "c"],
          branch_key: {:field, ["correlation_id"]},
          deadline_unix_ms: 2_000,
          max_result_bytes: 1_000,
          max_branches: 4,
          now: now
        )

      {:ok, join} = Aggregation.accept(join, completed("a"))
      set.(2_500)
      {:ok, join} = Aggregation.accept(join, completed("b"))

      {closed, %{decision: :expired, branches: branches}} =
        Aggregation.decision(join, 3_000)

      assert closed.closed
      assert closed.outcome == :expired
      assert branches["a"].status == :fulfilled
      assert branches["b"].status == :timed_out
      assert branches["c"].status == :missing
      assert branches["c"].decided_unix_ms == 3_000
    end

    test "mark_lost still settles at the deadline; results do not" do
      {now, set} = clock(1_000)

      {:ok, join} =
        Aggregation.new(["a", "b"],
          branch_key: {:field, ["correlation_id"]},
          deadline_unix_ms: 2_000,
          max_result_bytes: 1_000,
          max_branches: 4,
          now: now
        )

      set.(2_000)
      {:ok, join} = Aggregation.mark_lost(join, "a", :timed_out)
      assert statuses(join)["a"] == :timed_out

      {:ok, join} = Aggregation.accept(join, completed("b"))
      assert statuses(join)["b"] == :late

      {_closed, %{decision: :expired}} = Aggregation.decision(join, 2_000)
    end

    test "closed join returns stored outcome and records late input" do
      {:ok, join, _} = new_join(["a"])
      {:ok, join} = Aggregation.accept(join, completed("a"))
      {closed, %{decision: :all}} = Aggregation.decision(join, 1_000)

      {:ok, closed} = Aggregation.accept(closed, completed("a", %{"v" => "again"}))
      {:ok, %{"a" => record}} = Aggregation.status(closed)
      assert record.status == :fulfilled
      assert record.late_count == 1
      assert record.duplicate_count == 0

      {^closed, %{decision: :all}} = Aggregation.decision(closed, 2_000)
      assert closed.closed
    end

    test "unbounded deadline never expires" do
      {:ok, join, _} = new_join(["a", "b"])
      {same, %{decision: :pending}} = Aggregation.decision(join, 9_999_999)
      assert same == join
      refute same.closed
    end
  end

  describe "state properties" do
    test "plain-map state round-trips through term_to_binary" do
      {:ok, join, _} = new_join(["a", "b"])
      {:ok, join} = Aggregation.accept(join, completed("a", %{"secret" => "payload-1"}))

      restored = join |> :erlang.term_to_binary() |> then(&:erlang.binary_to_term/1)

      assert Aggregation.valid_state?(restored)
      assert statuses(restored) == statuses(join)
      assert {^restored, %{decision: :pending}} = Aggregation.decision(restored, 1_000)
    end

    test "restored data uses a freshly rebound clock after the old clock owner stops" do
      {:ok, old_clock} = Agent.start_link(fn -> 1_000 end)
      old_now = fn -> Agent.get(old_clock, & &1) end

      {:ok, join} =
        Aggregation.new(["a", "b", "c"], config(now: old_now, deadline_unix_ms: 2_000))

      {:ok, join} = Aggregation.accept(join, completed("a", %{"secret" => "stored-data"}))
      # A process-bound Need is not portable persistence data.
      stored = join |> Map.delete(:now) |> :erlang.term_to_binary()
      Agent.stop(old_clock)
      refute Process.alive?(old_clock)

      restored_data = :erlang.binary_to_term(stored)
      refute Map.has_key?(restored_data, :now)
      refute Aggregation.valid_state?(restored_data)
      {fresh_now, set_fresh} = clock(1_500)
      restored = Map.put(restored_data, :now, fresh_now)

      assert Aggregation.valid_state?(restored)
      assert statuses(restored) == statuses(join)
      assert {^restored, %{decision: :pending}} = Aggregation.decision(restored, 1_500)
      assert {:ok, restored} = Aggregation.accept(restored, completed("b"))
      assert statuses(restored)["b"] == :fulfilled

      set_fresh.(2_000)
      assert {:ok, restored} = Aggregation.accept(restored, completed("c"))
      assert statuses(restored)["c"] == :late
      assert {closed, %{decision: :expired}} = Aggregation.decision(restored, 2_000)
      assert closed.branches["a"].status == :fulfilled
      assert closed.branches["b"].status == :fulfilled
      assert closed.branches["c"].status == :timed_out
      refute inspect(closed) =~ "stored-data"
    end

    test "state never retains payload values" do
      {:ok, join, _} = new_join(["a"])
      secret = "s3cr3t-payload-value"
      {:ok, join} = Aggregation.accept(join, completed("a", %{"token" => secret}))

      refute inspect(join) =~ secret
      refute inspect(join) =~ "s3cr3t"

      {:ok, branches} = Aggregation.status(join)
      refute inspect(branches) =~ secret

      {_closed, %{branches: decided}} = Aggregation.decision(join, 1_000)
      refute inspect(decided) =~ secret
    end

    test "error tuples carry atoms only, no payload echo" do
      {:ok, join, _} = new_join(["a"])
      secret = "s3cr3t"
      bad = completed("a", secret) |> Map.put("dispatch", "bogus")

      assert {:error, :invalid_result} = Aggregation.accept(join, bad)
      refute inspect(bad) =~ "never-echoed"
    end

    test "no environment variable reads in source" do
      for file <- [
            Path.expand("../../lib/elzoo/aggregation.ex", __DIR__),
            Path.expand("../../lib/elzoo/aggregation/runner.ex", __DIR__)
          ] do
        source = File.read!(file)
        refute source =~ "System.get_env"
        refute source =~ "System.fetch_env"
      end
    end

    test "corrupt state is refused, not crashed" do
      assert {:error, :invalid_state} = Aggregation.status(%{})
      assert {:error, :invalid_state} = Aggregation.status(%{declared: []})
      assert {:error, :invalid_state} = Aggregation.accept(%{}, completed("a"))
      assert {:error, :invalid_state} = Aggregation.decision(nil, 1)
      refute Aggregation.valid_state?(%{})
      refute Aggregation.valid_state?(nil)
    end
  end
end
