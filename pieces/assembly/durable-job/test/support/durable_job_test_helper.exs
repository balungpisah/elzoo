# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableJob.UnreachableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableJob.TestMigration do
  use Ecto.Migration

  def up do
    # prefix/0 is Ecto.Migration's: the migrator's :prefix option.
    Oban.Migration.up(prefix: prefix())
    Elzoo.DurableLog.Postgres.Migration.up()
  end
end

defmodule Elzoo.DurableJob.TestHelper do
  @moduledoc false
  import ExUnit.Callbacks
  alias Elzoo.DurableJob
  alias Elzoo.DurableJob.{Run, TestRepo}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Postgres}

  def url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"
  end

  def setup_database! do
    case TestRepo.start_link(url: url!(), pool_size: 20, log: false) do
      {:ok, repo} ->
        Process.unlink(repo)
        # The module that started the Repo stops it: an idle pool must not outlive its module.
        # Stop by name: a test (DJ10) restarts the Repo, and the restarted one is the module's too.
        on_exit(fn ->
          try do
            Supervisor.stop(TestRepo)
          catch
            :exit, _ -> :ok
          end
        end)

      {:error, {:already_started, _}} ->
        :ok
    end

    try do
      TestRepo.query!("select 1", [], log: false)
    rescue
      _ ->
        raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
    end

    prefix = "elzoo_dj_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TestRepo.query!("create schema #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, Elzoo.DurableJob.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(prefix), do: TestRepo.query!("drop schema if exists #{prefix} cascade", [], log: false)

  def store(:memory, _prefix) do
    {:ok, pid} = Memory.start_link(fold: Run.store_fold(), limits: Run.limits())
    Memory.store(pid)
  end

  def store(:postgres, prefix),
    do: Postgres.store(TestRepo, prefix: prefix, fold: Run.store_fold(), limits: Run.limits())

  @doc "Start Oban and the Assembly for a fresh queue; the relay is manual."
  def flow(prefix, backend, opts \\ []) do
    queue = "dj" <> Integer.to_string(System.unique_integer([:positive]))
    store = Keyword.get_lazy(opts, :store, fn -> store(backend, prefix) end)
    oban = String.to_atom("Elzoo.DurableJob.TestOban." <> queue)
    start_oban(oban, prefix, queue, Keyword.get(opts, :oban, []))
    start_job(queue, store, oban, opts)
    %{queue: queue, store: store, oban: oban, prefix: prefix}
  end

  def start_oban(oban, prefix, queue, extra) do
    ensure_pg_scope!()

    base = [
      name: oban,
      repo: TestRepo,
      prefix: prefix,
      queues: [{String.to_atom(queue), 5}],
      stager: [interval: 50],
      notifier: Oban.Notifiers.PG,
      log: false
    ]

    start_supervised!({Oban, Keyword.merge(base, extra)}, id: oban)
  end

  # Oban.Notifiers.PG (2.24.2) calls `:pg.start_link(Oban.Notifiers.PG)` in its
  # init/1, so the first notifier owns the `:pg` scope and the scope dies with
  # it. A notifier started right after that Oban stops can see the dying scope
  # as already started and then exit with :noproc in `:pg.join/3` (DJ11 on PR
  # #57). Precondition for every Oban start here: the scope is registered and
  # unlinked, so no notifier stop can take it down. A linked scope belongs to a
  # notifier; wait for it to exit (bounded) and start the unlinked one.
  @pg_scope Oban.Notifiers.PG

  def ensure_pg_scope! do
    case Process.whereis(@pg_scope) do
      nil ->
        case :pg.start(@pg_scope) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> ensure_pg_scope!()
        end

      pid ->
        case Process.info(pid, :links) do
          {:links, []} -> :ok
          _linked_or_exited -> await_scope_exit!(pid)
        end
    end
  end

  defp await_scope_exit!(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> ensure_pg_scope!()
    after
      5_000 ->
        raise "#{inspect(@pg_scope)} scope #{inspect(pid)} is still linked to a live owner"
    end
  end

  def start_job(queue, store, oban, opts) do
    job_opts =
      [queue: queue, store: store, repo: TestRepo, oban: oban, relay_interval_ms: :manual]
      |> Keyword.merge(
        Keyword.take(opts, [
          :handler,
          :now_ms,
          :test_hook,
          :relay_limit,
          :snooze_s,
          :writer_timeout_ms
        ])
      )

    spec =
      Supervisor.child_spec({DurableJob, job_opts},
        id: {DurableJob, queue},
        restart: Keyword.get(opts, :restart, :permanent)
      )

    start_supervised!(spec)
  end

  def relay!(queue), do: Elzoo.Jobs.Relay.run_once(DurableJob.relay_process(queue))

  def records(store, stream) do
    {:ok, rows, _} = Log.read(store, stream, 1, 1_000)
    Enum.map(rows, &{&1.kind, Jason.decode!(&1.payload)})
  end

  def kinds(store, stream), do: Enum.map(records(store, stream), &elem(&1, 0))

  def oban_state(f, key) do
    case Elzoo.Jobs.state(f.oban, f.queue, key) do
      {:ok, {_, state}} -> state
      {:ok, :absent} -> :absent
    end
  end

  def poll(fun, tries \\ 800) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "poll timeout"
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end

  def phase(f, key) do
    case DurableJob.status(f.queue, key) do
      {:ok, %{phase: phase}} -> phase
      other -> other
    end
  end

  @doc "Hold FOR UPDATE on a stream's head row for `ms` in another process; returns once locked."
  def hold_head_lock(prefix, stream, ms) do
    parent = self()

    task =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          TestRepo.query!(
            "select 1 from #{prefix}.elzoo_log_heads where stream = $1 for update",
            [stream],
            log: false
          )

          send(parent, :head_locked)
          Process.sleep(ms)
        end)
      end)

    receive do
      :head_locked -> task
    after
      5_000 -> raise "head lock not taken"
    end
  end

  @doc "Hold the head lock until the callback has observed the timed-out transaction end."
  def with_head_lock(prefix, stream, fun) do
    parent = self()
    token = make_ref()

    task =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          %{rows: [[backend]]} =
            TestRepo.query!(
              "select pg_backend_pid() from #{prefix}.elzoo_log_heads where stream = $1 for update",
              [stream],
              log: false
            )

          send(parent, {token, :head_locked, backend})
          receive do: ({^token, :release} -> :ok)
        end)
      end)

    try do
      receive do
        {^token, :head_locked, backend} -> fun.(backend)
      after
        5_000 -> raise "head lock not taken"
      end
    after
      send(task.pid, {token, :release})
      {:ok, :ok} = Task.await(task, 20_000)
    end
  end

  @doc "One first-attempt barrier, using the real PostgreSQL Store and linked Writer."
  def writer_timeout_probe(prefix, key, boundary) when boundary in [:blocked, :committed] do
    parent = self()
    token = make_ref()
    once = :atomics.new(2, [])
    mode = {__MODULE__, token}
    controller = start_supervised!({Agent, fn -> nil end}, id: token)

    resume = fn ->
      Agent.update(controller, fn
        nil ->
          nil

        worker ->
          # The controller owns the suspension. Its own termination also
          # releases that count if a failing test tears down the fixture.
          try do
            :erlang.resume_process(worker)
          catch
            :error, :badarg -> :ok
          end

          nil
      end)
    end

    store =
      Postgres.store(TestRepo,
        prefix: prefix,
        fold: Run.store_fold(),
        limits: Run.limits(),
        test_dispatch: fn operation, request, run ->
          if operation == :append and request.expected == 1 and
               String.ends_with?(request.stream, "/" <> key) and
               :atomics.compare_exchange(once, 2, 0, 1) == :ok do
            # The actual GenServer.call has begun. Hold its caller from
            # handling the timeout until the test observes the SQL boundary;
            # neither SQL observation must race the 1_000 ms timer.
            {:links, [worker]} = Process.info(self(), :links)

            :ok =
              Agent.update(controller, fn nil ->
                :erlang.suspend_process(worker)
                worker
              end)

            Process.put(mode, request)

            try do
              if boundary == :blocked do
                # checkout keeps this backend for run/0's real transaction;
                # it does not start a caller transaction or change the Store.
                TestRepo.checkout(fn ->
                  %{rows: [[backend]]} = TestRepo.query!("select pg_backend_pid()", [], log: false)
                  send(parent, {token, :append_backend, self(), backend})
                  run.()
                end)
              else
                run.()
              end
            after
              Process.delete(mode)
            end
          else
            run.()
          end
        end,
        test_hook: fn
          :append, :after_commit_reply, _repo when boundary == :committed ->
            if request = Process.get(mode) do
              %{rows: [["attempt_started", nonce]]} =
                TestRepo.query!(
                  "select kind, nonce from #{prefix}.elzoo_log_records where stream = $1 and sequence = $2",
                  [request.stream, request.target],
                  log: false
                )

              true = nonce == request.nonce
              send(parent, {token, :committed, self(), request})
              # The real Writer call times out while its committed reply is
              # held here. No synthetic indeterminate result is returned.
              receive do: ({^token, :release_reply} -> :ok)
            end

          _, _, _ ->
            :ok
        end
      )

    hook = fn :before_begin, _job ->
      if :atomics.compare_exchange(once, 1, 0, 1) == :ok do
        {:links, links} = Process.info(self(), :links)

        [writer] =
          Enum.filter(links, fn pid ->
            :proc_lib.translate_initial_call(pid) == {Elzoo.DurableLog.Writer, :init, 1}
          end)

        send(parent, {token, :before_begin, self(), writer})
        receive do: ({^token, :begin} -> :ok)
      end

      :ok
    end

    %{store: store, hook: hook, token: token, resume: resume}
  end

  def far, do: System.os_time(:millisecond) + 3_600_000
  def fast, do: [max_attempts: 3, base_backoff_ms: 0, max_backoff_ms: 0]

  @doc "Handler that reports each call and blocks until released with a result."
  def blocking_handler(parent) do
    fn input ->
      send(parent, {:entered, self(), input})

      receive do
        {:release, result} -> result
      end
    end
  end
end
