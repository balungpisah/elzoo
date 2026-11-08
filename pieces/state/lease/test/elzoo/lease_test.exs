# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/lease_test_helper.exs", __DIR__)

defmodule Elzoo.LeaseTest do
  @moduledoc """
  `state/lease` on the volatile Memory double with the manual clock, plus the
  selected Cure laws and negative controls. Scenario IDs follow the ELZ-028
  work record (LS1–LS28). Finite scenarios, not proofs.
  """
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Memory
  alias Elzoo.Lease
  alias Elzoo.Lease.{Clock, Record, TestHelper}

  @cure :"Cure.Elzoo.Lease"
  @source File.read!(Path.expand("../../cure/elzoo/lease.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @laws ~w(no_holder_is_free unreadable_is_ambiguous holder_classifies_by_orders future_stamp_is_ambiguous
           stamp_now_classifies_by_expiry past_stamp_classifies_by_expiry expiry_passed_is_stale expiry_now_is_stale
           expiry_ahead_is_active claim_reads_holder renew_reads_holder seize_reads_holder release_reads_free
           unreadable_reads_unreadable regression_refuses same_stamp_keeps later_stamp_keeps seize_bypasses_gate
           claim_is_gated claim_expired_is_gated renew_is_gated release_is_gated complete_is_gated
           ambiguous_refuses_claim ambiguous_refuses_renew ambiguous_refuses_release ambiguous_refuses_claim_expired
           stale_refuses_renew free_refuses_renew active_other_refuses_claim active_other_refuses_renew
           active_other_refuses_release stale_permits_claim free_permits_claim active_holder_permits_renew
           seize_permits claim_expired_takes_stale claim_expired_skips_free claim_expired_refuses_active
           release_free_is_idempotent stale_other_refuses_release complete_permits compare_nat_before
           compare_nat_after compare_nat_same compare_struct_before compare_struct_after compare_struct_same)
  @minute 60_000
  @epoch TestHelper.epoch()

  defp law_line(law) do
    @source
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, "fn #{law}("))
    |> Kernel.+(1)
  end

  test "selected laws compile and audit clean; seven negative controls are rejected in the named law" do
    assert {:module, @cure} = Code.ensure_loaded(@cure)
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
    exports = @cure.module_info(:exports) |> Enum.map(&elem(&1, 0))
    for law <- @laws, do: assert(String.to_atom(law) in exports, "law #{law} not exported")
    IO.puts("ELZ-028 laws compiled: #{length(@laws)}")

    negatives = [
      {"FutureStampActive", "future_stamp_is_ambiguous",
       "StampAfter() -> LeaseAmbiguous()\n      StampSame() -> by_expiry(until_vs_now)",
       "StampAfter() -> by_expiry(until_vs_now)\n      StampSame() -> by_expiry(until_vs_now)"},
      {"ExpiryNowActive", "expiry_now_is_stale",
       "StampSame() -> LeaseStale()\n      StampBefore() -> LeaseStale()",
       "StampSame() -> LeaseActive()\n      StampBefore() -> LeaseStale()"},
      {"ReleaseReadsHolder", "release_reads_free", "EvRelease(at) -> NoHolder(at)",
       "EvRelease(at) -> HolderStamp(at, at)"},
      {"RegressionPermits", "regression_refuses",
       "StampBefore() -> RefuseAmbiguous()\n      StampSame() -> decision",
       "StampBefore() -> decision\n      StampSame() -> decision"},
      {"AmbiguousReleases", "ambiguous_refuses_release",
       "LeaseAmbiguous() -> RefuseAmbiguous()\n      LeaseActive() -> by_holder(caller)",
       "LeaseAmbiguous() -> by_holder(caller)\n      LeaseActive() -> by_holder(caller)"},
      {"StaleRenews", "stale_refuses_renew", "LeaseStale() -> RefuseStale()",
       "LeaseStale() -> Permit()"},
      {"FalseLaw", "stale_permits_claim",
       "decide(OpClaim(), LeaseStale(), caller), Permit()) =\n    reflexive(Permit())",
       "decide(OpClaim(), LeaseStale(), caller), RefuseStale()) =\n    reflexive(RefuseStale())"}
    ]

    for {name, law, from, to} <- negatives do
      assert String.contains?(@source, from), "negative #{name}: pattern missing"

      wrong =
        @source
        |> String.replace("mod Elzoo.Lease", "mod Elzoo." <> name)
        |> String.replace(from, to)

      assert {:error,
              {:codegen_error, {:source_context, {:conversion_failure, _, _}, %{line: line}}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)

      # Cure's diagnostic has proof_name nil on the pinned release; the failing line is the reflexive line of the law.
      assert line in [law_line(law), law_line(law) + 1],
             "negative #{name} failed at line #{line}, law #{law} at #{law_line(law)}"

      IO.puts("ELZ-028 negative rejected in #{law}: #{name}")
    end
  end

  test "LS19 compare/2 boundaries and agreement with the law-covered compare_struct on -32..32" do
    for a <- -32..32, b <- -32..32 do
      assert apply(@cure, :compare, [a, b]) == apply(@cure, :compare_struct, [a, b])
    end

    big = 9_223_372_036_854_775_807
    assert apply(@cure, :compare, [big, big]) == :StampSame
    assert apply(@cure, :compare, [big - 1, big]) == :StampBefore
    assert apply(@cure, :compare, [-big - 1, big]) == :StampBefore
    assert apply(@cure, :compare, [0, -1]) == :StampAfter
    assert apply(@cure, :classify, [{:HolderStamp, 10, 20}, 10]) == :LeaseActive
    assert apply(@cure, :classify, [{:HolderStamp, 10, 20}, 20]) == :LeaseStale
    assert apply(@cure, :classify, [{:HolderStamp, 10, 20}, 19]) == :LeaseActive
    assert apply(@cure, :classify, [{:HolderStamp, 11, 20}, 10]) == :LeaseAmbiguous
  end

  # ── Memory scenarios ────────────────────────────────────────────────

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # Run `fun` in a Task while this process drives the owner's seams: for each
  # {phase, action} in order, wait for the hook, run the action, release the seam.
  defp seamed(fun, actions) do
    task = Task.async(fun)

    for {phase, action} <- actions do
      receive do
        {^phase, key, owner} ->
          action.(key)
          send(owner, {:continue, phase})
      after
        5_000 -> raise "seam #{phase} not reached"
      end
    end

    Task.await(task, 10_000)
  end

  defp seam_hook(phases) do
    test = self()

    fn phase, ctx ->
      if phase in phases do
        send(test, {phase, ctx.key, ctx.owner})

        receive do
          {:continue, ^phase} -> :ok
        after
          5_000 -> raise "seam #{phase} not released"
        end
      end

      :ok
    end
  end

  defp pass, do: fn _ -> :ok end

  test "LS1 claim free, hold by holder and other, status fields" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    assert {:held, held} = Lease.claim(lease, "k1", "alice", @minute)
    assert %{owner: "alice", live: %{key: "k1", revision: 1, at: @epoch, until: until}} = held
    assert until == @epoch + @minute * 1000
    assert {:held, ^held} = Lease.hold(lease, "k1", "alice")
    assert {:lease_refused, %{reason: :active, holder: "alice"}} = Lease.hold(lease, "k1", "bob")

    assert {:ok,
            %{
              status: :active,
              holder: %{owner: "alice"},
              revision: 1,
              as_of: 1,
              now: @epoch,
              reason: nil
            }} = Lease.status(lease, "k1")

    Clock.advance(clock, @minute * 1000)
    assert {:ok, %{status: :stale, reason: nil}} = Lease.status(lease, "k1")
    assert {:lease_refused, %{reason: :stale}} = Lease.hold(lease, "k1", "alice")
    assert {:free, %{revision: 0}} = Lease.hold(lease, "never", "alice")
  end

  test "LS2 renew extends only the holder's live lease" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    {:held, _} = Lease.claim(lease, "k", "alice", @minute)
    Clock.advance(clock, 1_000)

    assert {:renewed, %{keys: ["k"], held: %{"k" => %{live: %{revision: 2, at: at, until: until}}}}} =
             Lease.renew(lease, "alice", ["k"], 2 * @minute)

    assert at == @epoch + 1_000 and until == at + 2 * @minute * 1000

    assert {:renewed, %{keys: [], refused: %{"k" => %{reason: :not_holder, holder: "alice"}}}} =
             Lease.renew(lease, "bob", ["k"], @minute)

    Clock.advance(clock, 3 * @minute * 1000)

    assert {:renewed, %{refused: %{"k" => %{reason: :stale}}}} =
             Lease.renew(lease, "alice", ["k"], @minute)

    assert {:renewed, %{refused: %{"free" => %{reason: :free}}}} =
             Lease.renew(lease, "alice", ["free"], @minute)

    assert length(TestHelper.rows(lease.store, "k")) == 2
  end

  test "LS3 release is the holder's, attributable, idempotent on free" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    {:held, _} = Lease.claim(lease, "k", "alice", @minute)
    assert {:lease_refused, %{reason: :not_holder}} = Lease.release(lease, "k", "bob")
    assert {:free, %{revision: 2}} = Lease.release(lease, "k", "alice")
    assert {:free, %{revision: 2}} = Lease.release(lease, "k", "alice")
    [_, released] = TestHelper.rows(lease.store, "k")

    assert %{"owner" => "alice", "by" => "alice", "reason" => "released", "at" => @epoch} =
             Jason.decode!(released.payload)

    {:held, _} = Lease.claim(lease, "s", "alice", @minute)
    Clock.advance(clock, @minute * 1000)
    assert {:free, _} = Lease.release(lease, "s", "alice")

    assert %{"reason" => "stale", "by" => "alice"} =
             Jason.decode!(List.last(TestHelper.rows(lease.store, "s")).payload)
  end

  test "LS4 the expired holder's old fence is refused by revision after a replacement; control without takeover" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    {:held, a} = Lease.claim(lease, "k", "alice", @minute)
    Clock.advance(clock, @minute * 1000)
    assert {:held, b} = Lease.claim(lease, "k", "bob", @minute)
    assert b.live.revision == 3
    [_, released, claimed] = TestHelper.rows(lease.store, "k")

    assert %{"owner" => "alice", "by" => "bob", "reason" => "stale"} =
             Jason.decode!(released.payload)

    assert %{"owner" => "bob"} = Jason.decode!(claimed.payload)
    assert {:fenced, %{expected: 1, observed: 3}} = Lease.write(lease, a, [{"added", 1, "x"}])
    assert {:held, %{live: %{revision: 4}}} = Lease.write(lease, b, [{"added", 1, "x"}])

    # control: expired, no takeover -> the revision cannot see time; the old fence still is the current fence
    {:held, c} = Lease.claim(lease, "lonely", "carol", @minute)
    Clock.advance(clock, 2 * @minute * 1000)
    assert {:ok, %{status: :stale}} = Lease.status(lease, "lonely")
    assert {:held, _} = Lease.write(lease, c, [{"added", 1, "late"}])
  end

  test "LS5 expiry is judged by the store clock only; LS5b seize over active is attributable" do
    far = 946_684_800_000_000
    %{lease: lease, clock: clock} = TestHelper.memory(now: far)
    assert {:held, %{live: %{at: ^far}}} = Lease.claim(lease, "k", "alice", @minute)
    assert {:ok, %{status: :active, now: ^far}} = Lease.status(lease, "k")
    Clock.set(clock, far + @minute * 1000)
    assert {:ok, %{status: :stale}} = Lease.status(lease, "k")
    Clock.set(clock, far + 1_000)
    assert {:ok, %{status: :active}} = Lease.status(lease, "k")
    assert {:lease_refused, %{reason: :active}} = Lease.claim(lease, "k", "op", @minute)

    assert {:held, %{owner: "op", live: %{revision: 3}}} =
             Lease.seize(lease, "k", "op", @minute, :operator_takeover)

    [_, released, seized] = TestHelper.rows(lease.store, "k")

    assert %{"owner" => "alice", "by" => "op", "reason" => "operator_takeover"} =
             Jason.decode!(released.payload)

    assert seized.kind == "lease_seized"
    assert {:error, {:invalid, :reason}} = Lease.seize(lease, "k", "op", @minute, :because)
  end

  test "LS6 concurrent claims on one key: exactly one holder" do
    %{lease: lease} = TestHelper.memory()

    results =
      1..8
      |> Task.async_stream(fn i -> Lease.claim(lease, "k", "w#{i}", @minute) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:held, _}, &1)) == 1
    assert Enum.count(results, &match?({:lease_refused, %{reason: :active}}, &1)) == 7
  end

  test "LS7 claim_expired on the double: stale only, limit, overlap with a return barrier, partial failure" do
    %{lease: lease, clock: clock, store: store} = TestHelper.memory()
    for k <- ~w(s1 s2 s3), do: {:held, _} = Lease.claim(lease, k, "old", 1)
    {:held, _} = Lease.claim(lease, "active", "old", @minute)
    Clock.advance(clock, 2_000)
    # LS7c limit and skipped; free keys refused, active refused
    assert {:claimed, r} =
             Lease.claim_expired(lease, "sweeper", @minute, 2, ~w(s3 free active s1 s2))

    assert Enum.map(r.held, & &1.live.key) == ~w(s1 s2)
    assert r.skipped == ~w(s3)
    assert %{reason: :active} = r.refused["active"]
    assert %{reason: :free} = r.refused["free"]
    assert r.skipped_locked == []
    assert {:ok, %{status: :active, holder: %{owner: "sweeper"}}} = Lease.status(lease, "s1")
    # LS7a: a second sweep sees s1/s2 active and takes s3
    assert {:claimed, %{held: [%{live: %{key: "s3"}}], refused: refused}} =
             Lease.claim_expired(lease, "other", @minute, 5, ~w(s1 s2 s3))

    assert %{reason: :active} = refused["s1"]
    # LS7e partial failure without rollback: the append of the second candidate fails
    for k <- ~w(p1 p2 p3), do: {:held, _} = Lease.claim(lease, k, "old", 1)
    Clock.advance(clock, 2_000)
    :ok = Memory.fault(store, :append, :unavailable)
    # the first append consumes the one-shot fault
    assert {:partial,
            %{committed: [], failed: {"p1", {:indeterminate, _}}, not_evaluated: ~w(p2 p3)}} =
             Lease.claim_expired(lease, "sweeper", @minute, 5, ~w(p1 p2 p3))

    assert {:claimed, %{held: held}} =
             Lease.claim_expired(lease, "sweeper", @minute, 5, ~w(p1 p2 p3))

    assert Enum.map(held, & &1.live.key) == ~w(p1 p2 p3)
    # LS7d overlap on the double: the owner serializes sweeps, so the pending-return
    # barrier is a PostgreSQL scenario; here A's grant expires before B's sweep and both list the key
    {:held, _} = Lease.claim(lease, "ov", "old", 1)
    Clock.advance(clock, 2_000)
    assert {:claimed, %{held: [a]}} = Lease.claim_expired(lease, "A", 1, 1, ~w(ov))
    Clock.advance(clock, 2_000)
    assert {:ok, %{status: :stale}} = Lease.status(lease, "ov")
    assert {:claimed, %{held: [b]}} = Lease.claim_expired(lease, "B", @minute, 1, ~w(ov))
    assert a.live.revision < b.live.revision and a.live.key == b.live.key
  end

  test "LS8 renewal after handoff, LS8b renewal sampled after expiry, LS8c admitted late commit, LS8d lost CAS" do
    %{lease: lease, clock: clock, store: store} =
      TestHelper.memory(hook: seam_hook([:before_lock, :after_clock, :before_write]))

    all = [before_lock: pass(), after_clock: pass(), before_write: pass()]
    assert {:held, _} = seamed(fn -> Lease.claim(lease, "k", "alice", @minute) end, all)
    # LS8: B takes over after expiry; A's renewal evaluated afterwards is refused, no record from A
    Clock.advance(clock, @minute * 1000)
    assert {:held, _} = seamed(fn -> Lease.claim(lease, "k", "bob", @minute) end, all)

    assert {:renewed, %{refused: %{"k" => %{reason: :not_holder, holder: "bob"}}}} =
             seamed(fn -> Lease.renew(lease, "alice", ["k"], @minute) end,
               before_lock: pass(),
               after_clock: pass()
             )

    assert length(TestHelper.rows(store, "k")) == 3

    # LS8b: the lease expires while the renewal waits before the lock -> sampled after expiry -> refused, nothing written
    assert {:held, _} = seamed(fn -> Lease.claim(lease, "b", "alice", @minute) end, all)

    assert {:renewed, %{refused: %{"b" => %{reason: :stale}}}} =
             seamed(fn -> Lease.renew(lease, "alice", ["b"], @minute) end,
               before_lock: fn _ -> Clock.advance(clock, @minute * 1000) end,
               after_clock: pass()
             )

    assert length(TestHelper.rows(store, "b")) == 1

    # LS8c: sampled live; the clock passes expiry after the sample; the commit is accepted with the earlier sample
    assert {:held, _} = seamed(fn -> Lease.claim(lease, "c", "alice", @minute) end, all)
    sample = Clock.sample(clock) |> elem(1)

    assert {:renewed, %{held: %{"c" => %{live: %{at: ^sample, until: until}}}}} =
             seamed(fn -> Lease.renew(lease, "alice", ["c"], 10 * @minute) end,
               before_lock: pass(),
               after_clock: fn _ -> Clock.advance(clock, 2 * @minute * 1000) end,
               before_write: pass()
             )

    assert until == sample + 10 * @minute * 1000
    assert {:ok, %{status: :active}} = Lease.status(lease, "c")
    assert %{"at" => ^sample} = Jason.decode!(List.last(TestHelper.rows(store, "c")).payload)
    # LS8d: a bypassing write between the read and the append loses the CAS; no stale write lands
    assert {:held, _} = seamed(fn -> Lease.claim(lease, "d", "alice", @minute) end, all)

    assert {:renewed, %{refused: %{"d" => %{reason: :lost_race, revision: 2}}}} =
             seamed(fn -> Lease.renew(lease, "alice", ["d"], @minute) end,
               before_lock: pass(),
               after_clock: pass(),
               before_write: fn _ -> TestHelper.forge!(store, "d", 1, [{"added", "bypass"}]) end
             )

    assert length(TestHelper.rows(store, "d")) == 2
  end

  test "LS9 future stamp is ambiguous for everyone; only seize recovers" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    {:held, _} = Lease.claim(lease, "k", "alice", @minute)
    Clock.set(clock, @epoch - 10)

    assert {:ok, %{status: :ambiguous, reason: :future_stamp, holder: %{owner: "alice"}}} =
             Lease.status(lease, "k")

    assert {:lease_refused, %{reason: :ambiguous}} = Lease.claim(lease, "k", "bob", @minute)
    assert {:lease_refused, %{reason: :ambiguous}} = Lease.claim(lease, "k", "alice", @minute)

    assert {:renewed, %{refused: %{"k" => %{reason: :ambiguous}}}} =
             Lease.renew(lease, "alice", ["k"], @minute)

    assert {:lease_refused, %{reason: :ambiguous}} = Lease.release(lease, "k", "alice")
    assert {:lease_refused, %{reason: :ambiguous}} = Lease.hold(lease, "k", "alice")
    assert {:held, _} = Lease.seize(lease, "k", "op", @minute, :clock_regression)
    assert {:ok, %{status: :active, holder: %{owner: "op"}}} = Lease.status(lease, "k")
  end

  test "LS10 unreadable latest record is ambiguous; unknown holder reported nil; seize recovers" do
    %{lease: lease, store: store} = TestHelper.memory()
    {:held, _} = Lease.claim(lease, "k", "alice", @minute)
    :ok = Memory.corrupt(store, :records, {"k", 1}, %{payload: "garbage"})
    assert {:ok, %{status: :ambiguous, reason: :unreadable, holder: nil}} = Lease.status(lease, "k")

    assert {:lease_refused, %{reason: :unreadable, holder: nil}} =
             Lease.claim(lease, "k", "bob", @minute)

    assert {:lease_refused, %{reason: :unreadable}} = Lease.release(lease, "k", "alice")
    assert {:held, _} = Lease.seize(lease, "k", "op", @minute, :corrupt_record)

    assert %{"owner" => nil, "reason" => "corrupt_record"} =
             Jason.decode!(Enum.at(TestHelper.rows(store, "k"), 1).payload)

    # unknown version and malformed JSON forged through the Store
    TestHelper.forge!(store, "v", 0, [
      {"lease_claimed", ~s({"v":2,"owner":"x","at":1,"ttl_ms":1,"until":1001})}
    ])

    assert {:ok, %{status: :ambiguous, reason: :unreadable}} = Lease.status(lease, "v")
    TestHelper.forge!(store, "j", 0, [{"lease_claimed", "{not json"}])
    assert {:ok, %{status: :ambiguous, reason: :unreadable}} = Lease.status(lease, "j")
  end

  test "LS11 crash between steps: lost reply then confirm, superseded, atomic terminal batch and rollback" do
    %{lease: lease, store: store} = TestHelper.memory()
    :ok = Memory.fault(store, :append, :reply_loss)
    assert {:indeterminate, info} = Lease.claim(lease, "k", "alice", @minute)
    assert {:committed, 1} = Lease.confirm(lease, info)
    assert {:held, _} = Lease.hold(lease, "k", "alice")
    :ok = Memory.fault(store, :append, :rollback)
    assert {:indeterminate, info2} = Lease.claim(lease, "s", "alice", @minute)
    assert {:unknown, :unfenced} = Lease.confirm(lease, info2)
    {:held, _} = Lease.claim(lease, "s", "bob", @minute)
    assert :superseded = Lease.confirm(lease, info2)
    # LS11c terminal batch: terminal record + release in one append; rollback leaves neither
    {:held, h} = Lease.claim(lease, "t", "alice", @minute)
    :ok = Memory.fault(store, :append, :rollback)
    assert {:indeterminate, _} = Lease.complete(lease, h, [{"done", 1, "result"}])
    assert length(TestHelper.rows(store, "t")) == 1

    assert {:completed, %{key: "t", owner: "alice", revision: 3}} =
             Lease.complete(lease, h, [{"done", 1, "result"}])

    assert [_, done, released] = TestHelper.rows(store, "t")
    assert done.kind == "done"

    assert %{"reason" => "terminal", "owner" => "alice", "by" => "alice"} =
             Jason.decode!(released.payload)

    assert {:ok, %{status: :free}} = Lease.status(lease, "t")
  end

  test "LS13 clock unavailable writes nothing" do
    %{lease: lease, clock: clock, store: store} = TestHelper.memory()
    Clock.fail(clock, true)
    assert {:error, :clock_unavailable} = Lease.claim(lease, "k", "alice", @minute)
    assert {:error, :clock_unavailable} = Lease.status(lease, "k")
    assert TestHelper.rows(store, "k") == []
    Clock.fail(clock, false)
    assert {:held, _} = Lease.claim(lease, "k", "alice", @minute)
  end

  test "LS14 input validation and construction pairing" do
    %{lease: lease, store: store, clock: clock} = TestHelper.memory()
    assert {:error, {:invalid, :key}} = Lease.claim(lease, "", "alice", @minute)

    assert {:error, {:invalid, :owner}} =
             Lease.claim(lease, "k", String.duplicate("a", 201), @minute)

    assert {:error, {:invalid, :ttl_ms}} = Lease.claim(lease, "k", "alice", 0)
    assert {:error, {:invalid, :ttl_ms}} = Lease.claim(lease, "k", "alice", Record.max_ttl_ms() + 1)
    assert {:error, {:invalid, :limit}} = Lease.claim_expired(lease, "a", @minute, 0, ["k"])

    assert {:error, {:invalid, :candidates}} =
             Lease.claim_expired(lease, "a", @minute, 1, ["k", "k"])

    assert {:error, {:invalid, :keys}} = Lease.renew(lease, "a", [], @minute)

    assert {:error, {:invalid, :reason}} =
             Lease.seize(lease, "k", "a", @minute, "operator_takeover")

    assert {:error, {:invalid, :held}} = Lease.write(lease, %{owner: "a"}, [{"added", 1, "x"}])

    assert {:error, {:invalid, :fold}} =
             Lease.new(
               store: store,
               fold: %{TestHelper.fold() | kinds: %{"added" => :state_bearing}},
               limits: TestHelper.limits(),
               clock: {:manual, clock}
             )

    assert {:error, {:invalid, :limits}} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: %{TestHelper.limits() | max_batch_size: 1},
               clock: {:manual, clock}
             )

    assert {:error, {:invalid, :clock}} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: TestHelper.limits(),
               clock: :store
             )
  end

  test "LS15 pruned latest record is ambiguous; retention_bound keeps it; LS17 self-contained renewal survives retention" do
    %{lease: lease, store: store, clock: clock} = TestHelper.memory()
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)
    {:held, h} = Lease.write(lease, h, [{"added", 1, "x"}])
    Clock.advance(clock, 1_000)
    {:renewed, %{held: %{"k" => _}}} = Lease.renew(lease, "alice", ["k"], @minute)

    assert [
             %{sequence: 1, kind: "lease_claimed"},
             %{sequence: 2, kind: "added"},
             %{sequence: 3, kind: "lease_renewed"}
           ] = TestHelper.rows(store, "k")

    assert {:ok, %{through: 2}} = Lease.retention_bound(lease, "k")
    _ = TestHelper.checkpoint(store, "k")

    # LS17: retain through 1 (the claim) keeps the renewal visible; the self-contained renewal reads active
    :ok = TestHelper.retain!(store, "k", 2)

    assert {:ok, %{status: :active, holder: %{owner: "alice"}, low_water: 2}} =
             Lease.status(lease, "k")

    # LS15: retain through the renewal -> pruned prefix -> ambiguous; seize recovers
    :ok = TestHelper.retain!(store, "k", 3)
    assert {:ok, %{status: :ambiguous, reason: :pruned_prefix}} = Lease.status(lease, "k")
    assert {:lease_refused, %{reason: :pruned_prefix}} = Lease.claim(lease, "k", "bob", @minute)
    assert {:held, _} = Lease.seize(lease, "k", "op", @minute, :pruned_prefix)
    assert {:ok, %{status: :active}} = Lease.status(lease, "k")
    _ = h
  end

  test "LS16b Memory retention: serialized through the owner, and a bypass detected after the fact" do
    %{lease: lease, store: store, clock: clock} =
      TestHelper.memory(hook: seam_hook([:before_write]))

    seams = [before_write: pass()]
    assert {:held, h} = seamed(fn -> Lease.claim(lease, "k", "alice", @minute) end, seams)
    assert {:held, _} = seamed(fn -> Lease.write(lease, h, [{"added", 1, "x"}]) end, seams)
    {_, replay} = TestHelper.checkpoint(store, "k")
    # (a) through the owner: the Store's retain, serialized with the sections
    assert {:committed, 1} =
             Elzoo.Lease.Memory.retain(lease.backend, "k", 0, 1, :crypto.strong_rand_bytes(16))

    assert {:ok, %{status: :ambiguous, reason: :pruned_prefix, low_water: 1}} =
             Lease.status(lease, "k")

    assert {:held, _} =
             seamed(fn -> Lease.seize(lease, "k", "op", @minute, :pruned_prefix) end, seams)

    # (b) bypass: a direct Store retain between the section's read and its append prunes the latest record
    Clock.advance(clock, 1_000)
    _ = TestHelper.checkpoint(store, "k", replay)

    assert {:renewed, %{held: %{"k" => %{retention_observed: true, live: %{revision: 5}}}}} =
             seamed(fn -> Lease.renew(lease, "op", ["k"], @minute) end,
               before_write: fn _ -> :ok = TestHelper.retain!(store, "k", 4) end
             )

    assert {:ok, %{status: :active, holder: %{owner: "op"}, low_water: 4}} =
             Lease.status(lease, "k")
  end

  test "LS18 clock regression on a free key is refused by the gate; LS25 the full 100 -> 90 -> 95 terminal sequence" do
    %{lease: lease, clock: clock} = TestHelper.memory(now: 100)
    {:held, _} = Lease.claim(lease, "f", "alice", 1)
    Clock.set(clock, 100_000)
    assert {:free, _} = Lease.release(lease, "f", "alice")
    Clock.set(clock, 90_000)
    assert {:lease_refused, %{reason: :regression}} = Lease.claim(lease, "f", "bob", @minute)
    assert {:held, _} = Lease.seize(lease, "f", "op", @minute, :clock_regression)
    # LS25
    Clock.set(clock, 100)
    {:held, h} = Lease.claim(lease, "t", "alice", @minute)
    assert %{live: %{at: 100}} = h
    Clock.set(clock, 90)
    assert {:lease_refused, %{reason: :regression}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert length(TestHelper.rows(lease.store, "t")) == 1
    Clock.set(clock, 95)

    assert {:ok, %{status: :ambiguous, reason: :future_stamp, holder: %{owner: "alice", at: 100}}} =
             Lease.status(lease, "t")

    assert {:lease_refused, %{reason: :regression}} = Lease.complete(lease, h, [{"done", 1, "r"}])

    assert {:renewed, %{refused: %{"t" => %{reason: :ambiguous}}}} =
             Lease.renew(lease, "alice", ["t"], @minute)

    assert {:lease_refused, %{reason: :ambiguous}} = Lease.release(lease, "t", "alice")
    assert {:held, s} = Lease.seize(lease, "t", "op", @minute, :clock_regression)
    assert %{live: %{at: 95, revision: 3}} = s

    assert %{"reason" => "clock_regression", "owner" => "alice", "by" => "op", "at" => 95} =
             Jason.decode!(Enum.at(TestHelper.rows(lease.store, "t"), 1).payload)

    assert {:ok, %{status: :active, holder: %{owner: "op"}}} = Lease.status(lease, "t")
    assert {:fenced, %{expected: 1, observed: 3}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert {:completed, %{revision: 5}} = Lease.complete(lease, s, [{"done", 1, "r"}])
  end

  test "LS20 a completed receipt is not a lease; LS21 renew batch over mixed keys" do
    %{lease: lease, clock: clock} = TestHelper.memory()
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)
    assert {:completed, receipt} = Lease.complete(lease, h, [{"done", 1, "r"}])
    refute Map.has_key?(receipt, :live)
    assert {:error, {:invalid, :held}} = Lease.write(lease, receipt, [{"added", 1, "x"}])
    assert {:error, {:invalid, :held}} = Lease.complete(lease, receipt, [{"done", 1, "x"}])
    assert {:fenced, _} = Lease.write(lease, h, [{"added", 1, "x"}])
    assert {:fenced, _} = Lease.complete(lease, h, [{"done", 1, "x"}])

    assert {:error, {:invalid, :items}} =
             Lease.complete(lease, h, [{"done", 1, "x"}], [{"sink", "e"}])

    {:held, _} = Lease.claim(lease, "mine", "alice", @minute)
    {:held, _} = Lease.claim(lease, "theirs", "bob", @minute)
    {:held, _} = Lease.claim(lease, "old", "alice", 1)
    Clock.advance(clock, 2_000)
    assert {:renewed, r} = Lease.renew(lease, "alice", ~w(mine theirs old missing), @minute)
    assert r.keys == ["mine"]

    assert %{
             "theirs" => %{reason: :not_holder},
             "old" => %{reason: :stale},
             "missing" => %{reason: :free}
           } = r.refused

    assert r.errors == %{}
  end

  test "Devin findings: the owner serializes the holder's write; a modifying call waits instead of failing; fold and limits come from the Store" do
    %{lease: lease, store: store, clock: clock} =
      TestHelper.memory(hook: seam_hook([:before_write]))

    seams = [before_write: pass()]
    assert {:held, a} = seamed(fn -> Lease.claim(lease, "a", "alice", @minute) end, seams)

    # a claim on another key is held at its seam; a holder write started meanwhile waits for the owner
    test = self()

    assert {:held, _} =
             seamed(fn -> Lease.claim(lease, "b", "bob", @minute) end,
               before_write: fn _ ->
                 writer = Task.async(fn -> Lease.write(lease, a, [{"added", 1, "x"}]) end)
                 Process.sleep(100)
                 refute Task.yield(writer, 0), "the holder's write bypassed the owner"
                 send(test, {:writer, writer})
               end
             )

    writer =
      receive do
        {:writer, w} -> w
      end

    # the write runs in its own owner section afterwards (and passes the seam itself)
    receive do
      {:before_write, "a", owner} -> send(owner, {:continue, :before_write})
    after
      5_000 -> raise "the holder's write did not reach the owner"
    end

    assert {:held, %{live: %{revision: 2}}} = Task.await(writer, 5_000)
    # the write itself passes the :before_write seam too
    assert {:held, %{live: %{revision: 3}}} =
             seamed(
               fn ->
                 Lease.write(lease, %{a | live: %{a.live | revision: 2}}, [{"added", 1, "y"}])
               end,
               seams
             )

    # fold and limits are the Store's: a different fold or limits is refused, equal ones are accepted
    assert {:error, {:invalid, :fold}} =
             Lease.new(
               store: store,
               fold: %{TestHelper.fold() | versions: [1, 2]},
               clock: {:manual, clock}
             )

    assert {:error, {:invalid, :limits}} =
             Lease.new(
               store: store,
               limits: %{TestHelper.limits() | max_batch_size: 3},
               clock: {:manual, clock}
             )

    GenServer.stop(lease.backend.owner)
    assert {:ok, _} = Lease.new(store: store, clock: {:manual, clock})
  end

  test "Devin finding 5: an owner exit during the holder's write is an unknown outcome; confirm stays behind that owner" do
    %{lease: lease, store: store} = TestHelper.memory(hook: seam_hook([:before_write]))
    seams = [before_write: pass()]
    assert {:held, a} = seamed(fn -> Lease.claim(lease, "a", "alice", @minute) end, seams)

    assert {:indeterminate, %{cause: :unavailable, records: [_]} = info} =
             seamed(fn -> Lease.write(lease, a, [{"added", 1, "x"}]) end,
               before_write: fn _ -> Process.exit(lease.backend.owner, :kill) end
             )

    assert {:error, :unavailable} = Lease.confirm(lease, info)
    assert length(TestHelper.rows(store, "a")) == 1
  end

  test "confirm/2 is read-only but serialized through the Memory owner" do
    %{lease: lease, store: store} =
      TestHelper.memory(hook: seam_hook([:before_write, :before_confirm]))

    assert {:held, _} =
             seamed(fn -> Lease.claim(lease, "a", "alice", @minute) end,
               before_write: pass()
             )

    [row] = TestHelper.rows(store, "a")
    test = self()

    assert {:held, _} =
             seamed(fn -> Lease.claim(lease, "b", "bob", @minute) end,
               before_write: fn _ ->
                 confirmer =
                   Task.async(fn ->
                     Lease.confirm(lease, %{
                       stream: "a",
                       expected: 0,
                       nonce: row.nonce,
                       records: [row]
                     })
                   end)

                 Process.sleep(100)
                 refute Task.yield(confirmer, 0), "confirm/2 bypassed the owner"
                 send(test, {:confirmer, confirmer})
               end
             )

    confirmer =
      receive do
        {:confirmer, task} -> task
      after
        5_000 -> raise "confirm/2 did not queue behind the owner"
      end

    receive do
      {:before_confirm, "a", owner} ->
        assert owner == lease.backend.owner
        send(owner, {:continue, :before_confirm})
    after
      5_000 -> raise "confirm/2 did not execute in the owner"
    end

    assert {:committed, 1} = Task.await(confirmer, 5_000)
  end

  test "LS27 duplicate owners on the double are rejected; the owner's section serializes" do
    %{lease: lease, store: store, clock: clock} = TestHelper.memory()

    assert {:error, {:invalid, :duplicate_owner}} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: TestHelper.limits(),
               clock: {:manual, clock}
             )

    GenServer.stop(lease.backend.owner)

    assert {:ok, _} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: TestHelper.limits(),
               clock: {:manual, clock}
             )
  end

  test "config and control evidence: construction-time settings, seize and release command results, hooks optional" do
    %{lease: lease} = TestHelper.memory(timeout_ms: 1_000)
    assert lease.backend.timeout == 1_000
    assert {:held, _} = Lease.claim(lease, "k", "alice", @minute)
    assert {:held, %{owner: "op"}} = Lease.seize(lease, "k", "op", @minute, :operator_takeover)
    assert {:free, %{revision: 4}} = Lease.release(lease, "k", "op")
    assert {:free, %{revision: 4}} = Lease.release(lease, "k", "op")

    assert Lease.kinds() == %{
             "lease_claimed" => :non_state_bearing,
             "lease_renewed" => :non_state_bearing,
             "lease_released" => :non_state_bearing,
             "lease_seized" => :non_state_bearing
           }

    assert :terminal in Lease.reasons()
    # the ready replay advances over lease records without calling the consumer reducer
    rows = TestHelper.rows(lease.store, "k")
    replay = Log.replay(rows, 4, TestHelper.fold())
    assert %{model: 0, cursor: {4, false, []}} = replay
  end
end
