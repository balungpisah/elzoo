# SPDX-License-Identifier: Apache-2.0
# Reduced feasibility probe, not the production HTTP job or a no-rearm proof.
ExUnit.start(seed: 0)

Code.require_file(
  "../../../pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs",
  __DIR__
)

defmodule Elz011Composition.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elz011Composition.ObanMigration do
  use Ecto.Migration
  def up, do: Oban.Migration.up(prefix: prefix())
end

defmodule Elz011Composition.Adapter do
  def failure_tags,
    do: [
      :preflight_unavailable,
      :request_rejected,
      :http_4xx,
      :http_5xx,
      :http_redirect,
      :not_acknowledged,
      :receipt_invalid,
      :transport_timeout,
      :transport_error
    ]

  def schema, do: "probe-v1"
  def validate(b, "probe-v1"), do: if(is_binary(b), do: :ok, else: :error)

  def send_effect(req) do
    send(req.context.parent, {:adapter_enter, self(), req})
    req.context.send.(req)
  end

  def poll(req), do: req.context.poll.(req)
  def authenticate({:no_effect, _}, _), do: :error
  def authenticate({:unknown_to_provider, _}, _), do: :error
  def authenticate({tag, _}, _) when tag in [:pending, :unavailable], do: :ok
  def authenticate(_, _), do: :error
  def validate_result(_, _), do: :error
end

defmodule Elz011Composition.Binding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elz011Composition.Adapter,
    id: "http-probe",
    provider_account: "loopback-origin",
    operation: "publication",
    clock: "ms",
    failures: %{
      preflight_unavailable: {"timed_out", "not_dispatched", "unavailable"},
      request_rejected: {"rejected", "not_dispatched", "permanent"},
      http_4xx: {"failed", "dispatched", "permanent"},
      http_5xx: {"failed", "dispatched", "retryable"},
      http_redirect: {"failed", "dispatched", "unclassified"},
      not_acknowledged: {"unknown", "dispatched", "unclassified"},
      receipt_invalid: {"unknown", "dispatched", "unclassified"},
      transport_timeout: {"timed_out", "unknown", "retryable"},
      transport_error: {"unknown", "unknown", "unavailable"}
    },
    no_send_attestations: [:preflight_unavailable, :request_rejected],
    recovery_grace_ms: 500,
    replay: :none
end

defmodule Elz011Composition.Call do
  def bounded(supervisor, fun, ms) do
    task =
      Task.Supervisor.async(supervisor, fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :call_exception}
        catch
          :exit, _ -> {:error, :call_exit}
        end
      end)

    case Task.yield(task, ms) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, :call_exit}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :call_timeout}
    end
  end
end

