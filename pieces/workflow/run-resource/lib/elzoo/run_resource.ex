# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunResource do
  @moduledoc "One Run's serialized, leased resource; authority and provider reconciliation belong to the host."
  use GenServer, restart: :temporary
  alias Elzoo.{Lease, PatternStep, EffectIntent, DurableLog}
  alias Elzoo.DurableLog.Store
  alias Elzoo.EffectIntent.Binding

  @phases [:new, :opening, :open, :closing, :closed]
  @dispositions [:accepted, :queued, :applied, :late]
  @tags [:action, :event, :observation, :dispatch, :control]

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def command(pid, command) do
    GenServer.call(pid, {:command, command})
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, _ -> {:unknown, %{command_id: Map.get(command, :id)}}
  end

  def read(pid, after_seq) do
    GenServer.call(pid, {:read, after_seq})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    with %{lease: %Lease{} = lease, held: held, clock: clock, resource: resource} <- options,
         :ok <-
           if(map_size(options) == 4 and is_function(clock, 0),
             do: :ok,
             else: {:error, :invalid_input}
           ),
         {:ok, descriptor} <- descriptor(resource),
         %{owner: _, live: %{key: _, at: at, until: until}} <- held,
         ttl when ttl > 0 <- div(until - at, 1000),
         s = %{lease: lease, held: held, clock: clock, ttl: ttl, model: nil, entries: []},
         {:ok, s} <- recover(s),
         true <- s.model == nil or s.model["resource"] == descriptor,
         {:ok, s} <- renew(s),
         {:ok, s} <- initialize(s, descriptor) do
      Process.send_after(self(), :renew, max(1, div(ttl, 2)))
      deadline_timer(s)
      {:ok, s}
    else
      false -> {:stop, :incompatible_recovery}
      {:error, :unknown} -> {:stop, :unavailable}
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :invalid_input}
    end
  rescue
    _ -> {:stop, :invalid_input}
  end

  defp initialize(%{model: nil} = s, resource) do
    model = %{
      "resource" => resource,
      "phase" => "new",
      "paused" => false,
      "run_ended" => false,
      "lost" => false,
      "expired" => false,
      "actions" => %{},
      "intents" => %{},
      "active" => nil,
      "waiting" => [],
      "opened" => nil,
      "through" => nil,
      "closed" => nil,
      "accrued" => nil,
      "actual" => nil,
      "budget" => nil,
      "receipts" => %{}
    }

    internal(%{s | model: model}, "initialize", now(s), fn m -> {m, [], [], nil} end)
  end

  defp initialize(s, _) do
    if s.model["phase"] in ["opening", "open", "closing"] do
      internal(s, "recovery", now(s), fn m -> lose(m, now(s)) end)
    else
      {:ok, s}
    end
  end

  @impl true
  def handle_call({:read, cursor}, _, s) when is_integer(cursor) and cursor >= 0 do
    case Store.read(s.lease.store, :head, [s.held.live.key]) do
      {:ok, _} ->
        entries = for e <- s.entries, e["seq"] > cursor, do: entry_view(e, s.model)
        {:reply, {:ok, %{state: view(s.model), entries: entries}}, s}

      _ ->
        {:reply, {:error, :unavailable}, s}
    end
  end

  def handle_call({:read, _}, _, s), do: {:reply, {:error, :invalid_input}, s}

  def handle_call({:command, command}, _, s) do
    case execute(s, command) do
      {reply, s, :stop} -> {:stop, :normal, reply, s}
      {reply, s} -> {:reply, reply, s}
    end
  end

  @impl true
  def handle_info(message, s) when message in [:renew, :deadline] do
    command = %{id: ["timer", s.held.live.revision], at_ms: now(s), body: :tick}

    case execute(s, command, true) do
      {_, s, :stop} ->
        {:stop, :normal, s}

      {_, s} ->
        if message == :renew, do: Process.send_after(self(), :renew, max(1, div(s.ttl, 2)))
        if message == :deadline, do: deadline_timer(s)
        {:noreply, s}
    end
  end

  defp deadline_timer(s) do
    if not s.model["expired"] and s.model["phase"] != "closed" do
      delay = max(0, s.model["resource"]["deadline_ms"] - now(s))
      Process.send_after(self(), :deadline, min(delay, 4_294_967_295))
    end
  end

  defp execute(s, command, internal? \\ false) do
    with {:ok, key, normalized} <- normalize(command, internal?) do
      case s.model["receipts"][Jason.encode!(key)] do
        %{"command" => ^normalized, "receipt" => receipt} -> {receipt_view(receipt), s}
        %{} -> {{:refused, :id_conflict}, s}
        nil -> execute_new(s, command, key, normalized)
      end
    else
      _ -> {{:refused, :invalid_input}, s}
    end
  end

  defp execute_new(s, command, key, normalized) do
    with {:ok, s} <- renew(s),
         {:ok, s} <- expire_first(s, now(s)) do
      case transition(s.model, normalized) do
        {:refused, reason} ->
          {{:refused, reason}, s}

        {m, disposition, effects, inputs, budget} ->
          dispatch? = match?({:dispatch, _, _}, command.body) and disposition == "accepted"

          receipt =
            if dispatch?,
              do: ["unknown", command.id],
              else: ["ok", s.held.live.revision + 1, disposition]

          case commit(s, m, key, normalized, receipt, effects, inputs, budget) do
            {:ok, s} ->
              if dispatch?,
                do: dispatch(s, command, key, normalized),
                else: {receipt_view(receipt), s}

            {:error, reason} ->
              storage_failure(s, reason, command.id)
          end
      end
    else
      {:error, reason} -> storage_failure(s, reason, command.id)
    end
  end

  defp dispatch(s, %{body: {:dispatch, identity, owner}, id: id}, key, normalized) do
    result =
      try do
        EffectIntent.advance(owner, :dispatch)
      catch
        :exit, _ -> :unknown
      end

    receipt =
      case result do
        {:ok, :dispatched} -> ["ok", s.held.live.revision, "accepted"]
        {:error, :read_only} -> ["refused", "read_only"]
        _ -> ["unknown", id]
      end

    # The pre-call reservation survives even if the post-call acknowledgement is lost.
    m =
      if result == {:error, :read_only} do
        put_in(
          s.model,
          ["intents", Jason.encode!(identity), "status"],
          "ready"
        )
      else
        s.model
      end

    with {:ok, s} <- renew(s),
         {:ok, s} <- commit(s, m, key, normalized, receipt, [], [], nil) do
      {receipt_view(receipt), s}
    else
      {:error, reason} -> storage_failure(s, reason, id)
    end
  end

  defp storage_failure(s, :unknown, id), do: {{:unknown, %{command_id: id}}, s, :stop}
  defp storage_failure(s, reason, _), do: {{:error, reason}, s, :stop}

  defp renew(s) do
    key = s.held.live.key

    case Lease.renew(s.lease, s.held.owner, [key], s.ttl) do
      {:renewed, %{held: %{^key => held}}} ->
        {:ok, %{s | held: held}}

      {:renewed, %{refused: refused, errors: errors}} ->
        cond do
          Map.has_key?(refused, key) -> {:error, :ownership_lost}
          match?({:indeterminate, _}, errors[key]) -> {:error, :unknown}
          true -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp expire_first(s, at) do
    if at >= s.model["resource"]["deadline_ms"] and not s.model["expired"] and
         s.model["phase"] != "closed" do
      internal(s, "expiry", at, fn m ->
        {m, effects, inputs, budget} = close(Map.put(m, "expired", true), at, "expired")
        {m, effects, inputs ++ [event(m, at, "expired", nil)], budget}
      end)
    else
      {:ok, s}
    end
  end

  defp internal(s, reason, at, fun) do
    {m, effects, inputs, budget} = fun.(s.model)
    seq = s.held.live.revision + 1
    key = ["control", ["internal", seq]]
    inputs = event_ids(inputs, s.held.live.key, seq)
    commit(s, m, key, [at, [reason]], ["ok", seq, "applied"], effects, inputs, budget)
  end

  defp commit(s, m, key, command, receipt, effects, inputs, budget) do
    seq = s.held.live.revision + 1
    m = put_in(m, ["receipts", Jason.encode!(key)], %{"command" => command, "receipt" => receipt})

    entry = %{
      "seq" => seq,
      "command_id" => key,
      "receipt" => receipt,
      "effects" => effects,
      "inputs" => event_ids(inputs, s.held.live.key, seq),
      "budget_command" => budget
    }

    payload = Jason.encode!(%{"version" => 1, "state" => m, "entry" => entry})

    case Lease.write(s.lease, s.held, [{"run_resource_state", 1, payload}]) do
      {:held, held} -> {:ok, %{s | held: held, model: m, entries: s.entries ++ [entry]}}
      {:fenced, _} -> {:error, :ownership_lost}
      {:indeterminate, _} -> {:error, :unknown}
      _ -> {:error, :unavailable}
    end
  end

  defp recover(s) do
    with {:ok, head} <- Store.read(s.lease.store, :head, [s.held.live.key]),
         true <- head.low_water == 0,
         {:ok, rows} <- rows(s.lease.store, s.held.live.key, 1, head.revision, []),
         replay <- DurableLog.replay(rows, head.revision, s.lease.fold),
         true <- replay.tail == :intact and elem(replay.cursor, 0) == head.revision do
      records =
        for row <- rows, row.kind == "run_resource_state" do
          record = Jason.decode!(row.payload)
          true = Map.keys(record) |> Enum.sort() == ["entry", "state", "version"]
          true = record["version"] == 1
          validate_state!(record["state"])
          validate_entry!(record["entry"], record["state"], row.sequence)
          record
        end

      model = if records == [], do: nil, else: List.last(records)["state"]
      {:ok, %{s | model: model, entries: Enum.map(records, & &1["entry"])}}
    else
      false -> {:error, :incompatible_recovery}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :incompatible_recovery}
  end

  defp rows(_, _, from, head, acc) when from > head, do: {:ok, acc}

  defp rows(store, key, from, head, acc) do
    case DurableLog.read(store, key, from, min(1000, head - from + 1)) do
      {:ok, [_ | _] = batch, _} ->
        rows(store, key, List.last(batch).sequence + 1, head, acc ++ batch)

      _ ->
        {:error, :unavailable}
    end
  end

  defp validate_state!(m) do
    true =
      Enum.sort(Map.keys(m)) ==
        Enum.sort(
          ~w(resource phase paused run_ended lost expired actions intents active waiting opened through closed accrued actual budget receipts)
        )

    true = m["phase"] in ~w(new opening open closing closed)
    for k <- ~w(paused run_ended lost expired), do: true = is_boolean(m[k])
    r = m["resource"]
    b = r["budget"]
    [inc, count] = b["generation"]
    true = Enum.sort(Map.keys(b)) == ~w(budget_id cost_ref generation unit)
    resource = Map.new(r, fn {k, v} -> {String.to_existing_atom(k), v} end)

    {:ok, ^r} =
      descriptor(%{
        resource
        | pause_policy: String.to_existing_atom(r["pause_policy"]),
          close_intent: intent_view(r["close_intent"]),
          budget: %{
            budget_id: b["budget_id"],
            unit: b["unit"],
            cost_ref: b["cost_ref"],
            generation: {inc, count}
          }
      })

    for k <- ~w(opened through closed accrued actual),
        do: true = m[k] == nil or (is_integer(m[k]) and m[k] >= 0)

    true =
      is_map(m["receipts"]) and is_map(m["intents"]) and is_map(m["actions"]) and
        is_list(m["waiting"])

    true = m["active"] == nil or m["actions"][m["active"]]["kind"] == "resource_use"
    true = Enum.uniq(m["waiting"]) == m["waiting"]
    for id <- m["waiting"], do: true = text?(id) and m["actions"][id]["kind"] == "resource_use"
    validate_budget!(m["budget"], r["budget"])

    for {key, receipt} <- m["receipts"] do
      decoded_key = Jason.decode!(key)
      validate_key!(decoded_key)
      true = Enum.sort(Map.keys(receipt)) == ~w(command receipt)
      validate_command!(decoded_key, receipt["command"])
      validate_receipt!(receipt["receipt"])
    end

    for {key, record} <- m["intents"] do
      true = Enum.sort(Map.keys(record)) == ~w(action descriptor kind status)
      {:ok, descriptor} = intent(intent_view(record["descriptor"]))
      true = descriptor == record["descriptor"] and key == intent_key(descriptor)
      true = record["kind"] in ~w(resource_open resource_use resource_close)
      true = record["status"] in ~w(ready reserved resolved)

      true =
        if record["kind"] == "resource_close",
          do: record["action"] == nil and descriptor == r["close_intent"],
          else: text?(record["action"]) and m["actions"][record["action"]]["intent"] == key
    end

    for {id, action} <- m["actions"] do
      true = text?(id) and Enum.sort(Map.keys(action)) == ~w(intent kind outcome request)
      {:ok, checked} = PatternStep.decode(action["request"])
      [a] = PatternStep.encode(checked)["actions"]
      true = a["id"] == id and a["kind"] == action["kind"]
      context = %{run_id: r["run_id"], scope: :owner, resource_names: []}

      descriptor =
        if action["intent"] != nil, do: intent_view(m["intents"][action["intent"]]["descriptor"])

      {:ok, "action", _, ^id} = body({:action, a, context, descriptor}, id, 0)
      tracker = PatternStep.open(checked)

      if action["outcome"] do
        {:ok, outcome} = PatternStep.decode(action["outcome"])
        {:applied, _} = PatternStep.accept(tracker, outcome)
      end
    end

    :ok
  end

  defp validate_key!([tag, id]) do
    true = tag in ~w(action event observation dispatch control)

    true =
      text?(id) or
        (tag == "control" and
           match?(
             [namespace, seq]
             when namespace in ["internal", "timer"] and is_integer(seq) and seq >= 0,
             id
           ))
  end

  defp validate_receipt!(["ok", seq, disposition]) do
    true = is_integer(seq) and seq > 0 and disposition in ~w(accepted queued applied late)
  end

  defp validate_receipt!(["unknown", id]), do: true = text?(id)
  defp validate_receipt!(["refused", "read_only"]), do: :ok

  defp validate_command!(["control", ["internal", _]], [at, [reason]])
       when reason in ~w(initialize recovery expiry) do
    true = Binding.uint?(at)
  end

  defp validate_command!([_, id] = key, [at, durable] = command) do
    restored =
      case durable do
        ["action", request, context, descriptor] ->
          [action] = request["actions"]
          true = Enum.sort(Map.keys(context)) == ~w(resource_names run_id scope)

          {:action, action,
           %{
             run_id: context["run_id"],
             scope: String.to_existing_atom(context["scope"]),
             resource_names: context["resource_names"]
           }, if(descriptor != nil, do: intent_view(descriptor))}

        ["input", input] ->
          {:ok, checked} = PatternStep.decode(input)
          {:input, checked}

        [control] when control in ~w(pause continue tick) ->
          String.to_existing_atom(control)

        ["dispatch", identity] ->
          {:dispatch, identity, self()}

        ["observed", identity, ["completed", data]] ->
          {:observed, identity, {:completed, data}}

        ["observed", identity, ["unknown", data]] ->
          {:observed, identity, {:unknown, data}}

        ["observed", identity, ["failed", dispatch, data]] ->
          {:observed, identity, {:failed, String.to_existing_atom(dispatch), data}}

        ["event", event_id, data] ->
          {:event, event_id, data}
      end

    {:ok, ^key, ^command} = normalize(%{id: id, at_ms: at, body: restored}, is_list(id))
  end

  defp validate_budget!(nil, _), do: :ok

  defp validate_budget!([kind, b], resource_budget) do
    true = kind in ~w(settle release)

    true =
      Enum.sort(Map.keys(b)) ==
        if(kind == "settle", do: ~w(actual cost_ref generation), else: ~w(cost_ref generation))

    true =
      b["cost_ref"] == resource_budget["cost_ref"] and
        b["generation"] == resource_budget["generation"]

    true = kind == "release" or (is_integer(b["actual"]) and b["actual"] > 0)
  end

  defp validate_entry!(e, m, seq) do
    true = Enum.sort(Map.keys(e)) == ~w(budget_command command_id effects inputs receipt seq)
    true = e["seq"] == seq
    validate_key!(e["command_id"])
    validate_receipt!(e["receipt"])
    true = m["receipts"][Jason.encode!(e["command_id"])]["receipt"] == e["receipt"]
    true = is_list(e["effects"]) and is_list(e["inputs"])

    for effect <- e["effects"] do
      {:ok, ^effect} = intent(intent_view(effect))
      true = m["intents"][intent_key(effect)]["descriptor"] == effect
    end

    for input <- e["inputs"] do
      {:ok, checked} = PatternStep.decode(input)
      true = PatternStep.encode(checked) == input and input["type"] == "input"
      true = input["kind"] in ~w(action_outcome resource_event)
      true = input["schema_id"] == "elzoo.run-resource.result" and input["schema_version"] == 1
      p = input["payload"]

      true =
        Enum.sort(Map.keys(p)) ==
          if(input["kind"] == "resource_event",
            do: ~w(data event_id reason resource_name run_id),
            else: ~w(data reason resource_name run_id)
          )

      true =
        p["run_id"] == m["resource"]["run_id"] and p["resource_name"] == m["resource"]["name"] and
          text?(p["reason"])

      true = input["kind"] != "resource_event" or text?(p["event_id"])
    end

    validate_budget!(e["budget_command"], m["resource"]["budget"])
    true = e["budget_command"] == nil or e["budget_command"] == m["budget"]
  end

  defp transition(m, [at, ["action", request, context, intent]]) do
    action = hd(request["actions"])
    id = action["id"]
    kind = action["kind"]
    resource = m["resource"]
    payload = action["payload"]

    cond do
      context["run_id"] != resource["run_id"] or payload["run_id"] != resource["run_id"] ->
        {:refused, :wrong_run}

      payload["resource_name"] != resource["name"] ->
        {:refused, :missing_name_grant}

      kind == "resource_use" and context["scope"] == "nested" and
          resource["name"] not in context["resource_names"] ->
        {:refused, :missing_name_grant}

      kind != "resource_close" and m["phase"] == "closed" ->
        {:refused, :closed}

      kind != "resource_close" and (m["run_ended"] or m["phase"] == "closing") ->
        {:refused, :closing}

      kind != "resource_close" and m["paused"] ->
        {:refused, :paused}

      kind == "resource_open" and m["phase"] != "new" ->
        {:refused, :not_open}

      kind == "resource_use" and m["phase"] != "open" ->
        {:refused, :not_open}

      kind == "resource_use" and m["active"] != nil and
          length(m["waiting"]) >= resource["max_waiting"] ->
        {:refused, :queue_full}

      intent != nil and
          (intent["deadline_ms"] <= at or intent["identity"] == resource["close_intent"]["identity"] or
             Map.has_key?(m["intents"], intent_key(intent))) ->
        {:refused, :invalid_input}

      true ->
        a = %{
          "request" => request,
          "outcome" => nil,
          "kind" => kind,
          "intent" => if(intent, do: intent_key(intent))
        }

        m = put_in(m, ["actions", id], a)

        case kind do
          "resource_close" ->
            {m, effects, inputs, budget} = close(m, at, "closed")
            {m, "accepted", effects, inputs, budget}

          "resource_open" ->
            m = m |> Map.put("phase", "opening") |> add_intent(intent, id, kind)
            {m, "accepted", [intent], [], nil}

          "resource_use" ->
            m = add_intent(m, intent, id, kind)

            if m["active"] == nil do
              {Map.put(m, "active", id), "accepted", [intent], [], nil}
            else
              {Map.update!(m, "waiting", &(&1 ++ [id])), "queued", [], [], nil}
            end
        end
    end
  end

  defp transition(m, [at, ["input", input]]) do
    if input["payload"]["run_id"] != m["resource"]["run_id"] do
      {:refused, :wrong_run}
    else
      {m, effects, inputs, budget} = close(Map.put(m, "run_ended", true), at, "closed")
      {m, "applied", effects, inputs, budget}
    end
  end

  defp transition(m, [at, ["pause"]]) do
    m = Map.put(m, "paused", true)

    if m["resource"]["pause_policy"] == "close" do
      {m, effects, inputs, budget} = close(m, at, "closed")
      {m, "applied", effects, inputs, budget}
    else
      {usage(m, at), "applied", [], [], nil}
    end
  end

  defp transition(m, [at, ["continue"]]) do
    {m, effects} = dequeue(Map.put(m, "paused", false))
    {usage(m, at), "applied", effects, [], nil}
  end

  defp transition(m, [at, ["tick"]]), do: {usage(m, at), "applied", [], [], nil}

  defp transition(m, [at, ["dispatch", identity]]) do
    key = Jason.encode!(identity)

    case m["intents"][key] do
      nil ->
        {m, "late", [], [], nil}

      record ->
        cond do
          record["status"] != "ready" -> {m, "late", [], [], nil}
          not dispatchable?(m, key) -> {:refused, dispatch_refusal(m)}
          record["descriptor"]["deadline_ms"] <= at -> {:refused, :closing}
          true -> {put_in(m, ["intents", key, "status"], "reserved"), "accepted", [], [], nil}
        end
    end
  end

  defp transition(m, [at, ["observed", identity, observation]]) do
    key = Jason.encode!(identity)

    case m["intents"][key] do
      nil ->
        {m, "late", [], [], nil}

      record ->
        settled? = record["action"] != nil and m["actions"][record["action"]]["outcome"] != nil

        if settled? and hd(observation) != "completed" and
             not match?(["failed", "not_dispatched", _], observation),
           do: {m, "late", [], [], nil},
           else: observe(m, key, record, observation, at)
    end
  end

  defp transition(m, [at, ["event", id, data]]) do
    if m["run_ended"],
      do: {m, "late", [], [], nil},
      else: {usage(m, at), "applied", [], [event(m, at, "provider_event", data, id)], nil}
  end

  defp add_intent(m, descriptor, id, kind) do
    put_in(m, ["intents", intent_key(descriptor)], %{
      "descriptor" => descriptor,
      "action" => id,
      "kind" => kind,
      "status" => "ready"
    })
  end

  defp dispatchable?(m, key) do
    r = m["intents"][key]

    case r["kind"] do
      "resource_close" -> m["phase"] == "closing"
      "resource_open" -> m["phase"] == "opening" and not m["paused"] and not m["lost"]
      "resource_use" -> m["phase"] == "open" and not m["paused"] and m["active"] == r["action"]
    end
  end

  defp dispatch_refusal(m) do
    cond do
      m["phase"] == "closed" -> :closed
      m["phase"] == "closing" -> :closing
      m["paused"] -> :paused
      true -> :not_open
    end
  end

  defp observe(m, key, record, ["completed", data], at) do
    case record["kind"] do
      "resource_close" ->
        if lifetime?(m, data, at, true) do
          if m["phase"] == "closed" do
            {m, "late", [], [], nil}
          else
            m =
              m
              |> Map.put("opened", data["opened_at_ms"])
              |> Map.put("closed", data["closed_at_ms"])

            {m, inputs} = settle_all(m, at, "resource_lost", "completed")
            {m, budget} = accounting(Map.put(m, "phase", "closed"))
            m = m |> Map.put("active", nil) |> Map.put("waiting", [])
            {m, "applied", [], inputs ++ [event(m, at, "closed", nil)], budget}
          end
        else
          {:refused, :invalid_input}
        end

      "resource_open" ->
        if lifetime?(m, data, at, false) do
          m = Map.put(m, "opened", data["opened_at_ms"])
          m = put_in(m, ["intents", key, "status"], "resolved")
          {m, inputs} = settle(m, record["action"], "completed", data, at)
          m = if m["phase"] == "opening" and not m["lost"], do: Map.put(m, "phase", "open"), else: m
          {usage(m, at), "applied", [], inputs, nil}
        else
          {:refused, :invalid_input}
        end

      "resource_use" ->
        {m, inputs} = settle(m, record["action"], "completed", data, at)
        m = put_in(m, ["intents", key, "status"], "resolved")
        m = if m["active"] == record["action"], do: Map.put(m, "active", nil), else: m
        {m, effects} = dequeue(m)
        {usage(m, at), "applied", effects, inputs, nil}
    end
  end

  defp observe(m, key, record, observation, at) do
    {outcome, dispatch, data} =
      case observation do
        ["unknown", data] -> {"unknown", "unknown", data}
        ["failed", dispatch, data] -> {"failed", dispatch, data}
      end

    {m, inputs} =
      if record["kind"] == "resource_close" do
        Enum.reduce(m["actions"], {m, []}, fn {id, a}, {m, inputs} ->
          if a["kind"] == "resource_close" do
            {m, added} = settle(m, id, outcome, data, at)
            {m, inputs ++ added}
          else
            {m, inputs}
          end
        end)
      else
        settle(m, record["action"], outcome, data, at)
      end

    cond do
      record["kind"] == "resource_open" and dispatch == "not_dispatched" and m["phase"] == "opening" ->
        {m, budget} = release(Map.put(m, "phase", "closed"))
        {m, "applied", [], inputs, budget}

      record["kind"] == "resource_open" and m["phase"] != "closed" ->
        {m, effects, lost_inputs, budget} = lose(m, at)
        {m, "applied", effects, inputs ++ lost_inputs, budget}

      record["kind"] == "resource_use" and dispatch == "not_dispatched" ->
        m = put_in(m, ["intents", key, "status"], "resolved")
        m = if m["active"] == record["action"], do: Map.put(m, "active", nil), else: m
        {m, effects} = dequeue(m)
        {usage(m, at), "applied", effects, inputs, nil}

      true ->
        {usage(m, at), "applied", [], inputs, nil}
    end
  end

  defp lifetime?(m, data, at, close?) do
    keys = if close?, do: ~w(opened_at_ms closed_at_ms), else: ~w(opened_at_ms)

    is_map(data) and Enum.sort(Map.keys(data)) == Enum.sort(keys) and
      Binding.uint?(data["opened_at_ms"]) and data["opened_at_ms"] <= at and
      (m["opened"] == nil or m["opened"] == data["opened_at_ms"]) and
      (not close? or
         (Binding.uint?(data["closed_at_ms"]) and data["opened_at_ms"] <= data["closed_at_ms"] and
            data["closed_at_ms"] <= at and
            (m["closed"] == nil or m["closed"] == data["closed_at_ms"])))
  end

  defp settle(m, id, outcome, data, at) do
    action = m["actions"][id]
    {:ok, checked} = PatternStep.decode(action["request"])
    tracker = PatternStep.open(checked)

    tracker =
      if action["outcome"] do
        {:ok, prior} = PatternStep.decode(action["outcome"])
        {:applied, tracker} = PatternStep.accept(tracker, prior)
        tracker
      else
        tracker
      end

    input = %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "at_ms" => at,
      "action_id" => id,
      "outcome" => outcome,
      "schema_id" => "elzoo.run-resource.result",
      "schema_version" => 1,
      "payload" => payload(m, outcome, data)
    }

    {:ok, checked_input} = PatternStep.decode(input)

    case PatternStep.accept(tracker, checked_input) do
      {:applied, _} ->
        {put_in(m, ["actions", id, "outcome"], PatternStep.encode(checked_input)), [input]}

      {:late, _} ->
        {m, []}
    end
  end

  defp settle_all(m, at, ordinary, closing) do
    Enum.reduce(Enum.sort(Map.keys(m["actions"])), {m, []}, fn id, {m, inputs} ->
      outcome = if m["actions"][id]["kind"] == "resource_close", do: closing, else: ordinary
      {m, added} = settle(m, id, outcome, nil, at)
      {m, inputs ++ added}
    end)
  end

  defp lose(m, at) do
    inputs = if m["lost"], do: [], else: [event(m, at, "lost", nil)]
    m = Map.put(m, "lost", true)

    {m, settled} =
      Enum.reduce(m["actions"], {m, []}, fn {id, a}, {m, acc} ->
        if a["kind"] == "resource_close",
          do: {m, acc},
          else:
            (
              {m, added} = settle(m, id, "resource_lost", nil, at)
              {m, acc ++ added}
            )
      end)

    {m, effects, dropped, budget} = close(m, at, "closed")
    {m, effects, inputs ++ settled ++ dropped, budget}
  end

  defp close(m, at, reason) do
    cond do
      m["phase"] in ["new", "closed"] ->
        {m, inputs} = settle_all(m, at, "resource_lost", "completed")
        {m, budget} = release(Map.put(m, "phase", "closed"))
        {m, [], inputs, budget}

      true ->
        {m, inputs} =
          Enum.reduce(m["waiting"], {m, []}, fn id, {m, acc} ->
            {m, added} =
              settle(m, id, if(reason == "expired", do: "expired", else: "refused"), nil, at)

            {m, acc ++ added}
          end)

        descriptor = m["resource"]["close_intent"]
        fresh? = not Map.has_key?(m["intents"], intent_key(descriptor))
        m = if fresh?, do: add_intent(m, descriptor, nil, "resource_close"), else: m
        m = m |> Map.put("phase", "closing") |> Map.put("waiting", []) |> usage(at)
        {m, if(fresh?, do: [descriptor], else: []), inputs, nil}
    end
  end

  defp dequeue(m) do
    if m["phase"] == "open" and not m["paused"] and m["active"] == nil and m["waiting"] != [] do
      [id | waiting] = m["waiting"]
      descriptor = m["intents"][m["actions"][id]["intent"]]["descriptor"]
      {m |> Map.put("active", id) |> Map.put("waiting", waiting), [descriptor]}
    else
      {m, []}
    end
  end

  defp usage(m, at) do
    if m["opened"] != nil and m["closed"] == nil do
      through = max(m["through"] || m["opened"], at)

      m
      |> Map.put("through", through)
      |> Map.put("accrued", max(m["accrued"] || 0, through - m["opened"]))
    else
      m
    end
  end

  defp accounting(m) do
    duration = m["closed"] - m["opened"]
    actual = div(duration + 59_999, 60_000) * m["resource"]["rate_per_minute"]

    m =
      m
      |> Map.put("actual", actual)
      |> Map.put("accrued", duration)
      |> Map.put("through", m["closed"])

    budget(m, if(actual == 0, do: "release", else: "settle"), actual)
  end

  defp release(m), do: budget(m, "release", nil)

  defp budget(m, kind, actual) do
    if m["budget"] != nil do
      {m, nil}
    else
      b = Map.take(m["resource"]["budget"], ~w(cost_ref generation))
      b = if kind == "settle", do: Map.put(b, "actual", actual), else: b
      command = [kind, b]
      {Map.put(m, "budget", command), command}
    end
  end

  defp payload(m, reason, data),
    do: %{
      "run_id" => m["resource"]["run_id"],
      "resource_name" => m["resource"]["name"],
      "reason" => reason,
      "data" => data
    }

  defp event(m, at, reason, data, id \\ nil) do
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "resource_event",
      "at_ms" => at,
      "schema_id" => "elzoo.run-resource.result",
      "schema_version" => 1,
      "payload" => Map.put(payload(m, reason, data), "event_id", id)
    }
  end

  defp event_ids(inputs, key, seq) do
    inputs
    |> Enum.with_index()
    |> Enum.map(fn {input, index} ->
      input =
        if input["kind"] == "resource_event" and input["payload"]["event_id"] == nil,
          do: put_in(input, ["payload", "event_id"], "#{key}/#{seq}/#{index}"),
          else: input

      {:ok, checked} = PatternStep.decode(input)
      PatternStep.encode(checked)
    end)
  end

  defp descriptor(r) do
    with true <-
           is_map(r) and
             Enum.sort(Map.keys(r)) in [
               Enum.sort([
                 :run_id,
                 :name,
                 :deadline_ms,
                 :rate_per_minute,
                 :max_waiting,
                 :budget,
                 :close_intent
               ]),
               Enum.sort([
                 :run_id,
                 :name,
                 :deadline_ms,
                 :rate_per_minute,
                 :max_waiting,
                 :budget,
                 :close_intent,
                 :pause_policy
               ])
             ],
         true <- text?(r.run_id) and text?(r.name) and Binding.uint?(r.deadline_ms),
         true <-
           is_integer(r.rate_per_minute) and r.rate_per_minute > 0 and is_integer(r.max_waiting) and
             r.max_waiting >= 0,
         true <- Map.get(r, :pause_policy, :stay) in [:stay, :close],
         %{budget_id: bid, unit: unit, cost_ref: ref, generation: {inc, count}} = b <- r.budget,
         true <-
           map_size(b) == 4 and Enum.all?([bid, unit, ref, inc], &text?/1) and is_integer(count) and
             count > 0,
         {:ok, close} <- intent(r.close_intent),
         true <- close["deadline_ms"] > r.deadline_ms do
      {:ok,
       %{
         "run_id" => r.run_id,
         "name" => r.name,
         "deadline_ms" => r.deadline_ms,
         "rate_per_minute" => r.rate_per_minute,
         "max_waiting" => r.max_waiting,
         "pause_policy" => Atom.to_string(Map.get(r, :pause_policy, :stay)),
         "close_intent" => close,
         "budget" => %{
           "budget_id" => bid,
           "unit" => unit,
           "cost_ref" => ref,
           "generation" => [inc, count]
         }
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp intent(
         %{
           identity: identity,
           arguments: args,
           binding: binding,
           binding_digest: digest,
           deadline_ms: deadline
         } = i
       )
       when map_size(i) == 5 do
    if is_list(identity) and length(identity) == 5 and Enum.all?(identity, &Binding.text?/1) and
         is_binary(args) and byte_size(args) <= 65_536 and Binding.text?(binding) and
         is_binary(digest) and byte_size(digest) == 32 and Binding.uint?(deadline),
       do:
         {:ok,
          %{
            "identity" => identity,
            "arguments" => Base.encode64(args),
            "binding" => binding,
            "binding_digest" => Base.encode64(digest),
            "deadline_ms" => deadline
          }},
       else: {:error, :invalid_input}
  end

  defp intent(_), do: {:error, :invalid_input}
  defp intent_key(i), do: Jason.encode!(i["identity"])

  defp normalize(%{id: id, at_ms: at, body: body} = c, internal?) when map_size(c) == 3 do
    with true <- (internal? or text?(id)) and Binding.uint?(at),
         {:ok, tag, durable, durable_id} <- body(body, id, at) do
      {:ok, [tag, durable_id], [at, durable]}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp normalize(_, _), do: :error

  defp body({:action, action, context, descriptor}, id, _) do
    request = %{"type" => "request", "version" => 1, "actions" => [action]}

    with {:ok, checked} <- PatternStep.decode(request),
         true <-
           action["id"] == id and action["kind"] in ~w(resource_open resource_use resource_close),
         true <-
           action["schema_id"] == "elzoo.run-resource.action" and action["schema_version"] == 1,
         %{"run_id" => run, "resource_name" => name, "data" => data} = p <- action["payload"],
         true <- map_size(p) == 3 and text?(run) and text?(name) and json?(data),
         %{run_id: crun, scope: scope, resource_names: names} <- context,
         true <-
           map_size(context) == 3 and text?(crun) and scope in [:owner, :nested] and is_list(names) and
             Enum.all?(names, &text?/1),
         {:ok, intent} <-
           if(action["kind"] == "resource_close",
             do: if(descriptor == nil, do: {:ok, nil}, else: :error),
             else: intent(descriptor)
           ) do
      {:ok, "action",
       [
         "action",
         PatternStep.encode(checked),
         %{"run_id" => crun, "scope" => Atom.to_string(scope), "resource_names" => names},
         intent
       ], id}
    else
      _ -> :error
    end
  end

  defp body({:input, checked}, id, at) do
    input = PatternStep.encode(checked)

    with {:ok, _} <- PatternStep.decode(input),
         true <-
           input["kind"] == "run_ended" and input["at_ms"] == at and
             input["schema_id"] == "elzoo.run-resource.run-ended" and input["schema_version"] == 1,
         %{"run_id" => run, "outcome" => outcome} = p <- input["payload"],
         true <- map_size(p) == 2 and text?(run) and json?(outcome) do
      {:ok, "control", ["input", input], id}
    else
      _ -> :error
    end
  end

  defp body(control, id, _) when control in [:pause, :continue, :tick],
    do: {:ok, "control", [Atom.to_string(control)], id}

  defp body({:dispatch, identity, owner}, id, _) when is_pid(owner) do
    if identity?(identity), do: {:ok, "dispatch", ["dispatch", identity], id}, else: :error
  end

  defp body({:observed, identity, observation}, id, _) do
    normalized =
      case observation do
        {:completed, %{opened_at_ms: opened, closed_at_ms: closed} = data}
        when map_size(data) == 2 ->
          ["completed", %{"opened_at_ms" => opened, "closed_at_ms" => closed}]

        {:completed, %{opened_at_ms: opened} = data} when map_size(data) == 1 ->
          ["completed", %{"opened_at_ms" => opened}]

        {:completed, data} ->
          ["completed", data]

        {:failed, dispatch, data} when dispatch in [:not_dispatched, :dispatched, :unknown] ->
          ["failed", Atom.to_string(dispatch), data]

        {:unknown, data} ->
          ["unknown", data]

        _ ->
          nil
      end

    if identity?(identity) and normalized != nil and json?(normalized),
      do: {:ok, "observation", ["observed", identity, normalized], id},
      else: :error
  end

  defp body({:event, event_id, data}, _, _) do
    if text?(event_id) and json?(data),
      do: {:ok, "event", ["event", event_id, data], event_id},
      else: :error
  end

  defp body(_, _, _), do: :error

  defp identity?(i), do: is_list(i) and length(i) == 5 and Enum.all?(i, &Binding.text?/1)
  defp text?(s), do: is_binary(s) and byte_size(s) > 0 and String.valid?(s)
  defp json?(v) when is_binary(v), do: String.valid?(v)
  defp json?(v) when is_number(v) or is_boolean(v) or is_nil(v), do: true
  defp json?(v) when is_list(v), do: Enum.all?(v, &json?/1)

  defp json?(v) when is_map(v),
    do: Enum.all?(v, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?(_), do: false

  defp now(s) do
    at = s.clock.()
    true = Binding.uint?(at)
    at
  end

  defp receipt_view(["ok", seq, disposition]),
    do:
      {:ok,
       %{seq: seq, disposition: Enum.find(@dispositions, &(Atom.to_string(&1) == disposition))}}

  defp receipt_view(["unknown", id]), do: {:unknown, %{command_id: id}}
  defp receipt_view(["refused", reason]), do: {:refused, String.to_existing_atom(reason)}

  defp view(m) do
    %{
      phase: Enum.find(@phases, &(Atom.to_string(&1) == m["phase"])),
      paused: m["paused"],
      run_ended: m["run_ended"],
      active_action_id: m["active"],
      waiting_action_ids: m["waiting"],
      opened_at_ms: m["opened"],
      observed_through_ms: m["through"],
      closed_at_ms: m["closed"],
      accrued_ms: m["accrued"],
      final_actual: m["actual"]
    }
  end

  defp entry_view(e, m) do
    effects =
      for i <- e["effects"],
          r = m["intents"][intent_key(i)],
          r != nil,
          r["status"] == "ready" and dispatchable?(m, intent_key(i)),
          do: intent_view(i)

    [tag, id] = e["command_id"]

    %{
      seq: e["seq"],
      command_id: {Enum.find(@tags, &(Atom.to_string(&1) == tag)), id},
      receipt: receipt_view(e["receipt"]),
      effects: effects,
      inputs: e["inputs"],
      budget_command: budget_view(e["budget_command"])
    }
  end

  defp intent_view(i),
    do: %{
      identity: i["identity"],
      arguments: Base.decode64!(i["arguments"]),
      binding: i["binding"],
      binding_digest: Base.decode64!(i["binding_digest"]),
      deadline_ms: i["deadline_ms"]
    }

  defp budget_view(nil), do: nil

  defp budget_view([kind, b]) do
    [inc, count] = b["generation"]
    fields = %{cost_ref: b["cost_ref"], generation: {inc, count}}
    fields = if kind == "settle", do: Map.put(fields, :actual, b["actual"]), else: fields
    {String.to_existing_atom(kind), fields}
  end
end
