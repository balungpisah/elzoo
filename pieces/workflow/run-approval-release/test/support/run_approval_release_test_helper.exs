# SPDX-License-Identifier: Apache-2.0
sql_helper = Path.expand("durable_log_postgres_test_helper.exs", __DIR__)

sql_helper =
  if File.regular?(sql_helper),
    do: sql_helper,
    else:
      Path.expand(
        "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
        __DIR__
      )

Code.require_file(sql_helper)

defmodule Elzoo.RunApprovalRelease.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RunApprovalRelease.TestAdapter do
  def failure_tags, do: [:timeout]
  def schema, do: "v1"
  def validate("bad", _), do: :error
  def validate(_, "v1"), do: :ok

  def send_effect(req) do
    send(req.context, {:send_started, self(), req})

    receive do
      :send ->
        send(req.context, {:physical_send, req})
        {:error, :timeout, :redacted}

      {:complete, result} ->
        send(req.context, {:physical_send, req})
        result
    end
  end

  def poll(_), do: {:unavailable, "trusted"}
  def authenticate(%{"correlation_id" => id}, req), do: if(id == req.key, do: :ok, else: :error)
  def authenticate(_, _), do: :ok

  def validate_result(%{"value" => value}, req),
    do: if(value["digest"] == req.arguments_digest, do: :ok, else: :error)

  def validate_result(_, _), do: :ok
end

defmodule Elzoo.RunApprovalRelease.TestBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunApprovalRelease.TestAdapter,
    id: "adapter",
    provider_account: "account",
    operation: "send",
    clock: "host-ms",
    failures: %{timeout: {"timed_out", "unknown", "retryable"}},
    recovery_grace_ms: 100
end

defmodule Elzoo.RunApprovalRelease.ChangedTestBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunApprovalRelease.TestAdapter,
    id: "adapter",
    provider_account: "account",
    operation: "send",
    clock: "host-ms",
    failures: %{timeout: {"timed_out", "unknown", "retryable"}},
    recovery_grace_ms: 101
end

