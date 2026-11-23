# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Room do
  @moduledoc """
  A room as the continuation chain of `delivery/durable-mailbox`: each link is one Run of
  `assembly/run-engine` on its own Unit, whose root pattern is `workflow/turn-policy`.

  `open/3` checks the first start, pins its recipe version, opens the chain and starts the
  first Run. `deliver/3` gives the tip one mail message, only while its Run is idle, or its
  rollover message when the next message's worst case could pass the engine's bounds.
  `wake/3` routes the host's timer. `rollover/3` runs the rollover sequence of a terminal tip
  (result, settlement, pin, the mailbox's atomic step, the successor's start, the old unpin)
  and `resume/3` finishes a start after a crash; every step can be repeated with the same
  request.

  The Piece has no table, process, timer or state of its own; it retries nothing, logs
  nothing and emits no telemetry. Its Needs are in the README.
  """
  alias Elzoo.{DurableMailbox, RecipeStore, RunEngine, TurnPolicy}

  @enforce_keys [
    :mailbox,
    :recipes,
    :principal,
    :turn_policy,
    :start,
    :engine,
    :clock,
    :request_cap,
    :reserve,
    :read_limits
  ]
  defstruct @enforce_keys

  @max_actions 256
  @max_int32 2_147_483_647
  @no_decision ["addressed", "round_robin", "everyone"]
  @own_names ["elzoo.room.start", "elzoo.room.rollover", "elzoo.room.carry"]
  @asked ["elzoo.room.turn", "elzoo.room.decide"]
  @given [
    :permit_new_work,
    :over_cap,
    :invalid_request,
    :invalid_pattern_state,
    :duplicate,
    :applied,
    :incompatible
  ]
  @refused_input [:invalid_input, :invalid_payload, :input_too_large]
  @reserved_prefixes ["mail:", "start:", "rollover:"]
  @segment ~r/\A[A-Za-z0-9._-]+\z/
  @identity ~r/\Arecipe-package-v1:sha256:[0-9a-f]{64}\z/
  @turn_id ~r/\At\/[0-9]+\/[0-9]+\z/

  @doc """
  A room binding from `opts`, exactly `mailbox:`, `recipes:`, `principal:`, `turn_policy:`,
  `start:`, `engine:`, `clock:`, `request_cap:`, `reserve:` and `read_limits:`:
  `{:ok, room}` or `{:error, :invalid_binding}`.
  """
  def new(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    if Enum.sort(keys) == Enum.sort(@enforce_keys) and binding?(Map.new(opts)),
      do: {:ok, struct!(__MODULE__, opts)},
      else: {:error, :invalid_binding}
  end

  def new(_), do: {:error, :invalid_binding}

  @doc "Open the chain `chain_id` with its first start and pin: `{:ok, %{run_id, unit_identity}}`."
  def open(%__MODULE__{} = room, tenant, %{chain_id: chain_id, start: start, pin: pin} = request)
      when map_size(request) == 3 do
    with :ok <- valid(tenant?(tenant) and text?(chain_id, 128) and pin?(pin) and plain?(start)),
         :ok <- first_start(room, start) do
      first = ids(tenant, chain_id, 1)
      opening = Map.merge(first, %{chain_id: chain_id, pin: pin, carry: start})

      case tip(room, tenant, chain_id) do
        {:ok, tip} -> reopen(room, tenant, opening, tip, first)
        {:error, {:mailbox, :unknown_chain}} -> create(room, tenant, opening, first)
        error -> error
      end
    end
  end

  def open(_, _, _), do: {:error, :invalid}

  @doc "Give the tip at most one input: the next mail message, or its rollover message."
  def deliver(%__MODULE__{} = room, tenant, %{chain_id: chain_id} = request)
      when map_size(request) == 1 do
    with :ok <- valid(tenant?(tenant) and text?(chain_id, 128)) do
      case live(room, tenant, chain_id) do
        {:live, tip, host, view} ->
          if idle?(view), do: next(room, tenant, tip, host, view), else: {:ok, :busy}

        other ->
          other
      end
    end
  end

  def deliver(_, _, _), do: {:error, :invalid}

  @doc "The route of the host's `wake` timer: what `deliver/3` does for an idle tip, then a wake."
  def wake(%__MODULE__{} = room, tenant, %{chain_id: chain_id, wake_id: wake_id} = request)
      when map_size(request) == 2 do
    with :ok <- valid(tenant?(tenant) and text?(chain_id, 128) and wake_id?(wake_id)) do
      case live(room, tenant, chain_id) do
        {:live, tip, host, view} ->
          if idle?(view) do
            with {:ok, result} <- next(room, tenant, tip, host, view),
                 {:ok, view} <- status(host.engine),
                 :ok <- give(host.engine, wake_id, %{"kind" => "wake"}, view),
                 do: {:ok, result}
          else
            with :ok <- give(host.engine, wake_id, %{"kind" => "wake"}, view), do: {:ok, :busy}
          end

        other ->
          other
      end
    end
  end

  def wake(_, _, _), do: {:error, :invalid}

  @doc """
  The rollover sequence of a terminal tip, `change` `nil` or `%{pin, ref}`:
  `{:ok, %{seq: successor_seq, carry_kind: :finished | :restarted}}`.
  """
  def rollover(%__MODULE__{} = room, tenant, %{chain_id: chain_id, change: change} = request)
      when map_size(request) == 2 do
    with :ok <- valid(tenant?(tenant) and text?(chain_id, 128) and change?(change)),
         {:ok, tip} <- tip(room, tenant, chain_id),
         {:ok, host} <- engine(room, tenant, tip),
         {:ok, outcome, carry, kind} <- ending(room, tip, host),
         :ok <- settle_claimed(room, tenant, chain_id, host) do
      next = ids(tenant, chain_id, tip.seq + 1)
      pin = if change, do: change.pin, else: tip.pin

      successor = Map.merge(next, %{carry: carry, carry_kind: kind})

      step = %{
        chain_id: chain_id,
        link_seq: tip.seq,
        outcome: outcome,
        successor: successor,
        change: change
      }

      with :ok <- plan_and_pin(room, tenant, tip, next, pin, change),
           {:ok, %{seq: seq}} <- close(room, tenant, step, pin),
           :ok <- pin(room, tenant, pin, next.run_id),
           :ok <- start_run(room, tenant, next, pin, carry),
           :ok <- unpin(room, tenant, tip.pin, tip.run_id),
           do: {:ok, %{seq: seq, carry_kind: kind}}
    end
  end

  def rollover(_, _, _), do: {:error, :invalid}

  @doc "Finish the tip's start and the predecessor's unpin: `{:ok, :live}` or `{:ok, :terminal}`."
  def resume(%__MODULE__{} = room, tenant, %{chain_id: chain_id} = request)
      when map_size(request) == 1 do
    with :ok <- valid(tenant?(tenant) and text?(chain_id, 128)),
         {:ok, tip} <- tip(room, tenant, chain_id),
         {:ok, host} <- started(room, tenant, tip),
         {:ok, view} <- begin(host, tip.run_id, tip.carry),
         :ok <- unpin_predecessor(room, tenant, chain_id, tip),
         do: {:ok, if(view.phase == :terminal, do: :terminal, else: :live)}
  end

  def resume(_, _, _), do: {:error, :invalid}

  ## open/3

  defp first_start(room, start) do
    case TurnPolicy.check_start(room.turn_policy, start) do
      :ok ->
        cond do
          start["link"] != 1 -> {:error, {:invalid_start, :link}}
          start["carry"] != nil -> {:error, {:invalid_start, :carry}}
          not fits?(room, start) -> {:error, :reserve}
          true -> :ok
        end

      {:error, reason} ->
        {:error, {:invalid_start, reason}}
    end
  end

  # An existing chain: the mailbox compares the bytes and writes nothing; no pin.
  defp reopen(room, tenant, opening, tip, first) do
    case DurableMailbox.open(room.mailbox, tenant, opening) do
      {:ok, _} ->
        if tip.seq == 1,
          do:
            with(
              :ok <- start_run(room, tenant, first, opening.pin, opening.carry),
              do: {:ok, first}
            ),
          else: {:ok, first}

      {:error, reason} ->
        {:error, {:mailbox, reason}}
    end
  end

  defp create(room, tenant, opening, first) do
    with :ok <- pin(room, tenant, opening.pin, first.run_id) do
      case DurableMailbox.open(room.mailbox, tenant, opening) do
        {:ok, _} ->
          with :ok <- start_run(room, tenant, first, opening.pin, opening.carry), do: {:ok, first}

        {:error, :conflict} ->
          with :ok <- release_conflict(room, tenant, opening),
               do: {:error, {:mailbox, :conflict}}

        {:error, reason} ->
          {:error, {:mailbox, reason}}
      end
    end
  end

  # A chain that appeared between the read and the open: keep the pin only when its first
  # link holds this Run ID and this pin.
  defp release_conflict(room, tenant, opening) do
    case DurableMailbox.chain(room.mailbox, tenant, %{
           chain_id: opening.chain_id,
           after_seq: nil,
           limit: 1
         }) do
      {:ok, %{links: [%{run_id: run_id, pin: pin} | _]}}
      when run_id == opening.run_id and pin == opening.pin ->
        :ok

      {:ok, _} ->
        unpin(room, tenant, opening.pin, opening.run_id)

      {:error, reason} ->
        {:error, {:mailbox, reason}}
    end
  end

  ## deliver/3 and wake/3

  defp live(room, tenant, chain_id) do
    with {:ok, tip} <- tip(room, tenant, chain_id),
         {:ok, host} <- engine(room, tenant, tip),
         {:ok, view} <- status(host.engine) do
      cond do
        view.phase == :terminal -> {:ok, :terminal}
        view.classification == :configured -> {:error, :not_started}
        true -> {:live, tip, host, view}
      end
    end
  end

  defp idle?(view) do
    view.reconciliation == nil and view.phase == :active and view.generation_closed == false and
      view.stop_pending == nil and Enum.all?(view.slots, fn {_, slot} -> slot.phase == :settled end)
  end

  defp next(room, tenant, tip, host, view) do
    if tip.stopped or threshold?(room, tip, host, view) do
      rollover_message(host, tip, view)
    else
      case DurableMailbox.claim(room.mailbox, tenant, %{chain_id: tip.chain_id}) do
        {:ok, :empty} -> {:ok, :empty}
        {:ok, :stopped} -> rollover_message(host, tip, view)
        {:ok, claimed} -> mail(room, tenant, tip.chain_id, host, view, claimed)
        {:error, reason} -> {:error, {:mailbox, reason}}
      end
    end
  end

  # Before a message: the per-message reserve and the two carry actions must still fit.
  defp threshold?(room, tip, host, view) do
    {actions, requests} = per_message(room, tip.carry)

    map_size(view.slots) + actions + 2 > @max_actions or
      view.request_count + requests + 2 > view.request_cap or
      room.clock.() + room.reserve.deadline_margin_ms >= host.run_deadline
  end

  defp rollover_message(host, tip, view) do
    input = %{
      "kind" => "message",
      "schema_id" => "elzoo.room.rollover",
      "schema_version" => 1,
      "payload" => %{}
    }

    with :ok <- give(host.engine, "rollover:" <> tip.run_id, input, view), do: {:ok, :rollover}
  end

  defp mail(room, tenant, chain_id, host, view, %{message: message, link_seq: seq}) do
    settle = &settle(room, tenant, chain_id, message.message_id, seq, &1)

    if own?(message) do
      settled(settle, {:refused, :invalid_input})
    else
      input = %{
        "kind" => "message",
        "schema_id" => message.name,
        "schema_version" => message.schema_version,
        "payload" => message.payload
      }

      case call(fn ->
             RunEngine.input(
               host.engine,
               "mail:" <> message.message_id,
               typed(input),
               context(view)
             )
           end) do
        {:reply, {:ok, reply}} when reply in [:applied, :duplicate] ->
          with {:ok, after_input} <- status(host.engine),
               do: settled(settle, reading(after_input))

        {:reply, {:error, :input_id_conflict}} ->
          settled(settle, {:refused, :input_id_conflict})

        {:reply, {:error, reason}} when reason in @refused_input ->
          settled(settle, {:refused, :invalid_input})

        other ->
          engine_error(other)
      end
    end
  end

  # Mail that names a room schema, has the form of a turn ID, or whose payload names another
  # message ID is refused and given to no engine.
  defp own?(message) do
    message.name in @own_names or Regex.match?(@turn_id, message.message_id) or
      (message.name == "elzoo.room.message" and
         not (is_map(message.payload) and message.payload["message_id"] == message.message_id))
  end

  defp reading(view) do
    cond do
      Enum.any?(view.slots, fn {_, slot} -> slot.phase != :settled end) -> :applied
      given?(view.classification) -> :applied
      view.classification == :record_size -> {:refused, :record_size}
      true -> {:refused, :unacknowledged}
    end
  end

  defp given?({:request, _}), do: true
  defp given?(classification), do: classification in @given

  defp settled(settle, result) do
    with :ok <- settle.(result),
         do: {:ok, if(result == :applied, do: :delivered, else: result)}
  end

  defp settle(room, tenant, chain_id, message_id, seq, result) do
    case DurableMailbox.settle(room.mailbox, tenant, %{
           chain_id: chain_id,
           message_id: message_id,
           link_seq: seq,
           result: result
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:mailbox, reason}}
    end
  end

  ## rollover/3

  defp ending(room, tip, host) do
    case call(fn -> RunEngine.result(host.engine, host.scope, room.read_limits) end) do
      {:reply, {:pending, :not_completed}} ->
        {:error, :not_terminal}

      {:reply, {:ok, %{schema_id: "elzoo.room.carry", schema_version: 1, payload: carry}}} ->
        if TurnPolicy.check_start(room.turn_policy, carry) == :ok and fits?(room, carry) and
             carry["link"] == tip.seq + 1,
           do: {:ok, "completed", carry, :finished},
           else: restart(room, tip, "completed")

      {:reply, {:ok, %{}}} ->
        restart(room, tip, "completed")

      {:reply, {:terminal, outcome}} when is_atom(outcome) ->
        restart(room, tip, Atom.to_string(outcome))

      {:reply, {:error, reason}} ->
        {:error, {:result, reason}}

      other ->
        engine_error(other)
    end
  end

  # A link that ended without a valid carry restarts from its own start carry, idle.
  defp restart(room, tip, outcome) do
    case TurnPolicy.restart_carry(tip.carry) do
      {:ok, carry} ->
        case TurnPolicy.check_start(room.turn_policy, carry) do
          :ok ->
            if fits?(room, carry),
              do: {:ok, outcome, carry, :restarted},
              else: {:error, {:invalid_start, :reserve}}

          {:error, reason} ->
            {:error, {:invalid_start, reason}}
        end

      {:error, :link_limit} ->
        {:error, :link_limit}

      {:error, :malformed} ->
        {:error, {:invalid_start, :malformed}}
    end
  end

  # A message delivering to the terminal tip (or the oldest pending one) is settled from the
  # tip's own record.
  defp settle_claimed(room, tenant, chain_id, host) do
    case DurableMailbox.claim(room.mailbox, tenant, %{chain_id: chain_id}) do
      {:ok, atom} when atom in [:empty, :stopped] ->
        :ok

      {:ok, %{message: message, link_seq: seq}} ->
        case call(fn -> RunEngine.transcript(host.engine, host.scope, room.read_limits) end) do
          {:reply, {:ok, %{entries: entries}}} ->
            settle(room, tenant, chain_id, message.message_id, seq, recorded(entries, message))

          {:reply, {:error, reason}} ->
            {:error, {:transcript, reason}}

          other ->
            engine_error(other)
        end

      {:error, reason} ->
        {:error, {:mailbox, reason}}
    end
  end

  defp recorded(entries, %{message_id: id}) do
    input_id = "mail:" <> id

    cond do
      not Enum.any?(entries, &(&1.type == :input and &1.input_id == input_id)) ->
        :not_applied

      Enum.any?(entries, fn entry ->
        entry.type == :action and entry.path == [] and entry.schema_id in @asked and
          is_map(entry.payload) and entry.payload["message_id"] == id
      end) ->
        :applied

      true ->
        {:refused, :unacknowledged}
    end
  end

  # (a) remove the pin of an earlier plan of another version, (b) plan, (c) pin.
  defp plan_and_pin(room, tenant, tip, next, pin, change) do
    with :ok <-
           if(tip.planned_pin in [nil, pin],
             do: :ok,
             else: unpin(room, tenant, tip.planned_pin, next.run_id)
           ),
         {:ok, _} <- plan(room, tenant, tip, change),
         do: pin(room, tenant, pin, next.run_id)
  end

  defp plan(room, tenant, tip, change) do
    case DurableMailbox.plan_rollover(room.mailbox, tenant, %{
           chain_id: tip.chain_id,
           link_seq: tip.seq,
           change: change
         }) do
      {:ok, planned} -> {:ok, planned}
      {:error, reason} -> {:error, {:mailbox, reason}}
    end
  end

  # The mailbox's atomic step; a plan replaced after (b) leaves no pin of the room's own.
  defp close(room, tenant, step, pin) do
    case DurableMailbox.rollover(room.mailbox, tenant, step) do
      {:ok, closed} ->
        {:ok, closed}

      {:error, :plan_mismatch} ->
        with :ok <- unpin(room, tenant, pin, step.successor.run_id),
             do: {:error, {:mailbox, :plan_mismatch}}

      {:error, reason} ->
        {:error, {:mailbox, reason}}
    end
  end

  ## Starts

  defp start_run(room, tenant, ids, pin, carry) do
    with {:ok, host} <- start_need(room, tenant, ids, pin),
         {:ok, _view} <- begin(host, ids.run_id, carry),
         do: :ok
  end

  defp started(room, tenant, tip) do
    case room.engine.(tenant, %{unit_identity: tip.unit_identity, run_id: tip.run_id}) do
      {:ok, host} ->
        {:ok, host}

      {:error, :not_started} ->
        with :ok <- pin(room, tenant, tip.pin, tip.run_id),
             do: start_need(room, tenant, tip, tip.pin)

      {:error, reason} ->
        {:error, {:engine, reason}}
    end
  end

  defp start_need(room, tenant, ids, pin) do
    case room.start.(tenant, %{
           unit_identity: ids.unit_identity,
           run_id: ids.run_id,
           pin: pin,
           request_cap: room.request_cap
         }) do
      {:ok, host} -> {:ok, host}
      {:error, reason} -> {:error, {:start, reason}}
    end
  end

  # The start input, when the Run has had none.
  defp begin(host, run_id, carry) do
    with {:ok, view} <- status(host.engine) do
      if view.classification == :configured do
        input = %{
          "kind" => "start",
          "schema_id" => "elzoo.room.start",
          "schema_version" => 1,
          "payload" => carry
        }

        case call(fn ->
               RunEngine.input(host.engine, "start:" <> run_id, typed(input), context(view))
             end) do
          {:reply, {:ok, reply}} when reply in [:applied, :duplicate] -> {:ok, view}
          {:reply, {:error, reason}} -> {:error, {:start, reason}}
          other -> engine_error(other)
        end
      else
        {:ok, view}
      end
    end
  end

  defp unpin_predecessor(_room, _tenant, _chain_id, %{seq: 1}), do: :ok

  defp unpin_predecessor(room, tenant, chain_id, tip) do
    case DurableMailbox.chain(room.mailbox, tenant, %{
           chain_id: chain_id,
           after_seq: if(tip.seq > 2, do: tip.seq - 2),
           limit: 1
         }) do
      {:ok, %{links: [predecessor | _]}} -> unpin(room, tenant, predecessor.pin, predecessor.run_id)
      {:error, reason} -> {:error, {:mailbox, reason}}
    end
  end

  ## Calls

  defp tip(room, tenant, chain_id) do
    case DurableMailbox.chain(room.mailbox, tenant, %{chain_id: chain_id, after_seq: nil, limit: 1}) do
      {:ok, %{tip: tip}} -> {:ok, Map.put(tip, :chain_id, chain_id)}
      {:error, reason} -> {:error, {:mailbox, reason}}
    end
  end

  defp engine(room, tenant, tip) do
    case room.engine.(tenant, %{unit_identity: tip.unit_identity, run_id: tip.run_id}) do
      {:ok, host} -> {:ok, host}
      {:error, :not_started} -> {:error, :not_started}
      {:error, reason} -> {:error, {:engine, reason}}
    end
  end

  defp status(engine) do
    case call(fn -> RunEngine.status(engine) end) do
      {:reply, {:ok, %{reconciliation: nil} = view}} -> {:ok, view}
      {:reply, {:ok, %{reconciliation: halted}}} -> {:error, {:engine, halted}}
      other -> engine_error(other)
    end
  end

  defp give(engine, id, input, view) do
    case call(fn -> RunEngine.input(engine, id, typed(input), context(view)) end) do
      {:reply, {:ok, reply}} when reply in [:applied, :duplicate] -> :ok
      other -> engine_error(other)
    end
  end

  defp engine_error({:reply, {:indeterminate, _}}), do: {:error, {:engine, :indeterminate}}
  defp engine_error({:reply, {:error, reason}}), do: {:error, {:engine, reason}}
  defp engine_error({:reply, other}), do: {:error, {:engine, other}}
  defp engine_error(:no_reply), do: {:error, {:engine, :no_reply}}

  # An exit of an engine call (its 60,000 ms limit, or a dead engine process) is caught.
  defp call(fun) do
    {:reply, fun.()}
  catch
    :exit, _ -> :no_reply
  end

  defp typed(input), do: Map.merge(%{"type" => "input", "version" => 1}, input)
  defp context(view), do: %{run_id: view.run_id, attempt_id: view.attempt_id}

  defp pin(room, tenant, identity, run_id) do
    case RecipeStore.pin(room.recipes, caller(room, tenant), identity, run_id) do
      {:ok, :pinned} -> :ok
      {:error, reason} -> {:error, {:pin, reason}}
    end
  end

  defp unpin(room, tenant, identity, run_id) do
    case RecipeStore.unpin(room.recipes, caller(room, tenant), identity, run_id) do
      {:ok, :unpinned} -> :ok
      {:error, reason} -> {:error, {:unpin, reason}}
    end
  end

  defp caller(room, tenant), do: %{tenant: tenant, principal: room.principal, scopes: []}

  ## The reserve and the IDs

  # The per-message count of the step over the declared worst cases (Q8 A): `d` is 1 for a
  # rule that may ask a decision.
  defp per_message(room, start) do
    turns = start["policy"]["max_bot_turns"]
    decision = if start["policy"]["rule"] in @no_decision, do: 0, else: 1
    %{turn: turn, decision: decide} = room.reserve

    {turns * (2 + turn.actions) + 1 + decision * (1 + decide.actions),
     turns * (2 + turn.requests) + 1 + decision * (1 + decide.requests)}
  end

  defp fits?(room, start) do
    {actions, requests} = per_message(room, start)
    actions + 2 <= @max_actions and requests + 2 <= room.request_cap
  end

  defp ids(tenant, chain_id, seq) do
    hash = Base.encode16(:crypto.hash(:sha256, [tenant, 0, chain_id]), case: :lower)
    id = "room/#{hash}/#{seq}"
    %{run_id: id, unit_identity: id}
  end

  ## Shapes

  defp valid(true), do: :ok
  defp valid(false), do: {:error, :invalid}

  defp binding?(%{reserve: reserve, read_limits: limits} = opts) do
    is_struct(opts.mailbox, DurableMailbox) and is_struct(opts.recipes, RecipeStore) and
      is_binary(opts.principal) and String.valid?(opts.principal) and
      not String.contains?(opts.principal, <<0>>) and turn_policy?(opts.turn_policy) and
      is_function(opts.start, 2) and is_function(opts.engine, 2) and is_function(opts.clock, 0) and
      int?(opts.request_cap, 1, @max_actions) and reserve?(reserve) and limits?(limits)
  end

  defp turn_policy?(%{phase: :new, host_rules: rules}) when is_map(rules), do: true
  defp turn_policy?(_), do: false

  defp reserve?(%{turn: turn, decision: decision, deadline_margin_ms: margin} = reserve)
       when map_size(reserve) == 3,
       do: cost?(turn) and cost?(decision) and int?(margin, 1, @max_int32)

  defp reserve?(_), do: false

  defp cost?(%{actions: actions, requests: requests} = cost) when map_size(cost) == 2,
    do: int?(actions, 0, @max_actions) and int?(requests, 0, @max_actions)

  defp cost?(_), do: false

  defp limits?(%{max_records: records, max_bytes: bytes} = limits) when map_size(limits) == 2,
    do: int?(records, 1, 65_536) and int?(bytes, 1, 536_870_912)

  defp limits?(_), do: false

  defp tenant?(tenant) do
    is_binary(tenant) and byte_size(tenant) in 1..64 and Regex.match?(@segment, tenant) and
      tenant not in [".", ".."]
  end

  defp pin?(pin), do: is_binary(pin) and Regex.match?(@identity, pin)

  defp change?(nil), do: true

  defp change?(%{pin: pin, ref: ref} = change) when map_size(change) == 2,
    do: pin?(pin) and text?(ref, 256)

  defp change?(_), do: false

  defp wake_id?(id),
    do: text?(id, 160) and not String.starts_with?(id, @reserved_prefixes)

  defp plain?(term), do: is_map(term) and not is_struct(term)

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character.
  defp text?(text, max) do
    is_binary(text) and byte_size(text) in 1..max and String.valid?(text) and
      not Enum.any?(String.to_charlist(text), &(&1 < 0x20 or &1 in 0x7F..0x9F))
  end

  defp int?(value, min, max), do: is_integer(value) and value >= min and value <= max
end
