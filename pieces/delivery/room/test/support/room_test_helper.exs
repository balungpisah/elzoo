# SPDX-License-Identifier: Apache-2.0
# The helpers of the composed Pieces: the run-engine fixture, the mailbox Repos and Harness,
# and the recipe-store builders and log hook. A copy may place them next to this file.
for {file, path} <- [
      {"run_engine_test_helper.exs", "../../../../assembly/run-engine/test/support"},
      {"durable_mailbox_test_helper.exs", "../../../durable-mailbox/test/support"},
      {"recipe_store_test_helper.exs", "../../../../state/recipe-store/test/support"}
    ] do
  local = Path.expand(file, __DIR__)

  Code.require_file(
    if File.regular?(local), do: local, else: Path.expand(Path.join(path, file), __DIR__)
  )
end

defmodule Elzoo.Room.TestBot do
  @moduledoc """
  The scripted child callable of a turn or a decision. Its plan is a list of batches, each the
  number of `local_work` actions of one request, then its finish; a batch `{:hold, n}` asks n
  actions whose work waits for `:release` from the test.
  """

  def step(state, %{"kind" => "start", "payload" => payload}),
    do: advance(%{state | id: payload["turn_id"] || payload["decision_id"]})

  def step(%{open: open} = state, %{"kind" => "action_outcome"}) when open > 1,
    do: {:Transition, %{state | open: open - 1}, :none}

  def step(%{open: 1} = state, %{"kind" => "action_outcome"}), do: advance(%{state | open: 0})
  def step(state, _), do: {:Transition, state, :none}

  defp advance(%{plan: [batch | rest]} = state) do
    {count, hold} = if is_tuple(batch), do: {elem(batch, 1), true}, else: {batch, false}
    n = state.asked

    actions =
      for k <- 1..count do
        %{
          "id" => "#{state.id}/w/#{n + k}",
          "kind" => "local_work",
          "schema_id" => "action",
          "schema_version" => 1,
          "payload" => %{"hold" => hold, "turn" => state.id}
        }
      end

    {:Transition, %{state | plan: rest, open: count, asked: n + count}, request(actions)}
  end

  defp advance(%{plan: []} = state) do
    {schema_id, payload} = state.answer

    finish = %{
      "id" => "#{state.id}/done",
      "kind" => "finish",
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }

    {:Transition, %{state | plan: nil}, request([finish])}
  end

  defp request(actions), do: {:some, %{"type" => "request", "version" => 1, "actions" => actions}}

  def work(%{"hold" => true} = payload) do
    if observer = Process.whereis(:room_observer), do: send(observer, {:held, self(), payload})
    receive do: (:release -> payload)
  end

  def work(payload), do: payload
  # The carry binding echoes its payload; a test may shift its link to make it invalid.
  def echo(payload, 0), do: payload
  def echo(payload, shift), do: Map.update!(payload, "link", &(&1 + shift))
end

defmodule Elzoo.Room.StandIn do
  @moduledoc """
  A stand-in for the tip's engine: answers the `Elzoo.RunEngine` calls with the documented
  replies. `script` maps an input ID to a list of steps, each `{reply, view_changes}`, `:die`
  (the process stops without a reply) or `:hang` (no reply); unscripted inputs are applied.
  """
  use GenServer

  def start(view), do: GenServer.start(__MODULE__, view)
  def script(pid, id, steps), do: GenServer.call(pid, {:script, id, steps})
  def inputs(pid), do: GenServer.call(pid, :inputs)
  def set(pid, changes), do: GenServer.call(pid, {:set, changes})

  @impl true
  def init(view) do
    {:ok,
     %{
       view:
         Map.merge(
           %{
             run_id: "run",
             attempt_id: "attempt",
             phase: :active,
             outcome: nil,
             request_cap: 256,
             request_count: 0,
             generation_closed: false,
             stop_pending: nil,
             classification: :configured,
             slots: %{},
             joins: %{},
             reconciliation: nil
           },
           view
         ),
       script: %{},
       inputs: []
     }}
  end

  @impl true
  def handle_call({:script, id, steps}, _, s), do: {:reply, :ok, put_in(s.script[id], steps)}
  def handle_call(:inputs, _, s), do: {:reply, Enum.reverse(s.inputs), s}
  def handle_call({:set, changes}, _, s), do: {:reply, :ok, %{s | view: Map.merge(s.view, changes)}}
  def handle_call(:status, _, s), do: {:reply, {:ok, s.view}, s}

  def handle_call({:input, id, input, context}, from, s) do
    s = %{s | inputs: [{id, input, context} | s.inputs]}

    case Map.get(s.script, id, []) do
      [] ->
        {:reply, {:ok, :applied}, %{s | view: %{s.view | classification: :permit_new_work}}}

      [step | rest] ->
        s = put_in(s.script[id], rest)

        case step do
          :die ->
            {:stop, :normal, s}

          :hang ->
            _ = from
            {:noreply, s}

          {reply, changes} ->
            {:reply, reply, %{s | view: Map.merge(s.view, changes)}}
        end
    end
  end

  def handle_call({kind, _scope, _limits}, _, s) when kind in [:result, :transcript],
    do: {:reply, {:error, :reader_unconfigured}, s}
