# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/metering_test_helper.exs", __DIR__)

defmodule Elzoo.MeteringTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL
  alias Elzoo.AiModel.Usage
  alias Elzoo.Metering, as: M
  alias Elzoo.Metering.{AdminRepo, AppRepo, DownRepo, Harness, Migration, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @max 9_223_372_036_854_775_807
  @message "invalid metering repo or prefix"
  @obs "elzoo_metering_observations"
  @corr "elzoo_metering_corrections"

  setup_all do
    role = Harness.app_role!()
    Harness.start!(AdminRepo, pool_size: 2)
    [[version]] = Harness.query!(AdminRepo, "SELECT current_setting('server_version_num')").rows
    assert String.to_integer(version) in 160_000..169_999
    Harness.start!(AppRepo, pool_size: 4, after_connect: {Harness, :connect, [role, []]})

    Harness.start!(RepeatableRepo,
      pool_size: 1,
      after_connect:
        {Harness, :connect, [role, ["SET default_transaction_isolation = 'repeatable read'"]]}
    )

    # Every application connection is the non-owner role that does not bypass row security.
    assert [[^role, false, false]] =
             Harness.query!(
               AppRepo,
               "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             ).rows

    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(AdminRepo, role)
    on_exit(fn -> Harness.drop!(AdminRepo, p) end)
    {:ok, p: p, m: M.new(repo: AppRepo, prefix: p)}
  end

  defp obs(id, changes \\ %{}) do
    Map.merge(
      %{
        usage_id: id,
        run_id: "run-1",
        operation_id: "op-1",
        attempt_id: "attempt-1",
        provider_id: "anthropic",
        model_id: "model-a",
        unit: :output_tokens,
        amount: 10,
        source: :provider_reported,
        period: "2026-11",
        observed_at_ms: 1_795_000_000_000
      },
      changes
    )
  end

  defp corr(id, usage_id, amount, changes \\ %{}) do
    Map.merge(
      %{
        correction_id: id,
        usage_id: usage_id,
        amount: amount,
        reason: "late usage",
        actor_ref: "ops:1"
      },
      changes
    )
  end

  defp totals!(m, tenant, period, max_rows \\ 1000) do
    {:ok, rows} = M.totals(m, tenant, %{period: period, max_rows: max_rows})
    rows
  end

  defp q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows

  # Ground truth as the owner with FORCE dropped inside a rolled-back transaction.
  defp truth(p, sql, params \\ []) do
    {:error, {:rows, rows}} =
      AdminRepo.transact(fn ->
        for t <- [@obs, @corr],
            do: q!(AdminRepo, "ALTER TABLE #{p}.#{t} NO FORCE ROW LEVEL SECURITY")

        {:error, {:rows, q!(AdminRepo, sql, params)}}
      end)

    rows
  end

  defp denied?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}), do: true
  defp denied?(_), do: false

  defp wait_until(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the barrier condition never held")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  describe "1 duplicates" do
    test "record: an equal request is :duplicate, any changed field is :conflict", %{m: m, p: p} do
      o = obs("u1")
      assert M.record(m, "T1", o) == {:ok, :applied}
      assert M.record(m, "T1", o) == {:ok, :duplicate}

      changes = [
        run_id: "run-2",
        operation_id: "op-2",
        attempt_id: "attempt-2",
        provider_id: "openai",
        model_id: "model-b",
        unit: {:cache_write_tokens, "5m"},
        amount: 11,
        amount: :unknown,
        source: :estimated,
        period: "2026-12",
        observed_at_ms: 1_795_000_000_001
      ]

      for {field, value} <- changes,
          do: assert(M.record(m, "T1", Map.put(o, field, value)) == {:error, :conflict})

      # Field framing: moving a byte between two adjacent fields is another request.
      assert M.record(m, "T1", obs("u2", %{run_id: "ab", operation_id: "c"})) == {:ok, :applied}

      assert M.record(m, "T1", obs("u2", %{run_id: "a", operation_id: "bc"})) ==
               {:error, :conflict}

      # The same usage_id under another tenant is another observation.
      assert M.record(m, "T2", Map.put(o, :amount, 99)) == {:ok, :applied}
      assert M.observation(m, "T1", "u1") == {:ok, Map.merge(o, %{effective: 10, corrections: []})}

      assert truth(p, "SELECT tenant, usage_id, amount FROM #{p}.#{@obs} ORDER BY 1, 2") ==
               [["T1", "u1", 10], ["T1", "u2", 10], ["T2", "u1", 99]]
    end

    test "correct: an equal request is :duplicate, any changed field is :conflict", %{m: m, p: p} do
      {:ok, :applied} = M.record(m, "T1", obs("u1"))
      {:ok, :applied} = M.record(m, "T1", obs("u2"))
      c = corr("c1", "u1", 12)
      assert M.correct(m, "T1", c) == {:ok, :applied}
      assert M.correct(m, "T1", c) == {:ok, :duplicate}

      for {field, value} <- [amount: 13, amount: :unknown, reason: "other", actor_ref: "ops:2"],
          do: assert(M.correct(m, "T1", Map.put(c, field, value)) == {:error, :conflict})

      # One correction_id names one correction of one observation.
      assert M.correct(m, "T1", Map.put(c, :usage_id, "u2")) == {:error, :conflict}

      assert {:ok, %{effective: 12, amount: 10, corrections: [^c]}} = M.observation(m, "T1", "u1")
      assert {:ok, %{effective: 10, corrections: []}} = M.observation(m, "T1", "u2")

      assert truth(p, "SELECT correction_id, usage_id, revision, amount FROM #{p}.#{@corr}") ==
               [["c1", "u1", 1, 12]]
    end

    test "the stored digests are SHA-256 of the README encoding", %{m: m, p: p} do
      o = obs("u1", %{unit: {:cache_write_tokens, "1h"}, amount: :unknown})
      c = corr("c1", "u1", 7)
      {:ok, :applied} = M.record(m, "T1", o)
      {:ok, :applied} = M.correct(m, "T1", c)

      frame = fn tag, fields ->
        body =
          for {k, v} <- Enum.sort(fields),
              into: "",
              do: <<byte_size(k)::32>> <> k <> <<byte_size(v)::32>> <> v

        :crypto.hash(:sha256, "elzoo.metering." <> tag <> <<0>> <> body)
      end

      expected_obs =
        frame.("observation", [
          {"usage_id", "u1"},
          {"run_id", "run-1"},
          {"operation_id", "op-1"},
          {"attempt_id", "attempt-1"},
          {"provider_id", "anthropic"},
          {"model_id", "model-a"},
          {"unit", "cache_write_tokens:1h"},
          {"amount", "unknown"},
          {"source", "provider_reported"},
          {"period", "2026-11"},
          {"observed_at_ms", "1795000000000"}
        ])

      expected_corr =
        frame.("correction", [
          {"correction_id", "c1"},
          {"usage_id", "u1"},
          {"amount", "7"},
          {"reason", "late usage"},
          {"actor_ref", "ops:1"}
        ])

      assert truth(p, "SELECT digest FROM #{p}.#{@obs}") == [[expected_obs]]
      assert truth(p, "SELECT digest FROM #{p}.#{@corr}") == [[expected_corr]]
    end
  end

  describe "2 concurrency" do
    test "two concurrent records of one usage_id held behind a SHARE lock store one",
         %{m: m, p: p} do
      table = "#{p}.#{@obs}"
      o = obs("u-race")

      waiting = fn ->
        q!(
          AdminRepo,
          "SELECT count(*) FROM pg_locks WHERE relation = to_regclass($1) AND mode = 'RowExclusiveLock' AND NOT granted",
          [table]
        ) == [[2]]
      end

      {:ok, tasks} =
        AdminRepo.transact(fn ->
          q!(AdminRepo, "LOCK TABLE #{table} IN SHARE MODE")
          tasks = for _ <- 1..2, do: Task.async(fn -> M.record(m, "T1", o) end)
          wait_until(waiting)
          {:ok, tasks}
        end)

      assert Enum.sort(Task.await_many(tasks, 10_000)) == [{:ok, :applied}, {:ok, :duplicate}]
      assert truth(p, "SELECT count(*) FROM #{table}") == [[1]]
    end

    test "concurrent corrections queue on the observation row lock in commit order",
         %{m: m, p: p} do
      {:ok, :applied} = M.record(m, "T1", obs("u1"))
      table = "#{p}.#{@obs}"

      # Both callers wait on the row the owner holds FOR UPDATE, then run one after the other.
      held = fn spawn ->
        {:ok, tasks} =
          TI.transact(AdminRepo, %{tenant: "T1"}, fn ->
            [["u1"]] = q!(AdminRepo, "SELECT usage_id FROM #{table} FOR UPDATE")
            tasks = spawn.()

            wait_until(fn ->
              q!(
                AdminRepo,
                "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()"
              ) == [[length(tasks)]]
            end)

            {:ok, tasks}
          end)

        Task.await_many(tasks, 10_000)
      end

      same = corr("c1", "u1", 20)
      results = held.(fn -> for _ <- 1..2, do: Task.async(fn -> M.correct(m, "T1", same) end) end)
      assert Enum.sort(results) == [{:ok, :applied}, {:ok, :duplicate}]

      results =
        held.(fn ->
          for {id, n} <- [{"c2", 30}, {"c3", 40}],
              do: Task.async(fn -> M.correct(m, "T1", corr(id, "u1", n)) end)
        end)

      assert results == [{:ok, :applied}, {:ok, :applied}]
      {:ok, %{effective: effective, corrections: cs}} = M.observation(m, "T1", "u1")
      assert hd(cs) == same
      assert Enum.sort(Enum.map(tl(cs), & &1.correction_id)) == ["c2", "c3"]
      # The effective amount is the latest correction by commit order (revision).
      assert effective == List.last(cs).amount

      assert truth(p, "SELECT correction_id FROM #{p}.#{@corr} ORDER BY revision") ==
               Enum.map(cs, &[&1.correction_id])

      assert truth(p, "SELECT revision FROM #{table}") == [[3]]
    end

    test "of two concurrent corrections the one that commits last is effective, listed last and totalled",
         %{m: m, p: p} do
      # The owner's pending row keys on another observation, so its foreign key never locks
      # the raced row.
      {:ok, :applied} = M.record(m, "T1", obs("u-hold", %{period: "2026-10"}))

      # pg_stat_activity keeps one snapshot per transaction unless it is cleared.
      blocked_by = fn pid ->
        q!(AdminRepo, "SELECT pg_stat_clear_snapshot()")

        q!(
          AdminRepo,
          "SELECT pid, query FROM pg_stat_activity WHERE pg_blocking_pids(pid) = ARRAY[$1::integer]",
          [pid]
        )
      end

      # The first correction takes the row lock, then waits on the key of the owner's
      # uncommitted correction of the same correction_id; the second waits on the row behind
      # the first. The owner rolls back, so the first commits, and only then the second.
      race = fn first, second ->
        {:ok, :applied} = M.record(m, "T1", obs(first.usage_id))

        {:error, {:held, tasks}} =
          TI.transact(AdminRepo, %{tenant: "T1"}, fn ->
            q!(
              AdminRepo,
              "INSERT INTO #{p}.#{@corr} (tenant, correction_id, usage_id, revision, reason, actor_ref, digest) VALUES ('T1', $1, 'u-hold', 1, 'hold', 'owner', $2)",
              [first.correction_id, <<0>>]
            )

            [[owner]] = q!(AdminRepo, "SELECT pg_backend_pid()")
            t1 = Task.async(fn -> M.correct(m, "T1", first) end)
            wait_until(fn -> blocked_by.(owner) != [] end)
            assert [[pid1, "INSERT INTO" <> _]] = blocked_by.(owner)
            t2 = Task.async(fn -> M.correct(m, "T1", second) end)
            wait_until(fn -> blocked_by.(pid1) != [] end)
            assert [[_, "SELECT revision " <> lock]] = blocked_by.(pid1)
            assert lock =~ "FOR UPDATE"
            {:error, {:held, [t1, t2]}}
          end)

        assert Task.await_many(tasks, 10_000) == [{:ok, :applied}, {:ok, :applied}]
        {:ok, %{effective: effective, corrections: cs}} = M.observation(m, "T1", first.usage_id)
        assert cs == [first, second]
        assert effective == second.amount
      end

      # Commit order against correction_id and amount order, then along it: the reverse order
      # of either pair lists, keeps and totals something else.
      race.(corr("c-a2", "u-a", 50), corr("c-a1", "u-a", 30))
      race.(corr("c-b1", "u-b", 7), corr("c-b2", "u-b", 900))

      assert totals!(m, "T1", "2026-11") == [
               %{
                 unit: :output_tokens,
                 source: :provider_reported,
                 known: 930,
                 unknown_count: 0,
                 count: 2
               }
             ]

      assert truth(p, "SELECT usage_id, correction_id, revision FROM #{p}.#{@corr} ORDER BY 1, 3") ==
               [["u-a", "c-a2", 1], ["u-a", "c-a1", 2], ["u-b", "c-b1", 1], ["u-b", "c-b2", 2]]
    end
  end

  describe "3 unknown amounts" do
    test "an unknown amount stays out of known until a correction makes it known", %{m: m} do
      {:ok, :applied} = M.record(m, "T1", obs("k1", %{amount: 7}))
      {:ok, :applied} = M.record(m, "T1", obs("stream-1", %{amount: :unknown}))
      row = %{unit: :output_tokens, source: :provider_reported}

      assert totals!(m, "T1", "2026-11") == [
               Map.merge(row, %{known: 7, unknown_count: 1, count: 2})
             ]

      late = corr("c-late", "stream-1", 5, %{reason: "provider report arrived"})
      assert M.correct(m, "T1", late) == {:ok, :applied}

      assert totals!(m, "T1", "2026-11") == [
               Map.merge(row, %{known: 12, unknown_count: 0, count: 2})
             ]

      back = corr("c-back", "stream-1", :unknown, %{reason: "report withdrawn", actor_ref: "ops:2"})
      assert M.correct(m, "T1", back) == {:ok, :applied}

      assert totals!(m, "T1", "2026-11") == [
               Map.merge(row, %{known: 7, unknown_count: 1, count: 2})
             ]

      assert {:ok, %{amount: :unknown, effective: :unknown, corrections: [^late, ^back]}} =
               M.observation(m, "T1", "stream-1")
    end
  end

  describe "4 unknown usage" do
    test "a correction of an absent or another tenant's usage_id is :unknown_usage", %{m: m, p: p} do
      {:ok, :applied} = M.record(m, "T2", obs("u-t2"))
      assert M.correct(m, "T1", corr("c1", "absent", 1)) == {:error, :unknown_usage}
      assert M.correct(m, "T1", corr("c2", "u-t2", 1)) == {:error, :unknown_usage}
      assert M.observation(m, "T1", "u-t2") == {:error, :unknown_usage}
      assert M.observation(m, "T1", "absent") == {:error, :unknown_usage}
      assert truth(p, "SELECT count(*) FROM #{p}.#{@corr}") == [[0]]
    end
  end

  describe "5 totals" do
    test "units, cache-write units, sources and periods stay in separate rows", %{m: m} do
      for {id, unit, source, amount, period} <- [
            {"a", :output_tokens, :provider_reported, 5, "2026-11"},
            {"b", :output_tokens, :estimated, 7, "2026-11"},
            {"c", :output_tokens, :unknown, :unknown, "2026-11"},
            {"d", {:cache_write_tokens, "5m"}, :provider_reported, 3, "2026-11"},
            {"e", {:cache_write_tokens, "1h"}, :provider_reported, 4, "2026-11"},
            {"f", :cache_read_tokens, :provider_reported, @max, "2026-11"},
            {"g", :cache_read_tokens, :provider_reported, @max, "2026-11"},
            {"h", :output_tokens, :provider_reported, 100, "2026-12"}
          ] do
        changes = %{unit: unit, source: source, amount: amount, period: period}
        {:ok, :applied} = M.record(m, "T1", obs(id, changes))
      end

      row = fn unit, source, known, unknown, count ->
        %{unit: unit, source: source, known: known, unknown_count: unknown, count: count}
      end

      assert totals!(m, "T1", "2026-11") == [
               row.(:cache_read_tokens, :provider_reported, 2 * @max, 0, 2),
               row.(:output_tokens, :estimated, 7, 0, 1),
               row.(:output_tokens, :provider_reported, 5, 0, 1),
               row.(:output_tokens, :unknown, 0, 1, 1),
               row.({:cache_write_tokens, "1h"}, :provider_reported, 4, 0, 1),
               row.({:cache_write_tokens, "5m"}, :provider_reported, 3, 0, 1)
             ]

      assert totals!(m, "T1", "2026-12") == [row.(:output_tokens, :provider_reported, 100, 0, 1)]
      assert totals!(m, "T1", "2027-01") == []
      assert totals!(m, "T2", "2026-11") == []
    end

    test "every unit of integration/ai-model and every cache-write TTL round-trips", %{m: m} do
      units = Usage.units() ++ Enum.map(Usage.ttls(), &{:cache_write_tokens, &1})

      for {unit, i} <- Enum.with_index(units),
          do:
            {:ok, :applied} =
              M.record(m, "T1", obs("u#{i}", %{unit: unit, period: "all", amount: i}))

      rows = totals!(m, "T1", "all")
      assert Enum.map(rows, & &1.unit) == Enum.sort(units)
      assert Enum.all?(rows, &(&1.count == 1))

      for {unit, i} <- Enum.with_index(units),
          do: assert({:ok, %{unit: ^unit, amount: ^i}} = M.observation(m, "T1", "u#{i}"))
    end
  end

  describe "6 row security as the application role" do
    test "verify passes; T1 sees no T2 row; a T2 insert and any DELETE fail 42501",
         %{m: m, p: p, role: role} do
      assert q!(AppRepo, "SELECT current_user") == [[role]]
      floor = [prefix: p, tenant_column: "tenant", space_column: nil]
      assert TI.verify(AppRepo, {p, @obs}, floor) == :ok
      assert TI.verify(AppRepo, {p, @corr}, floor) == :ok

      {:ok, :applied} = M.record(m, "T1", obs("u1", %{amount: 1}))
      {:ok, :applied} = M.record(m, "T2", obs("u2", %{amount: 1000}))
      {:ok, :applied} = M.correct(m, "T1", corr("c1", "u1", 2))
      {:ok, :applied} = M.correct(m, "T2", corr("c2", "u2", 2000))

      assert {:ok, {[["T1", "u1"]], [["T1", "c1"]]}} =
               TI.transact(AppRepo, %{tenant: "T1"}, fn ->
                 {:ok,
                  {q!(AppRepo, "SELECT tenant, usage_id FROM #{p}.#{@obs}"),
                   q!(AppRepo, "SELECT tenant, correction_id FROM #{p}.#{@corr}")}}
               end)

      assert M.observation(m, "T1", "u2") == {:error, :unknown_usage}
      assert [%{known: 2, count: 1}] = totals!(m, "T1", "2026-11")
      # Outside the helper no row is visible: fail closed.
      assert q!(AppRepo, "SELECT count(*) FROM #{p}.#{@obs}") == [[0]]

      insert_t2 = """
      INSERT INTO #{p}.#{@obs} (tenant, usage_id, run_id, operation_id, attempt_id, provider_id,
        model_id, unit, amount, source, period, observed_at_ms, digest, effective, revision)
      VALUES ('T2', 'u9', 'r', 'o', 'a', 'p', 'm', 'output_tokens', 1, 'estimated', '2026-11', 0, '\\x00', 1, 0)
      """

      for sql <- [
            insert_t2,
            "DELETE FROM #{p}.#{@obs} WHERE usage_id = 'u1'",
            "DELETE FROM #{p}.#{@corr} WHERE correction_id = 'c1'",
            "UPDATE #{p}.#{@corr} SET amount = 0 WHERE correction_id = 'c1'"
          ] do
        assert denied?(
                 TI.transact(AppRepo, %{tenant: "T1"}, fn ->
                   SQL.query(AppRepo, sql, [], log: false)
                 end)
               ),
               sql
      end

      assert truth(p, "SELECT tenant, usage_id, effective FROM #{p}.#{@obs} ORDER BY 1") ==
               [["T1", "u1", 2], ["T2", "u2", 2000]]

      assert truth(p, "SELECT count(*) FROM #{p}.#{@corr}") == [[2]]
    end
  end

  describe "7 caller transaction, isolation and failures" do
    def forward_query(_event, _measurements, meta, parent), do: send(parent, {:query, meta.query})

    test "a caller's open transaction gives :in_transaction for every function before any query",
         %{m: m} do
      {:ok, :applied} = M.record(m, "T1", obs("u1"))
      id = {__MODULE__, make_ref()}
      event = [:elzoo, :metering, :app_repo, :query]

      {:ok, results} =
        AppRepo.transact(fn ->
          :telemetry.attach(id, event, &__MODULE__.forward_query/4, self())

          try do
            {:ok,
             [
               M.record(m, "T1", obs("u2")),
               M.correct(m, "T1", corr("c1", "u1", 1)),
               M.totals(m, "T1", %{period: "2026-11", max_rows: 10}),
               M.observation(m, "T1", "u1"),
               M.model_totals(m, "T1", %{period: "2026-11", max_rows: 10}),
               # The shape check comes first.
               M.record(m, "T1", Map.delete(obs("u3"), :amount)),
               M.model_totals(m, "T1", %{period: "2026-11", max_rows: 0})
             ]}
            |> tap(fn _ -> SQL.query!(AppRepo, "SELECT 'probe'", [], log: false) end)
          after
            :telemetry.detach(id)
          end
        end)

      assert results ==
               List.duplicate({:error, :in_transaction}, 5) ++ List.duplicate({:error, :invalid}, 2)

      # The handler is live: the probe is the only query it saw.
      assert_received {:query, "SELECT 'probe'"}
      refute_received {:query, _}
      assert {:ok, %{corrections: []}} = M.observation(m, "T1", "u1")
      assert M.observation(m, "T1", "u2") == {:error, :unknown_usage}
    end

    test "a Repo whose connections default to repeatable read gets :isolation for writes",
         %{m: m, p: p} do
      rr = M.new(repo: RepeatableRepo, prefix: p)
      {:ok, :applied} = M.record(m, "T1", obs("u1"))
      assert M.record(rr, "T1", obs("u2")) == {:error, :isolation}
      assert M.correct(rr, "T1", corr("c1", "u1", 1)) == {:error, :isolation}
      assert M.observation(m, "T1", "u2") == {:error, :unknown_usage}
      assert {:ok, %{effective: 10, corrections: []}} = M.observation(m, "T1", "u1")
      assert truth(p, "SELECT count(*) FROM #{p}.#{@corr}") == [[0]]
    end

    test "a database failure is :unavailable", %{p: p} do
      missing = M.new(repo: AppRepo, prefix: p <> "_absent")
      {:ok, :applied} = M.record(M.new(repo: AppRepo, prefix: p), "T1", obs("u1"))

      assert M.record(missing, "T1", obs("u1")) == {:error, :unavailable}
      assert M.correct(missing, "T1", corr("c1", "u1", 1)) == {:error, :unavailable}
      assert M.totals(missing, "T1", %{period: "2026-11", max_rows: 1}) == {:error, :unavailable}

      assert M.model_totals(missing, "T1", %{period: "2026-11", max_rows: 1}) ==
               {:error, :unavailable}

      assert M.observation(missing, "T1", "u1") == {:error, :unavailable}

      capture_log(fn ->
        {:ok, pid} =
          DownRepo.start_link(
            hostname: "127.0.0.1",
            port: 1,
            database: "elz299_unreachable",
            username: "nobody",
            pool_size: 1,
            queue_target: 20,
            queue_interval: 100,
            connect_timeout: 200,
            log: false
          )

        Process.unlink(pid)
        down = M.new(repo: DownRepo, prefix: p)
        assert M.record(down, "T1", obs("u1")) == {:error, :unavailable}
        assert M.totals(down, "T1", %{period: "2026-11", max_rows: 1}) == {:error, :unavailable}
        Supervisor.stop(pid)
      end)
    end
  end

  describe "8 bounds" do
    # {value, accepted?} for a text bound of max bytes: byte length, UTF-8 and control characters.
    defp texts(max) do
      half = String.duplicate("é", div(max, 2))

      [
        {"", false},
        {"a", true},
        {half, true},
        {String.duplicate("a", max), true},
        {String.duplicate("a", max + 1), false},
        {half <> "a", false},
        {<<0xFF>>, false},
        {"a\u0000", false},
        {"a\u001F", false},
        {"a\u007F", false},
        {"a\u0085", false},
        {"a\u009F", false},
        {"a\u00A0", true},
        {:a, false}
      ]
    end

    defp expect(true, result), do: assert(match?({:ok, _}, result), inspect(result))
    defp expect(false, result), do: assert(result == {:error, :invalid})

    test "observation text fields, the tenant and the record bounds", %{m: m} do
      for {field, max} <- [
            usage_id: 128,
            provider_id: 128,
            model_id: 128,
            period: 128,
            run_id: 200,
            operation_id: 200,
            attempt_id: 200
          ],
          {{value, ok?}, i} <- Enum.with_index(texts(max)) do
        o = if field == :usage_id, do: obs(value), else: obs("#{field}-#{i}", %{field => value})
        expect(ok?, M.record(m, "T1", o))
      end

      for {{value, ok?}, i} <- Enum.with_index(texts(128)),
          do: expect(ok?, M.record(m, value, obs("tenant-#{i}")))

      cases = [
        amount: -1,
        amount: 0,
        amount: @max,
        amount: @max + 1,
        amount: 1.0,
        amount: "1",
        amount: nil,
        observed_at_ms: -1,
        observed_at_ms: 0,
        observed_at_ms: @max,
        observed_at_ms: @max + 1,
        observed_at_ms: :unknown,
        unit: :tokens,
        unit: "output_tokens",
        unit: {:cache_write_tokens, "2h"},
        unit: {:cache_write_tokens},
        unit: {:output_tokens, "5m"},
        source: :reported,
        source: "estimated",
        source: nil
      ]

      for {{field, value}, i} <- Enum.with_index(cases),
          do: expect(accepted?(field, value), M.record(m, "T1", obs("v-#{i}", %{field => value})))

      for bad <- [
            Map.delete(obs("x"), :period),
            Map.put(obs("x"), :extra, 1),
            Map.to_list(obs("x")),
            nil
          ],
          do: assert(M.record(m, "T1", bad) == {:error, :invalid})

      assert M.totals(m, "T1", %{period: "2026-11", max_rows: 1000}) |> elem(0) == :ok
    end

    defp accepted?(:amount, v), do: v in [0, @max]
    defp accepted?(:observed_at_ms, v), do: v in [0, @max]
    defp accepted?(_, _), do: false

    test "correction text fields and amount bounds", %{m: m} do
      {:ok, :applied} = M.record(m, "T1", obs("base"))

      for {field, max} <- [correction_id: 128, actor_ref: 128, reason: 256],
          {{value, ok?}, i} <- Enum.with_index(texts(max)) do
        c =
          if field == :correction_id,
            do: corr(value, "base", 1),
            else: corr("#{field}-#{i}", "base", 1, %{field => value})

        expect(ok?, M.correct(m, "T1", c))
      end

      # usage_id has the 128-byte rule: valid IDs pass the shape check and reach the lookup.
      for {{value, ok?}, i} <- Enum.with_index(texts(128)) do
        result = M.correct(m, "T1", corr("usage-#{i}", value, 1))
        if ok?, do: assert(result == {:error, :unknown_usage}), else: expect(false, result)
        result = M.observation(m, "T1", value)
        if ok?, do: assert(result == {:error, :unknown_usage}), else: expect(false, result)
      end

      for {amount, i} <- Enum.with_index([-1, 0, @max, @max + 1, 2.5, "3", nil]),
          do: expect(amount in [0, @max], M.correct(m, "T1", corr("amount-#{i}", "base", amount)))

      for bad <- [Map.delete(corr("x", "base", 1), :reason), Map.put(corr("x", "base", 1), :x, 1)],
          do: assert(M.correct(m, "T1", bad) == {:error, :invalid})
    end

    test "max_rows and the group limit: exactly max_rows groups pass, one more is :read_limit",
         %{m: m} do
      for {{value, ok?}, _} <- Enum.with_index(texts(128)),
          do: expect(ok?, M.totals(m, "T1", %{period: value, max_rows: 1}))

      for {max_rows, ok?} <- [{0, false}, {1, true}, {1000, true}, {1001, false}, {:all, false}],
          do: expect(ok?, M.totals(m, "T1", %{period: "edge", max_rows: max_rows}))

      for bad <- [%{period: "edge"}, %{period: "edge", max_rows: 1, x: 1}, nil],
          do: assert(M.totals(m, "T1", bad) == {:error, :invalid})

      units = [:output_tokens, :cache_read_tokens, {:cache_write_tokens, "5m"}]

      for {unit, i} <- Enum.with_index(units),
          do: {:ok, :applied} = M.record(m, "T1", obs("g#{i}", %{unit: unit, period: "edge"}))

      assert {:ok, [_, _, _]} = M.totals(m, "T1", %{period: "edge", max_rows: 3})
      assert M.totals(m, "T1", %{period: "edge", max_rows: 2}) == {:error, :read_limit}
      # A second observation of an existing group adds no group.
      {:ok, :applied} = M.record(m, "T1", obs("g9", %{unit: :output_tokens, period: "edge"}))
      assert {:ok, [_, _, _]} = M.totals(m, "T1", %{period: "edge", max_rows: 3})
      {:ok, :applied} = M.record(m, "T1", obs("g3", %{source: :estimated, period: "edge"}))
      assert M.totals(m, "T1", %{period: "edge", max_rows: 3}) == {:error, :read_limit}
      assert {:ok, [_, _, _, _]} = M.totals(m, "T1", %{period: "edge", max_rows: 4})
    end

    test "a 1,025th correction is :read_limit; the observation returns all 1,024 in order",
         %{m: m} do
      {:ok, :applied} = M.record(m, "T1", obs("u1"))
      ids = for i <- 1..1024, do: "c" <> String.pad_leading("#{i}", 4, "0")

      for {id, i} <- Enum.with_index(ids, 1),
          do: {:ok, :applied} = M.correct(m, "T1", corr(id, "u1", i))

      assert M.correct(m, "T1", corr("c1025", "u1", 0)) == {:error, :read_limit}
      # An existing correction_id is still decided before the limit.
      assert M.correct(m, "T1", corr("c1024", "u1", 1024)) == {:ok, :duplicate}
      assert M.correct(m, "T1", corr("c0001", "u1", 9)) == {:error, :conflict}
      {:ok, %{effective: 1024, corrections: cs}} = M.observation(m, "T1", "u1")
      assert Enum.map(cs, & &1.correction_id) == ids
    end

    test "meter, prefix and migration arguments raise the fixed ArgumentError", %{p: p} do
      assert M.record(%{repo: AppRepo, prefix: p}, "T1", obs("u1")) == {:error, :invalid}
      assert M.totals(:meter, "T1", %{period: "x", max_rows: 1}) == {:error, :invalid}

      for opts <- [
            [repo: AppRepo],
            [prefix: p],
            [repo: AppRepo, prefix: p, extra: 1],
            [repo: AppRepo, prefix: "Bad"],
            [repo: AppRepo, prefix: "a-b"],
            [repo: AppRepo, prefix: String.duplicate("a", 64)],
            [repo: nil, prefix: p],
            [repo: "Repo", prefix: p],
            %{repo: AppRepo, prefix: p}
          ],
          do: assert_raise(ArgumentError, @message, fn -> M.new(opts) end)

      assert %M{} = M.new(repo: AppRepo, prefix: String.duplicate("a", 63))

      # Outside a migration runner any queued DDL would fail differently: the raise comes first.
      for bad <- ["Bad", "x;y", "", nil, :p],
          do: assert_raise(ArgumentError, @message, fn -> Migration.install(bad) end)
    end
  end

  describe "9 model totals" do
    defp record_all!(m, tenant, entries) do
      for {id, provider, model, unit, source, amount} <- entries do
        changes = %{provider_id: provider, model_id: model, unit: unit, source: source}
        {:ok, :applied} = M.record(m, tenant, obs(id, Map.put(changes, :amount, amount)))
      end
    end

    defp model_totals!(m, tenant, period, max_rows \\ 1000) do
      {:ok, rows} = M.model_totals(m, tenant, %{period: period, max_rows: max_rows})
      rows
    end

    defp mrow(provider, model, unit, source, known, unknown_count, count) do
      %{
        provider_id: provider,
        model_id: model,
        unit: unit,
        source: source,
        known: known,
        unknown_count: unknown_count,
        count: count
      }
    end

    defp row(unit, source, known, unknown_count, count),
      do: %{unit: unit, source: source, known: known, unknown_count: unknown_count, count: count}

    # Each {unit, source} row of totals/3 is the sum of its provider and model rows.
    defp sums(rows) do
      rows
      |> Enum.group_by(&{&1.unit, &1.source})
      |> Enum.map(fn {{unit, source}, group} ->
        %{
          unit: unit,
          source: source,
          known: Enum.sum_by(group, & &1.known),
          unknown_count: Enum.sum_by(group, & &1.unknown_count),
          count: Enum.sum_by(group, & &1.count)
        }
      end)
      |> Enum.sort_by(&{&1.unit, &1.source})
    end

    test "rows per provider, model, unit and source, with effective amounts, sum to totals/3",
         %{m: m} do
      cw = {:cache_write_tokens, "5m"}

      record_all!(m, "T1", [
        {"a1", "anthropic", "model-a", :output_tokens, :provider_reported, 5},
        {"a2", "anthropic", "model-a", :output_tokens, :provider_reported, 7},
        {"a3", "anthropic", "model-b", :output_tokens, :provider_reported, 100},
        {"a4", "anthropic", "model-b", :output_tokens, :provider_reported, :unknown},
        {"a5", "anthropic", "model-a", :input_uncached_tokens, :estimated, 3},
        {"a6", "anthropic", "model-a", :output_tokens, :unknown, :unknown},
        {"a7", "anthropic", "model-b", :output_tokens, :unknown, 2},
        {"o1", "openai", "model-a", :output_tokens, :provider_reported, 1000},
        {"o2", "openai", "model-a", cw, :estimated, @max},
        {"o3", "openai", "model-a", cw, :estimated, @max}
      ])

      # Another period and another tenant add no row.
      {:ok, :applied} = M.record(m, "T1", obs("x1", %{amount: 9999, period: "2026-12"}))
      {:ok, :applied} = M.record(m, "T2", obs("a1", %{amount: 50_000}))

      before = [
        mrow("anthropic", "model-a", :input_uncached_tokens, :estimated, 3, 0, 1),
        mrow("anthropic", "model-a", :output_tokens, :provider_reported, 12, 0, 2),
        mrow("anthropic", "model-a", :output_tokens, :unknown, 0, 1, 1),
        mrow("anthropic", "model-b", :output_tokens, :provider_reported, 100, 1, 2),
        mrow("anthropic", "model-b", :output_tokens, :unknown, 2, 0, 1),
        mrow("openai", "model-a", :output_tokens, :provider_reported, 1000, 0, 1),
        mrow("openai", "model-a", cw, :estimated, 2 * @max, 0, 2)
      ]

      assert model_totals!(m, "T1", "2026-11") == before
      assert sums(before) == totals!(m, "T1", "2026-11")

      {:ok, :applied} = M.correct(m, "T1", corr("c1", "a6", 40))

      after_correction =
        List.replace_at(before, 2, mrow("anthropic", "model-a", :output_tokens, :unknown, 40, 0, 1))

      assert model_totals!(m, "T1", "2026-11") == after_correction
      assert sums(after_correction) == totals!(m, "T1", "2026-11")

      assert totals!(m, "T1", "2026-11") == [
               row(:input_uncached_tokens, :estimated, 3, 0, 1),
               row(:output_tokens, :provider_reported, 1112, 1, 5),
               row(:output_tokens, :unknown, 42, 0, 2),
               row(cw, :estimated, 2 * @max, 0, 2)
             ]

      assert model_totals!(m, "T1", "2026-12") == [
               mrow("anthropic", "model-a", :output_tokens, :provider_reported, 9999, 0, 1)
             ]
    end

    test "a correction from unknown to known moves into known of its own provider and model row only",
         %{m: m} do
      record_all!(m, "T1", [
        {"b1", "anthropic", "model-a", :output_tokens, :provider_reported, :unknown},
        {"b2", "anthropic", "model-b", :output_tokens, :provider_reported, :unknown},
        {"b3", "openai", "model-b", :output_tokens, :provider_reported, :unknown},
        {"b4", "anthropic", "model-b", :output_tokens, :provider_reported, 4}
      ])

      unchanged = fn model_b ->
        [
          mrow("anthropic", "model-a", :output_tokens, :provider_reported, 0, 1, 1),
          model_b,
          mrow("openai", "model-b", :output_tokens, :provider_reported, 0, 1, 1)
        ]
      end

      model_b = &mrow("anthropic", "model-b", :output_tokens, :provider_reported, &1, &2, 2)
      assert model_totals!(m, "T1", "2026-11") == unchanged.(model_b.(4, 1))

      {:ok, :applied} = M.correct(m, "T1", corr("c1", "b2", 25))
      assert model_totals!(m, "T1", "2026-11") == unchanged.(model_b.(29, 0))
      assert totals!(m, "T1", "2026-11") == [row(:output_tokens, :provider_reported, 29, 2, 4)]

      # The latest correction is the effective amount.
      {:ok, :applied} = M.correct(m, "T1", corr("c2", "b2", 6))
      assert model_totals!(m, "T1", "2026-11") == unchanged.(model_b.(10, 0))
    end

    test "rows sort by provider_id, model_id, unit, source in Erlang term order (bytes)",
         %{m: m} do
      # "xB" sorts before "xa" by bytes; a case-insensitive or locale order puts "xa" first.
      assert "xB" < "xa" and String.downcase("xa") < String.downcase("xB")

      record_all!(m, "T1", [
        {"s1", "xa", "m", :input_uncached_tokens, :estimated, 1},
        {"s2", "xB", "m", :output_tokens, :provider_reported, 2},
        {"s3", "xB", "m", :output_tokens, :estimated, 3},
        {"s4", "xB", "m", {:cache_write_tokens, "1h"}, :estimated, 4},
        {"s5", "xB", "M", :output_tokens, :unknown, 5}
      ])

      assert model_totals!(m, "T1", "2026-11") == [
               mrow("xB", "M", :output_tokens, :unknown, 5, 0, 1),
               mrow("xB", "m", :output_tokens, :estimated, 3, 0, 1),
               mrow("xB", "m", :output_tokens, :provider_reported, 2, 0, 1),
               mrow("xB", "m", {:cache_write_tokens, "1h"}, :estimated, 4, 0, 1),
               mrow("xa", "m", :input_uncached_tokens, :estimated, 1, 0, 1)
             ]
    end

    test "exactly max_rows groups pass, one more is :read_limit", %{m: m} do
      record_all!(m, "T1", [
        {"g1", "anthropic", "model-a", :output_tokens, :provider_reported, 1},
        {"g2", "anthropic", "model-b", :output_tokens, :provider_reported, 1},
        {"g3", "openai", "model-a", :output_tokens, :provider_reported, 1},
        # A second observation of an existing group adds no group.
        {"g4", "openai", "model-a", :output_tokens, :provider_reported, 1}
      ])

      query = &%{period: "2026-11", max_rows: &1}
      assert {:ok, [_, _, _]} = M.model_totals(m, "T1", query.(3))
      assert {:ok, [_, _, _]} = M.model_totals(m, "T1", query.(1000))
      assert M.model_totals(m, "T1", query.(2)) == {:error, :read_limit}
      assert M.model_totals(m, "T1", query.(1)) == {:error, :read_limit}
      # The same observations are one totals/3 group.
      assert {:ok, [%{count: 4}]} = M.totals(m, "T1", query.(1))

      # One grouped query per call, and the database returns at most max_rows + 1 groups.
      id = {__MODULE__, make_ref()}
      event = [:elzoo, :metering, :app_repo, :query]
      :telemetry.attach(id, event, &__MODULE__.forward_result/4, self())

      try do
        assert M.model_totals(m, "T1", query.(1)) == {:error, :read_limit}
      after
        :telemetry.detach(id)
      end

      grouped =
        for {:result, {:ok, %Postgrex.Result{columns: columns} = result}} <- drain([]),
            is_list(columns) and "provider_id" in columns,
            do: result

      assert [%{num_rows: 2}] = grouped
    end

    def forward_result(_event, _measurements, meta, parent),
      do: send(parent, {:result, meta.result})

    defp drain(acc) do
      receive do
        {:result, _} = message -> drain([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "malformed queries are refused before any query; another tenant gives no row",
         %{m: m, p: p} do
      for {value, ok?} <- texts(128),
          do: expect(ok?, M.model_totals(m, "T1", %{period: value, max_rows: 1}))

      for {max_rows, ok?} <- [{0, false}, {1, true}, {1000, true}, {1001, false}, {:all, false}],
          do: expect(ok?, M.model_totals(m, "T1", %{period: "2026-11", max_rows: max_rows}))

      id = {__MODULE__, make_ref()}
      event = [:elzoo, :metering, :app_repo, :query]
      :telemetry.attach(id, event, &__MODULE__.forward_query/4, self())

      try do
        q = %{period: "2026-11", max_rows: 1}

        for {meter, tenant, query} <- [
              {m, "T1", %{period: "2026-11"}},
              {m, "T1", %{max_rows: 1}},
              {m, "T1", Map.put(q, :x, 1)},
              {m, "T1", %{q | max_rows: 0}},
              {m, "T1", %{q | max_rows: 1001}},
              {m, "T1", %{q | max_rows: 1.0}},
              {m, "T1", %{q | period: ""}},
              {m, "T1", %{q | period: String.duplicate("a", 129)}},
              {m, "T1", %{q | period: "a\u0000"}},
              {m, "T1", %{q | period: <<0xFF>>}},
              {m, "T1", Map.to_list(q)},
              {m, "T1", nil},
              {m, "", q},
              {m, String.duplicate("t", 129), q},
              {%{repo: AppRepo, prefix: p}, "T1", q}
            ],
            do: assert(M.model_totals(meter, tenant, query) == {:error, :invalid})

        SQL.query!(AppRepo, "SELECT 'probe'", [], log: false)
      after
        :telemetry.detach(id)
      end

      assert_received {:query, "SELECT 'probe'"}
      refute_received {:query, _}

      {:ok, :applied} = M.record(m, "T2", obs("u1", %{amount: 8}))

      assert model_totals!(m, "T2", "2026-11") == [
               mrow("anthropic", "model-a", :output_tokens, :provider_reported, 8, 0, 1)
             ]

      assert model_totals!(m, "T1", "2026-11") == []
    end
  end
end