defmodule Elzoo.RunApprovalRelease.TestHelper do
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.{Lease, Authorization}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, Store, TestMigration}
  alias Elzoo.EffectIntent.{Binding, Model, StoreHost}

  def setup do
    repo = Elzoo.RunApprovalRelease.TestRepo

    {:ok, repo_pid} =
      repo.start_link(url: PostgresHarness.database_url!(), pool_size: 10, log: false)

    Process.unlink(repo_pid)

    PostgresHarness.reachable!(repo)
    prefix = "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(repo, 1, TestMigration, prefix: prefix, log: false)

    control =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{history: [], host: :fresh, fault: nil} end}
      )

    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    {:ok, binding} = Binding.load(Elzoo.RunApprovalRelease.TestBinding)
    run_store = store(repo, prefix, Run.fold(), Run.limits(), control)
    intent_store = store(repo, prefix, Model.fold(binding), Model.limits(), control)

    host_store =
      Postgres.store(repo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits())

    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, "runs", "owner", 3_600_000)
    supervisor = ExUnit.Callbacks.start_supervised!({Task.Supervisor, []})

    host = %{
      store: host_store,
      authorize: fn _, generation ->
        case Agent.get(control, & &1.host) do
          :fresh -> :fresh
          :recover -> {:recovered, generation}
          :read_only -> :refused
        end
      end
    }

    intents = %{
      "binding" => [
        binding: Elzoo.RunApprovalRelease.TestBinding,
        store: intent_store,
        clock: fn -> Agent.get(control, &Map.get(&1, :now, 2000)) end,
        host: {StoreHost, host},
        task_supervisor: supervisor,
        adapter_context: self()
      ]
    }

    opts = [store: run_store, lease: lease, held: held, effect_intent: intents]

    %{
      repo: repo,
      repo_pid: repo_pid,
      prefix: prefix,
      control: control,
      controller: controller,
      store: run_store,
      intent_store: intent_store,
      lease: lease,
      opts: opts
    }
  end

  def cleanup(c) do
    try do
      PostgresHarness.cleanup(c.controller)

      SQL.query!(c.repo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(c.prefix)} CASCADE", [],
        log: false
      )
    after
      Agent.stop(c.controller)
      Supervisor.stop(c.repo_pid)
    end
  end

  # The ready Store's test-only dispatch seam records commits and interrupts
  # exact append/checkpoint boundaries. No production crash hooks are added.
  defp store(repo, prefix, fold, limits, control) do
    base = Postgres.store(repo, prefix: prefix, fold: fold, limits: limits)
    {module, options} = base

    dispatch = fn op, request, run ->
      fault =
        Agent.get_and_update(control, fn state ->
          case state.fault do
            {^op, stream, expected, mode}
            when stream == request.stream and expected == request.expected ->
              {mode, %{state | fault: nil}}

            _ ->
              {nil, state}
          end
        end)

      result =
        case fault do
          :rejected ->
            {:rejected, :record_too_large}

          :unavailable ->
            {:indeterminate, %{cause: :unavailable}}

          :reply_loss ->
            run.()

          {:pause, parent} ->
            send(parent, {:write_paused, self(), request})

            receive do
              :commit -> run.()
            end

          nil ->
            run.()
        end

      event =
        if op == :append and match?({:committed, _}, result) do
          {:ok, row, _} = Store.read(base, :read_at, [request.stream, request.target])

          case Model.decode_term(row.payload, limits.max_record_bytes) do
            {:ok, event} -> event
            _ -> :lease
          end
        end

      Agent.update(
        control,
        &%{&1 | history: &1.history ++ [{op, request.stream, request.target, event, result}]}
      )

      if fault == :reply_loss, do: {:indeterminate, %{cause: :timeout}}, else: result
    end

    {module, Map.put(options, :test_dispatch, dispatch)}
  end

  def owner(c, opts \\ nil) do
    {:held, held} = Lease.hold(c.lease, "runs", "owner")
    opts = Keyword.put(opts || c.opts, :held, held)
    {:ok, pid} = Run.start_link(opts)
    Process.unlink(pid)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  def restart(c, pid, opts \\ nil) do
    GenServer.stop(pid)
    owner(c, opts)
  end

  def snapshot(pid, run \\ "run") do
    {:ok, snapshot} = Run.status(pid, run)
    snapshot
  end

  def command(pid, kind, fields \\ %{}, run \\ "run") do
    revision =
      case Run.status(pid, run) do
        {:ok, s} -> s.revision
        {:error, :not_found} -> fields[:expected_revision]
      end

    Run.command(pid, Map.merge(%{kind: kind, run_id: run, expected_revision: revision}, fields))
  end

  def create(pid, c, run \\ "run") do
    {:held, held} = Lease.hold(c.lease, "runs", "owner")

    assert {:ok, _, ^run} =
             command(
               pid,
               :create,
               %{
                 operation_id: "operation",
                 provider_refs: %{"provider" => "external"},
                 expected_revision: held.live.revision
               },
               run
             )

    assert snapshot(pid, run).current_attempt == nil
    assert {:ok, _, "attempt-1"} = command(pid, :begin_attempt, %{attempt_id: "attempt-1"}, run)
  end

  def write, do: %{target: "post", field: "state", value: {:text, "published"}}

  def context(scope \\ :once) do
    %{
      now: 2000,
      max_age: 10_000,
      verifiers: ["verifier"],
      run: %{id: "run", root: "run", ancestry: []},
      policy: %{
        id: "policy",
        version: 1,
        content_hash: :binary.copy(<<9>>, 32),
        effect_classes: ["publish"],
        rules: [
          %{
            id: "ask",
            effect_class: "publish",
            verdict: :ask,
            requirement: %{name: "human", version: 1, scope: scope}
          }
        ]
      },
      proposal: %{
        tenant: "tenant",
        resource: "post",
        action_id: "action",
        payload: {:text, "publish"},
        writes: [write()]
      },
      authority: %{proposer: "agent", effect_class: "publish", own: [write()], parent: :none},
      approver: %{identity: "reviewer", authority: [write()]}
    }
  end

  def request(pid, scope \\ :once) do
    ctx = context(scope)
    {:ok, decision} = Authorization.decide(ctx.policy, ctx.proposal, ctx.authority)

    assert {:ok, _, key} =
             command(pid, :approval_request, %{attempt_id: "attempt-1", decision: decision})

    {key, ctx}
  end

  def evidence(key, scope \\ :once),
    do: %{
      verifier: "verifier",
      evidence_id: "evidence",
      reviewer: "reviewer",
      request: key,
      decision: :approve,
      scope: scope,
      issued_at: 1000,
      expiry: 20_000
    }

  def approve(pid, key, scope \\ :once) do
    assert {:ok, _, ^key} =
             command(pid, :approval_evidence, %{
               attempt_id: "attempt-1",
               request_key: key,
               evidence: evidence(key, scope)
             })
  end

  def intent,
    do: %{
      identity: ["tenant", "account", "adapter", "send", "stable-action"],
      arguments: "canonical",
      binding_ref: "binding",
      deadline: 10_000
    }

  def dispatch(pid, key, ctx, intent \\ intent()),
    do:
      command(pid, :dispatch_approved, %{
        attempt_id: "attempt-1",
        request_key: key,
        context: ctx,
        intent: intent
      })

  def release(pid, key, ctx, fields \\ %{}),
    do:
      command(
        pid,
        :release_approved,
        Map.merge(%{attempt_id: "attempt-1", request_key: key, context: ctx}, fields)
      )

  def fault(c, op, stream, expected, mode),
    do: Agent.update(c.control, &%{&1 | fault: {op, stream, expected, mode}})

  def history(c), do: Agent.get(c.control, & &1.history)
  def recover(c), do: Agent.update(c.control, &%{&1 | host: :recover})
  def intent_stream, do: Model.stream(Model.key(intent().identity))

  def committed_evidence(c, data) do
    fold = %{
      initial: nil,
      kinds: %{"evidence" => :state_bearing},
      versions: [1],
      reduce: fn _, _, _, b -> b end
    }

    store = Postgres.store(c.repo, prefix: c.prefix, fold: fold, limits: Run.limits())
    stream = "evidence/" <> Base.encode16(:crypto.strong_rand_bytes(8))

    {:ok, rows, req} =
      Lease.Record.records(stream, 0, [{"evidence", 1, Model.binary(data)}], fold, Run.limits())

    assert {:committed, 1} = Store.write(store, :append, [stream, 0, rows, []], req)
    %{stream: stream, sequence: 1}
  end

  def release_before_intent!(c) do
    h = history(c)

    release =
      Enum.find_index(h, fn
        {:append, "runs", _, {:approval, _, _, _, {:released, _, _}}, {:committed, _}} -> true
        _ -> false
      end)

    admission =
      Enum.find_index(h, fn
        {:append, _, _, {:admit, 1, _, _, _, _, _}, {:committed, _}} -> true
        _ -> false
      end)

    assert is_integer(release) and is_integer(admission) and release < admission
  end

  def approval_state(c) do
    {:ok, rows, head} = Elzoo.DurableLog.read(c.store, "runs", 1, 1000)
    Elzoo.DurableLog.replay(rows, head, Run.fold()).model.approvals
  end
end