end

defmodule Elzoo.Room.TestHelper do
  @moduledoc false
  import ExUnit.Assertions
  alias Elzoo.{DurableMailbox, DynamicUnits, RecipeStore, Room, RunEngine, TurnPolicy}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableMailbox.{AdminRepo, AppRepo, Harness}
  alias Elzoo.RecipeStore.TestHelper, as: RS
  alias Elzoo.RunEngine.TestHelper, as: Engine
  alias Elzoo.PayloadSchema

  @message %{
    "type" => "object",
    "required" => ["message_id", "from", "text", "mentions"]
  }

  @schemas ~w(elzoo.room.start elzoo.room.message elzoo.room.rollover elzoo.room.turn
              elzoo.room.answer elzoo.room.decide elzoo.typed-decision.result elzoo.room.post
              elzoo.room.notice elzoo.room.carry elzoo.room.finish)

  ## Services of the test module (setup_all)

  def services! do
    db = Engine.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for process <- [registry, units], do: Process.unlink(process)

    ExUnit.Callbacks.on_exit(fn ->
      for process <- [registry, units, db], Process.alive?(process), do: Supervisor.stop(process)
    end)

    role = Harness.app_role!()
    Harness.start!(AdminRepo, pool_size: 2)
    Harness.start!(AppRepo, pool_size: 4, after_connect: {Harness, :connect, [role, []]})

    # Every mailbox call runs as the application role, which does not bypass row security.
    [[^role, false, false]] =
      Harness.query!(
        AppRepo,
        "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
      ).rows

    role
  end

  ## One room world per test: a mailbox schema, an engine fixture, a recipe store and a host

  @doc """
  Options: `:reserve`, `:request_cap`, `:host_rules`, `:run_deadline` (a function of the link
  sequence), `:messages` (extra mailbox names), `:room_clock`, `:unit` (a function from the
  Unit identity the room asks for to the one the host uses), `:read_limits`.
  """
  def world(role, opts \\ []) do
    Process.register(self(), :room_observer)
    prefix = Harness.install!(AdminRepo, role)
    ExUnit.Callbacks.on_exit(fn -> Harness.drop!(AdminRepo, prefix) end)

    messages =
      Map.merge(
        %{"elzoo.room.message" => %{schema_version: 1, schema: @message}},
        Keyword.get(opts, :messages, %{})
      )

    {:ok, mailbox} =
      DurableMailbox.new([repo: AppRepo, prefix: prefix], %{
        id: "room.mail",
        version: 1,
        max_pending: 64,
        messages: messages
      })

    :ok = DurableMailbox.verify(mailbox)
    {:ok, posts} = Agent.start_link(fn -> [] end)
    {:ok, engines} = Agent.start_link(fn -> %{} end)
    poster = spawn_link(fn -> poster(posts, engines) end)

    c =
      Engine.fixture(
        effect_bindings: %{"effect" => {Elzoo.RunEngine.TestBinding, poster}},
        budget: %{cap: 10_000_000, unit: "credits", id: "budget", incarnation: "sealed"}
      )

    store = RS.memory_store()
    {:ok, hooks} = Agent.start_link(fn -> nil end)

    hook = fn stream, expected, records ->
      case Agent.get(hooks, & &1) do
        nil -> :pass
        fun -> fun.(stream, expected, records)
      end
    end

    %{rs: recipes} = RS.build(store, log_hook: hook)
    %{rs: plain} = RS.build(store)
    tenant = "t-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    caller = RS.caller(tenant, principal: "room")
    versions = for v <- 1..3, do: put!(plain, caller, RS.package(version: "#{v}"))
    {:ok, script} = Agent.start_link(fn -> %{} end)
    {:ok, start_hooks} = Agent.start_link(fn -> nil end)
    {:ok, clock} = Agent.start_link(fn -> nil end)
    {:ok, unit_map} = Agent.start_link(fn -> Keyword.get(opts, :unit, & &1) end)
    {:ok, engine_hooks} = Agent.start_link(fn -> nil end)

    ExUnit.Callbacks.on_exit(fn -> stop_engines(engines) end)

    {:ok, turn_policy} = TurnPolicy.new(%{host_rules: Keyword.get(opts, :host_rules, %{})})

    w = %{
      turn_policy: turn_policy,
      c: c,
      mailbox: mailbox,
      store: store,
      recipes: recipes,
      plain: plain,
      hooks: hooks,
      tenant: tenant,
      caller: caller,
      versions: versions,
      posts: posts,
      script: script,
      engines: engines,
      start_hooks: start_hooks,
      room_clock: clock,
      unit_map: unit_map,
      engine_hooks: engine_hooks,
      opts: opts
    }

    Map.put(w, :room, room(w, turn_policy, opts))
  end

  def room(w, turn_policy, opts) do
    {:ok, room} =
      Room.new(
        mailbox: w.mailbox,
        recipes: w.recipes,
        principal: "room",
        turn_policy: turn_policy,
        start: fn tenant, request -> start_need(w, tenant, request) end,
        engine: fn tenant, request -> engine_need(w, tenant, request) end,
        clock: fn -> Agent.get(w.room_clock, & &1) || Agent.get(w.c.clock, & &1) end,
        request_cap: Keyword.get(opts, :request_cap, 256),
        reserve:
          Keyword.get(opts, :reserve, %{
            turn: %{actions: 2, requests: 2},
            decision: %{actions: 2, requests: 2},
            deadline_margin_ms: 1_000
          }),
        read_limits: Keyword.get(opts, :read_limits, %{max_records: 65_536, max_bytes: 536_870_912})
      )

    room
  end

  defp put!(rs, caller, package) do
    {:ok, identity} = RecipeStore.put(rs, caller, package)
    identity
  end

  # The post and notice bindings: the Effect completes, and the host's sink gives its
  # outcome to the engine through input/4, as an Adapter sink does.
  defp poster(posts, engines) do
    receive do
      {:effect_started, pid, request} ->
        payload = Jason.decode!(request.arguments)
        Agent.update(posts, &[payload | &1])
        send(pid, {:result, %{}})
        action_id = if id = payload["turn_id"], do: id <> "/post", else: payload["notice_id"]

        for {_, %{pid: engine}} <- Agent.get(engines, & &1), is_pid(engine) do
          try do
            {:ok, view} = RunEngine.status(engine)

            for {key, %{action_id: ^action_id, phase: phase}} <- view.slots, phase != :settled do
              context = %{
                run_id: view.run_id,
                attempt_id: view.attempt_id,
                occurrence: key,
                actual: 1,
                dispatch: "dispatched"
              }

              RunEngine.input(
                engine,
                "posted:" <> action_id,
                Engine.result(action_id, %{}),
                context
              )
            end
          catch
            # An engine that the host has stopped (a later link's start) takes no outcome.
            :exit, _ -> :ok
          end
        end

        poster(posts, engines)
    end
  end

  ## The host's Needs

  # The start Need: create and begin the link's Run in the Run owner, then start its engine
  # on its own Unit (the previous link's engine and Unit stop first: the fixture routes
  # offers to one engine). A Run already started returns the same and starts nothing.
  defp start_need(w, _tenant, %{unit_identity: unit, run_id: run_id, pin: pin, request_cap: cap}) do
    if hook = Agent.get(w.start_hooks, & &1), do: hook.(:before, run_id)

    reply =
      Agent.get_and_update(
        w.engines,
        fn engines ->
          case engines[run_id] do
            %{pid: pid} = entry when is_pid(pid) ->
              if Process.alive?(pid),
                do: {{:ok, entry}, engines},
                else: launch(w, engines, unit, run_id, pin, cap)

            _ ->
              launch(w, engines, unit, run_id, pin, cap)
          end
        end,
        120_000
      )

    if hook = Agent.get(w.start_hooks, & &1), do: hook.(:after, run_id)
    reply
  end

  defp launch(w, engines, unit, run_id, pin, cap) do
    for {_, %{pid: pid, unit: old}} <- engines, is_pid(pid) do
      if Process.alive?(pid), do: GenServer.stop(pid)
      _ = DynamicUnits.stop(w.c.directory, old)
    end

    unit = Agent.get(w.unit_map, & &1).(unit)
    ensure_run(w.c, run_id)
    seq = run_id |> String.split("/") |> List.last() |> String.to_integer()
    now = Agent.get(w.c.clock, & &1)
    deadline = Keyword.get(w.opts, :run_deadline, fn _seq, now -> now + 58_000 end).(seq, now)

    case Keyword.get(w.opts, :engine_override) do
      fun when is_function(fun, 2) ->
        entry = fun.(run_id, deadline)

        {{:ok, entry},
         Map.put(engines, run_id, Map.merge(entry, %{pid: entry.engine, unit: unit, pin: pin}))}

      nil ->
        opts =
          Keyword.merge(w.c.opts,
            identity: unit,
            run_id: run_id,
            pattern: {TurnPolicy, :step, w.turn_policy},
            request_cap: cap,
            run_deadline: deadline,
            bindings: bindings(w),
            schemas: schemas(w.c),
            result_reader:
              Keyword.get(w.opts, :result_reader, %{
                evidence_store: w.c.evidence_store,
                retention_count: 1_024
              })
          )
          |> Keyword.reject(fn {key, value} -> key == :result_reader and value == :none end)

        {:ok, pid} = RunEngine.start_link(opts)
        Process.unlink(pid)

        entry = %{
          engine: pid,
          scope: %{tenant: "tenant", principal: "principal", run_id: run_id},
          run_deadline: deadline
        }

        {{:ok, entry},
         Map.put(engines, run_id, Map.merge(entry, %{pid: pid, unit: unit, pin: pin}))}
    end
  end

  defp ensure_run(c, run_id) do
    case Run.status(c.run, run_id) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        {:ok, owner} = Run.status(c.run, "run")

        {:ok, revision, _} =
          Run.command(c.run, %{
            kind: :create,
            run_id: run_id,
            operation_id: "op-" <> run_id,
            provider_refs: %{},
            expected_revision: owner.revision
          })

        {:ok, _, _} =
          Run.command(c.run, %{
            kind: :begin_attempt,
            run_id: run_id,
            attempt_id: "attempt",
            expected_revision: revision
          })

        :ok
    end
  end

  defp engine_need(w, _tenant, %{run_id: run_id}) do
    if hook = Agent.get(w.engine_hooks, & &1), do: hook.(run_id)

    case Agent.get(w.engines, & &1[run_id]) do
      %{engine: engine} = entry ->
        if not is_pid(engine) or Process.alive?(engine),
          do: {:ok, Map.take(entry, [:engine, :scope, :run_deadline])},
          else: {:error, :not_started}

      nil ->
        {:error, :not_started}
    end
  end

  defp stop_engines(engines) do
    if Process.alive?(engines) do
      for {_, %{pid: pid}} <- Agent.get(engines, & &1), is_pid(pid), Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  ## The room's bindings and schemas

  defp bindings(w) do
    # Each slot deadline is 40,000 ms after the action's admission by the fixture clock.
    base =
      Map.new(w.c.opts[:bindings], fn {kind, binding} ->
        facts = fn action ->
          deadline = Agent.get(w.c.clock, & &1) + 40_000
          facts = %{binding.facts.(action) | deadline_ms: deadline}
          if facts[:intent], do: put_in(facts.intent.deadline_ms, deadline), else: facts
        end

        {kind, %{binding | facts: facts}}
      end)

    computation = base["finish"]

    nested = fn kind ->
      %{
        computation
        | facts: fn a -> %{computation.facts.(a) | estimate: 10_000} end,
          result:
            if(kind == :turn,
              do: {"elzoo.room.answer", 1},
              else: {"elzoo.typed-decision.result", 1}
            )
      }
      |> Map.put(:nested, fn action ->
        payload = action["payload"]
        key = if kind == :turn, do: payload["member"], else: :decide
        spec = Agent.get(w.script, &Map.get(&1, key, %{}))

        %{
          budget_id: "nested-" <> action["id"],
          incarnation: "sealed",
          mfa: {Elzoo.Room.TestBot, :step},
          initial_state: %{
            id: nil,
            plan: Map.get(spec, :plan, [1]),
            open: 0,
            asked: 0,
            answer: answer(kind, spec)
          },
          schema_id: action["schema_id"],
          schema_version: 1,
          payload: payload
        }
      end)
    end

    local =
      Map.put(base["local_work"], :work, fn a -> {Elzoo.Room.TestBot, :work, [a["payload"]]} end)

    carry_link = Keyword.get(w.opts, :carry_link, 0)

    carry =
      base["local_work"]
      |> Map.put(:work, fn a -> {Elzoo.Room.TestBot, :echo, [a["payload"], carry_link]} end)
      |> Map.put(:result, {"elzoo.room.carry", 1})

    %{
      base
      | "nested_callable" => %{
          "elzoo.room.turn" => nested.(:turn),
          "elzoo.room.decide" => nested.(:decide)
        },
        "local_work" => %{"action" => local, "elzoo.room.carry" => carry},
        "tool_call" => %{
          "elzoo.room.post" => base["tool_call"],
          "elzoo.room.notice" => base["tool_call"]
        }
    }
  end

  defp answer(:turn, spec),
    do:
      {"elzoo.room.answer",
       %{
         "text" => Map.get(spec, :text, "ok"),
         "mentions" => Map.get(spec, :mentions, []),
         "handoff_to" => nil,
         "escalate" => false
       }}

  defp answer(:decide, spec),
    do:
      {"elzoo.typed-decision.result",
       %{"status" => "decided", "value" => %{"pick" => Map.get(spec, :pick, "several")}}}

  defp schemas(c) do
    Map.merge(
      c.opts[:schemas],
      Map.new(@schemas, fn id ->
        port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
        {:ok, compiled} = PayloadSchema.build(port, %{})
        {{id, 1}, %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, "{}")}}
      end)
    )
  end

  ## Scripts, starts and mail

  @doc "Set the plan of a bot member (or `:decide`): `%{plan: batches, mentions, text, pick}`."
  def script(w, member, spec), do: Agent.update(w.script, &Map.put(&1, member, spec))

  def start(opts \\ []) do
    bots = Keyword.get(opts, :bots, ["bot-a", "bot-b"])

    %{
      "room_id" => "room-1",
      "link" => 1,
      "members" =>
        [%{"id" => "alice", "kind" => "human"}] ++ for(b <- bots, do: %{"id" => b, "kind" => "bot"}),
      "policy" => %{
        "rule" => Keyword.get(opts, :rule, "addressed"),
        "default_member" => Keyword.get(opts, :default_member, nil),
        "max_bot_turns" => Keyword.get(opts, :max_bot_turns, 2),
        "handoff" => "denied",
        "post_to" => "channel-1",
        "window" => %{"messages" => 4, "bytes" => 8_192},
        "rollover" => %{"max_turns" => Keyword.get(opts, :max_turns, 63)}
      },
      "summary" => nil,
      "carry" => nil
    }
  end

  def put(w, chain_id, id, opts \\ []) do
    name = Keyword.get(opts, :name, "elzoo.room.message")

    payload =
      Keyword.get(opts, :payload, %{
        "message_id" => id,
        "from" => Keyword.get(opts, :from, "alice"),
        "text" => Keyword.get(opts, :text, "hello #{id}"),
        "mentions" => Keyword.get(opts, :mentions, [])
      })

    address = Keyword.get(opts, :address, {:chain, chain_id})

    DurableMailbox.put(w.mailbox, w.tenant, %{
      sender: %{kind: :human, id: "alice"},
      address: address,
      message: %{message_id: id, name: name, schema_version: 1, payload: payload}
    })
  end

  def status(w, chain_id, id) do
    {:ok, status} =
      DurableMailbox.status(w.mailbox, w.tenant, %{chain_id: chain_id, message_id: id})

    status
  end

  def chain(w, chain_id) do
    {:ok, chain} =
      DurableMailbox.chain(w.mailbox, w.tenant, %{chain_id: chain_id, after_seq: nil, limit: 256})

    chain
  end

  def ids(w, chain_id, seq) do
    hash = Base.encode16(:crypto.hash(:sha256, [w.tenant, 0, chain_id]), case: :lower)
    "room/#{hash}/#{seq}"
  end

  def engine(w, run_id), do: Agent.get(w.engines, &get_in(&1, [run_id, :engine]))
  def view(w, run_id), do: Engine.view(engine(w, run_id))

  @doc "Wait until the tip's Run is idle or terminal (the engine has no timer of its own)."
  def settle_engine(w, run_id) do
    Engine.wait_for(
      engine(w, run_id),
      fn view ->
        # A request that the engine refused leaves its callable waiting: fail with the view.
        if view.classification == :invalid_request,
          do: flunk("the engine refused a request (invalid_request): #{inspect(view)}")

        view.phase == :terminal or
          (view.phase == :active and Enum.all?(view.slots, fn {_, s} -> s.phase == :settled end))
      end,
      20_000
    )
  end

  def transcript(w, run_id) do
    {:ok, %{entries: entries}} =
      RunEngine.transcript(
        engine(w, run_id),
        %{tenant: "tenant", principal: "principal", run_id: run_id},
        %{max_records: 65_536, max_bytes: 536_870_912}
      )

    entries
  end

  def inputs(w, run_id),
    do: for(%{type: :input, input_id: id} <- transcript(w, run_id), do: id)

  def actions(w, run_id),
    do: for(%{type: :action, path: [], action_id: id} <- transcript(w, run_id), do: id)

  def posts(w), do: Agent.get(w.posts, &Enum.reverse/1)

  ## Recipe store

  @doc "The live pin records of the tenant, as `{identity, run_id}` pairs."
  def pins(w) do
    w.store
    |> RS.rows(RS.stream(w.tenant))
    |> Enum.reduce(MapSet.new(), fn
      {"recipe_pinned", %{"identity" => i, "run_id" => r}}, set -> MapSet.put(set, {i, r})
      {"recipe_unpinned", %{"identity" => i, "run_id" => r}}, set -> MapSet.delete(set, {i, r})
      _, set -> set
    end)
  end

  def pins_of(w, run_id), do: for({i, ^run_id} <- pins(w), do: i)
  def records(w), do: length(RS.rows(w.store, RS.stream(w.tenant)))

  def hook(w, fun), do: Agent.update(w.hooks, fn _ -> fun end)
  def engine_hook(w, fun), do: Agent.update(w.engine_hooks, fn _ -> fun end)

  @doc "The host restarts the tip's engine (a stand-in) from `view`, as after a reconcile."
  def replace_engine(w, run_id, view) do
    {:ok, pid} = Elzoo.Room.StandIn.start(view)

    Agent.update(w.engines, fn engines ->
      update_in(engines[run_id], &%{&1 | engine: pid, pid: pid})
    end)

    pid
  end

  @doc "Give the tip's engine a wake straight, as the host's timer would without the room."
  def raw_wake(w, run_id, id) do
    view = view(w, run_id)

    RunEngine.input(
      engine(w, run_id),
      id,
      %{"type" => "input", "version" => 1, "kind" => "wake"},
      %{run_id: view.run_id, attempt_id: view.attempt_id}
    )
  end

  @doc "Give a claimed mail message straight to the engine: a delivery whose reply was lost."
  def raw_mail(w, run_id, %{message_id: id, name: name, payload: payload}) do
    view = view(w, run_id)

    RunEngine.input(
      engine(w, run_id),
      "mail:" <> id,
      %{
        "type" => "input",
        "version" => 1,
        "kind" => "message",
        "schema_id" => name,
        "schema_version" => 1,
        "payload" => payload
      },
      %{run_id: view.run_id, attempt_id: view.attempt_id}
    )
  end

  def start_hook(w, fun), do: Agent.update(w.start_hooks, fn _ -> fun end)
  def room_clock(w, ms), do: Agent.update(w.room_clock, fn _ -> ms end)
  def clock(w, ms), do: Agent.update(w.c.clock, fn _ -> ms end)

  @doc "Run `fun` in a process of its own; `{:crashed, reason}` when it ends without a result."
  def isolated(fun) do
    task = Task.async(fn -> fun.() end)

    try do
      Task.await(task, 120_000)
    catch
      :exit, reason -> {:crashed, reason}
    end
  end

  @doc """
  A log hook that ends the calling process at the first append that `match` accepts: before
  the append, or (`:after`) once the record is appended.
  """
  def crash_on(w, match, mode \\ :before) do
    {:ok, once} = Agent.start_link(fn -> false end)

    fn stream, expected, records ->
      if match.(records) and Agent.get_and_update(once, &{not &1, true}) do
        if mode == :after do
          {module, _} = w.store
          {:committed, _} = module.append(w.store, stream, expected, records, [])
        end

        Process.exit(self(), :kill)
      else
        :pass
      end
    end
  end

  def kind?(records, kind, run_id \\ nil) do
    Enum.any?(records, fn r ->
      r.kind == kind and (run_id == nil or Jason.decode!(r.payload)["run_id"] == run_id)
    end)
  end

  def assert_settled(w, chain_id, id, state, reason \\ nil) do
    status = status(w, chain_id, id)
    assert {status.state, status.reason} == {state, reason}
  end
end