defmodule Elz011Composition.Test do
  use ExUnit.Case, async: false
  alias Elz011Composition.{Repo, Binding, Adapter, Call}
  alias Elzoo.EffectIntent, as: I
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.{Postgres, Store}
  import Ecto.Query

  setup_all do
    {:ok, repo} =
      Repo.start_link(url: System.fetch_env!("ELZOO_TEST_DATABASE_URL"), pool_size: 10, log: false)

    Process.unlink(repo)
    prefix = "elz011_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    Repo.query!("CREATE SCHEMA #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(Repo, 1, Elzoo.DurableLog.TestMigration, prefix: prefix, log: false)
    :ok = Ecto.Migrator.up(Repo, 2, Elz011Composition.ObanMigration, prefix: prefix, log: false)

    on_exit(fn ->
      Repo.query!("DROP SCHEMA #{prefix} CASCADE", [], log: false)
      Supervisor.stop(repo)
    end)

    %{prefix: prefix}
  end

  setup c do
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})
    calls = start_supervised!({Task.Supervisor, []}, id: :calls)
    clock = start_supervised!({Agent, fn -> 100 end})
    authority = start_supervised!({Agent, fn -> :fresh end}, id: :authority)
    store = Postgres.store(Repo, prefix: c.prefix, fold: I.fold(Binding), limits: I.limits())

    host = %{
      store:
        Postgres.store(Repo, prefix: c.prefix, fold: StoreHost.fold(), limits: StoreHost.limits()),
      authorize: fn _, gen ->
        if Agent.get(authority, & &1) == :fresh, do: :fresh, else: {:recovered, gen}
      end
    }

    ctx = %{
      parent: self(),
      send: fn _ -> {:error, :transport_error, :unknown} end,
      poll: fn _ -> {:unavailable, :http_404} end
    }

    opts = [
      binding: Binding,
      identity: [
        "t",
        "loopback-origin",
        "http-probe",
        "publication",
        Integer.to_string(System.unique_integer([:positive]))
      ],
      arguments: "{}",
      deadline: 1000,
      clock: fn -> Agent.get(clock, & &1) end,
      store: store,
      host: {StoreHost, host},
      task_supervisor: supervisor,
      adapter_context: ctx
    ]

    %{opts: opts, context: ctx, clock: clock, store: store, authority: authority, calls: calls}
  end

  defp owner(opts), do: start_supervised!({I, opts}, id: make_ref())
  defp eventually(fun, count \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(10)
            eventually(fun, n - 1)
          )
      )

  defp oban(c, queues \\ false) do
    start_supervised!(
      {Oban,
       name: Elz011Composition.Oban,
       repo: Repo,
       prefix: c.prefix,
       queues: queues,
       plugins: false,
       stager: [interval: 50],
       notifier: Oban.Notifiers.PG,
       log: false}
    )

    Elz011Composition.Oban
  end

  test "approved failure map passes the real binding compiler", _ do
    assert {:ok, b} = Elzoo.EffectIntent.Binding.load(Binding)
    assert length(Map.keys(b.failures)) == 9
    assert b.replay == :none
    assert Adapter.authenticate({:unknown_to_provider, :x}, nil) == :error
    assert Adapter.authenticate({:no_effect, :x}, nil) == :error
  end

  test "PostgreSQL Intended deadline and permanent no-send refuse without infinite rearm", c do
    p = owner(c.opts)
    Agent.update(c.clock, fn _ -> 2000 end)
    assert {:ok, :Stop} = I.advance(p, :expire)
    assert {:error, :not_dispatchable} = I.advance(p, :dispatch)
    assert I.status(p).phase == {:Intended, :Fresh, 0}
    Agent.update(c.clock, fn _ -> 100 end)
    ctx = %{c.context | send: fn _ -> {:error, :request_rejected, :permanent} end}

    q =
      owner(
        c.opts
        |> Keyword.put(:identity, ["t", "loopback-origin", "http-probe", "publication", "permanent"])
        |> Keyword.put(:adapter_context, ctx)
      )

    assert {:ok, :dispatched} = I.advance(q, :dispatch)
    eventually(fn -> I.status(q).flags.disarmed end)
    assert {:error, :not_rearmable} = I.advance(q, :rearm)
    assert {:error, :not_rearmable} = I.advance(q, :rearm)
  end

  test "PostgreSQL send/poll collision consumes evidence but never grants no-send", c do
    ctx = %{
      c.context
      | send: fn _ ->
          receive do
            :release -> {:error, :transport_error, :unknown}
          end
        end
    }

    p = owner(Keyword.put(c.opts, :adapter_context, ctx))
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    assert_receive {:adapter_enter, sender, _}, 2000
    before = I.status(p).revision
    assert {:error, :task_start} = I.advance(p, :poll)
    assert I.status(p).revision == before + 1
    assert {:Dispatched, :Fresh, 1} = I.status(p).phase
    send(sender, :release)
    eventually(fn -> I.status(p).revision > before + 1 end)
    assert {:error, :not_rearmable} = I.advance(p, :rearm)
  end

  test "PostgreSQL typed preflight rearm, 404 remains Dispatched, expiry strands", c do
    {:ok, mode} = Agent.start_link(fn -> :preflight_unavailable end)
    ctx = %{c.context | send: fn _ -> {:error, Agent.get(mode, & &1), :probe} end}
    p = owner(Keyword.put(c.opts, :adapter_context, ctx))
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    eventually(fn -> I.status(p).phase == {:Definite, :AdapterNoSend, 1} end)
    assert {:ok, :Stop} = I.advance(p, :rearm)
    Agent.update(mode, fn _ -> :transport_error end)
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    eventually(fn -> I.status(p).revision >= 6 end)
    assert {:ok, :polling} = I.advance(p, :poll)
    eventually(fn -> I.status(p).revision >= 7 end)
    assert {:Dispatched, {:After, :AdapterNoSend}, 2} = I.status(p).phase
    assert {:error, :not_rearmable} = I.advance(p, :rearm)
    Agent.update(c.clock, fn _ -> 1500 end)
    assert {:ok, _} = I.advance(p, :expire)
    assert {:Stranded, 2} = I.status(p).phase
    Agent.stop(mode)
  end

  test "PostgreSQL checkpoint before send, read-only restart and bound host activation", c do
    p = owner(c.opts)
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    assert_receive {:adapter_enter, _, req}, 2000

    assert {:ok, %{sequence: 2}} =
             Store.read(c.store, :latest_checkpoint, [Elzoo.EffectIntent.Model.stream(req.key), 1])

    eventually(fn -> I.status(p).revision >= 3 end)
    GenServer.stop(p)
    q = owner(c.opts)
    refute I.status(q).active
    assert {:error, :read_only} = I.advance(q, :dispatch)
    GenServer.stop(q)
    Agent.update(c.authority, fn _ -> :recover end)
    r = owner(c.opts)
    assert I.status(r).active
    assert {:error, :not_dispatchable} = I.advance(r, :dispatch)
    refute_receive {:adapter_enter, _, _}, 50
  end

  test "pinned Oban retry states on real PostgreSQL preserve ID and uniqueness", c do
    name = oban(c)

    for state <- ~w(available executing scheduled retryable completed discarded cancelled) do
      key = "state-" <> state
      cs = Elzoo.Jobs.changeset("matrix", key, 1)
      assert {:ok, id} = Elzoo.Jobs.enqueue(name, cs)

      Repo.query!("UPDATE #{c.prefix}.oban_jobs SET state=$1, attempt=1 WHERE id=$2", [state, id],
        log: false
      )

      assert {:ok, ^id} = Elzoo.Jobs.enqueue(name, cs)
      assert :ok = Oban.retry_job(name, id)
      expected = if state == "executing", do: "executing", else: "available"
      assert {:ok, {^id, ^expected}} = Elzoo.Jobs.state_by_id(name, id)
      job = Repo.one!(from(j in Oban.Job, prefix: ^c.prefix, where: j.id == ^id))
      assert job.max_attempts == if(state in ["available", "executing"], do: 1, else: 2)
      assert {:ok, [{^id, ^expected}]} = Elzoo.Jobs.states(name, "matrix", key)
    end

    assert :ok = Oban.retry_job(name, 9_000_000_000)
    assert {:ok, :absent} = Elzoo.Jobs.state_by_id(name, 9_000_000_000)
  end

  test "actual Jobs worker exhausts read-only job; existing ID re-wakes after grant without second send",
       c do
    p = owner(c.opts)
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    assert_receive {:adapter_enter, _, req}, 2000
    eventually(fn -> I.status(p).revision >= 3 end)
    GenServer.stop(p)
    recovered = owner(c.opts)
    holder = start_supervised!({Agent, fn -> recovered end}, id: :holder)
    parent = self()

    Elzoo.Jobs.register("probe", %{
      backoff: fn _ -> 0 end,
      perform: fn _ ->
        pid = Agent.get(holder, & &1)

        if I.status(pid).active do
          send(parent, :reactivated_job)
          {:cancel, :probe_done}
        else
          {:error, :owner_unavailable}
        end
      end
    })

    on_exit(fn -> Elzoo.Jobs.unregister("probe") end)
    name = oban(c, probe: 1)
    assert {:ok, id} = Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset("probe", req.key, 1))
    eventually(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "discarded"}} end)
    assert {:Dispatched, _, 1} = I.status(recovered).phase
    GenServer.stop(recovered)
    Agent.update(c.authority, fn _ -> :recover end)
    active = owner(c.opts)
    Agent.update(holder, fn _ -> active end)
    assert {:ok, ^id} = Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset("probe", req.key, 1))
    assert :ok = Oban.retry_job(name, id)
    assert_receive :reactivated_job, 4000
    eventually(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "cancelled"}} end)
    refute_receive {:adapter_enter, _, _}, 50
    Agent.update(c.clock, fn _ -> 1500 end)
    assert {:ok, _} = I.advance(active, :expire)
    assert {:Stranded, 1} = I.status(active).phase
  end

  test "bounded control call timeout does not cancel already queued owner operation", c do
    p = owner(c.opts)
    :ok = :sys.suspend(p)
    assert {:error, :call_timeout} = Call.bounded(c.calls, fn -> I.advance(p, :dispatch) end, 30)
    :ok = :sys.resume(p)
    assert_receive {:adapter_enter, _, _}, 2000
    assert {:Dispatched, _, 1} = I.status(p).phase

    assert {:error, :call_exit} =
             Call.bounded(c.calls, fn -> GenServer.call(:nonexistent_elz011, :x) end, 100)
  end
end
