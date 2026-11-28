defmodule Elzoo.Wave4ChannelExample do
  @moduledoc """
  The signed wave 4 channel host. CheckedCommand stays its atomic admission
  boundary: each Conversation-writing command commits its gated write, its
  Approval, its receipt and its pending outbox item in one append. The
  conversation itself is an `Elzoo.Conversation` owner that this host starts
  for its profile: before each command commits, the host checks the exact
  intent against the owner with the conversation's earlier committed,
  undelivered intents, and each advance first delivers the committed intents
  in command sequence order through the owner. So a message or an
  association is visible in the conversation after its delivery, not at the
  command's commit. The profile's `tenant` and `conversation_id` must be
  `state/conversation` stream-name segments (1–64 bytes of `[A-Za-z0-9._-]`,
  never `.` or `..`); the earlier 128-byte allowance for `conversation_id` is
  gone.
  """
  use GenServer

  alias Elzoo.{
    AsyncWork,
    CheckedCommand,
    Conversation,
    DurableLog,
    DynamicUnits,
    Lease,
    Outbox,
    RunApprovalRelease,
    RunEngine,
    TriggerBinding,
    WebhookIn
  }

  alias Elzoo.Wave4ChannelExample.Intents

  @destination "wave4-channel-input"
  @reply_destination "wave4-channel-reply"
  @delivery_destination "wave4-channel-delivery"
  @max_view_bytes 1_048_576
  @view_entries 32
  @outbox_limit 64
  @result_limits %{max_records: 2_048, max_bytes: 16_777_216}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def admit(host, event, trusted_scope),
    do: GenServer.call(host, {:admit, event, trusted_scope}, 65_000)

  def admit_reply(host, event, trusted_scope),
    do: GenServer.call(host, {:admit_reply, event, trusted_scope}, 65_000)

  def advance(host), do: GenServer.call(host, :advance, 65_000)

  def release(host, event, trusted_scope, command_purpose_evidence),
    do: GenServer.call(host, {:release, event, trusted_scope, command_purpose_evidence}, 65_000)

  def release_reply(host, event, trusted_scope, command_purpose_evidence),
    do:
      GenServer.call(
        host,
        {:release_reply, event, trusted_scope, command_purpose_evidence},
        65_000
      )

  def view(host, trusted_scope), do: GenServer.call(host, {:view, trusted_scope}, 65_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, profile} <- profile(Keyword.fetch!(opts, :profile)),
         {:ok, target} <- select_target(profile, Keyword.fetch!(opts, :bindings)),
         handles when is_map(handles) <- Keyword.fetch!(opts, :handles),
         true <- handles?(handles, profile),
         {:ok, native} <- native(Keyword.fetch!(opts, :native), profile, target),
         authority when is_function(authority, 4) <- Keyword.fetch!(opts, :authority),
         policy when is_function(policy, 3) <- Keyword.fetch!(opts, :policy),
         clock when is_function(clock, 0) <- Keyword.fetch!(opts, :clock),
         true <- Process.alive?(native.run_owner),
         {:ok, conversation} <- conversation(Keyword.fetch!(opts, :conversation_store), profile) do
      {:ok,
       %{
         profile: profile,
         target: target,
         command_store: Keyword.fetch!(opts, :command_store),
         conversation: conversation,
         delivered: %{},
         held: %{},
         handles: handles,
         native: native,
         authority: authority,
         policy: policy,
         clock: clock,
         phase: :idle,
         current: nil,
         reply: nil,
         latest_native: nil,
         latest_run: nil,
         completed_pair: nil,
         ambiguous_reply: false,
         approval: nil,
         engine: nil,
         engine_ref: nil,
         async_work: nil,
         async_work_ref: nil,
         writer: nil,
         writer_ref: nil,
         poison: nil,
         native_wait: nil,
         completed: %{}
       }}
    else
      {:error, {:conversation, reason}} -> {:stop, {:conversation, reason}}
      _ -> {:stop, :invalid_options}
    end
  rescue
    _ -> {:stop, :invalid_options}
  end

  # The host is the caller that supervises its conversation owner: it starts
  # the owner linked, restarts it from the validated stream when it exits
  # (and stops itself when that restart fails, for its own supervisor to
  # reopen), and stops it on terminate.
  defp conversation(store, profile) do
    case Conversation.start_link(
           store: store,
           target_tenant: profile.tenant,
           conversation_id: profile.conversation_id
         ) do
      {:ok, owner} -> {:ok, %{owner: owner, store: store}}
      {:error, reason} -> {:error, {:conversation, reason}}
    end
  end

  @impl true
  def handle_call({:admit, event, trusted_scope}, _from, state) do
    {reply, state} = admit_event(state, event, trusted_scope)
    {:reply, reply, state}
  end

  def handle_call({:admit_reply, event, trusted_scope}, _from, state) do
    {reply, state} = admit_reply_event(state, event, trusted_scope)
    {:reply, reply, state}
  end

  def handle_call(:advance, _from, state) do
    {reply, state} = advance_once(state)
    {:reply, reply, state}
  end

  def handle_call({:release, event, trusted_scope, evidence}, _from, state) do
    {reply, state} = release_event(state, event, trusted_scope, evidence)
    {:reply, reply, state}
  end

  def handle_call({:release_reply, event, trusted_scope, evidence}, _from, state) do
    {reply, state} = release_reply_event(state, event, trusted_scope, evidence)
    {:reply, reply, state}
  end

  def handle_call({:view, trusted_scope}, _from, state) do
    {:reply, read_view(state, trusted_scope), state}
  end

  defp admit_reply_event(%{poison: poison} = state, _, _) when not is_nil(poison),
    do: {{:error, :unavailable}, state}

  # Admission reads the outbox window (`primary_reply_pending?/1`,
  # `admission_intent/3`), and each read holds the input items that it shows
  # (`pending_window/1`): the state that holds them is the one returned,
  # whatever admission decides.
  defp admit_reply_event(state, event, trusted_scope) do
    with true <- reply_profile?(state.profile),
         :ok <- valid_event(event),
         :ok <- valid_admission_scope(state.profile, event, trusted_scope) do
      operation_id = input_operation(state.profile.reply_source_id, event.event_id)
      identity = {state.profile.tenant, state.profile.actor, operation_id}

      result =
        CheckedCommand.result(state.handles.reply_input, result_scope(state.profile), identity)

      case existing_reply_or_capacity(state, event, operation_id, result) do
        {{:ok, decision}, state} -> execute_reply_input(state, event, operation_id, decision)
        {refusal, state} -> {reply_admission_reply(refusal), state}
      end
    else
      refusal -> {reply_admission_reply(refusal), state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    :exit, _ -> {{:error, :unavailable}, state}
    _, _ -> {{:error, :unavailable}, state}
  end

  defp reply_admission_reply(refusal) do
    case refusal do
      {:error, :expired} -> {:rejected, :conflict}
      {:error, {:conflict, _code}} -> {:rejected, :conflict}
      {:error, :busy} -> {:error, :unavailable}
      {:error, :scope} -> {:rejected, :forbidden}
      {:error, :ticket} -> {:rejected, :conflict}
      {:error, :capacity} -> {:rejected, :conflict}
      {:error, :ambiguous} -> {:rejected, :conflict}
      {:error, :unknown} -> {:error, :unavailable}
      _ -> {:rejected, :invalid}
    end
  end

  defp existing_reply_or_capacity(%{ambiguous_reply: ambiguous} = state, _event, _operation_id, {
         :unknown,
         :not_observed
       })
       when ambiguous in [:check, true],
       do: {{:error, :ambiguous}, state}

  # A fresh reply executes against the event's resource, so the event must
  # name this host's conversation before any check runs on that conversation:
  # the same fixed-target rule as primary admission and reply release.
  # `{result, state}`.
  defp existing_reply_or_capacity(state, event, operation_id, {:unknown, :not_observed}) do
    with :ok <- fixed_release_scope(state.profile, event),
         nil <- state.reply,
         %{run_id: run_id} = current when not is_nil(current) <- state.current,
         :result <- state.phase,
         true <- is_nil(state.approval) and is_nil(state.poison),
         {:ok, wait} <- live_reply_wait(state, event, run_id) do
      case primary_reply_pending?(state) do
        {:ok, state} -> fresh_reply_admission(state, event, operation_id, run_id, wait)
        {refusal, state} -> {reply_refusal(refusal), state}
      end
    else
      refusal -> {reply_refusal(refusal), state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    :exit, _ -> {{:error, :unknown}, state}
    _, _ -> {{:error, :unknown}, state}
  end

  defp existing_reply_or_capacity(state, _event, _operation_id, {:unknown, _}),
    do: {{:error, :unknown}, state}

  defp existing_reply_or_capacity(state, _event, _operation_id, result)
       when is_tuple(result) and elem(result, 0) in [:error, :unavailable],
       do: {{:error, :unknown}, state}

  defp existing_reply_or_capacity(state, _event, _operation_id, _retained),
    do: {{:ok, :replay}, state}

  # The rest of a fresh reply's admission, after its first window read:
  # `{result, state}` with the state that holds what each window showed.
  defp fresh_reply_admission(state, event, operation_id, run_id, wait) do
    if before_reply_deadlines?(state, wait) do
      case admission_intent(state, input_request(event, operation_id), input_facts()) do
        {:ok, state} -> {reply_admission_tail(state, event, run_id, wait), state}
        {refusal, state} -> {reply_refusal(refusal), state}
      end
    else
      {{:error, :ticket}, state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    :exit, _ -> {{:error, :unknown}, state}
    _, _ -> {{:error, :unknown}, state}
  end

  defp reply_admission_tail(state, event, run_id, wait) do
    with :ok <- reply_capacity_preflight(state, event),
         {:ok, current_wait} <- live_reply_wait(state, event, run_id),
         true <- current_wait.occurrence == wait.occurrence,
         true <- before_reply_deadlines?(state, current_wait) do
      {:ok, {:fresh, wait}}
    else
      refusal -> reply_refusal(refusal)
    end
  end

  defp reply_refusal(refusal) do
    case refusal do
      false -> {:error, :ticket}
      nil -> {:error, :busy}
      :busy -> {:error, :busy}
      {:error, _} = error -> error
      _ -> {:error, :ticket}
    end
  end

  defp live_reply_wait(
         %{engine: engine, native: native, current: current, profile: profile},
         event,
         run_id
       )
       when is_pid(engine) and is_map(current) do
    scope = %{tenant: profile.tenant, principal: profile.actor, run_id: run_id}

    with true <- Process.alive?(engine),
         {:ok, %{waits: [wait]}} <- RunEngine.event_waits(engine, scope, @result_limits),
         {:ok, run} <- RunApprovalRelease.status(native.run_owner, run_id),
         true <-
           run.operation_id == native_operation(run_id, %{profile: profile}) and
             run.current_attempt == attempt_id(run_id, %{profile: profile}) and
             is_nil(run.outcome),
         true <-
           wait.status == :waiting and wait.action_id == "reply" and
             wait.source_id == profile.reply_source_id and
             wait.correlation_id == event.input_id and is_tuple(wait.occurrence) and
             is_integer(wait.deadline_ms) do
      {:ok, wait}
    else
      _ -> {:error, :ticket}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    :exit, _ -> {:error, :unknown}
    _, _ -> {:error, :unknown}
  end

  defp live_reply_wait(_, _, _), do: {:error, :ticket}

  # The reply admission's window: this round's primary item pending and no
  # reply item. The window read holds the input items that it shows
  # (`pending_window/1`): `{result, state}`.
  defp primary_reply_pending?(state) do
    case pending_window(state) do
      {:ok, items, state} -> {reply_window_ready(state, items), state}
      {:error, _cause} -> {{:error, :unknown}, state}
    end
  end

  defp reply_window_ready(state, items) do
    primary? =
      Enum.any?(items, fn item ->
        item.idempotency_key == state.current.item.key and item.destination == @destination
      end)

    reply? = Enum.any?(items, &(&1.destination == @reply_destination))

    cond do
      reply? -> {:error, :busy}
      pending_window_full?(items) -> {:error, :unknown}
      not primary? -> {:error, :busy}
      true -> :ok
    end
  rescue
    _ -> {:error, :unknown}
  end

  defp before_reply_deadlines?(state, wait) do
    now = state.clock.()
    is_integer(now) and now < state.profile.deadline_ms and now < wait.deadline_ms
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp reply_capacity_preflight(state, event),
    do: reply_capacity_preflight(state, event, 1020)

  # The reply round still needs the reply input, the reply association and the
  # answer within CheckedCommand's operation bound, on the resource revision
  # that the signed reply names.
  defp reply_capacity_preflight(state, event, head_limit) do
    stream = checked_stream(state.profile.tenant)

    with {:ok, head} <- DurableLog.Store.read(state.command_store, :head, [stream]),
         true <- reply_preflight_head?(head, head_limit),
         {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         true <- snapshot.revision == event.expected_revision do
      :ok
    else
      _ -> {:error, :capacity}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp reply_preflight_head?(%{revision: revision, low_water: 0}, head_limit)
       when is_integer(head_limit) and is_integer(revision) and revision in 0..head_limit//1,
       do: true

  defp reply_preflight_head?(_, _), do: false

  defp execute_reply_input(state, event, operation_id, decision) do
    request = input_request(event, operation_id)
    {result, state} = execute_checked(state, :reply_input, event, request, input_facts())

    case {decision, result} do
      {:replay, {:completed, %{revision: revision}}} ->
        {{:committed, revision}, state}

      {:replay, {:approval_pending, pending}} ->
        if is_nil(state.reply) and state.ambiguous_reply in [:check, true],
          do: restore_ambiguous_reply_ask(state, event, operation_id, request, pending),
          else: {{:pending, :approval}, state}

      {:replay, {:conflict, _}} ->
        {{:rejected, :conflict}, state}

      {:replay, {:denied, _}} ->
        {{:rejected, :forbidden}, state}

      {{:fresh, wait}, {:completed, %{revision: revision, response: response}}}
      when revision == event.expected_revision + 1 ->
        with {:ok, ticket, ^revision} <- receipt_input(response),
             true <- ticket == event.input_id do
          reply = %{
            event: event,
            operation_id: operation_id,
            request: request,
            ticket: ticket,
            wait: wait,
            resource_revision: revision,
            item: nil,
            text: nil,
            association_operation: association_operation(operation_id, ticket, state.profile),
            association_revision: nil
          }

          {{:committed, revision}, %{state | reply: reply, phase: :reply_observe}}
        else
          _ -> {{:unknown, :reply_identity}, %{state | poison: {:reply_input, operation_id}}}
        end

      {{:fresh, wait}, {:approval_pending, pending}} ->
        reply = %{
          event: event,
          operation_id: operation_id,
          request: request,
          facts: input_facts(),
          key: pending.key,
          requirement: pending.requirement,
          pending: pending,
          wait: wait,
          release_state: :pending
        }

        {{:pending, :approval}, %{state | reply: reply}}

      {{:fresh, _wait}, {:denied, {:authorization, _}}} ->
        {{:rejected, :forbidden}, state}

      {{:fresh, _wait}, {:denied, _}} ->
        {{:rejected, :forbidden}, state}

      {{:fresh, _wait}, {:conflict, _}} ->
        {{:rejected, :conflict}, state}

      {{:fresh, _wait}, {:refused, _}} ->
        {{:rejected, :invalid}, state}

      {{:fresh, wait}, {:unknown, _}} ->
        reply = %{
          event: event,
          operation_id: operation_id,
          request: request,
          facts: input_facts(),
          wait: wait,
          release_state: :unknown
        }

        {{:unknown, :reply_input}, %{state | reply: reply, poison: {:reply_input, operation_id}}}

      {_, {:unavailable, _}} ->
        {{:error, :unavailable}, state}

      _ ->
        {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:unknown, :reply_input}, %{state | poison: {:reply_input, operation_id}}}
  catch
    _, _ -> {{:unknown, :reply_input}, %{state | poison: {:reply_input, operation_id}}}
  end

  defp restore_ambiguous_reply_ask(state, event, operation_id, request, pending) do
    with %{run_id: run_id} <- state.current,
         true <-
           is_map(pending) and Map.has_key?(pending, :key) and
             Map.has_key?(pending, :requirement),
         {:ok, wait} <- live_reply_wait(state, event, run_id) do
      reply = %{
        event: event,
        operation_id: operation_id,
        request: request,
        facts: input_facts(),
        key: pending.key,
        requirement: pending.requirement,
        pending: pending,
        wait: wait,
        release_state: :pending
      }

      {{:pending, :approval}, %{state | reply: reply, native_wait: wait, ambiguous_reply: false}}
    else
      _ -> {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    _, _ -> {{:error, :unavailable}, state}
  end

  defp release_reply_event(%{poison: poison} = state, _event, _trusted_scope, _evidence)
       when not is_nil(poison),
       do: {{:error, :unavailable}, state}

  defp release_reply_event(%{profile: profile} = state, event, trusted_scope, evidence) do
    if reply_profile?(profile),
      do: release_v2(state, :reply, event, trusted_scope, evidence),
      else: {{:error, :unavailable}, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, reason}, state) do
    contain_native_exit(state, pid, reference, reason)
  end

  # The conversation owner exited: a new owner reads and validates the whole
  # stream again. Deliveries already proven stay proven, because they are in
  # that stream; a delivery that the exit interrupted is unknown and is
  # retried with its identical intent. When the restart fails, the host
  # stops, for its own supervisor to reopen it.
  def handle_info({:EXIT, pid, reason}, %{conversation: %{owner: pid}} = state) do
    case conversation(state.conversation.store, state.profile) do
      {:ok, conversation} ->
        {:noreply, %{state | conversation: conversation}}

      {:error, cause} ->
        {:stop, {:conversation_owner, reason, cause},
         %{state | conversation: %{state.conversation | owner: nil}}}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    contain_native_exit(state, pid, nil, reason)
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fence_native(state)
    stop_conversation_owner(state)
    :ok
  end

  # The owner is linked to this host; a normal stop would not propagate, so
  # terminate stops it with the host's own reason shape.
  defp stop_conversation_owner(%{conversation: %{owner: owner}}) when is_pid(owner) do
    if Process.alive?(owner) do
      Process.unlink(owner)
      GenServer.stop(owner, :normal, 5_000)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
    _, _ -> :ok
  end

  defp stop_conversation_owner(_), do: :ok

  @impl true
  def format_status(status) do
    Enum.reduce([:state, :message, :reason, :log], status, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, :redacted), else: acc
    end)
  end

  defp admit_event(%{poison: poison} = state, _, _) when not is_nil(poison),
    do: {{:error, :unavailable}, state}

  # Admission reads the outbox window (`admission_intent/3`,
  # `pending_input?/1`), and each read holds the input items that it shows
  # (`pending_window/1`): the state that holds them is the one returned,
  # whatever admission decides.
  defp admit_event(state, event, trusted_scope) do
    with :ok <- valid_event(event),
         :ok <- valid_admission_scope(state.profile, event, trusted_scope) do
      operation_id = input_operation(state.profile.source_id, event.event_id)
      identity = {state.profile.tenant, state.profile.actor, operation_id}
      result = CheckedCommand.result(state.handles.input, result_scope(state.profile), identity)

      case existing_or_capacity(state, event, operation_id, result) do
        {{:ok, decision}, state} -> execute_input(state, event, operation_id, decision)
        {refusal, state} -> {admission_reply(refusal), state}
      end
    else
      refusal -> {admission_reply(refusal), state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    :exit, _ -> {{:error, :unavailable}, state}
    :throw, _ -> {{:error, :unavailable}, state}
  end

  defp admission_reply(refusal) do
    case refusal do
      {:error, :expired} -> {:rejected, :conflict}
      {:error, {:conflict, _code}} -> {:rejected, :conflict}
      {:error, :busy} -> {:error, :unavailable}
      {:error, :scope} -> {:rejected, :forbidden}
      {:error, :unknown} -> {:error, :unavailable}
      _ -> {:rejected, :invalid}
    end
  end

  # `{result, state}`.
  defp existing_or_capacity(state, event, operation_id, {:unknown, :not_observed}) do
    cond do
      not before_deadline?(state) ->
        {{:error, :expired}, state}

      event.conversation_id != state.profile.conversation_id ->
        {{:error, :scope}, state}

      true ->
        # The conflict check comes before the busy checks: a command that
        # conflicts with the admitted state is refused even while an earlier
        # delivery is pending.
        case admission_intent(state, input_request(event, operation_id), input_facts()) do
          {:ok, state} -> fresh_primary_admission(state)
          {refusal, state} -> {refusal, state}
        end
    end
  end

  defp existing_or_capacity(state, _event, _operation_id, {:unknown, _}),
    do: {{:error, :unknown}, state}

  defp existing_or_capacity(state, _event, _operation_id, _retained),
    do: {{:ok, :replay}, state}

  # The busy checks of a fresh primary after its admitted-state check:
  # `{result, state}` with the state that holds what each window showed.
  defp fresh_primary_admission(state) do
    case fresh_primary_ready?(state) do
      :ok ->
        case pending_input?(state) do
          {{:ok, true}, state} -> {{:error, :busy}, state}
          {{:ok, false}, state} -> {capacity?(state), state}
          {_unavailable, state} -> {{:error, :unknown}, state}
        end

      {:error, _} = error ->
        {error, state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    _, _ -> {{:error, :unknown}, state}
  end

  # The command stream's operation bound (CheckedCommand's 1,024 operations)
  # must leave room for the whole round before a fresh primary is admitted:
  # the input, the association and the answer, and in the reply profile the
  # reply input and the reply association too.
  defp capacity?(state) do
    if reply_profile?(state.profile),
      do: reply_capacity?(state, 1017),
      else: reply_capacity?(state, 1021)
  end

  defp reply_capacity?(state, head_limit) do
    stream = checked_stream(state.profile.tenant)

    case Elzoo.DurableLog.Store.read(state.command_store, :head, [stream]) do
      {:ok, head} ->
        if fresh_projection_head?(head, head_limit), do: {:ok, :new}, else: {:ok, :capacity}

      _ ->
        {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  end

  defp fresh_projection_head?(%{revision: revision, low_water: 0}, head_limit)
       when is_integer(head_limit) and is_integer(revision) and revision in 0..head_limit//1,
       do: true

  defp fresh_projection_head?(_, _), do: false

  defp answer_projection_head?(%{revision: revision, low_water: 0})
       when is_integer(revision) and revision in 0..1023,
       do: true

  defp answer_projection_head?(_), do: false

  # A stable head pair proves no concurrent command committed between the two
  # reads: the revision chain and retention are identical.
  defp stable_projection_heads?(before, after_head) do
    Map.drop(before, [:capabilities]) == Map.drop(after_head, [:capabilities])
  end

  # Admission governs commands that have not committed their writes. A
  # command whose identity already holds a retained outcome (completed,
  # denied, conflicted or refused) is an idempotent re-execution of its own
  # row, never a fresh claim of its message IDs, so the admitted-state check
  # does not apply to it. An approval-pending command has committed nothing
  # yet: admission still decides it, and its release revalidates against the
  # state as it is then. Anything else, a storage or history read failure
  # included, proves neither and fails closed.
  defp admission_freshness(state, operation_id) do
    case CheckedCommand.result(
           state.handles.input,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation_id}
         ) do
      {:unknown, :not_observed} -> :fresh
      {:approval_pending, _} -> :fresh
      outcome -> if retained_outcome?(outcome), do: :retained, else: :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp retained_outcome?({:completed, result}) when is_map(result), do: true
  defp retained_outcome?({:denied, {:gate, _}}), do: true
  defp retained_outcome?({:denied, {:authorization, _}}), do: true
  defp retained_outcome?({:conflict, :stale_revision}), do: true
  defp retained_outcome?({:conflict, {:domain, _}}), do: true
  defp retained_outcome?({:refused, :domain_failure}), do: true
  defp retained_outcome?(_), do: false

  # Before a Conversation-writing command commits, its exact intent must be a
  # new admissible record after this conversation's earlier committed,
  # undelivered intents, which must all still be admissible or present
  # (`Elzoo.Conversation.check/2`). An `{:ok, :already_present}` candidate is
  # a conflict: delivery of an earlier command is not admission for this one.
  # A command whose identity holds a retained outcome is its own re-execution
  # and is exempt; an unreadable identity is `{:error, :unknown}`.
  # `{result, state}`: the window read holds what it shows.
  defp admission_intent(state, request, facts) do
    case admission_freshness(state, request.operation_id) do
      :fresh -> admission_check(state, request, facts)
      :retained -> {:ok, state}
      :unknown -> {{:error, :unknown}, state}
    end
  end

  defp admission_check(state, request, facts) do
    case Intents.candidate(request, prepare_facts(state.profile, facts)) do
      {:ok, mode, dto} ->
        case undelivered_intents(state) do
          {{:ok, earlier}, state} -> {admission_decision(state, earlier ++ [{mode, dto}]), state}
          {_unavailable, state} -> {{:error, :unknown}, state}
        end

      :error ->
        {{:error, :invalid}, state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    _, _ -> {{:error, :unknown}, state}
  end

  # The owner's decision on the earlier undelivered intents and the
  # candidate, in order.
  defp admission_decision(state, intents) do
    with {:ok, decisions} <- Conversation.check(state.conversation.owner, intents) do
      {prior, [candidate]} = Enum.split(decisions, -1)

      if Enum.all?(prior, &(&1 in [:ok, {:ok, :already_present}])) do
        case candidate do
          :ok -> :ok
          {:ok, :already_present} -> {:error, {:conflict, "already_present"}}
          {:refused, code} -> {:error, {:conflict, code}}
          _ -> {:error, :unknown}
        end
      else
        {:error, :unknown}
      end
    else
      :error -> {:error, :invalid}
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  # The intents of this conversation's pending outbox items whose delivery is
  # not yet proven, in command sequence order. Items of another conversation
  # are not part of it; a full window cannot show every earlier intent. The
  # window read holds the input items that it shows (`pending_window/1`):
  # `{result, state}`.
  defp undelivered_intents(state) do
    case pending_window(state) do
      {:ok, items, state} -> {window_intents(state, items), state}
      {:error, _cause} -> {{:error, :unavailable}, state}
    end
  end

  defp window_intents(state, items) do
    if pending_window_full?(items) do
      {:error, :unavailable}
    else
      items
      |> Enum.reject(&Map.has_key?(state.delivered, &1.idempotency_key))
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        case delivery_intent(state, item) do
          {:ok, mode, dto} -> {:cont, {:ok, [{mode, dto} | acc]}}
          {:error, :foreign} -> {:cont, {:ok, acc}}
          _ -> {:halt, {:error, :unavailable}}
        end
      end)
      |> case do
        {:ok, intents} -> {:ok, Enum.reverse(intents)}
        error -> error
      end
    end
  end

  defp execute_input(state, _event, _operation_id, :capacity),
    do: {{:error, :unavailable}, state}

  # Called with the state that admission's window reads held: a failure here
  # keeps it.
  defp execute_input(state, event, operation_id, decision) do
    request = input_request(event, operation_id)

    case command_context(state, :input, event, request, input_facts()) do
      {:ok, context} ->
        execute_input_command(state, event, operation_id, context, request, decision)

      _ ->
        {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    _, _ -> {{:error, :unavailable}, state}
  end

  defp execute_input_command(state, event, operation_id, context, request, _decision) do
    result =
      try do
        CheckedCommand.execute(state.handles.input, context, request)
      rescue
        _ -> {:unknown, :exception}
      catch
        _, _ -> {:unknown, :exception}
      end

    case result do
      {:completed, %{revision: revision}} when revision == event.expected_revision + 1 ->
        {{:committed, revision}, state}

      {:approval_pending, pending} ->
        approval = %{
          event: event,
          operation_id: operation_id,
          key: pending.key,
          requirement: pending.requirement
        }

        approval =
          if reply_profile?(state.profile),
            do:
              Map.merge(approval, %{
                request: request,
                facts: input_facts(),
                release_state: :pending
              }),
            else: approval

        {{:pending, :approval}, %{state | approval: approval}}

      {:denied, {:authorization, _}} ->
        {{:rejected, :forbidden}, state}

      {:denied, _} ->
        {{:rejected, :forbidden}, state}

      {:conflict, :identity} ->
        {{:rejected, :conflict}, state}

      {:conflict, :stale_revision} ->
        {{:rejected, :conflict}, state}

      {:conflict, {:domain, _}} ->
        {{:rejected, :invalid}, state}

      {:refused, _} ->
        {{:rejected, :invalid}, state}

      {:unknown, _} = unknown ->
        approval = %{event: event, operation_id: operation_id, key: nil, requirement: nil}

        approval =
          if reply_profile?(state.profile),
            do:
              Map.merge(approval, %{
                request: request,
                facts: input_facts(),
                release_state: :unknown
              }),
            else: approval

        {{:unknown, :unavailable},
         %{state | approval: approval, poison: {:input, operation_id, unknown}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      _ ->
        {{:unknown, :unavailable},
         %{
           state
           | approval: %{event: event, operation_id: operation_id},
             poison: {:input, operation_id, :unknown}
         }}
    end
  end

  defp release_event(%{poison: poison} = state, _, _, _) when not is_nil(poison),
    do: {{:error, :unavailable}, state}

  defp release_event(state, event, trusted_scope, evidence) do
    if reply_profile?(state.profile) do
      release_v2(state, :primary, event, trusted_scope, evidence)
    else
      case release_plan(state, event, trusted_scope, evidence) do
        {{:ready, operation_id, facts, request, context}, state} ->
          execute_release(state, event, operation_id, facts, request, context, evidence)

        {{:reply, reply}, state} ->
          {reply, state}
      end
    end
  end

  # `{plan, state}`: the release's admission reads the window, which holds
  # what it shows.
  defp release_plan(state, event, trusted_scope, evidence) do
    if is_map(evidence) and Map.get(evidence, :purpose) == :command do
      with %{event: pending, operation_id: operation_id} <- state.approval,
           true <- event == pending,
           true <- is_nil(state.current) and state.phase == :idle,
           :ok <-
             if(event.conversation_id == state.profile.conversation_id,
               do: :ok,
               else: {:error, :profile_scope}
             ),
           :ok <- valid_admission_scope(state.profile, event, trusted_scope),
           true <- before_deadline?(state) do
        case release_admission(state, event, operation_id) do
          {:ok, state} -> {release_ready(state, event, operation_id, evidence), state}
          {refusal, state} -> {release_refusal(refusal), state}
        end
      else
        refusal -> {release_refusal(refusal), state}
      end
    else
      {{:reply, {:rejected, :invalid}}, state}
    end
  rescue
    _ -> {{:reply, {:error, :unavailable}}, state}
  catch
    _, _ -> {{:reply, {:error, :unavailable}}, state}
  end

  defp release_ready(state, event, operation_id, evidence) do
    case release_context(state, event, operation_id, evidence) do
      {:ok, facts, request, context} -> {:ready, operation_id, facts, request, context}
      refusal -> release_refusal(refusal)
    end
  rescue
    _ -> {:reply, {:error, :unavailable}}
  catch
    _, _ -> {:reply, {:error, :unavailable}}
  end

  defp release_refusal(refusal) do
    case refusal do
      false -> {:reply, {:rejected, :conflict}}
      nil -> {:reply, {:rejected, :conflict}}
      {:error, :profile_scope} -> {:reply, {:rejected, :forbidden}}
      {:error, :intent} -> {:reply, {:rejected, :conflict}}
      {:error, :evidence} -> {:reply, {:error, :unavailable}}
      {:error, :intent_unavailable} -> {:reply, {:error, :unavailable}}
      _ -> {:reply, {:rejected, :invalid}}
    end
  end

  defp execute_release(state, event, operation_id, facts, request, context, evidence) do
    result =
      try do
        CheckedCommand.release(
          state.handles.input,
          context,
          {state.profile.tenant, state.profile.actor, operation_id},
          evidence
        )
      rescue
        _ -> {:unknown, :exception}
      catch
        _, _ -> {:unknown, :exception}
      end

    case result do
      {:completed, %{revision: revision}} when revision == event.expected_revision + 1 ->
        {{:committed, revision}, %{state | approval: nil}}

      {:approval_pending, _} ->
        {{:pending, :approval}, state}

      {:release_refused, reason} ->
        {{:rejected, if(reason == :invalid_request, do: :invalid, else: :forbidden)}, state}

      {:conflict, :stale_revision} ->
        {{:rejected, :conflict}, %{state | approval: nil}}

      {:unknown, _} = unknown ->
        {{:unknown, :unavailable},
         %{state | poison: {:release, operation_id, facts, request, unknown}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      _ ->
        {{:unknown, :unavailable},
         %{state | poison: {:release, operation_id, facts, request, :unknown}}}
    end
  rescue
    _ ->
      {{:unknown, :unavailable},
       %{state | poison: {:release, operation_id, facts, request, :exception}}}
  catch
    _, _ ->
      {{:unknown, :unavailable},
       %{state | poison: {:release, operation_id, facts, request, :exception}}}
  end

  # The release commit of an approval-gated input is a Conversation-writing
  # commit, so the exact intent is validated against the ordered admitted
  # state again: the check at admission is not proof at release time.
  defp release_admission(state, event, operation_id) do
    case admission_intent(state, input_request(event, operation_id), input_facts()) do
      {:ok, state} -> {:ok, state}
      {{:error, {:conflict, _}}, state} -> {{:error, :intent}, state}
      {_unavailable, state} -> {{:error, :intent_unavailable}, state}
    end
  end

  defp release_context(state, event, operation_id, evidence) do
    request = input_request(event, operation_id)
    facts = input_facts()

    with true <- is_map(evidence),
         true <- Map.get(evidence, :purpose) == :command,
         {:ok, context} <- command_context(state, :release, event, request, facts),
         fresh when is_map(fresh) <- state.authority.(:release, event, request, facts),
         true <-
           Map.has_key?(fresh, :approver) and Map.has_key?(fresh, :now) and
             Map.has_key?(fresh, :revoked) do
      {:ok, facts, request, Map.merge(context, fresh)}
    else
      _ -> {:error, :evidence}
    end
  rescue
    _ -> {:error, :evidence}
  catch
    _, _ -> {:error, :evidence}
  end

  defp release_v2(state, kind, event, trusted_scope, evidence) do
    with :ok <- valid_event(event),
         :ok <- fixed_release_scope(state.profile, event),
         :ok <- valid_admission_scope(state.profile, event, trusted_scope),
         :ok <- valid_v2_release_evidence(state.profile, evidence),
         operation_id <- input_operation(release_source_id(state.profile, kind), event.event_id),
         result <-
           CheckedCommand.result(
             release_handle(state, kind),
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, operation_id}
           ),
         {:ok, record} <- v2_release_record(state, kind, event, operation_id) do
      release_v2_result(state, kind, event, operation_id, record, result, evidence)
    else
      {:error, :scope} -> {{:rejected, :forbidden}, state}
      {:error, :forbidden} -> {{:rejected, :forbidden}, state}
      {:error, :purpose} -> {{:rejected, :invalid}, state}
      {:error, :event} -> {{:rejected, :invalid}, state}
      {:error, :identity} -> {{:rejected, :conflict}, state}
      _ -> {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    :exit, _ -> {{:error, :unavailable}, state}
    _, _ -> {{:error, :unavailable}, state}
  end

  defp release_v2_result(state, kind, event, operation_id, record, result, evidence) do
    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == event.expected_revision + 1 ->
        if Map.get(record, :release_state) in [:committed, :committed_expired] do
          if v2_release_receipt_matches?(kind, event, revision, response),
            do: {{:committed, revision}, state},
            else: v2_release_unknown(state, kind, operation_id, record, :receipt)
        else
          case record_v2_release_completion(
                 state,
                 kind,
                 event,
                 operation_id,
                 record,
                 revision,
                 response
               ) do
            {:ok, state} -> {{:committed, revision}, state}
            :error -> v2_release_unknown(state, kind, operation_id, record, :receipt)
          end
        end

      {:approval_pending, pending} ->
        if v2_pending_matches?(record, pending) and
             Map.get(record, :release_state) in [:pending, :unknown] do
          release_v2_pending(state, kind, event, operation_id, record, evidence)
        else
          {{:rejected, :conflict}, state}
        end

      {:unknown, :not_observed} ->
        {{:rejected, :conflict}, state}

      {:unknown, _reason} = unknown ->
        v2_release_unknown(state, kind, operation_id, record, unknown)

      {:conflict, :stale_revision} ->
        {{:rejected, :conflict}, state}

      {:denied, {:authorization, _}} ->
        {{:rejected, :forbidden}, state}

      {:denied, _} ->
        {{:rejected, :forbidden}, state}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      _ ->
        {{:rejected, :conflict}, state}
    end
  end

  defp v2_release_receipt_matches?(:primary, event, revision, response) do
    match?({:ok, input_id, ^revision} when input_id == event.input_id, receipt_input(response))
  end

  defp v2_release_receipt_matches?(:reply, event, revision, response) do
    match?({:ok, ticket, ^revision} when ticket == event.input_id, receipt_input(response))
  end

  defp release_v2_pending(state, kind, event, operation_id, record, evidence) do
    case v2_release_preflight(state, kind, event, operation_id, record) do
      {:ok, state} ->
        mode = release_mode(kind)

        with {:ok, context} <- release_context_v2(state, mode, event, record.request, record.facts) do
          execute_v2_release(state, kind, event, operation_id, record, context, evidence)
        else
          _ -> {{:error, :unavailable}, state}
        end

      {{:error, :unknown}, state} ->
        {{:error, :unavailable}, state}

      {_refusal, state} ->
        {{:rejected, :conflict}, state}
    end
  end

  defp execute_v2_release(state, kind, event, operation_id, record, context, evidence) do
    result =
      try do
        CheckedCommand.release(
          release_handle(state, kind),
          context,
          {state.profile.tenant, state.profile.actor, operation_id},
          evidence
        )
      rescue
        _ -> {:unknown, :exception}
      catch
        _, _ -> {:unknown, :exception}
      end

    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == event.expected_revision + 1 ->
        case record_v2_release_completion(
               state,
               kind,
               event,
               operation_id,
               record,
               revision,
               response
             ) do
          {:ok, state} -> {{:committed, revision}, state}
          :error -> v2_release_unknown(state, kind, operation_id, record, :receipt)
        end

      {:approval_pending, _pending} ->
        {{:pending, :approval}, state}

      {:release_refused, reason} ->
        {{:rejected, if(reason == :invalid_request, do: :invalid, else: :forbidden)}, state}

      {:conflict, :stale_revision} ->
        {{:rejected, :conflict}, state}

      {:unknown, _} = unknown ->
        v2_release_unknown(state, kind, operation_id, record, unknown)

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      other ->
        v2_release_unknown(state, kind, operation_id, record, other)
    end
  rescue
    _ -> v2_release_unknown(state, kind, operation_id, record, :exception)
  catch
    _, _ -> v2_release_unknown(state, kind, operation_id, record, :exception)
  end

  # `{result, state}`: the preflight's window reads hold what they show.
  defp v2_release_preflight(state, :primary, _event, _operation_id, record) do
    cond do
      not is_nil(state.current) or state.phase != :idle or not is_nil(state.poison) ->
        {{:error, :busy}, state}

      not before_deadline?(state) ->
        {{:error, :expired}, state}

      true ->
        with :ok <- prior_v2_pair_proven(state) do
          case admission_intent(state, record.request, record.facts) do
            {:ok, state} -> {primary_release_capacity(state), state}
            {refusal, state} -> {refusal, state}
          end
        else
          refusal -> {refusal, state}
        end
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    _, _ -> {{:error, :unknown}, state}
  end

  defp v2_release_preflight(state, :reply, event, _operation_id, record) do
    with %{run_id: run_id} when state.phase == :result <- state.current,
         true <- is_nil(state.poison),
         {:ok, wait} <- live_reply_wait(state, event, run_id),
         true <- same_release_wait?(record.wait, wait) do
      case primary_reply_pending?(state) do
        {:ok, state} -> reply_release_admission(state, event, record, run_id, wait)
        {refusal, state} -> {reply_release_refusal(refusal), state}
      end
    else
      refusal -> {reply_release_refusal(refusal), state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    _, _ -> {{:error, :unknown}, state}
  end

  defp primary_release_capacity(state) do
    case reply_capacity?(state, 1018) do
      {:ok, :new} -> :ok
      {:ok, :capacity} -> {:error, :capacity}
      _ -> {:error, :unknown}
    end
  end

  defp reply_release_admission(state, event, record, run_id, wait) do
    if before_reply_deadlines?(state, wait) do
      case admission_intent(state, record.request, record.facts) do
        {:ok, state} -> {reply_release_tail(state, event, run_id, wait), state}
        {refusal, state} -> {reply_release_refusal(refusal), state}
      end
    else
      {{:error, :ticket}, state}
    end
  rescue
    _ -> {{:error, :unknown}, state}
  catch
    _, _ -> {{:error, :unknown}, state}
  end

  defp reply_release_tail(state, event, run_id, wait) do
    with :ok <- reply_capacity_preflight(state, event, 1021),
         {:ok, current_wait} <- live_reply_wait(state, event, run_id),
         true <- same_release_wait?(wait, current_wait),
         true <- before_reply_deadlines?(state, current_wait) do
      :ok
    else
      refusal -> reply_release_refusal(refusal)
    end
  end

  defp reply_release_refusal({:error, :unknown}), do: {:error, :unknown}
  defp reply_release_refusal(_refusal), do: {:error, :ticket}

  defp release_context_v2(state, mode, event, request, facts) do
    with true <- Map.has_key?(request, :operation_id),
         {:ok, context} <- command_context(state, mode, event, request, facts),
         fresh when is_map(fresh) <- state.authority.(mode, event, request, facts),
         true <-
           Map.has_key?(fresh, :approver) and Map.has_key?(fresh, :now) and
             Map.has_key?(fresh, :revoked) do
      {:ok, Map.merge(context, fresh)}
    else
      _ -> {:error, :evidence}
    end
  rescue
    _ -> {:error, :evidence}
  catch
    _, _ -> {:error, :evidence}
  end

  defp record_v2_release_completion(
         state,
         :primary,
         event,
         _operation_id,
         record,
         revision,
         response
       ) do
    with {:ok, input_id, ^revision} <- receipt_input(response),
         true <- input_id == event.input_id do
      release_state = if primary_deadline_live?(state), do: :committed, else: :committed_expired
      approval = Map.merge(record, %{release_state: release_state, release_revision: revision})
      {:ok, %{state | approval: approval}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp record_v2_release_completion(state, :reply, event, operation_id, record, revision, response) do
    with {:ok, ticket, ^revision} <- receipt_input(response),
         true <- ticket == event.input_id do
      live_state = reply_release_live?(state, event, record)

      release_state =
        if live_state == :live,
          do: :committed,
          else: if(live_state == :expired, do: :committed_expired, else: :unknown)

      reply =
        Map.merge(record, %{
          ticket: ticket,
          resource_revision: revision,
          item: nil,
          text: nil,
          association_operation: association_operation(operation_id, ticket, state.profile),
          association_revision: nil,
          pending: nil,
          release_state: release_state,
          release_revision: revision
        })

      phase = if live_state == :live, do: :reply_observe, else: state.phase
      poison = if live_state == :unknown, do: {:reply_release_live, operation_id}, else: nil
      {:ok, %{state | reply: reply, phase: phase, poison: poison}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp reply_release_live?(state, event, record) do
    case state.current do
      %{run_id: run_id} when state.phase == :result ->
        case live_reply_wait(state, event, run_id) do
          {:ok, wait} ->
            cond do
              not same_release_wait?(record.wait, wait) -> :unknown
              before_reply_deadlines?(state, wait) -> :live
              proven_reply_expiry?(state, record.wait) -> :expired
              true -> :unknown
            end

          _ ->
            if proven_reply_expiry?(state, record.wait), do: :expired, else: :unknown
        end

      _ ->
        if proven_reply_expiry?(state, record.wait), do: :expired, else: :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp proven_reply_expiry?(state, %{deadline_ms: wait_deadline}) when is_integer(wait_deadline) do
    now = state.clock.()
    is_integer(now) and (now >= wait_deadline or now >= state.profile.deadline_ms)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp proven_reply_expiry?(_, _), do: false

  defp prior_v2_pair_proven(%{completed_pair: nil, latest_native: nil}), do: :ok

  defp prior_v2_pair_proven(state) do
    case completed_pair_proven?(state) do
      :ok -> :ok
      _ -> {:error, :unknown}
    end
  end

  defp same_release_wait?(saved, current) when is_map(saved) and is_map(current) do
    Enum.all?([:action_id, :source_id, :correlation_id, :occurrence, :deadline_ms], fn key ->
      Map.get(saved, key) == Map.get(current, key)
    end)
  end

  defp same_release_wait?(_, _), do: false

  defp v2_release_record(state, :primary, event, operation_id) do
    case state.approval do
      %{event: saved_event, operation_id: ^operation_id, request: request, facts: facts} = record ->
        if saved_event == event and request == input_request(event, operation_id) and
             facts == input_facts() and
             Map.get(record, :release_state) in [
               :pending,
               :unknown,
               :committed,
               :committed_expired
             ],
           do: {:ok, record},
           else: {:error, :identity}

      _ ->
        {:error, :identity}
    end
  end

  defp v2_release_record(state, :reply, event, operation_id) do
    case state.reply do
      %{
        event: saved_event,
        operation_id: ^operation_id,
        request: request,
        facts: facts,
        wait: wait
      } = record ->
        if saved_event == event and request == input_request(event, operation_id) and
             facts == input_facts() and is_map(wait) and
             Map.get(record, :release_state) in [
               :pending,
               :unknown,
               :committed,
               :committed_expired
             ],
           do: {:ok, record},
           else: {:error, :identity}

      _ ->
        {:error, :identity}
    end
  end

  defp v2_pending_matches?(record, pending) do
    Map.get(record, :key) == Map.get(pending, :key) and
      Map.get(record, :requirement) == Map.get(pending, :requirement)
  end

  defp v2_release_unknown(state, kind, operation_id, record, reason) do
    poison =
      {:v2_release, kind, operation_id, record.facts, record.request, Map.get(record, :wait),
       reason}

    {{:unknown, :unavailable}, %{state | poison: poison}}
  end

  defp valid_v2_release_evidence(profile, evidence)
       when is_map(evidence) and not is_struct(evidence) do
    if Map.get(evidence, :purpose) == :command and Map.get(evidence, :tenant) == profile.tenant and
         is_map(Map.get(evidence, :evidence)) do
      :ok
    else
      {:error, :purpose}
    end
  end

  defp valid_v2_release_evidence(_, _), do: {:error, :purpose}

  defp fixed_release_scope(profile, event) do
    if event.conversation_id == profile.conversation_id, do: :ok, else: {:error, :scope}
  end

  defp release_source_id(profile, :primary), do: profile.source_id
  defp release_source_id(profile, :reply), do: profile.reply_source_id
  defp release_handle(state, :primary), do: state.handles.input
  defp release_handle(state, :reply), do: state.handles.reply_input
  defp release_mode(:primary), do: :release
  defp release_mode(:reply), do: :reply_release

  # A retryable recovery delivers and observes again: the delivery pass
  # appends what the window shows now (a reply input that a full window hid
  # included) before recovery reads the conversation. When the window itself
  # cannot be read, nothing was delivered or observed: the recovery stays the
  # retry state, instead of a terminal observation failure, until its reads
  # succeed.
  defp advance_once(%{poison: {:v2_recovery, _reason} = retry} = state) do
    case deliver_pending(%{state | poison: nil, phase: :idle}) do
      {:ok, delivered} ->
        case observe_input(delivered) do
          {_reply, %{poison: {:rediscover, _cause}} = failed} ->
            {{:unknown, :recovery}, %{failed | poison: retry}}

          {_reply, %{poison: {:input_observation, cause}} = failed}
          when cause in [:exception, :exit] ->
            {{:unknown, :recovery}, %{failed | poison: retry}}

          other ->
            other
        end

      {:error, %{poison: {:rediscover, _cause}} = failed, _reply} ->
        {{:unknown, :recovery}, %{failed | poison: retry}}

      {:error, failed, reply} ->
        {reply, failed}
    end
  end

  defp advance_once(%{poison: {:reply_association, _operation, _}} = state),
    do: reconcile_reply_association(state)

  defp advance_once(%{poison: {:reply_ack, key, nonce, _}} = state),
    do: reconcile_reply_ack(state, key, nonce)

  defp advance_once(%{poison: {:reply_custody, operation}} = state),
    do: reconcile_reply_custody(state, operation)

  defp advance_once(%{poison: {:reply_release_live, operation}} = state),
    do: reconcile_v2_release(state, :reply, operation)

  defp advance_once(%{poison: {:reply_native_input, _reason}} = state),
    do: reconcile_v2_native_uncertainty(state)

  defp advance_once(%{poison: {:native_event, _reason}} = state) do
    if reply_profile?(state.profile),
      do: reconcile_v2_native_uncertainty(state),
      else: {{:blocked, :native_event}, state}
  end

  defp advance_once(%{poison: {:native_child_exit, _child}} = state) do
    if reply_profile?(state.profile),
      do: reconcile_v2_native_uncertainty(state),
      else: {{:blocked, :native_child_exit}, state}
  end

  defp advance_once(%{poison: {:native_child_exit, _child, _reason}} = state) do
    if reply_profile?(state.profile),
      do: reconcile_v2_native_uncertainty(state),
      else: {{:blocked, :native_child_exit}, state}
  end

  defp advance_once(%{poison: {:native_input, _reason}} = state) do
    if reply_profile?(state.profile),
      do: reconcile_v2_native_uncertainty(state),
      else: {{:blocked, :native_input}, state}
  end

  defp advance_once(%{poison: {:ack, key, nonce, receipt}} = state),
    do: reconcile_ack(state, key, nonce, receipt)

  defp advance_once(%{poison: {:input, operation, _}} = state),
    do: reconcile_input(state, operation)

  defp advance_once(%{poison: {:reply_input, operation}} = state),
    do: reconcile_reply_input(state, operation)

  defp advance_once(%{poison: {:release, operation, _facts, _request, _}} = state),
    do: reconcile_release(state, operation)

  defp advance_once(%{poison: {:v2_release, kind, operation, _, _, _, _}} = state),
    do: reconcile_v2_release(state, kind, operation)

  defp advance_once(%{poison: {:association, operation, _}} = state),
    do: reconcile_association(state, operation)

  defp advance_once(%{poison: {:run_create, _}} = state),
    do: reconcile_run_create(state)

  defp advance_once(%{poison: {:attempt, _}} = state),
    do: reconcile_attempt(state)

  defp advance_once(%{poison: {:answer, _, _}} = state),
    do: reconcile_answer(state)

  defp advance_once(%{poison: {:answer, _}} = state),
    do: reconcile_answer(state)

  defp advance_once(%{poison: {:delivery, key, _reason}} = state),
    do: retry_delivery(state, key)

  # A window read failed after earlier work: nothing was delivered or
  # observed, so the retry repeats discovery, read first, and never repeats
  # a write that was already proven.
  defp advance_once(%{poison: {:rediscover, _cause}} = state),
    do: deliver_retry(state)

  defp advance_once(%{poison: {:answer_delivery_receipt, revision}} = state),
    do: resume_answer_delivery(state, revision)

  defp advance_once(%{poison: {:association_delivery_receipt, kind, revision}} = state),
    do: resume_association_delivery(state, kind, revision)

  # The reply observation only reads, from the resume point its committed
  # reply input set: a read that failed repeats on the next advance, after
  # the delivery pass. An unproven reply item stays fenced, as on main.
  defp advance_once(%{poison: {:reply_observation, :unavailable}} = state),
    do: deliver_retry(state)

  defp advance_once(%{poison: {:delivery_ack, key, nonce, _reason}} = state),
    do: confirm_delivery_ack(state, key, nonce)

  defp advance_once(%{poison: {:delivery_ack_unsent, key, nonce, _reason}} = state),
    do: send_unsent_delivery_ack(state, key, nonce)

  defp advance_once(%{poison: {:delivery_refused, _key, code}} = state),
    do: {{:blocked, {:delivery_refused, code}}, state}

  defp advance_once(%{poison: {:intent, _mode, code}} = state),
    do: {{:blocked, {:intent, code}}, state}

  defp advance_once(%{poison: poison} = state) when not is_nil(poison),
    do: {{:blocked, elem(poison, 0)}, state}

  # Every non-poison advance first delivers the tenant's committed,
  # not-yet-delivered intents in command sequence order; a failure stops the
  # pass and no phase step runs.
  defp advance_once(state), do: deliver_then_step(state)

  defp advance_step(%{approval: %{release_state: :committed_expired}} = state),
    do: advance_committed_expired(state)

  defp advance_step(%{approval: %{input_state: :committed_expired}} = state),
    do: advance_committed_expired(state)

  defp advance_step(%{reply: %{release_state: :committed_expired}} = state),
    do: advance_committed_expired(state)

  defp advance_step(%{reply: %{input_state: :committed_expired}} = state),
    do: advance_committed_expired(state)

  defp advance_step(%{phase: :idle} = state), do: observe_input(state)
  defp advance_step(%{phase: :association} = state), do: associate(state)
  defp advance_step(%{phase: :create_run} = state), do: create_run(state)
  defp advance_step(%{phase: :begin_attempt} = state), do: begin_attempt(state)
  defp advance_step(%{phase: :start_engine} = state), do: start_engine(state)
  defp advance_step(%{phase: :start_input} = state), do: start_input(state)
  defp advance_step(%{phase: :result} = state), do: observe_result(state)
  defp advance_step(%{phase: :answer} = state), do: append_answer(state)
  defp advance_step(%{phase: :reply_observe} = state), do: observe_reply(state)
  defp advance_step(%{phase: :reply_association} = state), do: associate_reply(state)
  defp advance_step(%{phase: :reply_input} = state), do: submit_reply_input(state)
  defp advance_step(%{phase: :reply_ack} = state), do: acknowledge_reply(state)
  defp advance_step(%{phase: :ack} = state), do: acknowledge(state)
  defp advance_step(state), do: {{:blocked, :invalid_phase}, state}

  # The delivery pass: pending outbox items in command sequence order.
  # Delivery-only items (association, answer) are acknowledged with their
  # original key and nonce once their append is proven; primary and reply
  # input items stay pending, marked delivered, until their native-work
  # custody and teardown checks complete. A retried poisoned delivery runs
  # the identical intent again before anything else. When the window itself
  # cannot be read, nothing was delivered: the retry state stays (an unknown
  # delivery, or `{:rediscover, cause}` after a window read failed), discovery
  # is retried on the next advance, read first, and no later work of this
  # conversation runs meanwhile.
  defp deliver_retry(%{poison: retry} = state) do
    case deliver_pending(%{state | poison: nil}) do
      {:ok, state} ->
        advance_once(state)

      {:error, %{poison: {:rediscover, _cause}} = failed, reply} ->
        {reply, %{failed | poison: retry}}

      {:error, state, reply} ->
        {reply, state}
    end
  end

  # An unknown or failed delivery is retried with the identical intent,
  # before any later intent of its conversation, while its item is pending.
  # An item acknowledged meanwhile is never seen by a delivery pass again,
  # and the channel never appends it: only its Conversation row, compared
  # with the intent its retained command binds, proves that delivery. Without
  # the row it is the `{:delivery_unproven, kind, key}` fence, and another
  # record in its place is the Conversation's refusal. An item, receipt or
  # row that cannot be read keeps the retry.
  defp retry_delivery(state, key) do
    case read_delivery_item(state, key) do
      {:ok, %{state: :acked} = item} -> acked_delivery(state, key, item)
      {:ok, %{state: :pending}} -> retry_pending_delivery(state, key)
      _ -> {{:unknown, :delivery}, state}
    end
  end

  # The unresolved item read pending: the retry's window must still show it
  # before any later item is consumed. A window that no longer shows it (an
  # acknowledgement landed between the two reads) consumes nothing: the key
  # is read again, its receipt first, then its row. Either way the window's
  # input items are held first (`pending_window/1`).
  defp retry_pending_delivery(state, key) do
    case pending_window(state) do
      {:ok, items, state} -> retry_window(state, key, items)
      {:error, _cause} -> {{:unknown, :delivery}, state}
    end
  end

  defp retry_window(%{poison: retry} = state, key, items) do
    if Enum.any?(items, &(&1.idempotency_key == key)) do
      case deliver_items(%{state | poison: nil}, items) do
        {:ok, state} ->
          advance_once(state)

        {:error, %{poison: {:rediscover, _cause}} = failed, reply} ->
          {reply, %{failed | poison: retry}}

        {:error, state, reply} ->
          {reply, state}
      end
    else
      case read_delivery_item(state, key) do
        {:ok, %{state: :acked} = item} -> acked_delivery(state, key, item)
        _ -> {{:unknown, :delivery}, state}
      end
    end
  rescue
    _ -> {{:unknown, :delivery}, state}
  catch
    _, _ -> {{:unknown, :delivery}, state}
  end

  # An acknowledged retry item is decided as a delivery pass decides an item
  # that it observed acknowledged (`acked_decision/5`), after the same
  # ordered prefix (`prefix_proven/3`): each earlier held item and each item
  # that the custody of a round not yet restored names, in command order,
  # from their latest observations. An earlier breach fences first; an
  # earlier item or a discovery that cannot be read keeps the retry.
  defp acked_delivery(state, key, item) do
    pass = %{window: [], seen: %{key => item}, custody: :unread}

    with {:ok, mode, intent} <- delivery_intent(state, item) do
      case prefix_proven(state, pass, item.sequence) do
        {:ok, state, pass} ->
          case acked_decision(state, pass, Map.get(pass.seen, key, item), mode, intent) do
            {:ok, _observed} ->
              deliver_retry(%{state | delivered: Map.put(state.delivered, key, nil)})

            {:error, _reason} ->
              {{:unknown, :delivery}, state}

            failure ->
              unconfirmed_delivery(state, failure)
          end

        {{:error, _reason}, state} ->
          {{:unknown, :delivery}, state}

        {failure, state} ->
          unconfirmed_delivery(state, failure)
      end
    else
      _ -> {{:unknown, :delivery}, state}
    end
  end

  # An item of this channel by its original key, whatever its destination.
  defp read_delivery_item(state, key) do
    case DurableLog.Store.read(state.command_store, :read_ack, [key]) do
      {:ok, %{destination: destination}}
      when destination in [@destination, @reply_destination, @delivery_destination] ->
        read_original_item(state, key, destination)

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  # The custody kind of a delivery-only item (`:association`,
  # `:reply_association` or `:answer`): the round's carried name, else
  # derived from the retained intent and the persisted round, also before
  # the round is restored: an association of another input than the round's
  # primary is its reply association. The primary's item is taken from
  # `seen`, a delivery pass's own observation of it, before it is read
  # again. `{:ok, kind, observed}`, with the primary's item when it was read
  # here (`observed_settled/2` decides it), or `:error`.
  defp custody_kind(state, key, mode, intent, seen) do
    carried = if is_map(state.current), do: Map.get(state.current, :deliveries, %{}), else: %{}

    case Enum.find(carried, fn {_kind, {carried_key, _nonce}} -> carried_key == key end) do
      {kind, _receipt} ->
        {:ok, kind, %{}}

      nil when mode == :association ->
        with {:ok, primary, observed} <- round_primary_input(state, seen) do
          reply? = not is_nil(primary) and primary != intent.input_message_id
          {:ok, if(reply?, do: :reply_association, else: :association), observed}
        end

      nil ->
        {:ok, mode, %{}}
    end
  end

  # The round's primary input: the restored round's, else the one that the
  # persisted custody facts name (`nil` without facts, and in version 1),
  # with the primary's item when it was read here.
  defp round_primary_input(%{current: %{input_id: input}}, _seen), do: {:ok, input, %{}}

  defp round_primary_input(state, seen) do
    with true <- reply_profile?(state.profile),
         {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         {:ok, %{primary_key: key}} <- Intents.metadata(snapshot.fields, state.profile.tenant),
         {:ok, item, observed} <- seen_item(state, seen, key, @destination),
         {:ok, event, _operation, _revision, _intent} <- recover_input(state, item) do
      {:ok, event.input_id, observed}
    else
      false -> {:ok, nil, %{}}
      {:ok, nil} -> {:ok, nil, %{}}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # An item by its latest observation in a delivery pass (`seen`), else read
  # by its key: `{:ok, item, observed}`, with the item when it was read here.
  defp seen_item(state, seen, key, destination) do
    case Map.fetch(seen, key) do
      {:ok, item} ->
        {:ok, item, %{}}

      :error ->
        with {:ok, item} <- read_original_item(state, key, destination),
             do: {:ok, item, %{key => item}}
    end
  end

  # A primary that deriving a kind read by its key is a newer observation
  # than anything the caller holds: it is decided like a held item before
  # anything goes on (`item_decision/3`). `:ok` while it is settled or still
  # pending; a fence, or `{:error, reason}` when its check cannot be read.
  defp observed_settled(state, observed) do
    Enum.reduce_while(observed, :ok, fn {_key, item}, :ok ->
      case item_decision(state, :input, item) do
        :ok -> {:cont, :ok}
        {:undelivered, _kind} -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  # The append of a delivery-only item is proven and only its acknowledgement
  # is unknown. The original acknowledgement receipt (key, nonce and digest)
  # decides, read-only, before anything advances: an acknowledgement committed
  # with that receipt is confirmed, one with another nonce is reported as
  # superseded, and a pending, unreadable or mismatching item stays fenced.
  # A pending item is never acknowledged again here: an acknowledgement paused
  # before its commit still reads pending elsewhere, so a second write would
  # race it. Only a fenced reopen, which ends that writer, acknowledges again.
  defp confirm_delivery_ack(state, key, nonce) do
    receipt = Elzoo.DurableLog.Codec.ack_receipt(key, nonce)

    case DurableLog.confirm_ack(state.command_store, receipt) do
      {:committed, _} ->
        case acknowledged_outbox_item(state, key, nonce, @delivery_destination) do
          :ok -> advance_once(%{state | poison: nil})
          _ -> {{:unknown, :delivery}, state}
        end

      :superseded ->
        {{:blocked, :delivery_ack_superseded}, state}

      _ ->
        {{:unknown, :delivery}, state}
    end
  rescue
    _ -> {{:unknown, :delivery}, state}
  catch
    _, _ -> {{:unknown, :delivery}, state}
  end

  # A delivery-only acknowledgement that was never sent, because its item
  # could not be read: the retry reads that exact item by its original key.
  # Still pending with its original nonce, the first acknowledgement is sent
  # now and the advance continues; acknowledged with the original receipt
  # (key, nonce and digest), it is confirmed; acknowledged with another
  # nonce, it is superseded and stays fenced. Unreadable, or a dispatched
  # acknowledgement whose outcome is unknown, keeps the host fenced.
  defp send_unsent_delivery_ack(state, key, nonce) do
    case read_original_item(state, key, @delivery_destination) do
      {:ok, %{state: :pending, nonce: ^nonce}} ->
        case dispatch_ack(state, key, nonce, @delivery_destination) do
          :ok ->
            advance_once(%{state | poison: nil})

          {:error, reason} ->
            {{:unknown, :delivery}, %{state | poison: {:delivery_ack, key, nonce, reason}}}
        end

      {:ok, %{state: :acked, nonce: ^nonce}} ->
        receipt = Elzoo.DurableLog.Codec.ack_receipt(key, nonce)

        case DurableLog.confirm_ack(state.command_store, receipt) do
          {:committed, _} ->
            if acknowledged_outbox_item(state, key, nonce, @delivery_destination) == :ok,
              do: advance_once(%{state | poison: nil}),
              else: {{:unknown, :delivery}, state}

          :superseded ->
            {{:blocked, :delivery_ack_superseded},
             %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

          _ ->
            {{:unknown, :delivery}, state}
        end

      _ ->
        {{:unknown, :delivery}, state}
    end
  rescue
    _ -> {{:unknown, :delivery}, state}
  catch
    _, _ -> {{:unknown, :delivery}, state}
  end

  # A restarted host has no memory of a delivery acknowledgement, so before
  # recovery moves past a completed delivery-only command it rebuilds that
  # command's delivery identity from durable evidence: the stream row that
  # notified it lies at or after its resource revision, so the outbox items
  # from the stream head down to there are read until the one whose notice
  # names this operation at that revision. `{:ok, key, nonce}` when that item
  # is still pending or was acknowledged with its original receipt (key,
  # nonce and digest): the caller carries both in the round's custody
  # (`carry_delivery/4`), and the round's first native acknowledgement waits
  # for a positive confirmation of that receipt (`deliveries_confirmed/1`).
  # Another nonce's acknowledgement is `{:superseded, key, nonce}`. An item
  # found whose acknowledgement does not verify keeps its key, held as the
  # `kind` item: `{:error, {:held, {kind, destination, key}}}`. Anything else
  # is `{:error, :delivery_ack}`.
  defp delivery_receipt(state, kind, operation, revision) do
    case delivery_item(state, operation, revision) do
      {:ok, item, _observed} -> item_receipt(item, kind)
      _ -> {:error, :delivery_ack}
    end
  end

  # The delivery item of a command, by its operation and committed revision,
  # as read now: `{:ok, item, observed}` with `observed`, the other items of
  # this channel that the scan read on its way, by key, or `{:error,
  # reason}`.
  defp delivery_item(state, operation, revision) do
    stream = checked_stream(state.profile.tenant)

    with {:ok, head} <- DurableLog.Store.read(state.command_store, :head, [stream]) do
      find_delivery_item(state, stream, {operation, revision}, head.revision, revision, %{})
    end
  rescue
    _ -> {:error, :delivery_ack}
  catch
    _, _ -> {:error, :delivery_ack}
  end

  # The receipt of a found item, decided from the read that found it, the
  # same row that a confirmation would read again: pending, or acknowledged
  # with its own nonce and the digest that its original receipt binds.
  defp item_receipt(item, kind) do
    key = item.idempotency_key
    nonce = item.nonce

    cond do
      item.state == :pending ->
        {:ok, key, nonce}

      not Elzoo.DurableLog.Codec.item_valid?(item) ->
        {:error, {:held, {kind, @delivery_destination, key}}}

      item.ack_nonce != nonce ->
        {:superseded, key, nonce}

      item.ack_digest == Elzoo.DurableLog.Codec.ack_receipt(key, nonce).digest ->
        {:ok, key, nonce}

      true ->
        {:error, {:held, {kind, @delivery_destination, key}}}
    end
  rescue
    _ -> {:error, {:held, {kind, @delivery_destination, item.idempotency_key}}}
  end

  # From the stream head down to the command's resource revision: the
  # notifying row of a command lies at or after that revision, and a recent
  # command's row lies near the head. Only a positive exact match ends the
  # scan, validated as read: an empty slot, an unrelated item, and a row this
  # Store cannot read as one of its profile's destinations (another
  # profile's item, reported malformed) are not this item, so the scan goes
  # on. Each item of this channel that it reads on the way is kept in
  # `observed`, a later observation than any window. A storage failure stops
  # it, and reaching the revision without a match is `{:error, :absent}`:
  # the caller stays fenced either way.
  defp find_delivery_item(_state, _stream, _command, from, through, _observed)
       when from < through or from < 1,
       do: {:error, :absent}

  defp find_delivery_item(state, stream, {operation, revision} = command, from, through, observed) do
    key = Elzoo.DurableLog.Codec.item_key(stream, from, 1)

    case DurableLog.Store.read(state.command_store, :read_ack, [key]) do
      {:ok, item} when is_map(item) ->
        if delivery_item_for?(item, state.profile, operation, revision) do
          with {:ok, item} <- original_item(state, key, @delivery_destination, item),
               do: {:ok, item, observed}
        else
          observed = observe_crossed(state, key, item, observed)
          find_delivery_item(state, stream, command, from - 1, through, observed)
        end

      unrelated when unrelated in [{:ok, :absent}, {:error, :malformed}] ->
        find_delivery_item(state, stream, command, from - 1, through, observed)

      _ ->
        {:error, :unavailable}
    end
  end

  defp observe_crossed(state, key, %{destination: destination} = item, observed)
       when destination in [@destination, @reply_destination, @delivery_destination] do
    case original_item(state, key, destination, item) do
      {:ok, item} -> Map.put(observed, key, item)
      _ -> observed
    end
  end

  defp observe_crossed(_state, _key, _item, observed), do: observed

  defp delivery_item_for?(item, profile, operation, revision) do
    item.destination == @delivery_destination and
      match?(
        {:ok, %{"operation_id" => ^operation, "revision" => ^revision}},
        delivery_notice(item, profile)
      )
  end

  defp deliver_then_step(state) do
    case deliver_pending(state) do
      {:ok, state} -> advance_step(state)
      {:error, state, reply} -> {reply, state}
    end
  end

  defp deliver_pending(state) do
    # The window holds the lowest pending sequences, so delivering what it
    # shows keeps command sequence order; a full window hides only later
    # intents. Admission and the observation step keep their own full-window
    # refusals. A window that cannot be read delivers nothing: the advance
    # keeps the read-only resume state `{:rediscover, cause}`.
    case pending_window(state) do
      {:ok, items, state} -> deliver_items(state, items)
      {:error, cause} -> fail_delivery(state, {:rediscover, cause}, {:unknown, :delivery})
    end
  end

  # The window's items in order, its input items already held
  # (`pending_window/1`). The pass keeps the latest observation of each item
  # that it knows (`seen`): the window shows its items pending, and a later
  # read in this pass (custody discovery) replaces that entry; the older
  # window never overrides a later observation. The items that the persisted
  # custody of a round not yet restored names are discovered at most once
  # per pass, and only when an item after that round's first item needs
  # them (`pass_custody/3`).
  defp deliver_items(state, window) do
    pass = %{
      window: window,
      seen: Map.new(window, &{&1.idempotency_key, &1}),
      custody: :unread
    }

    deliver_window(state, window, pass)
  rescue
    _ -> fail_delivery(state, {:rediscover, :exception}, {:unknown, :delivery})
  catch
    _, _ -> fail_delivery(state, {:rediscover, :exit}, {:unknown, :delivery})
  end

  defp deliver_window(state, [], _pass), do: {:ok, state}

  defp deliver_window(state, [item | rest], pass) do
    if item.destination in [@destination, @reply_destination] and
         Map.has_key?(state.delivered, item.idempotency_key) do
      deliver_window(state, rest, pass)
    else
      case deliver_item(state, item, pass) do
        {:ok, state, pass} -> deliver_window(state, rest, pass)
        {:error, state, reply} -> {:error, state, reply}
      end
    end
  end

  defp fail_delivery(state, poison, reply) do
    {:error, %{state | poison: poison}, reply}
  end

  # One item: an unreadable item blocks this tenant's ordered delivery; our
  # items are rebuilt from their committed receipts, verified against their
  # bound digest and appended through the conversation owner. A well-formed
  # item of another conversation is not one of this conversation's intents:
  # it is neither delivered nor allowed to block them (admission skips it the
  # same way), and the observation step keeps its own rules for it. The
  # window's input items were held when it was read (`pending_window/1`),
  # also those that a failure here keeps this pass from reaching. The
  # ordered prefix before it is then checked (`prefix_proven/3`) before the
  # append; when a read fails, the retry is keyed on this item, so an
  # acknowledgement that removes it from the window meanwhile is reconciled
  # by its key, after the same prefix, before anything else.
  defp deliver_item(state, item, pass) do
    case delivery_intent(state, item) do
      {:ok, mode, dto} ->
        case prefix_proven(state, pass, item.sequence) do
          {:ok, state, pass} -> deliver_current(state, item, mode, dto, pass)
          {{:error, _reason}, state} -> held_unreadable(state, item)
          {failure, state} -> fence_delivery(state, failure)
        end

      {:error, :foreign} ->
        {:ok, state, pass}

      {:error, reason} ->
        fail_delivery(state, {:delivery, item.idempotency_key, reason}, {:unknown, :delivery})
    end
  end

  # The ordered prefix before the command sequence `before`: each held item
  # of the conversation and each item that the custody of a round not yet
  # restored names (`pass_custody/3`), decided in command order from their
  # latest observations (`held_items_proven/4`). When discovery cannot read
  # everything, what it named and read is kept, and only the items before
  # the first sequence at which an item it could not name can lie
  # (`discovery_limit/4`) are decided: a breach among them fences, else the
  # read is retried. `{:ok, state, pass}`, `{failure, state}`, or
  # `{{:error, reason}, state}`.
  defp prefix_proven(state, pass, before) do
    case pass_custody(state, pass, before) do
      {:ok, pass, custody} ->
        case held_items_proven(state, before, custody, pass.seen) do
          {:ok, state} -> {:ok, state, pass}
          failure -> failure
        end

      {:error, reason, custody, seen, base} ->
        limit = min(before, discovery_limit(state, base, custody, seen))

        case held_items_proven(state, limit, custody, seen) do
          {:ok, state} -> {{:error, reason}, state}
          failure -> failure
        end
    end
  end

  # A held check that could not be read: the retry is keyed on this item, and
  # the exact held item that could not be read stays held (`held_proven/3`).
  defp held_unreadable(state, item),
    do: fail_delivery(state, {:delivery, item.idempotency_key, :held}, {:unknown, :delivery})

  defp fence_delivery(state, failure) do
    {reply, fenced} = unconfirmed_delivery(state, failure)
    {:error, fenced, reply}
  end

  # The item itself, by its latest observation in this pass. Shown pending,
  # it is appended: an acknowledgement that this host has not observed can
  # only meet the append in flight. Seen acknowledged by a later read of this
  # pass, it is never appended: its own receipt and its row decide, as for
  # any acknowledged item of this channel, under the kind that the pass's
  # custody discovery named it (`pass_kind/5`). A primary that deriving the
  # kind had to read is decided first and kept as this pass's observation.
  defp deliver_current(state, item, mode, dto, pass) do
    key = item.idempotency_key

    case Map.get(pass.seen, key, item) do
      %{state: :acked} = latest ->
        case acked_decision(state, pass, latest, mode, dto) do
          {:ok, observed} ->
            {:ok, %{state | delivered: Map.put(state.delivered, key, nil)},
             %{pass | seen: Map.merge(pass.seen, observed)}}

          {:error, _reason} ->
            fail_delivery(state, {:delivery, key, :acked}, {:unknown, :delivery})

          failure ->
            fence_delivery(state, failure)
        end

      _pending ->
        case deliver_owner(state, item, mode, dto) do
          {:ok, state} -> {:ok, state, pass}
          failure -> failure
        end
    end
  end

  # An item observed acknowledged is never appended. Its own receipt
  # decides first: another nonce's acknowledgement is the superseded fence,
  # whatever its kind or row. Else its row decides, under the kind that the
  # pass's custody discovery named it (`pass_kind/5`), after a primary that
  # deriving the kind had to read. `{:ok, observed}` with that primary's
  # read, a fence, or `{:error, reason}`.
  defp acked_decision(state, pass, item, mode, dto) do
    key = item.idempotency_key

    if item.ack_nonce != item.nonce do
      {:superseded, key, item.nonce}
    else
      with {:ok, kind, observed} <- pass_kind(state, pass, key, mode, dto),
           :ok <- observed_settled(state, observed),
           :ok <- intent_delivery(state, kind, item, mode, dto) do
        {:ok, observed}
      else
        :error -> {:error, :kind}
        failure -> failure
      end
    end
  end

  # The kind of an item that this pass observed acknowledged: as its custody
  # discovery named it, with no further read; else `custody_kind/5`, which
  # takes the round's primary from this pass's observations.
  defp pass_kind(state, pass, key, mode, dto) do
    named =
      case pass.custody do
        {_root, items} when is_list(items) -> Enum.find(items, &match?({_, _, ^key}, &1))
        _ -> nil
      end

    case named do
      {kind, _destination, _key} -> {:ok, kind, %{}}
      nil -> custody_kind(state, key, mode, dto, pass.seen)
    end
  end

  # The pass's custody: `:unread`, then `{root, :later}` (`root` is `nil`, or
  # the round's first outbox sequence with what names its items, from
  # `custody_root/2`), then `{root, items}` once an item after that first
  # sequence needed them: no custody item lies before it. The root's own
  # read (a version 1 primary read by its key) and discovery's reads are
  # later observations than the window and replace its entries in `seen`,
  # also for the root's first item itself. `{:ok, pass, items}` with the
  # items that this item's check needs, or `{:error, reason, items, seen,
  # base}` with what discovery named and read before a read failed
  # (`custody_items/2`; `nil` base when the root could not be read).
  defp pass_custody(state, %{custody: :unread} = pass, before) do
    case custody_root(state, pass.window) do
      {:ok, root} ->
        seen =
          case root do
            {_first, {:primary, primary}} -> Map.put(pass.seen, primary.idempotency_key, primary)
            _ -> pass.seen
          end

        pass_custody(state, %{pass | custody: {root, :later}, seen: seen}, before)

      {:error, reason} ->
        {:error, reason, [], pass.seen, nil}
    end
  end

  defp pass_custody(_state, %{custody: {nil, _items}} = pass, _before), do: {:ok, pass, []}

  defp pass_custody(state, %{custody: {{first, _names} = root, :later}} = pass, before) do
    if before > first do
      case custody_items(state, root) do
        {:ok, items, seen} ->
          {:ok, %{pass | custody: {root, items}, seen: Map.merge(pass.seen, seen)}, items}

        {:error, reason, items, seen, base} ->
          {:error, reason, items, Map.merge(pass.seen, seen), base}
      end
    else
      {:ok, pass, []}
    end
  end

  defp pass_custody(_state, %{custody: {_root, items}} = pass, _before), do: {:ok, pass, items}

  # An input item of this conversation is held from its first observation in
  # a window of this host (`hold_window/2`) until this host acknowledges it
  # (`release_held/2`).
  defp hold_input(state, %{destination: destination} = item)
       when destination in [@destination, @reply_destination],
       do: hold_item(state, {:input, destination, item.idempotency_key})

  defp hold_input(state, _item), do: state

  # A held item whose check could not be read stays held by its exact key,
  # whatever named it, until a later check settles it (`held_proven/3`).
  defp hold_item(state, {kind, destination, key}),
    do: %{state | held: Map.put(state.held, key, {kind, destination})}

  defp release_held(state, keys), do: %{state | held: Map.drop(state.held, keys)}

  # One read of this host's outbox window: `{:ok, items, state}`, or
  # `{:error, cause}` (`:read`, `:exception` or `:exit`) with nothing held.
  # A successful read holds the window's input items of this conversation
  # (`hold_window/2`) before the step that read it makes any other read or
  # decision, so no failure or early exit of that step loses them.
  defp pending_window(state) do
    case Outbox.pending(state.command_store, checked_stream(state.profile.tenant), @outbox_limit) do
      {:ok, items} -> {:ok, items, hold_window(state, items)}
      _ -> {:error, :read}
    end
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exit}
  end

  # Each primary or reply input item of the window whose notice verifies as
  # this conversation's (`delivery_notice/2`) is held, at most one entry per
  # key: once an acknowledgement removes it from the window, its own receipt
  # and its row decide (`unseen_held_proven/2`, `held_items_proven/4`). An
  # item of another conversation, or whose notice cannot be read, is not
  # held here; the step that reads the window keeps its own rule for it.
  defp hold_window(state, window) do
    Enum.reduce(window, state, fn item, state ->
      if item.destination in [@destination, @reply_destination] and
           match?({:ok, _notice}, delivery_notice(item, state.profile)),
         do: hold_input(state, item),
         else: state
    end)
  end

  defp deliver_owner(state, item, mode, dto) do
    result =
      case mode do
        :input -> Conversation.append_input(state.conversation.owner, dto)
        :association -> Conversation.associate_run(state.conversation.owner, dto)
        :answer -> Conversation.append_answer(state.conversation.owner, dto)
      end

    key = item.idempotency_key

    case result do
      {:ok, %{sequence: sequence}} ->
        delivery_proven(state, item, sequence)

      {:ok, :already_present} ->
        delivery_proven(state, item, nil)

      {:refused, code} ->
        fail_delivery(
          state,
          {:delivery_refused, key, code},
          {:blocked, {:delivery_refused, code}}
        )

      {unknown, :unresolved} when unknown == :unknown ->
        fail_delivery(state, {:delivery, key, :unresolved}, {:unknown, :delivery})

      {:error, reason} ->
        fail_delivery(state, {:delivery, key, reason}, {:unknown, :delivery})

      other ->
        fail_delivery(state, {:delivery, key, other}, {:unknown, :delivery})
    end
  rescue
    _ -> fail_delivery(state, {:delivery, item.idempotency_key, :exception}, {:unknown, :delivery})
  catch
    _, _ -> fail_delivery(state, {:delivery, item.idempotency_key, :exit}, {:unknown, :delivery})
  end

  # A proven append is recorded in `delivered`, with the conversation
  # sequence when it is known (an `already_present` redelivery proves the
  # append without it, which the association facts scan for when they need
  # it). Delivery-only items are then acknowledged at once with their
  # original key and nonce, and their recorded append result is what the
  # custody gate before the first native acknowledgement accepts as proof of
  # delivery in this lifetime; an unknown acknowledgement keeps both, so the
  # next advance confirms exactly that acknowledgement before anything else.
  # Primary and reply items stay pending until their native-work custody and
  # teardown checks complete.
  defp delivery_proven(state, item, sequence) do
    delivered = Map.put(state.delivered, item.idempotency_key, sequence)
    state = %{state | delivered: delivered}

    if item.destination == @delivery_destination do
      case acknowledge_original_item(state, item.idempotency_key, item.nonce, @delivery_destination) do
        :ok ->
          {:ok, state}

        # Not sent: the item could not be read before the write. The retry
        # keeps this item's original key and nonce and reads exactly it again.
        {:not_sent, :superseded} ->
          fail_delivery(
            state,
            {:delivery_ack, item.idempotency_key, item.nonce, :superseded},
            {:blocked, :delivery_ack_superseded}
          )

        {:not_sent, reason} ->
          fail_delivery(
            state,
            {:delivery_ack_unsent, item.idempotency_key, item.nonce, reason},
            {:unknown, :delivery}
          )

        # Sent and indeterminate: only read-only confirmation follows.
        {:error, reason} ->
          fail_delivery(
            state,
            {:delivery_ack, item.idempotency_key, item.nonce, reason},
            {:unknown, :delivery}
          )
      end
    else
      {:ok, state}
    end
  end

  # The intent of one pending item: `{:ok, mode, dto}` for an item of this
  # channel, `{:error, :foreign}` for an item of another destination,
  # principal or conversation, or `{:error, reason}` when the committed
  # receipt cannot be read or the binding does not verify.
  defp delivery_intent(state, item) do
    profile = state.profile

    with true <- item.destination in [@destination, @reply_destination, @delivery_destination],
         {:ok, notice} <- delivery_notice(item, profile) do
      case CheckedCommand.result(
             state.handles.input,
             result_scope(profile),
             {profile.tenant, profile.actor, notice["operation_id"]}
           ) do
        {:completed, result} ->
          if result.revision == notice["revision"] do
            Intents.delivery(result.response)
          else
            {:error, :revision}
          end

        # A result that could not be read is retried; any other outcome of
        # the item's command is final.
        {:unknown, reason} when reason != :not_observed ->
          {:error, :read}

        _ ->
          {:error, :result}
      end
    else
      false -> {:error, :foreign}
      {:error, :foreign} -> {:error, :foreign}
      {:error, :notice} -> {:error, :notice}
    end
  rescue
    _ -> {:error, :exception}
  catch
    :exit, _ -> {:error, :exit}
    _, _ -> {:error, :exception}
  end

  # The notice of one of this channel's items. Its identity fields are
  # validated before any classification: this stream's tenant, and a bounded
  # actor, conversation and operation. A notice of another actor or
  # conversation is then foreign; any other notice, a malformed identity
  # included (an `actor: null`), cannot be classified and blocks delivery
  # like any unreadable item.
  defp delivery_notice(item, profile) do
    with {:ok, notice} <- Jason.decode(item.payload),
         true <-
           Map.keys(notice) |> Enum.sort() == [
             "actor",
             "operation_id",
             "resource",
             "revision",
             "tenant",
             "type",
             "version"
           ],
         true <- notice["type"] == "checked_command" and notice["version"] == 1,
         true <- notice["tenant"] == profile.tenant,
         true <-
           bounded_text?(notice["actor"]) and bounded_text?(notice["resource"]) and
             bounded_text?(notice["operation_id"]),
         true <- is_integer(notice["revision"]) and notice["revision"] > 0 do
      if notice["actor"] == profile.actor and notice["resource"] == profile.conversation_id,
        do: {:ok, notice},
        else: {:error, :foreign}
    else
      _ -> {:error, :notice}
    end
  rescue
    _ -> {:error, :notice}
  end

  # The conversation sequence of a delivered input record: remembered when
  # the delivery itself returned it, otherwise scanned from the stream. The
  # record is present because its delivery is proven before any use.
  defp input_sequence(state, key, message_id) do
    case Map.get(state.delivered, key) do
      sequence when is_integer(sequence) ->
        {:ok, sequence}

      _ ->
        conversation_sequence(state, message_id, [:input])
    end
  end

  # The sequence for a custody fact, `nil` when the scan is unavailable: the
  # pair cannot be proven then, which is the same outcome as a damaged stream.
  defp custody_sequence(state, key, message_id) do
    case input_sequence(state, key, message_id) do
      {:ok, sequence} -> sequence
      _ -> nil
    end
  end

  # The sequence of the delivered record, as the delivery itself would have
  # remembered it; message readers that need the entry use `scan_pages/4`.
  defp conversation_sequence(state, message_id, kinds) do
    reference = %{
      target_tenant: state.profile.tenant,
      conversation_id: state.profile.conversation_id
    }

    case scan_pages(state, reference, 1, fn entry ->
           entry.kind in kinds and entry.message_id == message_id
         end) do
      {:ok, %{sequence: sequence}} when is_integer(sequence) and sequence >= 1 ->
        {:ok, sequence}

      {:ok, _entry} ->
        {:error, :damaged}

      error ->
        error
    end
  end

  # Scan the conversation forward in bounded pages until `match?` holds for
  # one entry or the head is reached: `{:ok, entry}`, `{:error, :absent}` or
  # the page read's error.
  defp scan_pages(state, reference, from, match?) do
    case Conversation.page(
           state.conversation.store,
           resource_scope(state.profile),
           reference,
           from,
           1_000
         ) do
      {:ok, %{revision: revision, entries: entries}} ->
        case Enum.find(entries, match?) do
          nil ->
            if revision >= from + length(entries),
              do: scan_pages(state, reference, from + length(entries), match?),
              else: {:error, :absent}

          entry ->
            {:ok, entry}
        end

      error ->
        error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  # One pass, in stream order, over the prefix `1..head` that the first page
  # samples: `fun.(entry, acc)` returns `{:cont, acc}` or `{:halt, result}`.
  # `{:halted, result}`, `{:done, acc}` at that head, or the page read's
  # error; later pages never extend the sampled prefix.
  defp fold_prefix(state, reference, acc, fun),
    do: fold_prefix(state, reference, 1, nil, acc, fun)

  defp fold_prefix(state, reference, from, head, acc, fun) do
    case Conversation.page(
           state.conversation.store,
           resource_scope(state.profile),
           reference,
           from,
           1_000
         ) do
      {:ok, %{revision: revision, entries: entries}} ->
        head = head || revision
        entries = Enum.take_while(entries, &(&1.sequence <= head))

        case Enum.reduce_while(entries, {:cont, acc}, fn entry, {:cont, acc} ->
               case fun.(entry, acc) do
                 {:halt, result} -> {:halt, {:halted, result}}
                 {:cont, acc} -> {:cont, {:cont, acc}}
               end
             end) do
          {:halted, _result} = halted ->
            halted

          {:cont, acc} ->
            next = from + length(entries)

            cond do
              next > head -> {:done, acc}
              entries == [] -> {:error, :damaged}
              true -> fold_prefix(state, reference, next, head, acc, fun)
            end
        end

      error ->
        error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  # Scan the whole delivered conversation for one association.
  defp conversation_association?(state, input_message_id, run_id) do
    reference = %{
      target_tenant: state.profile.tenant,
      conversation_id: state.profile.conversation_id
    }

    case scan_pages(state, reference, 1, fn entry ->
           entry.kind == :association and entry.input_message_id == input_message_id and
             entry.run_id == run_id
         end) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp advance_committed_expired(%{profile: profile, current: current} = state)
       when is_map(current) do
    if reply_profile?(profile),
      do: advance_expired_v2_current(state),
      else: {{:pending, :expired}, state}
  end

  defp advance_committed_expired(state), do: {{:pending, :expired}, state}

  defp advance_expired_v2_current(%{current: current} = state) do
    operation_id = native_operation(current.run_id, state)
    expected_attempt = attempt_id(current.run_id, state)

    case RunApprovalRelease.status(state.native.run_owner, current.run_id) do
      {:ok, %{operation_id: ^operation_id, current_attempt: ^expected_attempt}} ->
        continue_expired_v2_current(state)

      {:ok, %{operation_id: ^operation_id, current_attempt: nil}} ->
        {{:pending, :expired}, state}

      {:error, :not_found} ->
        {{:pending, :expired}, state}

      {:ok, _} ->
        {{:unknown, :native_identity}, %{state | poison: {:native_identity, current.run_id}}}

      _ ->
        {{:blocked, :native_owner}, state}
    end
  rescue
    _ -> {{:blocked, :native_owner}, state}
  catch
    _, _ -> {{:blocked, :native_owner}, state}
  end

  defp continue_expired_v2_current(
         %{reply: %{release_state: :committed_expired, item: nil}} = state
       ) do
    rediscover_expired_v2_reply(state)
  end

  defp continue_expired_v2_current(%{reply: %{input_state: :committed_expired, item: nil}} = state) do
    rediscover_expired_v2_reply(state)
  end

  defp continue_expired_v2_current(%{phase: :reply_ack} = state), do: acknowledge_reply(state)
  defp continue_expired_v2_current(%{phase: :ack} = state), do: acknowledge(state)
  defp continue_expired_v2_current(%{phase: :answer} = state), do: append_answer(state)
  defp continue_expired_v2_current(%{phase: :start_engine} = state), do: start_engine(state)
  defp continue_expired_v2_current(%{phase: :create_run} = state), do: create_run(state)
  defp continue_expired_v2_current(%{phase: :begin_attempt} = state), do: begin_attempt(state)

  defp continue_expired_v2_current(%{phase: :start_input} = state),
    do: {{:pending, :expired}, state}

  defp continue_expired_v2_current(state),
    do: observe_result(%{state | phase: :result})

  defp rediscover_expired_v2_reply(state) do
    case observe_reply(%{state | phase: :reply_observe}) do
      {{:reply_observed, _}, next_state} ->
        observe_result(%{next_state | phase: :result})

      other ->
        other
    end
  end

  # Before the observation idles or adopts an item, each held input that the
  # window no longer shows is checked by its key (`unseen_held_proven/2`): a
  # proven append does not keep the host idle past another nonce's
  # acknowledgement. When that read fails, the keys stay held and discovery
  # is retried, read first. The window's input items are held first
  # (`pending_window/1`).
  defp observe_input(state) do
    case pending_window(state) do
      {:ok, items, state} ->
        observe_window(state, items)

      # An unreadable window observes nothing: the next advance repeats
      # discovery, read first, instead of a terminal observation failure.
      {:error, cause} ->
        {{:unknown, :input_observation}, %{state | poison: {:rediscover, cause}}}
    end
  end

  defp observe_window(state, items) do
    case unseen_held_proven(state, items) do
      {:ok, state, items} ->
        if reply_profile?(state.profile),
          do: observe_reply_profile(state, items),
          else: observe_pending_input(state, items)

      {{:error, _reason}, state} ->
        {{:unknown, :input_observation}, %{state | poison: {:rediscover, :held}}}

      {failure, state} ->
        unconfirmed_delivery(state, failure)
    end
  rescue
    _ -> {{:unknown, :input_observation}, %{state | poison: {:rediscover, :exception}}}
  end

  # The window as last observed (`unseen_held_proven/2`): an item that a
  # later read saw acknowledged is never adopted.
  defp observe_pending_input(state, items) do
    case Enum.find(items, &(&1.destination == @destination and &1.state == :pending)) do
      nil ->
        # A full window may hide this conversation's next input behind other
        # conversations' items: discovery is retried, read first.
        if pending_window_full?(items) do
          {{:unknown, :input_observation}, %{state | poison: {:rediscover, :window}}}
        else
          {{:idle, :no_input}, state}
        end

      item ->
        observe_primary_item(state, item)
    end
  end

  defp observe_reply_profile(state, items) do
    primary = Enum.find(items, &(&1.destination == @destination))

    with {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         {:ok, metadata} <- retained_reply_metadata(snapshot, state.profile) do
      case metadata do
        nil ->
          cond do
            is_map(primary) ->
              observe_primary_item(state, primary)

            Enum.any?(items, &(&1.destination == @reply_destination)) ->
              {{:unknown, :reply_observation},
               %{state | poison: {:input_observation, :reply_without_primary}}}

            pending_window_full?(items) ->
              {{:unknown, :input_observation}, %{state | poison: {:rediscover, :window}}}

            true ->
              {{:idle, :no_input}, state}
          end

        metadata ->
          cond do
            is_map(primary) and primary.idempotency_key != metadata.primary_key and
                completed_pair_matches_metadata?(state.completed_pair, metadata) ->
              with {:ok, state} <- retire_previous_native(state) do
                observe_primary_item(state, primary)
              else
                _ ->
                  {{:unknown, :completed_pair}, %{state | poison: {:v2_recovery, :previous_pair}}}
              end

            is_nil(primary) and completed_pair_matches_metadata?(state.completed_pair, metadata) ->
              if pending_window_full?(items) do
                {{:unknown, :input_observation}, %{state | poison: {:rediscover, :window}}}
              else
                {{:idle, :no_input}, state}
              end

            true ->
              recover_v2_metadata(state, metadata, items, snapshot)
          end
      end
    else
      # The resource could not be read: observation is retried, read first,
      # and a recovery keeps its retry state.
      {:unknown, _} ->
        {{:unknown, :input_observation}, %{state | poison: {:rediscover, :resource}}}

      _ ->
        {{:unknown, :input_observation}, %{state | poison: {:input_observation, :metadata}}}
    end
  rescue
    _ -> {{:unknown, :input_observation}, %{state | poison: {:input_observation, :exception}}}
  catch
    _, _ -> {{:unknown, :input_observation}, %{state | poison: {:input_observation, :exit}}}
  end

  # This conversation's input item was held when the window was read
  # (`pending_window/1`), so a failed read here keeps it held.
  defp observe_primary_item(state, item) do
    item_result =
      if reply_profile?(state.profile),
        do: read_original_item(state, item.idempotency_key, @destination),
        else: {:ok, item}

    with {:ok, item} <- item_result,
         {:ok, event, operation_id, resource_revision, intent} <- recover_input(state, item) do
      observe_recovered_input(state, item, event, operation_id, resource_revision, intent)
    else
      failure -> observation_failure(state, failure)
    end
  rescue
    _ -> {{:unknown, :input_observation}, %{state | poison: {:input_observation, :exception}}}
  catch
    _, _ -> {{:unknown, :input_observation}, %{state | poison: {:input_observation, :exit}}}
  end

  defp observe_recovered_input(state, item, event, operation_id, resource_revision, intent) do
    case input_from_resource(state, event, resource_revision, item, intent) do
      {:ok, input, text, snapshot} ->
        if reply_profile?(state.profile) and not before_deadline?(state) do
          retained_event = %{event | text: text}

          approval = %{
            event: retained_event,
            operation_id: operation_id,
            request: input_request(retained_event, operation_id),
            facts: input_facts(),
            input_state: :committed_expired
          }

          {{:pending, :expired}, %{state | approval: approval}}
        else
          with {:ok, state} <- retire_previous_native(state),
               {:ok, phase, current} <-
                 retained_phase(
                   state,
                   %{
                     event: event,
                     input_id: input,
                     text: text,
                     operation_id: operation_id,
                     run_id: run_id(event, operation_id, state),
                     resource_revision: resource_revision,
                     item: %{
                       key: item.idempotency_key,
                       nonce: item.nonce,
                       sequence: item.sequence
                     },
                     association_operation:
                       association_operation(operation_id, input, state.profile),
                     answer_operation: answer_operation(operation_id, input, state.profile),
                     answer: nil,
                     terminal: nil
                   },
                   snapshot
                 ) do
            {{:observed, input}, %{state | current: current, phase: phase, approval: nil}}
          else
            failure -> observation_failure(state, failure)
          end
        end

      failure ->
        observation_failure(state, failure)
    end
  end

  # A delivery that its Conversation row contradicts, or that was
  # acknowledged without that row, ends the observation in its fence. A read
  # that failed, or a delivery that the delivery pass has not made yet,
  # retries the observation, read first; an unreadable acknowledgement proof
  # is observed again, read-only. Anything else contradicts the round.
  defp observation_failure(state, failure) do
    case failure do
      {:superseded, _key, _nonce} ->
        unconfirmed_delivery(state, failure)

      {:unproven, _kind, _key} ->
        unconfirmed_delivery(state, failure)

      {:conflict, _key, _code} ->
        unconfirmed_delivery(state, failure)

      {:error, :delivery_ack} ->
        {{:unknown, :recovery}, %{state | poison: {:v2_recovery, :delivery_ack}}}

      {:error, :read} ->
        {{:unknown, :input_observation}, %{state | poison: {:rediscover, :recovery}}}

      # A held item that the round names could not be read: it stays held by
      # its exact key, whatever the window shows on the retry.
      {:error, {:held, held}} ->
        {{:unknown, :input_observation},
         %{hold_item(state, held) | poison: {:rediscover, :recovery}}}

      _ ->
        {{:unknown, :input_observation}, %{state | poison: {:input_observation, :unknown}}}
    end
  end

  defp retained_reply_metadata(snapshot, profile) do
    case Intents.metadata(snapshot.fields, profile.tenant) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, metadata} ->
        {:ok,
         %{
           run_id: metadata.run_id,
           primary_key: metadata.primary_key,
           reply_key: metadata.reply_key
         }}

      {:error, _} ->
        {:error, :metadata}
    end
  rescue
    _ -> {:error, :metadata}
  end

  defp completed_pair_matches_metadata?(pair, metadata) when is_map(pair) do
    pair.run_id == metadata.run_id and pair.primary_key == metadata.primary_key
  end

  defp completed_pair_matches_metadata?(_, _), do: false

  defp recover_v2_metadata(state, metadata, pending, _snapshot) do
    with {:ok, item} <- read_original_item(state, metadata.primary_key, @destination),
         {:ok, event, operation_id, resource_revision, intent} <- recover_input(state, item),
         {:ok, input, text, snapshot} <-
           input_from_resource(state, event, resource_revision, item, intent),
         run_id <- run_id(event, operation_id, state),
         true <- run_id == metadata.run_id,
         true <- snapshot.revision >= resource_revision + 1,
         {:completed, %{revision: association_revision, response: association_response}} <-
           CheckedCommand.result(
             state.handles.association,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor,
              association_operation(operation_id, input, state.profile)}
           ),
         true <- association_revision == resource_revision + 1,
         true <- association_receipt?(association_response, input, run_id),
         {:ok, association_key, association_nonce} <-
           delivery_receipt(
             state,
             :association,
             association_operation(operation_id, input, state.profile),
             association_revision
           ),
         # The association's receipt first, then its row: an association
         # acknowledged without its row is fenced and never appended here,
         # and one whose check cannot be read stays held by its key.
         :ok <- recovered_delivery(state, :association, association_key),
         {:ok, reply} <- recover_v2_reply(state, metadata, pending, run_id),
         {:ok, answer} <- recovered_answer(state, operation_id, input, run_id),
         current <- %{
           event: event,
           input_id: input,
           text: text,
           operation_id: operation_id,
           run_id: run_id,
           resource_revision: resource_revision,
           item: %{
             key: item.idempotency_key,
             nonce: item.nonce,
             sequence: item.sequence,
             state: item.state
           },
           association_operation: association_operation(operation_id, input, state.profile),
           answer_operation: answer_operation(operation_id, input, state.profile),
           answer: nil,
           answer_revision: nil,
           terminal: nil,
           deliveries:
             recovered_deliveries(
               %{association: {association_key, association_nonce}},
               reply,
               answer
             )
         } do
      case v2_recovery_expiry(state, current) do
        :expired ->
          approval = %{
            event: %{event | text: text},
            operation_id: operation_id,
            request: input_request(%{event | text: text}, operation_id),
            facts: input_facts(),
            input_state: :committed_expired
          }

          {{:pending, :expired}, %{state | approval: approval, reply: reply}}

        :ok ->
          {{:observed, input},
           %{
             state
             | current: current,
               reply: reply,
               phase: :create_run,
               approval: nil,
               poison: nil,
               ambiguous_reply: if(is_nil(reply), do: :check, else: false)
           }}

        :unknown ->
          {{:unknown, :recovery}, %{state | poison: {:v2_recovery, operation_id}}}
      end
    else
      {:superseded, _key, _nonce} = failure ->
        unconfirmed_delivery(state, failure)

      {:unproven, _kind, _key} = failure ->
        unconfirmed_delivery(state, failure)

      {:conflict, _key, _code} = failure ->
        unconfirmed_delivery(state, failure)

      # An item found whose acknowledgement could not be verified stays held
      # by its key while recovery retries.
      {:error, {:held, held}} ->
        {{:unknown, :recovery}, %{hold_item(state, held) | poison: {:v2_recovery, :metadata}}}

      _ ->
        {{:unknown, :recovery}, %{state | poison: {:v2_recovery, :metadata}}}
    end
  rescue
    _ -> {{:unknown, :recovery}, %{state | poison: {:v2_recovery, :exception}}}
  catch
    _, _ -> {{:unknown, :recovery}, %{state | poison: {:v2_recovery, :exit}}}
  end

  # The delivery receipts a v2 recovery rebuilt: the primary association's,
  # the reply association's when the recovered reply carries one, and the
  # answer's once its command committed.
  defp recovered_deliveries(deliveries, reply, answer) do
    deliveries =
      case reply do
        %{association_delivery: {_key, _nonce} = receipt} ->
          Map.put(deliveries, :reply_association, receipt)

        _ ->
          deliveries
      end

    if is_nil(answer), do: deliveries, else: Map.put(deliveries, :answer, answer)
  end

  # A round restored before its answer replays holds the answer's delivery
  # item once the answer command committed, so the custody gate checks it
  # before the Run, the Attempt or the engine is touched again: `{:ok, nil}`
  # before the commit, `{:ok, {key, nonce}}`, another nonce's
  # acknowledgement as `{:superseded, key, nonce}`, or `{:error, :answer}`.
  defp recovered_answer(state, operation, input, run_id) do
    answer_operation = answer_operation(operation, input, state.profile)

    case CheckedCommand.result(
           state.handles.answer,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, answer_operation}
         ) do
      {:unknown, :not_observed} ->
        {:ok, nil}

      {:completed, %{revision: revision, response: response}} ->
        with true <- answer_receipt?(response, input, run_id, answer_id(input)),
             {:ok, key, nonce} <- delivery_receipt(state, :answer, answer_operation, revision) do
          {:ok, {key, nonce}}
        else
          {:superseded, _key, _nonce} = superseded -> superseded
          {:error, {:held, _held}} = held -> held
          _ -> {:error, :answer}
        end

      # Still unreadable: recovery retries. Any other retained outcome (a
      # denial, a refusal) settled with no outbox item: there is nothing to
      # deliver, and the restored round meets that outcome again.
      {:unknown, _reason} ->
        {:error, :answer}

      _settled ->
        {:ok, nil}
    end
  end

  defp v2_recovery_expiry(state, current) do
    if before_deadline?(state) do
      :ok
    else
      operation_id = native_operation(current.run_id, state)
      expected_attempt = attempt_id(current.run_id, state)

      case RunApprovalRelease.status(state.native.run_owner, current.run_id) do
        {:ok,
         %{
           operation_id: ^operation_id,
           current_attempt: ^expected_attempt
         }} ->
          :ok

        _ ->
          :expired
      end
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # Without reply facts the round's reply is the window's only reply item,
  # as on main: another conversation's pending reply item, or several reply
  # items, keep recovery retrying until they drain, and no item is adopted
  # that is not proven this round's. A window holding `@outbox_limit` items
  # may hide the reply, so an empty one reads as "no reply" only when it is
  # not full; a full one keeps discovery retryable.
  defp recover_v2_reply(state, %{reply_key: nil}, pending, run_id) do
    case Enum.filter(pending, &(&1.destination == @reply_destination)) do
      [] ->
        if pending_window_full?(pending), do: {:error, :reply_window}, else: {:ok, nil}

      [candidate] ->
        with {:ok, item} <- read_original_item(state, candidate.idempotency_key, @reply_destination),
             {:ok, reply} <- recover_v2_reply_item(state, item, nil, run_id) do
          {:ok, reply}
        end

      _ ->
        {:error, :reply}
    end
  end

  defp recover_v2_reply(state, %{reply_key: key}, _pending, run_id) when is_binary(key) do
    with {:ok, item} <- read_original_item(state, key, @reply_destination),
         {:ok, reply} <- recover_v2_reply_item(state, item, key, run_id) do
      {:ok, reply}
    end
  end

  # The reply's text is the retained reply input's intent, never its
  # Conversation row: the row counts only when it equals that intent (kind,
  # message ID, role, actor and text).
  defp recover_v2_reply_item(state, item, metadata_key, run_id) do
    with {:ok, notice} <- reply_notice(item, state.profile),
         {:completed, result} <-
           CheckedCommand.result(
             state.handles.reply_input,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, notice["operation_id"]}
           ),
         true <- result.revision == notice["revision"],
         {:ok, ticket, receipt_revision} <- receipt_input(result.response),
         true <- receipt_revision == result.revision,
         {:ok, :input, intent} <- Intents.delivery(result.response),
         true <- intent.message_id == ticket,
         :ok <- intent_delivery(state, :input, item, :input, intent),
         reply_operation <- notice["operation_id"],
         association_operation <- association_operation(reply_operation, ticket, state.profile),
         {:ok, association_revision, association_delivery} <-
           retained_reply_association(
             state,
             metadata_key,
             association_operation,
             reply_operation,
             result.revision,
             ticket,
             run_id,
             item
           ) do
      event = %{
        version: 1,
        event_id: "retained",
        conversation_id: state.profile.conversation_id,
        input_id: ticket,
        expected_revision: result.revision - 1,
        text: intent.text
      }

      {:ok,
       %{
         event: event,
         operation_id: reply_operation,
         request: input_request(event, reply_operation),
         facts: input_facts(),
         key: nil,
         requirement: nil,
         input_state: :committed,
         release_state: :committed,
         resource_revision: result.revision,
         ticket: ticket,
         item: item,
         text: intent.text,
         intent: intent,
         association_operation: association_operation,
         association_revision: association_revision,
         association_delivery: association_delivery,
         wait: nil,
         native_input_id: nil,
         pending: nil
       }}
    else
      {:superseded, _key, _nonce} = superseded -> superseded
      {:unproven, _kind, _key} = unproven -> unproven
      {:conflict, _key, _code} = conflict -> conflict
      {:error, :delivery_ack} -> {:error, :delivery_ack}
      {:error, {:held, _held}} = held -> held
      _ -> {:error, :reply}
    end
  rescue
    _ -> {:error, :reply}
  catch
    _, _ -> {:error, :reply}
  end

  defp retained_reply_association(
         state,
         nil,
         operation,
         _reply_operation,
         _revision,
         ticket,
         run_id,
         item
       ) do
    case CheckedCommand.result(
           state.handles.reply_association,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:unknown, :not_observed} ->
        if item.state == :pending and
             association_record(state, ticket, run_id) == :absent,
           do: {:ok, nil, nil},
           else: {:error, :association}

      _ ->
        {:error, :association}
    end
  end

  # Reply facts in the resource come from the reply association, or, for a
  # terminal reply acknowledged without one, from the reply custody command.
  defp retained_reply_association(
         state,
         key,
         operation,
         reply_operation,
         revision,
         ticket,
         run_id,
         _item
       )
       when is_binary(key) do
    case CheckedCommand.result(
           state.handles.reply_association,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: association_revision, response: response}}
      when association_revision == revision + 1 ->
        # The association's receipt first, then its row: an association
        # acknowledged without its row is fenced and never appended here.
        with true <- association_receipt?(response, ticket, run_id),
             {:ok, delivery_key, delivery_nonce} <-
               delivery_receipt(state, :reply_association, operation, association_revision),
             :ok <- recovered_delivery(state, :reply_association, delivery_key) do
          {:ok, association_revision, {delivery_key, delivery_nonce}}
        else
          false -> {:error, :association}
          other -> other
        end

      {:unknown, :not_observed} ->
        if reply_custody_recorded?(state, reply_operation, ticket, run_id) and
             association_record(state, ticket, run_id) == :absent,
           do: {:ok, nil, nil},
           else: {:error, :association}

      _ ->
        {:error, :association}
    end
  end

  defp retained_reply_association(_, _, _, _, _, _, _, _), do: {:error, :association}

  defp reply_custody_recorded?(state, reply_operation, ticket, run_id) do
    case CheckedCommand.result(
           state.handles.reply_custody,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor,
            reply_custody_operation(reply_operation, ticket, state.profile)}
         ) do
      {:completed, %{response: {:record, fields}}} ->
        Map.new(fields) |> Map.take(["message_id", "run_id"]) ==
          %{"message_id" => {:text, ticket}, "run_id" => {:text, run_id}}

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp recover_input(state, item) do
    with true <-
           item.destination == @destination and item.stream == checked_stream(state.profile.tenant),
         {:ok, notice} <- Jason.decode(item.payload),
         true <-
           Map.keys(notice) |> Enum.sort() == [
             "actor",
             "operation_id",
             "resource",
             "revision",
             "tenant",
             "type",
             "version"
           ],
         true <- notice["type"] == "checked_command" and notice["version"] == 1,
         true <- notice["tenant"] == state.profile.tenant and notice["actor"] == state.profile.actor,
         true <- is_binary(notice["operation_id"]) and is_binary(notice["resource"]),
         true <- notice["resource"] == state.profile.conversation_id,
         true <-
           is_integer(notice["revision"]) and notice["revision"] in 1..9_223_372_036_854_775_807,
         revision <- notice["revision"],
         {:completed, %{revision: ^revision, response: response}} <-
           CheckedCommand.result(
             state.handles.input,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, notice["operation_id"]}
           ),
         {:ok, response_id, response_revision} <- receipt_input(response),
         true <- response_revision == notice["revision"],
         true <- response_id == input_id_from_receipt(response),
         {:ok, :input, intent} <- Intents.delivery(response),
         true <- intent.message_id == response_id do
      event = %{
        version: 1,
        event_id: "retained",
        conversation_id: notice["resource"],
        input_id: response_id,
        expected_revision: notice["revision"] - 1,
        text: nil
      }

      {:ok, event, notice["operation_id"], notice["revision"], intent}
    else
      {:unknown, reason} when reason != :not_observed -> {:error, :read}
      _ -> {:error, :unavailable}
    end
  end

  # The input's text is its retained intent, never its Conversation row: the
  # row counts only when it equals that intent (kind, message ID, role, actor
  # and text).
  defp input_from_resource(state, event, revision, item, intent) do
    scope = resource_scope(state.profile)

    with true <- event.conversation_id == state.profile.conversation_id,
         {:ok, snapshot} <-
           CheckedCommand.resource(state.handles.input, scope, state.profile.conversation_id),
         true <- snapshot.revision >= revision,
         :ok <- intent_delivery(state, :input, item, :input, intent) do
      {:ok, intent.message_id, intent.text, snapshot}
    else
      {:unknown, _} -> {:error, :read}
      {:undelivered, _kind} -> {:error, :read}
      {:error, :record} -> {:error, :read}
      {:unproven, _kind, _key} = failure -> failure
      {:conflict, _key, _code} = failure -> failure
      {:superseded, _key, _nonce} = failure -> failure
      _ -> {:error, :unavailable}
    end
  end

  defp retained_phase(state, current, snapshot) do
    identity = {state.profile.tenant, state.profile.actor, current.association_operation}

    case CheckedCommand.result(state.handles.association, result_scope(state.profile), identity) do
      {:unknown, :not_observed} ->
        {:ok, :association, current}

      {:completed, %{revision: revision, response: response}}
      when revision == current.resource_revision + 1 ->
        cond do
          not association_receipt?(response, current.input_id, current.run_id) ->
            {:error, :association}

          reply_profile?(state.profile) ->
            {:error, :metadata_required}

          true ->
            # The association's receipt first, then its row: an association
            # acknowledged without its row is fenced and never appended here,
            # and one whose check cannot be read stays held by its key.
            case delivery_receipt(state, :association, current.association_operation, revision) do
              {:ok, key, nonce} ->
                case carried_delivery(state, :association, key) do
                  :ok ->
                    current = carry_delivery(current, :association, key, nonce)
                    retained_answer_phase(state, current, snapshot)

                  {:undelivered, _kind} ->
                    {:error, :read}

                  {:error, _reason} ->
                    {:error, {:held, {:association, @delivery_destination, key}}}

                  other ->
                    other
                end

              other ->
                other
            end
        end

      {:unknown, _} ->
        {:error, :read}

      _ ->
        {:error, :association}
    end
  rescue
    _ -> {:error, :association}
  catch
    _, _ -> {:error, :read}
  end

  defp retained_answer_phase(state, current, snapshot) do
    identity = {state.profile.tenant, state.profile.actor, current.answer_operation}

    case CheckedCommand.result(state.handles.answer, result_scope(state.profile), identity) do
      {:unknown, :not_observed} ->
        {:ok, :create_run, current}

      {:completed, %{revision: revision, response: response}}
      when revision == current.resource_revision + 2 and
             snapshot.revision >= current.resource_revision + 2 ->
        message_id = answer_id(current.input_id)
        expected_operation = native_operation(current.run_id, state)

        valid_run? =
          case RunApprovalRelease.status(state.native.run_owner, current.run_id) do
            {:ok,
             %{operation_id: ^expected_operation, current_attempt: attempt, outcome: :completed}} ->
              attempt == attempt_id(current.run_id, state)

            _ ->
              false
          end

        # The answer is the intent the command retained (its response and
        # digest), never a value read from the Conversation row it must
        # prove: the custody gate compares that row with this intent.
        with true <-
               valid_run? and
                 answer_receipt?(response, current.input_id, current.run_id, message_id),
             {:ok, :answer, intent} <- Intents.delivery(response),
             true <-
               intent.message_id == message_id and intent.input_message_id == current.input_id and
                 intent.run_id == current.run_id and
                 valid_answer_payload?(%{"answer" => intent.text}),
             {:ok, key, nonce} <-
               delivery_receipt(state, :answer, current.answer_operation, revision) do
          {:ok, :ack, carry_delivery(%{current | answer: intent.text}, :answer, key, nonce)}
        else
          {:superseded, _key, _nonce} = superseded -> superseded
          {:error, :delivery_ack} -> {:error, :delivery_ack}
          {:error, {:held, _held}} = held -> held
          _ -> {:error, :answer}
        end

      {:unknown, _} ->
        {:error, :read}

      _ ->
        {:error, :answer}
    end
  rescue
    _ -> {:error, :answer}
  catch
    _, _ -> {:error, :read}
  end

  defp associate(state) do
    c = state.current

    request =
      command_request(
        state.profile,
        c.event.conversation_id,
        c.resource_revision,
        c.association_operation,
        %{"message_id" => c.input_id}
      )

    facts_result =
      if reply_profile?(state.profile) do
        with {:ok, sequence} <- input_sequence(state, c.item.key, c.input_id) do
          {:ok, reply_primary_association_facts(c.run_id, c.item.key, c.item.nonce, sequence)}
        end
      else
        {:ok, association_facts(c.run_id)}
      end

    case facts_result do
      {:ok, facts} ->
        {result, state} = execute_checked(state, :association, c.event, request, facts)
        classify_association(state, c, result)

      _ ->
        {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    _, _ -> {{:error, :unavailable}, state}
  end

  defp classify_association(state, c, result) do
    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 1 ->
        if association_receipt?(response, c.input_id, c.run_id) do
          association_delivery(state, c, revision)
        else
          {{:unknown, :association},
           %{state | poison: {:association, c.association_operation, :receipt}}}
        end

      {:unknown, _} = unknown ->
        {{:unknown, :association},
         %{state | poison: {:association, c.association_operation, unknown}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      {:denied, _} ->
        {{:blocked, :association_denied},
         %{state | poison: {:association, c.association_operation, :denied}}}

      {:conflict, _} ->
        {{:blocked, :association_conflict}, %{state | poison: {:association, :conflict}}}

      {:intent_conflict, code} ->
        {{:blocked, {:intent, code}}, %{state | poison: {:intent, :association, code}}}

      other ->
        {{:blocked, :association}, %{state | poison: {:association, other}}}
    end
  rescue
    _ ->
      {{:unknown, :association},
       %{state | poison: {:association, c.association_operation, :exception}}}
  catch
    _, _ ->
      {{:unknown, :association},
       %{state | poison: {:association, c.association_operation, :exception}}}
  end

  defp create_run(state), do: held_then(state, &create_run_held/1)

  defp create_run_held(state) do
    c = state.current
    expected_operation = native_operation(c.run_id, state)

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: ^expected_operation, current_attempt: nil}} ->
        if reply_profile?(state.profile) and not primary_deadline_live?(state) do
          {{:pending, :expired}, state}
        else
          with {:held, held} <-
                 Lease.hold(state.native.lease, state.native.lease_stream, state.native.lease_owner) do
            {{:run_recovered, c.run_id},
             %{state | native: %{state.native | held: held}, phase: :begin_attempt}}
          else
            other -> {{:unknown, :run_create}, %{state | poison: {:run_create, other}}}
          end
        end

      {:ok, %{operation_id: ^expected_operation, current_attempt: attempt}}
      when is_binary(attempt) ->
        if attempt == attempt_id(c.run_id, state) do
          with {:held, held} <-
                 Lease.hold(state.native.lease, state.native.lease_stream, state.native.lease_owner) do
            {{:run_recovered, c.run_id},
             %{state | native: %{state.native | held: held}, phase: :start_engine}}
          else
            other -> {{:unknown, :run_create}, %{state | poison: {:run_create, other}}}
          end
        else
          {{:unknown, :run_identity}, %{state | poison: {:run_create, :attempt_identity}}}
        end

      {:error, :not_found} ->
        create_run_command(state, c, expected_operation)

      other ->
        {{:unknown, :run_identity}, %{state | poison: {:run_create, other}}}
    end
  rescue
    _ -> {{:unknown, :run_create}, %{state | poison: {:run_create, :exception}}}
  catch
    :exit, _ -> {{:unknown, :run_create}, %{state | poison: {:run_create, :exit}}}
    _, _ -> {{:unknown, :run_create}, %{state | poison: {:run_create, :exception}}}
  end

  defp create_run_command(state, c, operation) do
    if reply_profile?(state.profile) and not primary_deadline_live?(state) do
      {{:pending, :expired}, state}
    else
      create_run_command_live(state, c, operation)
    end
  end

  defp create_run_command_live(state, c, operation) do
    with {:held, held} <-
           Lease.hold(state.native.lease, state.native.lease_stream, state.native.lease_owner) do
      case RunApprovalRelease.command(state.native.run_owner, %{
             kind: :create,
             run_id: c.run_id,
             operation_id: operation,
             provider_refs: %{},
             expected_revision: held.live.revision
           }) do
        {:ok, revision, _} ->
          {{:run_created, revision},
           %{state | native: %{state.native | held: held}, phase: :begin_attempt}}

        {:indeterminate, _} = unknown ->
          {{:unknown, :run_create}, %{state | poison: {:run_create, unknown}}}

        {:error, _} = error ->
          {{:unknown, :run_create}, %{state | poison: {:run_create, error}}}

        other ->
          {{:blocked, :run_create}, %{state | poison: {:run_create, other}}}
      end
    else
      other -> {{:unknown, :run_create}, %{state | poison: {:run_create, other}}}
    end
  end

  defp begin_attempt(state), do: held_then(state, &begin_attempt_held/1)

  defp begin_attempt_held(state) do
    c = state.current

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: operation, revision: revision, current_attempt: nil}} ->
        expected_operation = native_operation(c.run_id, state)

        if operation != expected_operation do
          {{:unknown, :run_identity}, %{state | poison: {:run_status, :identity}}}
        else
          if reply_profile?(state.profile) and not primary_deadline_live?(state) do
            {{:pending, :expired}, state}
          else
            attempt_id = attempt_id(c.run_id, state)

            case RunApprovalRelease.command(state.native.run_owner, %{
                   kind: :begin_attempt,
                   run_id: c.run_id,
                   attempt_id: attempt_id,
                   expected_revision: revision
                 }) do
              {:ok, _, _} ->
                {{:attempt_started, attempt_id}, %{state | phase: :start_engine}}

              {:indeterminate, _} = unknown ->
                {{:unknown, :attempt}, %{state | poison: {:attempt, unknown}}}

              other ->
                {{:blocked, :attempt}, %{state | poison: {:attempt, other}}}
            end
          end
        end

      {:ok, %{operation_id: operation, current_attempt: current}} when is_binary(current) ->
        if operation == native_operation(c.run_id, state) and current == attempt_id(c.run_id, state),
          do: {{:attempt_existing, current}, %{state | phase: :start_engine}},
          else: {{:unknown, :attempt_identity}, %{state | poison: {:attempt, :identity}}}

      other ->
        {{:unknown, :run_status}, %{state | poison: {:run_status, other}}}
    end
  rescue
    _ -> {{:unknown, :attempt}, %{state | poison: {:attempt, :exception}}}
  catch
    _, _ -> {{:unknown, :attempt}, %{state | poison: {:attempt, :exception}}}
  end

  defp start_engine(state), do: held_then(state, &start_engine_held/1)

  defp start_engine_held(state) do
    if reply_profile?(state.profile) do
      case native_start_allowed?(state) do
        :ok ->
          start_engine_owned(state)

        {:error, reason} ->
          {{:blocked, :native_ownership}, %{state | poison: {:native_ownership, reason}}}
      end
    else
      start_engine_owned(state)
    end
  end

  defp start_engine_owned(state) do
    c = state.current
    attempt_id = attempt_id(c.run_id, state)
    unit_id = unit_id(c.run_id, state)
    engine_name = {:via, Registry, {state.native.registry, unit_id}}

    case safe_evidence_writer_start(state, c.run_id) do
      {:ok, writer} ->
        case own_native_child(state, :writer, writer) do
          {:ok, owned_state} ->
            start_async_work(owned_state, c, attempt_id, unit_id, engine_name)

          {:error, owned_state, reason} ->
            engine_start_failed(owned_state, unit_id, reason)
        end

      other ->
        {{:unknown, :engine_start}, %{state | poison: {:engine_start, other}}}
    end
  end

  defp native_start_allowed?(state) do
    owned = [state.engine, state.async_work, state.writer]
    references = [state.engine_ref, state.async_work_ref, state.writer_ref]

    cond do
      Enum.any?(owned, &is_pid/1) or Enum.any?(references, &is_reference/1) ->
        {:error, :owned_children}

      Task.Supervisor.children(state.native.task_supervisor) != [] ->
        {:error, :native_work}

      no_live_native_unit(state) != :ok ->
        {:error, :native_unit}

      no_native_unit_children(state) != :ok ->
        {:error, :native_unit_child}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp native_result_phase(state, current) do
    if reply_profile?(state.profile) do
      operation_id = native_operation(current.run_id, state)
      expected_attempt = attempt_id(current.run_id, state)

      case RunApprovalRelease.status(state.native.run_owner, current.run_id) do
        {:ok,
         %{
           operation_id: ^operation_id,
           current_attempt: ^expected_attempt,
           outcome: nil
         }} ->
          if primary_deadline_live?(state), do: :start_input, else: :result

        _ ->
          :result
      end
    else
      :start_input
    end
  rescue
    _ -> :result
  catch
    _, _ -> :result
  end

  defp start_async_work(state, c, attempt_id, unit_id, engine_name) do
    case safe_async_start(engine_name, state.native.task_supervisor) do
      {:ok, async} ->
        case own_native_child(state, :async_work, async) do
          {:ok, owned_state} ->
            start_native_engine(owned_state, c, attempt_id, unit_id, engine_name)

          {:error, owned_state, reason} ->
            engine_start_failed(owned_state, unit_id, reason)
        end

      other ->
        engine_start_failed(state, unit_id, other)
    end
  end

  defp start_native_engine(state, c, attempt_id, unit_id, engine_name) do
    case safe_engine_options(state, c, attempt_id, unit_id, engine_name) do
      {:ok, options} ->
        case safe_engine_start(options) do
          {:ok, engine} ->
            case own_native_child(state, :engine, engine) do
              {:ok, owned_state} ->
                {{:engine_started, unit_id},
                 %{owned_state | phase: native_result_phase(owned_state, c)}}

              {:error, owned_state, reason} ->
                engine_start_failed(owned_state, unit_id, reason)
            end

          other ->
            engine_start_failed(state, unit_id, other)
        end

      {:error, reason} ->
        engine_start_failed(state, unit_id, reason)
    end
  end

  defp safe_engine_options(state, c, attempt_id, unit_id, engine_name) do
    {:ok,
     engine_options(
       state,
       c,
       attempt_id,
       unit_id,
       engine_name,
       state.async_work,
       state.writer
     )}
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  defp safe_async_start(owner, task_supervisor) do
    AsyncWork.start_link(owner: owner, task_supervisor: task_supervisor, max_concurrency: 1)
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  defp safe_engine_start(options) do
    RunEngine.start_link(options)
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  defp safe_evidence_writer_start(state, run_id) do
    start_evidence_writer(state, run_id)
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  defp own_native_child(state, child_key, pid) do
    case Map.get(state, child_key) do
      ^pid ->
        {:ok, state}

      owned when is_pid(owned) ->
        if Process.alive?(owned),
          do: {:error, state, :owned_child_live},
          else: own_native_child_unchecked(state, child_key, pid)

      _ ->
        own_native_child_unchecked(state, child_key, pid)
    end
  end

  defp own_native_child_unchecked(state, child_key, pid) do
    owned_state = Map.put(state, child_key, pid)

    reference_key =
      case child_key do
        :writer -> :writer_ref
        :async_work -> :async_work_ref
        :engine -> :engine_ref
      end

    monitor_result =
      try do
        {:ok, Process.monitor(pid)}
      rescue
        _ -> {:error, :monitor}
      catch
        _, _ -> {:error, :monitor}
      end

    case monitor_result do
      {:ok, reference} ->
        monitored_state = Map.put(owned_state, reference_key, reference)

        unlink_result =
          try do
            Process.unlink(pid)
            :ok
          rescue
            _ -> {:error, :unlink}
          catch
            _, _ -> {:error, :unlink}
          end

        case unlink_result do
          :ok -> {:ok, monitored_state}
          {:error, reason} -> {:error, monitored_state, reason}
        end

      {:error, reason} ->
        {:error, owned_state, reason}
    end
  end

  defp engine_start_failed(state, unit_id, reason) do
    case engine_registry_lookup(state.native.registry, unit_id) do
      {:ok, registry_engine} ->
        cleanup_state =
          case registry_engine do
            nil ->
              state

            pid when pid == state.engine ->
              state

            pid ->
              case own_native_child(state, :engine, pid) do
                {:ok, owned_state} -> owned_state
                {:error, owned_state, _} -> owned_state
              end
          end

        case fence_native(cleanup_state) do
          :ok ->
            clean_state = clear_native_children(cleanup_state)
            {{:unknown, :engine_start}, %{clean_state | poison: {:engine_start, reason}}}

          {:error, cleanup_reason} ->
            {{:unknown, :engine_start},
             %{cleanup_state | poison: {:engine_start, {reason, cleanup_reason}}}}
        end

      {:error, _} ->
        keep_engine_start_fenced(state, {reason, :registry_unavailable})
    end
  end

  defp engine_registry_lookup(registry, unit_id) do
    case Registry.lookup(registry, unit_id) do
      [] -> {:ok, nil}
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp keep_engine_start_fenced(state, reason) do
    case stop_known_native_children(state) do
      {:ok, state} ->
        {{:unknown, :engine_start}, %{state | poison: {:engine_start, reason}}}

      {:error, state, cleanup_reason} ->
        {{:unknown, :engine_start}, %{state | poison: {:engine_start, {reason, cleanup_reason}}}}
    end
  end

  defp stop_known_native_children(state) do
    with :ok <- stop_native_process(state.engine),
         :ok <- stop_native_process(state.async_work),
         :ok <- stop_native_process(state.writer),
         :ok <- no_live_native_processes([state.engine, state.async_work, state.writer]) do
      demonitor_native(state)

      {:ok,
       %{
         state
         | engine_ref: nil,
           async_work_ref: nil,
           writer_ref: nil
       }}
    else
      {:error, reason} -> {:error, state, reason}
    end
  rescue
    _ -> {:error, state, :exception}
  catch
    _, _ -> {:error, state, :exit}
  end

  defp clear_native_children(state) do
    %{
      state
      | engine: nil,
        engine_ref: nil,
        async_work: nil,
        async_work_ref: nil,
        writer: nil,
        writer_ref: nil
    }
  end

  defp start_input(state) do
    if reply_profile?(state.profile) and not primary_deadline_live?(state) do
      {{:pending, :expired}, %{state | phase: :result}}
    else
      submit_start_input(state)
    end
  end

  defp submit_start_input(state), do: held_then(state, &submit_start_input_held/1)

  defp submit_start_input_held(state) do
    c = state.current
    id = native_input_id(c.run_id, state)

    input = %{
      "type" => "input",
      "version" => if(reply_profile?(state.profile), do: 2, else: 1),
      "kind" => "wake"
    }

    context = %{run_id: c.run_id, attempt_id: attempt_id(c.run_id, state)}

    case safe_native_input(state.engine, id, input, context) do
      {:ok, {:ok, result}} when result in [:applied, :duplicate] ->
        {{:native_input, result}, %{state | phase: :result}}

      {:ok, {:error, reason}} ->
        native_input_unknown(state, reason)

      {:error, reason} ->
        native_input_unknown(state, reason)

      other ->
        native_input_unknown(state, other)
    end
  end

  # The reply observation reads the window, and each held item that it no
  # longer shows is checked by its key first, as in `observe_input/1`. The
  # window's input items, the round's reply item among them, are held when
  # it is read (`pending_window/1`), whatever the observation decides.
  defp observe_reply(%{reply: reply, current: current} = state)
       when is_map(reply) and is_map(current) do
    case pending_window(state) do
      {:ok, pending, state} -> observe_reply_window(state, reply, current, pending)
      {:error, _cause} -> reply_observation_failure(state, :unavailable)
    end
  end

  defp observe_reply(state), do: {{:blocked, :reply_state}, state}

  defp observe_reply_window(state, reply, current, pending) do
    with {:ok, state, pending} <- unseen_held_proven(state, pending),
         {:ok, item} <- observed_reply_item(state, reply, current, pending) do
      adopt_reply(state, reply, item)
    else
      {{:error, _reason}, %{} = held} -> reply_observation_failure(held, :unavailable)
      {failure, %{} = held} -> reply_observation_failure(held, failure)
      failure -> reply_observation_failure(state, failure)
    end
  rescue
    _ -> reply_observation_failure(state, :unavailable)
  catch
    _, _ -> reply_observation_failure(state, :unavailable)
  end

  defp adopt_reply(state, reply, item) do
    with {:completed, result} <-
           CheckedCommand.result(
             state.handles.reply_input,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, reply.operation_id}
           ),
         true <- result.revision == reply.resource_revision,
         {:ok, ticket, response_revision} <- receipt_input(result.response),
         true <- ticket == reply.ticket and response_revision == result.revision,
         {:ok, :input, intent} <- Intents.delivery(result.response),
         true <- intent.message_id == ticket and intent.text == reply.event.text,
         :ok <- intent_delivery(state, :input, item, :input, intent),
         :ok <- carried_deliveries(state, [:association]) do
      reply = Map.put(%{reply | item: item, text: intent.text}, :intent, intent)
      {{:reply_observed, item.idempotency_key}, %{state | reply: reply, phase: :reply_association}}
    else
      failure -> reply_observation_failure(state, failure)
    end
  end

  defp reply_observation_failure(state, failure) do
    case failure do
      :unproven ->
        {{:blocked, :reply_observation}, %{state | poison: {:reply_observation, :unproven}}}

      {:unproven, _kind, _key} ->
        unconfirmed_delivery(state, failure)

      {:conflict, _key, _code} ->
        unconfirmed_delivery(state, failure)

      {:superseded, _key, _nonce} ->
        unconfirmed_delivery(state, failure)

      {:missing, _kind} ->
        unconfirmed_delivery(state, failure)

      _ ->
        {{:blocked, :reply_observation}, %{state | poison: {:reply_observation, :unavailable}}}
    end
  end

  # The round's reply item, by main's rule: the window shows this round's
  # primary item and exactly one reply item, whose notice names this
  # conversation and the reply input's operation at its revision. Anything
  # else is `:unproven`, a fence: no item is adopted that is not proven this
  # round's, and a visible reply item of another conversation fences the
  # round as on main, in a full window too. Only a full window that shows no
  # reply item may hide this round's: that is the retried `{:error,
  # :window}`. An unreadable item is `{:error, :read}`.
  defp observed_reply_item(state, reply, current, pending) do
    candidates = Enum.filter(pending, &(&1.destination == @reply_destination))
    primary? = Enum.any?(pending, &(&1.idempotency_key == current.item.key))

    case candidates do
      [] ->
        if pending_window_full?(pending), do: {:error, :window}, else: :unproven

      [candidate] when primary? ->
        proven_reply_item(state, reply, candidate)

      _ ->
        :unproven
    end
  end

  defp proven_reply_item(state, reply, candidate) do
    case read_reply_item(state, candidate.idempotency_key) do
      {:ok, item} ->
        case reply_notice(item, state.profile) do
          {:ok, %{"operation_id" => operation, "revision" => revision}}
          when operation == reply.operation_id and revision == reply.resource_revision ->
            {:ok, item}

          _ ->
            :unproven
        end

      error ->
        error
    end
  end

  defp read_reply_item(state, key) do
    read_original_item(state, key, @reply_destination)
  end

  defp read_original_item(state, key, destination) do
    with {:ok, {stream, _sequence, 1}} <- Outbox.parse_id(key),
         true <- stream == checked_stream(state.profile.tenant),
         {:ok, item} when is_map(item) <-
           DurableLog.Store.read(state.command_store, :read_ack, [key]) do
      original_item(state, key, destination, item)
    else
      {:error, :unavailable} -> {:error, :read}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :read}
  end

  # An item as read, when it is the original item at its key: this stream's
  # sequence and first position, the destination, and the nonce and digest
  # that its payload binds, pending or acknowledged. `{:ok, item}`, else
  # `{:error, :unavailable}`.
  defp original_item(state, key, destination, item) do
    with {:ok, {stream, sequence, 1}} <- Outbox.parse_id(key),
         true <- stream == checked_stream(state.profile.tenant),
         canonical <- Outbox.new(stream, sequence, 1, destination, item.payload, item.nonce),
         true <-
           item.stream == stream and item.sequence == sequence and item.position == 1 and
             item.destination == destination and item.idempotency_key == key and
             item.nonce == canonical.nonce and item.digest == canonical.digest and
             is_binary(item.nonce) and byte_size(item.nonce) == 16 and
             item.state in [:pending, :acked] do
      {:ok, item}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp reply_notice(%{payload: payload, destination: destination}, profile) do
    with {:ok, notice} <- Jason.decode(payload),
         true <- destination == @reply_destination,
         true <-
           Map.keys(notice) |> Enum.sort() == [
             "actor",
             "operation_id",
             "resource",
             "revision",
             "tenant",
             "type",
             "version"
           ],
         true <-
           notice["type"] == "checked_command" and is_integer(notice["version"]) and
             notice["version"] == 1,
         true <- notice["tenant"] == profile.tenant and notice["actor"] == profile.actor,
         true <- notice["resource"] == profile.conversation_id,
         true <- is_binary(notice["operation_id"]) and byte_size(notice["operation_id"]) in 1..128,
         true <- is_integer(notice["revision"]) and notice["revision"] > 0 do
      {:ok, notice}
    else
      _ -> {:error, :notice}
    end
  rescue
    _ -> {:error, :notice}
  end

  defp associate_reply(%{reply: reply, current: current} = state)
       when is_map(reply) and is_map(current) and is_map(reply.item) do
    request =
      command_request(
        state.profile,
        reply.event.conversation_id,
        reply.resource_revision,
        reply.association_operation,
        %{"message_id" => reply.ticket}
      )

    facts_result =
      case input_sequence(state, reply.item.idempotency_key, reply.ticket) do
        {:ok, sequence} ->
          {:ok,
           reply_association_facts(
             current.run_id,
             current.item.key,
             reply.item.idempotency_key,
             reply.item.nonce,
             sequence
           )}

        _ ->
          :error
      end

    case facts_result do
      {:ok, facts} ->
        classify_reply_association(state, reply, current, request, facts)

      _ ->
        {{:error, :unavailable}, state}
    end
  rescue
    _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  catch
    _, _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  end

  defp associate_reply(state), do: {{:blocked, :reply_state}, state}

  defp classify_reply_association(state, reply, current, request, facts) do
    {result, state} = execute_checked(state, :reply_association, reply.event, request, facts)
    reply_association_result(state, reply, current, result)
  rescue
    _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  catch
    _, _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  end

  defp reply_association_result(state, reply, current, result) do
    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == reply.resource_revision + 1 ->
        if association_receipt?(response, reply.ticket, current.run_id) and
             confirm_reply_association(state, reply, current) do
          reply_association_delivery(state, revision)
        else
          {{:unknown, :reply_association},
           %{
             state
             | poison:
                 {:reply_association, reply.association_operation,
                  {:completed, %{revision: revision, response: response}}}
           }}
        end

      {:unknown, _} = result ->
        {{:unknown, :reply_association},
         %{state | poison: {:reply_association, reply.association_operation, result}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      {:intent_conflict, code} ->
        {{:blocked, {:intent, code}}, %{state | poison: {:intent, :reply_association, code}}}

      _ ->
        {{:blocked, :reply_association}, %{state | poison: {:reply_association, :conflict}}}
    end
  rescue
    _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  catch
    _, _ -> {{:unknown, :reply_association}, %{state | poison: {:reply_association, :exception}}}
  end

  defp reconcile_reply_association(%{reply: reply, current: current} = state)
       when is_map(reply) and is_map(current) do
    case CheckedCommand.result(
           state.handles.reply_association,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, reply.association_operation}
         ) do
      {:completed, %{revision: revision, response: response}}
      when revision == reply.resource_revision + 1 ->
        if association_receipt?(response, reply.ticket, current.run_id) and
             confirm_reply_association(state, reply, current) do
          case reply_association_delivery(%{state | poison: nil}, revision) do
            {{:reply_associated, _revision}, state} -> {{:reconciled, :reply_association}, state}
            other -> other
          end
        else
          {{:unknown, :reply_association},
           %{state | poison: {:reply_association, reply.association_operation, :identity}}}
        end

      {:unknown, :not_observed} ->
        {{:reconciled, :not_observed}, %{state | phase: :reply_association, poison: nil}}

      other ->
        {{:unknown, :reply_association},
         %{state | poison: {:reply_association, reply.association_operation, other}}}
    end
  rescue
    _ ->
      {{:unknown, :reply_association},
       %{state | poison: {:reply_association, reply.association_operation, :exception}}}
  catch
    _, _ ->
      {{:unknown, :reply_association},
       %{state | poison: {:reply_association, reply.association_operation, :exception}}}
  end

  defp reconcile_reply_association(state), do: {{:blocked, :reply_state}, state}

  defp reconcile_reply_ack(state, key, nonce) do
    case confirm_native_ack(state, key, nonce, @reply_destination) do
      :ok -> {{:reconciled, :reply_ack}, %{state | phase: :ack, poison: nil}}
      _ -> {{:unknown, :reply_ack}, state}
    end
  end

  defp reconcile_v2_native_uncertainty(%{current: current} = state) when is_map(current) do
    # Stopping this host cannot prove its PostgreSQL append caller has exited.
    {{:blocked, :provider_owner_replacement},
     %{state | poison: {:provider_owner_replacement, current.run_id}}}
  end

  defp reconcile_v2_native_uncertainty(state),
    do:
      {{:blocked, :provider_owner_replacement},
       %{state | poison: {:provider_owner_replacement, :unknown_run}}}

  defp confirm_reply_association(state, reply, current) do
    # The reply association command is committed (its receipt verifies) but
    # not yet delivered; the delivered primary association and the reply
    # input, equal to the reply input's retained intent, are the
    # conversation-side proof.
    conversation_association?(state, current.input_id, current.run_id) and
      is_map(Map.get(reply, :intent)) and intent_record(state, :input, reply.intent) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp submit_reply_input(%{reply: reply, current: current, engine: engine} = state)
       when is_map(reply) and is_map(current) and is_map(reply.item) and is_pid(engine),
       do: held_then(state, &submit_reply_input_held/1)

  defp submit_reply_input(state), do: {{:blocked, :reply_state}, state}

  defp submit_reply_input_held(%{reply: reply, current: current, engine: engine} = state) do
    id =
      stable_id("reply-native-input", [
        current.run_id,
        reply.item.idempotency_key,
        reply.wait.occurrence
      ])

    input = %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => "reply",
      "source_id" => state.profile.reply_source_id,
      "correlation_id" => reply.ticket,
      "event_id" => reply.item.idempotency_key,
      "schema_id" => "message/v1",
      "schema_version" => 1,
      "payload" => %{"text" => reply.text}
    }

    context = %{
      run_id: current.run_id,
      attempt_id: attempt_id(current.run_id, state),
      occurrence: reply.wait.occurrence,
      actual: 0,
      dispatch: "not_dispatched"
    }

    case reply_answer_preflight(state) do
      :ok ->
        case safe_native_input(engine, id, input, context) do
          {:ok, {:ok, result}} when result in [:applied, :duplicate] ->
            reply = Map.put(reply, :native_input_id, id)
            {{:native_reply, result}, %{state | reply: reply, phase: :result}}

          other ->
            {{:unknown, :native_reply}, %{state | poison: {:reply_native_input, other}}}
        end

      # A carried association that the delivery pass has not appended yet,
      # or a Conversation row read that failed: nothing was written, and the
      # step runs again.
      {:error, reason} when reason in [:undelivered, :unreadable] ->
        {{:error, :unavailable}, state}

      {:error, {:unproven, _kind, _key} = failure} ->
        unconfirmed_delivery(state, failure)

      {:error, {:conflict, _key, _code} = failure} ->
        unconfirmed_delivery(state, failure)

      {:error, {:superseded, _key, _nonce} = failure} ->
        unconfirmed_delivery(state, failure)

      {:error, reason} ->
        {{:blocked, :reply_preflight}, %{state | poison: {:reply_preflight, reason}}}
    end
  rescue
    _ -> {{:unknown, :native_reply}, %{state | poison: {:reply_native_input, :exception}}}
  catch
    _, _ -> {{:unknown, :native_reply}, %{state | poison: {:reply_native_input, :exception}}}
  end

  # The answer preflight before the native reply. A carried association
  # that the delivery pass has not appended yet, or a Conversation row read
  # that failed (a carried item's, or the reply input's own), is retried
  # with nothing dispatched; the command head, the retained reply
  # association and the resource keep main's fence.
  defp reply_answer_preflight(%{reply: reply, current: current} = state)
       when is_map(reply) and is_map(current) and is_map(reply.item) do
    stream = checked_stream(state.profile.tenant)
    primary_key = current.item.key
    reply_key = reply.item.idempotency_key

    with {:ok, head} <- Elzoo.DurableLog.Store.read(state.command_store, :head, [stream]),
         true <- answer_projection_head?(head),
         {:completed, %{revision: revision, response: response}} <-
           CheckedCommand.result(
             state.handles.reply_association,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, reply.association_operation}
           ),
         true <-
           revision == reply.association_revision and
             association_receipt?(response, reply.ticket, current.run_id),
         {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         true <-
           snapshot.revision == revision and
             reply_metadata_matches?(
               snapshot,
               current.run_id,
               primary_key,
               reply_key,
               state.profile.tenant
             ),
         :ok <- carried_deliveries(state, [:association, :reply_association]),
         true <- is_map(Map.get(reply, :intent)) and reply.intent.text == reply.text,
         :ok <- reply_input_row(state, reply.intent),
         {:ok, after_head} <- Elzoo.DurableLog.Store.read(state.command_store, :head, [stream]),
         true <- answer_projection_head?(after_head) and stable_projection_heads?(head, after_head) do
      :ok
    else
      # Delivery-time visibility: an association that the delivery pass has
      # not appended yet, or a Conversation row read that failed, is
      # retried; the command head's own failure keeps main's fence. One
      # acknowledged without its row or under another nonce, or held by
      # another record, is fenced like the custody gate fences it.
      {:error, :record} -> {:error, :unreadable}
      {:error, :read} -> {:error, :unreadable}
      {:undelivered, _kind} -> {:error, :undelivered}
      {:unproven, _kind, _key} = failure -> {:error, failure}
      {:conflict, _key, _code} = failure -> {:error, failure}
      {:superseded, _key, _nonce} = failure -> {:error, failure}
      _ -> {:error, :capacity}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  # The reply input's own Conversation row, compared with its retained
  # intent; a row read that fails is `{:error, :record}`, as for a carried
  # item.
  defp reply_input_row(state, intent) do
    case intent_record(state, :input, intent) do
      {:error, _reason} -> {:error, :record}
      other -> other
    end
  end

  # The keys are already validated; sequences and nonces are delivery-custody
  # facts verified through scans, not repeated here.
  defp reply_metadata_matches?(snapshot, run_id, primary_key, reply_key, tenant) do
    case Intents.metadata(snapshot.fields, tenant) do
      {:ok, metadata} ->
        metadata.run_id == run_id and metadata.primary_key == primary_key and
          metadata.reply_key == reply_key and is_binary(metadata.reply_nonce) and
          is_integer(metadata.reply_sequence) and is_binary(metadata.primary_nonce) and
          is_integer(metadata.primary_sequence)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp safe_native_input(engine, id, input, context) do
    {:ok, RunEngine.input(engine, id, input, context)}
  rescue
    _ -> {:error, :native_exit}
  catch
    _, _ -> {:error, :native_exit}
  end

  defp native_input_unknown(state, reason) do
    case fence_native(state) do
      :ok ->
        {{:unknown, :native_input},
         %{
           state
           | poison: {:native_input, reason},
             engine: nil,
             engine_ref: nil,
             async_work: nil,
             async_work_ref: nil,
             writer: nil,
             writer_ref: nil
         }}

      {:error, _} ->
        {{:unknown, :native_input}, %{state | poison: {:native_input, :fencing}}}
    end
  end

  defp observe_result(state) do
    c = state.current
    scope = %{tenant: state.profile.tenant, principal: state.profile.actor, run_id: c.run_id}

    case RunEngine.result(state.engine, scope, @result_limits) do
      {:ok, result} ->
        expected_operation = native_operation(c.run_id, state)

        expected_action =
          if reply_profile?(state.profile) and is_map(state.reply), do: "hash", else: "work"

        if (not reply_profile?(state.profile) or is_nil(state.reply) or
              is_integer(state.reply.association_revision)) and
             result.run_id == c.run_id and result.operation_id == expected_operation and
             result.attempt_id == attempt_id(c.run_id, state) and
             result.action_id == expected_action and
             result.schema_id == "answer/v1" and result.schema_version == 1 and
             valid_answer_payload?(result.payload) do
          case restore_reply_wait_for_result(state, c) do
            {:ok, state} ->
              {{:result, :completed},
               %{state | current: Map.put(c, :answer, result.payload["answer"]), phase: :answer}}

            {:error, reason} ->
              {{:unknown, :result_identity}, %{state | poison: {:result, {:reply_event, reason}}}}
          end
        else
          {{:unknown, :result_identity}, %{state | poison: {:result, :identity}}}
        end

      {:pending, reason} ->
        if reply_profile?(state.profile) do
          case native_event_waits(state) do
            {:ok, %{waits: [wait]}}
            when is_map(wait) ->
              if valid_native_reply_wait?(state, c, wait) do
                if is_map(state.reply) do
                  case recover_reply_wait(state, c, wait) do
                    {:ok, next_state, accepted?} ->
                      phase =
                        cond do
                          accepted? ->
                            :result

                          is_integer(Map.get(next_state.reply, :association_revision)) ->
                            :reply_input

                          is_map(Map.get(next_state.reply, :item)) ->
                            :reply_association

                          true ->
                            :result
                        end

                      next_state = %{next_state | phase: phase}
                      pending_v2_wait(next_state, wait, reason)

                    {:error, reason} ->
                      {{:unknown, :native_event}, %{state | poison: {:native_event, reason}}}
                  end
                else
                  next_state =
                    %{state | native_wait: wait}
                    |> recover_ambiguous_reply_cursor(c, wait)

                  pending_v2_wait(next_state, wait, reason)
                end
              else
                {{:pending, reason}, state}
              end

            _ ->
              {{:pending, reason}, state}
          end
        else
          {{:pending, reason}, state}
        end

      {:terminal, outcome} when outcome in [:failed, :cancelled, :out_of_budget, :out_of_time] ->
        case recover_terminal_reply_wait(state, c) do
          {:ok, state} ->
            current = Map.put(c, :terminal, outcome)

            terminal_ack_phase(%{state | current: current})

          {:error, reason} ->
            {{:unknown, :native_event}, %{state | poison: {:native_event, reason}}}
        end

      {:error, reason} ->
        {{:pending, reason}, state}

      other ->
        {{:unknown, :result}, %{state | poison: {:result, other}}}
    end
  rescue
    _ -> {{:pending, :result_unavailable}, state}
  catch
    :exit, _ -> {{:pending, :result_unavailable}, state}
    _, _ -> {{:pending, :result_unavailable}, state}
  end

  defp pending_v2_wait(state, wait, reason) do
    if wait.status == :waiting and proven_reply_expiry?(state, wait) do
      expire_v2_wait(state, wait)
    else
      if wait.status == :waiting,
        do: {{:pending, :event_waiting}, state},
        else: {{:pending, reason}, state}
    end
  end

  # The expiry wake is a native input: an ambiguous reply cursor keeps main's
  # fence, and otherwise each held item is checked before the wake is
  # dispatched (`held_then/2`).
  defp expire_v2_wait(state, wait) do
    if state.ambiguous_reply in [true, :check],
      do: {{:blocked, :reply_ambiguous}, %{state | poison: {:reply_ambiguity, :expiry}}},
      else: held_then(state, &dispatch_expiry_wake(&1, wait))
  end

  defp dispatch_expiry_wake(%{current: current} = state, wait) do
    operation_id = native_operation(current.run_id, state)
    expected_attempt = attempt_id(current.run_id, state)

    case RunApprovalRelease.status(state.native.run_owner, current.run_id) do
      {:ok,
       %{
         operation_id: ^operation_id,
         current_attempt: ^expected_attempt,
         outcome: nil
       }} ->
        id = native_expiry_input_id(current.run_id, wait, state)

        input = %{
          "type" => "input",
          "version" => 2,
          "kind" => "wake"
        }

        context = %{run_id: current.run_id, attempt_id: expected_attempt}

        case safe_native_input(state.engine, id, input, context) do
          {:ok, {:ok, result}} when result in [:applied, :duplicate] ->
            {{:native_expiry_wake, result}, %{state | phase: :result, native_wait: wait}}

          {:ok, {:error, reason}} ->
            native_input_unknown(state, {:expiry_wake, reason})

          {:error, reason} ->
            native_input_unknown(state, {:expiry_wake, reason})

          other ->
            native_input_unknown(state, {:expiry_wake, other})
        end

      {:ok, %{operation_id: ^operation_id, current_attempt: ^expected_attempt}} ->
        {{:pending, :result_reconciliation}, state}

      _ ->
        native_input_unknown(state, :expiry_owner)
    end
  rescue
    _ -> native_input_unknown(state, :expiry_exception)
  catch
    _, _ -> native_input_unknown(state, :expiry_exception)
  end

  defp terminal_ack_phase(state) do
    case reply_ack_eligibility(state) do
      :committed ->
        {{:terminal, state.current.terminal}, %{state | phase: :reply_ack}}

      :none ->
        {{:terminal, state.current.terminal}, %{state | phase: :ack}}

      :unknown ->
        {{:unknown, :reply_state}, %{state | poison: {:terminal_reply_state, :unknown}}}
    end
  end

  defp reply_ack_eligibility(%{profile: profile}) when not is_map(profile), do: :unknown

  defp reply_ack_eligibility(%{profile: profile} = state) do
    if not reply_profile?(profile) do
      :none
    else
      case state.reply do
        nil ->
          if state.ambiguous_reply in [true, :check], do: :unknown, else: :none

        %{release_state: :pending} = reply ->
          case Map.get(reply, :item) do
            item when is_map(item) ->
              if committed_reply_item?(state, reply, item), do: :committed, else: :unknown

            _ ->
              :none
          end

        %{item: item} = reply when is_map(item) ->
          if committed_reply_item?(state, reply, item), do: :committed, else: :unknown

        _ ->
          :unknown
      end
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp committed_reply_item?(state, reply, item) do
    key = Map.get(item, :idempotency_key)
    nonce = Map.get(item, :nonce)

    with true <- is_binary(key) and is_binary(nonce),
         {:ok, committed} <- read_reply_item(state, key),
         true <-
           committed.idempotency_key == key and committed.nonce == nonce and
             committed.sequence == item.sequence and committed.state in [:pending, :acked],
         {:completed, result} <-
           CheckedCommand.result(
             state.handles.reply_input,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, reply.operation_id}
           ),
         true <- result.revision == reply.resource_revision,
         {:ok, ticket, revision} <- receipt_input(result.response),
         true <-
           revision == result.revision and ticket == reply.ticket and
             ticket == reply.event.input_id do
      true
    else
      _ -> false
    end
  end

  defp recover_ambiguous_reply_cursor(%{ambiguous_reply: :check} = state, current, wait) do
    scope = %{
      tenant: state.profile.tenant,
      principal: state.profile.actor,
      run_id: current.run_id
    }

    heads =
      Enum.map(1..2, fn _ ->
        Elzoo.Wave4ChannelExample.ReplySource.head(
          scope,
          state.profile,
          current.run_id,
          state.command_store
        )
      end)

    ambiguous =
      case heads do
        [{:ok, first}, {:ok, second}] when first == second ->
          first.revision != Map.get(wait, :cursor)

        _ ->
          true
      end

    %{state | ambiguous_reply: ambiguous}
  rescue
    _ -> %{state | ambiguous_reply: true}
  catch
    _, _ -> %{state | ambiguous_reply: true}
  end

  defp recover_ambiguous_reply_cursor(state, _current, _wait), do: state

  defp valid_native_reply_wait?(state, _current, wait) do
    expected_ticket =
      case state.reply do
        %{ticket: ticket} when is_binary(ticket) -> ticket
        %{wait: %{correlation_id: ticket}} when is_binary(ticket) -> ticket
        _ -> nil
      end

    wait.status in [:waiting, :settled, :closed] and wait.action_id == "reply" and
      wait.source_id == state.profile.reply_source_id and is_binary(wait.correlation_id) and
      is_tuple(wait.occurrence) and
      (is_nil(expected_ticket) or wait.correlation_id == expected_ticket)
  rescue
    _ -> false
  end

  defp recover_reply_wait(state, current, wait) do
    with true <- is_map(state.reply),
         true <- valid_native_reply_wait?(state, current, wait) do
      reply = Map.put(state.reply, :wait, wait)
      next_state = %{state | native_wait: wait, reply: reply}

      case accepted_reply_native_input_id(reply, current, wait) do
        {:ok, input_id} ->
          {:ok, %{next_state | reply: Map.put(reply, :native_input_id, input_id)}, true}

        :pending ->
          {:ok, next_state, false}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :wait}
    end
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  defp restore_reply_wait_for_result(%{reply: reply} = state, current) when is_map(reply) do
    case native_event_waits(state) do
      {:ok, %{waits: [wait]}} when is_map(wait) ->
        case recover_reply_wait(state, current, wait) do
          {:ok, restored, true} -> {:ok, restored}
          _ -> {:error, :accepted_event}
        end

      _ ->
        {:error, :event_waits}
    end
  end

  defp restore_reply_wait_for_result(state, _current), do: {:ok, state}

  defp recover_terminal_reply_wait(%{reply: reply} = state, current) when is_map(reply) do
    case native_event_waits(state) do
      {:ok, %{waits: [wait]}} when is_map(wait) ->
        case recover_reply_wait(state, current, wait) do
          {:ok, restored, _accepted?} -> {:ok, restored}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :event_waits}
    end
  end

  defp recover_terminal_reply_wait(state, _current), do: {:ok, state}

  defp accepted_reply_native_input_id(reply, current, wait) do
    case Map.get(wait, :accepted_event) do
      nil ->
        :pending

      %{event_id: event_id, input_id: input_id, sequence: sequence}
      when is_binary(event_id) and is_binary(input_id) and is_integer(sequence) ->
        expected_id =
          stable_id("reply-native-input", [
            current.run_id,
            reply.item.idempotency_key,
            wait.occurrence
          ])

        if event_id == reply.item.idempotency_key and input_id == expected_id and
             sequence == reply.item.sequence and
             (is_nil(reply.native_input_id) or reply.native_input_id == input_id) do
          {:ok, input_id}
        else
          {:error, :accepted_event_identity}
        end

      _ ->
        {:error, :accepted_event}
    end
  rescue
    _ -> {:error, :accepted_event}
  end

  # The deliveries the answer builds on (the round's association, and a reply
  # round's reply association) are proven before it is written: one that the
  # delivery pass has not appended yet is retried, and one acknowledged
  # without its row, or held by another record, is fenced.
  defp append_answer(state) do
    case carried_deliveries(state, List.delete(required_deliveries(state), :answer)) do
      :ok -> answer_command(state)
      {:undelivered, _kind} -> {{:error, :unavailable}, state}
      failure -> unconfirmed_delivery(state, failure)
    end
  end

  defp answer_command(state) do
    c = state.current
    expected_revision = answer_expected_revision(state, c)

    request =
      command_request(
        state.profile,
        c.event.conversation_id,
        expected_revision,
        c.answer_operation,
        %{"message_id" => answer_id(c.input_id), "text" => c.answer}
      )

    facts = answer_facts(c.run_id, c.input_id, true)

    {result, state} = execute_checked(state, :answer, c.event, request, facts)
    classify_answer(state, c, result)
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    _, _ -> {{:error, :unavailable}, state}
  end

  defp classify_answer(state, c, result) do
    expected_revision = answer_expected_revision(state, c)

    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == expected_revision + 1 ->
        if answer_receipt?(response, c.input_id, c.run_id, answer_id(c.input_id)),
          do: answer_delivery(state, c, revision),
          else: {{:unknown, :answer_receipt}, %{state | poison: {:answer, :receipt}}}

      {:unknown, _} = unknown ->
        {{:unknown, :answer}, %{state | poison: {:answer, c.answer_operation, unknown}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      {:intent_conflict, code} ->
        {{:blocked, {:intent, code}}, %{state | poison: {:intent, :answer, code}}}

      other ->
        {{:blocked, :answer}, %{state | poison: {:answer, other}}}
    end
  rescue
    _ ->
      {{:unknown, :answer}, %{state | poison: {:answer, c.answer_operation, :exception}}}
  catch
    _, _ ->
      {{:unknown, :answer}, %{state | poison: {:answer, c.answer_operation, :exception}}}
  end

  # The committed answer's delivery item, by its original key and nonce: a
  # fresh answer's item is still pending (the next delivery pass appends and
  # acknowledges it) and a replayed one may be acknowledged already. Both are
  # carried in the round's custody, and the first native acknowledgement
  # waits for a positive confirmation of that receipt. When the lookup cannot
  # be read, the answer's command is committed and only this read is retried
  # (`{:answer_delivery_receipt, revision}`): the command is never executed
  # again, so write-time policy and authority are not consulted again.
  defp answer_delivery(state, c, revision) do
    next_phase =
      if reply_profile?(state.profile) and is_map(state.reply), do: :reply_ack, else: :ack

    case delivery_receipt(state, :answer, c.answer_operation, revision) do
      {:ok, key, nonce} ->
        current = c |> Map.put(:answer_revision, revision) |> carry_delivery(:answer, key, nonce)
        {{:answered, revision}, %{state | current: current, phase: next_phase, poison: nil}}

      {:superseded, key, nonce} ->
        {{:blocked, :delivery_ack_superseded},
         %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

      {:error, {:held, held}} ->
        {{:unknown, :answer_delivery},
         %{hold_item(state, held) | poison: {:answer_delivery_receipt, revision}}}

      _ ->
        {{:unknown, :answer_delivery}, %{state | poison: {:answer_delivery_receipt, revision}}}
    end
  end

  defp resume_answer_delivery(%{current: current} = state, revision) when is_map(current),
    do: answer_delivery(%{state | poison: nil}, current, revision)

  defp resume_answer_delivery(state, _revision), do: {{:blocked, :answer_state}, state}

  # The delivery receipts a round relies on, carried in its custody by kind
  # (`:association`, `:reply_association`, `:answer`): each was accepted by
  # its original key and nonce, possibly while its item was still pending.
  defp carry_delivery(current, kind, key, nonce) do
    deliveries = current |> Map.get(:deliveries, %{}) |> Map.put(kind, {key, nonce})
    Map.put(current, :deliveries, deliveries)
  end

  # A committed association's delivery item (`kind` is `:association` or
  # `:reply_association`), carried in the round's custody as recovery
  # carries it. `{:ok, current}`, `{:superseded, key, nonce}` or `{:error,
  # :delivery_ack}`.
  defp carry_association_delivery(state, current, kind, operation, revision) do
    case delivery_receipt(state, kind, operation, revision) do
      {:ok, key, nonce} -> {:ok, carry_delivery(current, kind, key, nonce)}
      other -> other
    end
  end

  # A committed association's delivery receipt (`kind` is `:association` or
  # `:reply_association`), on the fresh, the reconciled and the reply paths.
  # When its lookup cannot be read, the association is committed and only
  # that read is retried (`{:association_delivery_receipt, kind,
  # revision}`): the command is never executed again, and neither its
  # confirmed history nor the Conversation is read again, so write-time
  # policy and authority are not consulted again.
  defp association_delivery(state, c, revision) do
    case carry_association_delivery(state, c, :association, c.association_operation, revision) do
      {:ok, current} ->
        {{:associated, c.run_id}, %{state | current: current, phase: :create_run, poison: nil}}

      failure ->
        association_receipt_unread(state, :association, revision, failure)
    end
  end

  defp reply_association_delivery(%{reply: reply, current: c} = state, revision) do
    case carry_association_delivery(
           state,
           c,
           :reply_association,
           reply.association_operation,
           revision
         ) do
      {:ok, current} ->
        reply = %{reply | association_revision: revision}

        {{:reply_associated, revision},
         %{state | current: current, reply: reply, phase: :reply_input, poison: nil}}

      failure ->
        association_receipt_unread(state, :reply_association, revision, failure)
    end
  end

  defp association_receipt_unread(state, _kind, _revision, {:superseded, key, nonce}),
    do:
      {{:blocked, :delivery_ack_superseded},
       %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

  defp association_receipt_unread(state, kind, revision, {:error, {:held, held}}),
    do:
      {{:unknown, :association_delivery},
       %{hold_item(state, held) | poison: {:association_delivery_receipt, kind, revision}}}

  defp association_receipt_unread(state, kind, revision, _failure),
    do:
      {{:unknown, :association_delivery},
       %{state | poison: {:association_delivery_receipt, kind, revision}}}

  defp resume_association_delivery(%{current: current} = state, :association, revision)
       when is_map(current),
       do: association_delivery(%{state | poison: nil}, current, revision)

  defp resume_association_delivery(
         %{current: current, reply: reply} = state,
         :reply_association,
         revision
       )
       when is_map(current) and is_map(reply),
       do: reply_association_delivery(%{state | poison: nil}, revision)

  defp resume_association_delivery(state, _kind, _revision),
    do: {{:blocked, :association_state}, state}

  # Before a round's first native acknowledgement, every delivery-only item
  # the round relies on is proven delivered: its association, a reply round's
  # reply association and an answered round's answer. For each, the carried
  # receipt's acknowledgement is confirmed with the item's original receipt,
  # read-only, and the Conversation append itself is proven: by the exact
  # append result this host's delivery pass remembered in this lifetime, or
  # by the durable record whose every persisted field equals the intent
  # rebuilt from the item's retained command (its response and digest). An
  # acknowledgement alone proves nothing: anyone can read an item's key and
  # nonce. `:ok`, `{:superseded, key, nonce}`, `{:unproven, kind, key}`,
  # `{:conflict, key, code}`, `{:missing, kind}` or `{:error, reason}`
  # (retried; nothing is written).
  defp deliveries_confirmed(%{current: current} = state) do
    deliveries = Map.get(current, :deliveries, %{})

    Enum.reduce_while(required_deliveries(state), :ok, fn kind, :ok ->
      with {:ok, {key, nonce}} <- Map.fetch(deliveries, kind),
           :ok <- confirmed_delivery(state, kind, key, nonce) do
        {:cont, :ok}
      else
        :error -> {:halt, {:missing, kind}}
        failure -> {:halt, failure}
      end
    end)
  end

  # Every round delivered its association; a reply round also its reply
  # association, and an answered round its answer.
  defp required_deliveries(%{current: current, reply: reply}) do
    reply_association =
      if is_map(reply) and is_integer(Map.get(reply, :association_revision)),
        do: [:reply_association],
        else: []

    answer = if is_nil(current.answer), do: [], else: [:answer]
    [:association | reply_association] ++ answer
  end

  defp confirmed_delivery(state, kind, key, nonce) do
    receipt = Elzoo.DurableLog.Codec.ack_receipt(key, nonce)

    case DurableLog.confirm_ack(state.command_store, receipt) do
      {:committed, _} ->
        case read_original_item(state, key, @delivery_destination) do
          {:ok, %{state: :acked, nonce: ^nonce} = item} -> delivered_append(state, kind, item)
          _ -> {:error, :delivery}
        end

      :superseded ->
        {:superseded, key, nonce}

      _ ->
        {:error, :delivery_ack}
    end
  rescue
    _ -> {:error, :delivery_ack}
  catch
    _, _ -> {:error, :delivery_ack}
  end

  # The Conversation append of one delivery-only item: the exact append
  # result this host's delivery pass remembered for that item in this
  # lifetime, else the durable record compared with the item's retained
  # intent (`item_delivery/3`).
  defp delivered_append(state, kind, item) do
    if Map.has_key?(state.delivered, item.idempotency_key),
      do: :ok,
      else: item_delivery(state, kind, item)
  end

  # Before a later Conversation write or the native reply delivery, the
  # delivery-only items that the round carries for it (its association, and
  # a reply round's reply association) are proven the same way: an item
  # still pending is `{:undelivered, kind}` (the delivery pass has not
  # appended it yet, and the step runs again), and every other failure,
  # another nonce's acknowledgement included, is returned for the caller's
  # fence: supersession never proves a delivery.
  defp carried_deliveries(%{current: current} = state, kinds) do
    deliveries = Map.get(current, :deliveries, %{})

    Enum.reduce_while(kinds, :ok, fn kind, :ok ->
      case Map.fetch(deliveries, kind) do
        {:ok, {key, _nonce}} ->
          case carried_delivery(state, kind, key) do
            :ok -> {:cont, :ok}
            failure -> {:halt, failure}
          end

        :error ->
          {:halt, {:missing, kind}}
      end
    end)
  end

  defp carried_delivery(state, kind, key), do: held_item(state, kind, @delivery_destination, key)

  # A delivery-only item that recovery found, checked like a carried one; a
  # check that cannot be read keeps the found key held while recovery
  # retries.
  defp recovered_delivery(state, kind, key) do
    case carried_delivery(state, kind, key) do
      {:error, _reason} -> {:error, {:held, {kind, @delivery_destination, key}}}
      other -> other
    end
  end

  # The delivery of one of this channel's items, decided by its Conversation
  # row compared with the intent its retained command binds: `:ok` when the
  # row is there; `{:undelivered, kind}` while the item is pending without
  # it; `{:unproven, kind, key}` when the item is acknowledged with its own
  # nonce without it, which breaks the Need that only the channel
  # acknowledges its items, after their append (the channel never appends
  # such an item); `{:superseded, key, nonce}` when another nonce
  # acknowledged it without it; `{:conflict, key, code}` when another record
  # holds its place (the Conversation's own refusal); `{:error, reason}` when
  # the item's retained command or the row cannot be read.
  defp item_delivery(state, kind, item) do
    case delivery_intent(state, item) do
      {:ok, mode, intent} -> intent_delivery(state, kind, item, mode, intent)
      {:error, :read} -> {:error, :read}
      _ -> {:error, :intent}
    end
  end

  defp intent_delivery(state, kind, item, mode, intent) do
    cond do
      mode != intent_mode(kind) ->
        {:error, :intent}

      # The item's own receipt decides before its row: an acknowledgement
      # under another nonce keeps the superseded fence, also when the exact
      # row exists.
      item.state == :acked and item.ack_nonce != item.nonce ->
        {:superseded, item.idempotency_key, item.nonce}

      true ->
        case intent_record(state, mode, intent) do
          :ok ->
            :ok

          :absent ->
            if item.state == :pending,
              do: {:undelivered, kind},
              else: {:unproven, kind, item.idempotency_key}

          {:conflict, code} ->
            {:conflict, item.idempotency_key, code}

          _ ->
            {:error, :record}
        end
    end
  end

  defp intent_mode(kind) when kind in [:input, :answer], do: kind
  defp intent_mode(_kind), do: :association

  # Before a later native action of the conversation (a Run, an Attempt, an
  # engine start, or a native input: the start wake, the reply and the
  # expiry wake), each held item is checked, in command order: an
  # acknowledgement without its row or under another nonce, or a row that
  # rules the item out, fences the round with nothing dispatched, and a read
  # that fails is retried with nothing dispatched.
  defp held_then(state, step) do
    case held_items_proven(state, nil, [], %{}) do
      {:ok, state} -> step.(state)
      {{:error, _reason}, state} -> {{:error, :unavailable}, state}
      {failure, state} -> unconfirmed_delivery(state, failure)
    end
  end

  # The held items of the conversation (before the command sequence `before`
  # when given): the round's own items, the host's held items (`state.held`)
  # and `custody`, the items that the persisted custody of a round not yet
  # restored names (`custody_items/2`), each decided from its latest
  # observation in `seen`, else read by its key (`held_proven/3`).
  defp held_items_proven(state, before, custody, seen) do
    (round_items(state) ++ held_list(state) ++ custody)
    |> Enum.uniq_by(fn {_kind, _destination, key} -> key end)
    |> Enum.filter(fn {_kind, _destination, key} ->
      sequence = item_sequence(key)
      is_integer(sequence) and (is_nil(before) or sequence < before)
    end)
    |> held_proven(state, seen)
  end

  # Held items in command order, each decided by `item_decision/3` from its
  # latest observation (`seen`, else one read by its key): `{:ok, state}`
  # when each is settled (proven, or pending without its row: its own
  # delivery comes in its turn), else `{failure, state}` with the first
  # failure: a fence (`{:unproven, kind, key}`, `{:superseded, key, nonce}`
  # or `{:conflict, key, code}`) after which nothing later is dispatched, or
  # `{:error, reason}` when the item cannot be read. An unreadable item stays
  # held by its exact key (`settle_held/3` decides the release).
  defp held_proven(items, state, seen) do
    items
    |> Enum.sort_by(fn {_kind, _destination, key} -> item_sequence(key) end)
    |> Enum.reduce_while({:ok, state}, fn held, {:ok, state} ->
      {decision, item} = held_decision(state, held, seen)

      case decision do
        :ok -> {:cont, {:ok, settle_held(state, held, item)}}
        {:undelivered, _kind} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, {error, hold_item(state, held)}}
        failure -> {:halt, {failure, state}}
      end
    end)
  end

  # The decision for one held item and the observation that it rests on.
  defp held_decision(state, {kind, destination, key}, seen) do
    observed =
      case Map.fetch(seen, key) do
        {:ok, item} -> {:ok, item}
        :error -> observe_item(state, destination, key)
      end

    case observed do
      {:ok, item} -> {item_decision(state, kind, item), item}
      error -> {error, nil}
    end
  end

  # A held input stays held until this host acknowledges it
  # (`release_held/2`). A held delivery-only item stays held while its
  # observed item is pending, also with its exact row, and is released once
  # observed acknowledged with its own nonce, its append proven. Items that
  # are not held are never added here.
  defp settle_held(state, {:input, _destination, _key}, _item), do: state

  defp settle_held(state, {_kind, _destination, key}, item) do
    if item.state == :acked and item.ack_nonce == item.nonce,
      do: %{state | held: Map.delete(state.held, key)},
      else: state
  end

  # Live, the round's input items and the delivery-only items that it
  # carries.
  defp round_items(%{current: current} = state) when is_map(current) do
    reply =
      case state.reply do
        %{item: %{idempotency_key: key}} -> [{:input, @reply_destination, key}]
        _ -> []
      end

    deliveries =
      for {kind, {key, _nonce}} <- Map.get(current, :deliveries, %{}),
          do: {kind, @delivery_destination, key}

    [{:input, @destination, current.item.key} | reply] ++ deliveries
  end

  defp round_items(_state), do: []

  defp held_list(state),
    do: for({key, {kind, destination}} <- state.held, do: {kind, destination, key})

  # Before an observation idles or adopts an item: each held item that this
  # window no longer shows was acknowledged meanwhile, and its own receipt
  # and its row decide, read by its key: an append that this host proved
  # does not settle an acknowledgement under another nonce. In version 1,
  # before a round is restored, the held primaries still name their rounds'
  # delivery items: their custody is discovered in command order
  # (`discover_roots/6`) before anything is decided. Discovery's reads are
  # later observations than the window: a window item that one of them saw
  # acknowledged is no longer shown, and a held primary that is no longer
  # shown is discovered in its turn. The unseen held items and the items
  # that the roots name are then decided together in command order
  # (`held_proven/3`), so the earliest breach fences. When a read of
  # discovery fails, what it named and read is kept, and only the items
  # before the first sequence at which an item it could not name can lie
  # (`discovery_limit/4`) are decided: a breach among them fences, else the
  # step is retried with everything held. A settled root is released; each
  # item that an unsettled root names and that is not settled is held by
  # its key, so that a round adopted later still checks it. `{:ok, state,
  # window}` with the window as last observed, or `{failure, state}`.
  defp unseen_held_proven(state, window) do
    shown = Map.new(window, &{&1.idempotency_key, &1})

    {seen, frontier, settled, named} =
      discover_roots(state, unseen_roots(state), shown, %{}, [], [])

    limit =
      case frontier do
        :complete -> nil
        {base, _error} -> discovery_limit(state, base, named, Map.merge(shown, seen))
      end

    window = Enum.map(window, &Map.get(seen, &1.idempotency_key, &1))

    decided =
      state
      |> held_list()
      |> Enum.reject(fn {_kind, _destination, key} -> shown?(shown, seen, key) end)
      |> Kernel.++(named)
      |> Enum.uniq_by(fn {_kind, _destination, key} -> key end)
      |> Enum.filter(fn {_kind, _destination, key} ->
        is_nil(limit) or item_sequence(key) < limit
      end)
      |> held_proven(state, seen)

    case {decided, frontier} do
      {{:ok, state}, :complete} ->
        state = release_held(state, settled)
        {:ok, Enum.reduce(named, state, &hold_unsettled(&2, &1, seen)), window}

      {{:ok, state}, {_base, error}} ->
        {error, state}

      {failure, _frontier} ->
        failure
    end
  end

  # Whether the window shows `key` pending, as last observed.
  defp shown?(shown, seen, key) do
    case Map.fetch(shown, key) do
      {:ok, item} -> Map.get(seen, key, item).state == :pending
      :error -> false
    end
  end

  # The first sequence after `base` at which an item that discovery could
  # not name can lie (`nil` base: none is known). Such an item is a
  # delivery item of a round, the row of its own command, so it never lies
  # at the sequence of a known input item, the row of another command: an
  # input that this host holds, that custody names or that a read observed.
  # Every item before that sequence is known.
  defp discovery_limit(_state, nil, _named, _seen), do: 0

  defp discovery_limit(state, base, named, seen) do
    occupied =
      MapSet.new(
        for(
          {:input, _destination, key} <- round_items(state) ++ held_list(state) ++ named,
          do: item_sequence(key)
        ) ++
          for(
            {_key, %{destination: destination, sequence: sequence}} <- seen,
            destination in [@destination, @reply_destination],
            do: sequence
          )
      )

    (base + 1) |> Stream.iterate(&(&1 + 1)) |> Enum.find(&(not MapSet.member?(occupied, &1)))
  end

  # Version 1, before a round is restored: the held primaries in command
  # order. The first is the custody root (`held_primary/1`).
  defp unseen_roots(%{current: nil} = state) do
    if reply_profile?(state.profile) do
      []
    else
      state.held
      |> Enum.filter(fn {_key, held} -> held == {:input, @destination} end)
      |> Enum.map(fn {key, _held} -> key end)
      |> Enum.sort_by(&item_sequence/1)
    end
  end

  defp unseen_roots(_state), do: []

  # The held primaries in command order, up to the first that the window
  # shows pending as last observed: each is taken from its latest
  # observation in `seen`, else read by its key, and the items that its
  # custody names are discovered (`custody_items/2`), whose reads replace
  # older ones in `seen`. A root whose round these reads show settled (the
  # root and each item that it names acknowledged with its own nonce) lets
  # the next held primary be discovered; the first that is not ends
  # discovery and stays the custody root. `{seen, frontier, settled,
  # named}`: the frontier is `:complete`, or `{base, error}` when a read
  # failed, with what discovery named and read before it kept: every item
  # that it could not name lies after the sequence `base`.
  defp discover_roots(_state, [], _shown, seen, settled, named),
    do: {seen, :complete, settled, named}

  defp discover_roots(state, [key | roots], shown, seen, settled, named) do
    if shown?(shown, seen, key) do
      {seen, :complete, settled, named}
    else
      case seen_root(state, seen, key) do
        {:ok, root} ->
          seen = Map.put(seen, key, root)

          case custody_items(state, {root.sequence, {:primary, root}}) do
            {:ok, items, found} ->
              seen = Map.merge(seen, found)
              named = items ++ named

              if Enum.all?([{:input, @destination, key} | items], fn {_kind, _destination, key} ->
                   settled?(Map.get(seen, key))
                 end),
                 do: discover_roots(state, roots, shown, seen, [key | settled], named),
                 else: {seen, :complete, settled, named}

            {:error, reason, items, found, base} ->
              {Map.merge(seen, found), {base, {:error, reason}}, settled, items ++ named}
          end

        # The held root itself is decided by its key with the held items.
        error ->
          {seen, {item_sequence(key), error}, settled, named}
      end
    end
  end

  defp seen_root(state, seen, key) do
    case Map.fetch(seen, key) do
      {:ok, item} -> {:ok, item}
      :error -> observe_item(state, @destination, key)
    end
  end

  defp hold_unsettled(state, {_kind, _destination, key} = item, seen),
    do: if(settled?(Map.get(seen, key)), do: state, else: hold_item(state, item))

  defp settled?(%{state: :acked, ack_nonce: nonce, nonce: nonce}), do: true
  defp settled?(_item), do: false

  # Before a round is restored (a restored round holds its own,
  # `round_items/1`), the round that the persisted custody names: in version
  # 1, the window's first pending primary input of this conversation; in
  # version 2, the custody facts, unless they name the round that this host
  # completed. `{:ok, {first, names}}` with the round's first outbox
  # sequence, before which none of its items lies, `{:ok, nil}` without such
  # a round, or `{:error, reason}` when a read fails.
  defp custody_root(%{current: current}, _window) when is_map(current), do: {:ok, nil}

  defp custody_root(state, window) do
    if reply_profile?(state.profile) do
      with {:ok, snapshot} <-
             CheckedCommand.resource(
               state.handles.input,
               resource_scope(state.profile),
               state.profile.conversation_id
             ),
           {:ok, metadata} <- Intents.metadata(snapshot.fields, state.profile.tenant) do
        cond do
          is_nil(metadata) -> {:ok, nil}
          completed_pair_matches_metadata?(state.completed_pair, metadata) -> {:ok, nil}
          true -> {:ok, {item_sequence(metadata.primary_key), {:facts, metadata}}}
        end
      else
        _ -> {:error, :custody}
      end
    else
      v1_custody_root(state, window)
    end
  rescue
    _ -> {:error, :custody}
  catch
    _, _ -> {:error, :custody}
  end

  # Version 1: the round's primary is the earliest primary input that this
  # host holds (it observed it and has not acknowledged it), also once it has
  # left the window, never a later input that a newer window shows first;
  # without one, the window's first pending primary of this conversation.
  defp v1_custody_root(state, window) do
    case held_primary(state) do
      nil ->
        primary =
          Enum.find(window, fn item ->
            item.destination == @destination and
              match?({:ok, _notice}, delivery_notice(item, state.profile))
          end)

        if is_nil(primary), do: {:ok, nil}, else: {:ok, {primary.sequence, {:primary, primary}}}

      key ->
        case read_original_item(state, key, @destination) do
          {:ok, item} -> {:ok, {item.sequence, {:primary, item}}}
          _ -> {:error, :custody}
        end
    end
  end

  defp held_primary(state) do
    state.held
    |> Enum.filter(fn {_key, held} -> held == {:input, @destination} end)
    |> Enum.map(fn {key, _held} -> key end)
    |> Enum.min_by(&item_sequence/1, &<=/2, fn -> nil end)
  end

  # The items that a custody root names: in version 1, the delivery items of
  # the primary's association and answer; in version 2, the custody facts'
  # primary and reply inputs and, through them and the retained commands,
  # the delivery items of the round's association, reply association and
  # answer. They are discovered in command order, each read newer than the
  # one before it (a newer read of a key replaces an older one): the
  # primary, its association's scan, the custody facts' inputs and their
  # scan, then its answer's scan. `{:ok, items, seen}` with the items read
  # on the way, or `{:error, reason, items, seen, base}` when a read fails:
  # what was named and read before it is kept, and every item that could
  # not be named lies after the sequence `base` (`nil` when the round could
  # not be read at all).
  defp custody_items(state, {first, names}) do
    primary =
      case names do
        {:primary, primary} -> {:ok, primary}
        {:facts, metadata} -> read_original_item(state, metadata.primary_key, @destination)
      end

    case primary do
      {:ok, item} -> round_custody(state, names, item)
      _ -> {:error, :custody, [], %{}, first - 1}
    end
  rescue
    _ -> {:error, :custody, [], %{}, nil}
  catch
    _, _ -> {:error, :custody, [], %{}, nil}
  end

  defp round_custody(state, names, item) do
    found = {:ok, [], %{item.idempotency_key => item}, item.sequence}

    with {:ok, event, operation, _revision, _intent} <- recover_input(state, item) do
      input = event.input_id

      [
        fn ->
          command_receipt(
            state,
            state.handles.association,
            :association,
            association_operation(operation, input, state.profile)
          )
        end,
        fn -> fact_inputs(state, names) end,
        fn ->
          command_receipt(
            state,
            state.handles.answer,
            :answer,
            answer_operation(operation, input, state.profile)
          )
        end
      ]
      |> Enum.reduce_while(found, fn step, {:ok, items, seen, base} ->
        case step.() do
          {:ok, named, read} ->
            base =
              Enum.reduce(named, base, fn {_kind, _destination, key}, base ->
                max(base, item_sequence(key))
              end)

            {:cont, {:ok, named ++ items, Map.merge(seen, read), base}}

          _ ->
            {:halt, {:error, :custody, items, seen, base}}
        end
      end)
      |> case do
        {:ok, items, seen, _base} -> {:ok, items, seen}
        error -> error
      end
    else
      _ -> {:error, :custody, [], elem(found, 2), item.sequence}
    end
  end

  defp fact_inputs(_state, {:primary, _primary}), do: {:ok, [], %{}}
  defp fact_inputs(state, {:facts, metadata}), do: fact_items(state, metadata)

  # The input items that version 2 custody facts name, and the reply
  # association's delivery item through the reply's retained commands, with
  # the items read on the way.
  defp fact_items(_state, %{primary_key: primary, reply_key: nil}),
    do: {:ok, [{:input, @destination, primary}], %{}}

  defp fact_items(state, %{primary_key: primary, reply_key: key}) do
    with {:ok, item} <- read_original_item(state, key, @reply_destination),
         {:ok, %{"operation_id" => operation}} <- reply_notice(item, state.profile),
         {:completed, %{response: response}} <-
           CheckedCommand.result(
             state.handles.reply_input,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, operation}
           ),
         {:ok, ticket, _revision} <- receipt_input(response),
         {:ok, association, seen} <-
           command_receipt(
             state,
             state.handles.reply_association,
             :reply_association,
             association_operation(operation, ticket, state.profile)
           ) do
      # The reply's read comes before the scan's: a newer read of a key wins.
      {:ok, [{:input, @destination, primary}, {:input, @reply_destination, key} | association],
       Map.merge(%{key => item}, seen)}
    else
      _ -> {:error, :custody}
    end
  end

  # The delivery item of one committed command, read now (an observation for
  # the pass) whatever its acknowledgement: the check decides that. None
  # while the command is not committed, or when it settled without one; a
  # result that cannot be read is retried.
  defp command_receipt(state, handle, kind, operation) do
    case CheckedCommand.result(
           handle,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: revision}} ->
        case delivery_item(state, operation, revision) do
          {:ok, item, observed} ->
            {:ok, [{kind, @delivery_destination, item.idempotency_key}],
             Map.put(observed, item.idempotency_key, item)}

          _ ->
            {:error, :receipt}
        end

      {:unknown, :not_observed} ->
        {:ok, [], %{}}

      {:unknown, _reason} ->
        {:error, :command}

      _settled ->
        {:ok, [], %{}}
    end
  end

  # One held item, read by its key and decided (`item_decision/3`).
  defp held_item(state, kind, destination, key),
    do: state |> held_decision({kind, destination, key}, %{}) |> elem(0)

  # One item read by its key: `{:ok, item}`; a read that the store could not
  # serve is `{:error, :read}` and is retried; an item that is absent,
  # malformed or not this channel's is `{:error, :item}`, which a retry does
  # not change.
  defp observe_item(state, destination, key) do
    case read_original_item(state, key, destination) do
      {:ok, item} -> {:ok, item}
      {:error, :read} -> {:error, :read}
      _ -> {:error, :item}
    end
  end

  # The one decision for a held item from an observation of it: its own
  # receipt first (another nonce's acknowledgement is the superseded fence;
  # an append that this host proved does not override it), then that proven
  # append, else its row (`item_delivery/3`).
  defp item_decision(state, kind, %{idempotency_key: key, nonce: nonce} = item) do
    cond do
      item.state == :acked and item.ack_nonce != nonce -> {:superseded, key, nonce}
      Map.has_key?(state.delivered, key) -> :ok
      true -> item_delivery(state, kind, item)
    end
  end

  defp item_sequence(key) do
    case Outbox.parse_id(key) do
      {:ok, {_stream, sequence, _position}} -> sequence
      _ -> nil
    end
  end

  # The Conversation row of one retained intent, compared with every field
  # the intent persists, never with values read from the row itself: an
  # input or an answer by its message ID (an answer's Run completion fact
  # must be true, or the Conversation never admits it), an association by
  # its input message. Another content under that ID is the Conversation's
  # own refusal code, and so is a record that rules the intent out for good:
  # another Run bound to the input (`"already_associated"`) or another answer
  # to it (`"already_answered"`). No row is `:absent`.
  defp intent_record(state, :input, intent) do
    fields = [:message_id, :role, :actor, :text]

    case scan_pages(state, conversation_reference(state), 1, fn entry ->
           Map.get(entry, :message_id) == intent.message_id
         end) do
      {:ok, entry} ->
        if entry.kind == :input and Map.take(entry, fields) == Map.take(intent, fields),
          do: :ok,
          else: {:conflict, "duplicate_message_id"}

      {:error, :absent} ->
        :absent

      _ ->
        {:error, :unavailable}
    end
  end

  # The owner's precedence, decided against one history: a single pass over
  # the prefix `1..head` that the first page samples (`fold_prefix/4`). A
  # record that holds the answer's message ID decides at once: the identical
  # answer is `:ok`, any other record `"duplicate_message_id"`. Another
  # answer to the same input is only remembered, and is `"already_answered"`
  # once the pass reaches that head with no record of the message ID. A row
  # appended after the sample is not part of this history.
  defp intent_record(state, :answer, intent) do
    fields = [:message_id, :actor, :text, :run_id, :input_message_id]

    decision =
      fold_prefix(state, conversation_reference(state), :absent, fn entry, found ->
        cond do
          Map.get(entry, :message_id) == intent.message_id ->
            {:halt, entry}

          entry.kind == :answer and entry.input_message_id == intent.input_message_id ->
            {:cont, {:conflict, "already_answered"}}

          true ->
            {:cont, found}
        end
      end)

    case decision do
      {:halted, entry} ->
        if intent.completed == true and entry.kind == :answer and
             Map.take(entry, fields) == Map.take(intent, fields),
           do: :ok,
           else: {:conflict, "duplicate_message_id"}

      {:done, found} ->
        found

      _ ->
        {:error, :unavailable}
    end
  end

  defp intent_record(state, :association, intent) do
    case scan_pages(state, conversation_reference(state), 1, fn entry ->
           entry.kind == :association and entry.input_message_id == intent.input_message_id
         end) do
      {:ok, %{run_id: run_id}} ->
        if run_id == intent.run_id, do: :ok, else: {:conflict, "already_associated"}

      {:error, :absent} ->
        :absent

      _ ->
        {:error, :unavailable}
    end
  end

  defp association_record(state, input_message_id, run_id) do
    case scan_pages(state, conversation_reference(state), 1, fn entry ->
           entry.kind == :association and entry.input_message_id == input_message_id and
             entry.run_id == run_id
         end) do
      {:ok, _entry} -> :ok
      {:error, :absent} -> :absent
      _ -> {:error, :unavailable}
    end
  end

  defp conversation_reference(state),
    do: %{target_tenant: state.profile.tenant, conversation_id: state.profile.conversation_id}

  defp unconfirmed_delivery(state, {:superseded, key, nonce}),
    do:
      {{:blocked, :delivery_ack_superseded},
       %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

  # Acknowledged, yet never appended: an acknowledged item without its row
  # breaks the Need that only the channel acknowledges its items, after their
  # append. A defined fence, live and after a reopen: no delivery pass sees
  # the item again, and the channel never appends it.
  defp unconfirmed_delivery(state, {:unproven, kind, key}),
    do: {{:blocked, :delivery_unproven}, %{state | poison: {:delivery_unproven, kind, key}}}

  # Another content holds the item's place: the Conversation's refusal, a
  # defined fence.
  defp unconfirmed_delivery(state, {:conflict, key, code}),
    do: {{:blocked, {:delivery_refused, code}}, %{state | poison: {:delivery_refused, key, code}}}

  defp unconfirmed_delivery(state, {:missing, kind}),
    do: {{:blocked, :delivery_receipt}, %{state | poison: {:delivery_receipt, kind}}}

  defp unconfirmed_delivery(state, _failure), do: {{:error, :unavailable}, state}

  defp answer_expected_revision(%{reply: %{association_revision: revision}}, _current)
       when is_integer(revision),
       do: revision

  defp answer_expected_revision(_state, current), do: current.resource_revision + 1

  defp acknowledge_reply(state), do: acknowledge_reply_v2(state)

  # The reply item is acknowledged only after its custody facts (original key
  # and nonce, and the reply input's conversation sequence) are persisted in
  # the channel resource. The reply association records them on every round
  # that reaches it; a terminal reply acknowledged without that association
  # records them first with the reply custody command, one advance before
  # the acknowledgement.
  defp acknowledge_reply_v2(%{reply: %{item: item} = reply, current: current} = state)
       when is_map(item) and is_map(current) and
              (not is_nil(current.answer) or not is_nil(current.terminal)) do
    key = item.idempotency_key
    nonce = item.nonce

    with :ok <- deliveries_confirmed(state) do
      case reply_custody_state(state, reply, current) do
        :persisted ->
          case acknowledge_original_item(state, key, nonce, @reply_destination) do
            :ok ->
              {{:reply_acknowledged, key}, %{state | phase: :ack}}

            {:not_sent, :superseded} ->
              {{:unknown, :reply_ack}, %{state | poison: {:reply_ack, key, nonce, :superseded}}}

            {:not_sent, _reason} ->
              {{:error, :unavailable}, state}

            {:error, reason} ->
              {{:unknown, :reply_ack}, %{state | poison: {:reply_ack, key, nonce, reason}}}
          end

        {:record, sequence, snapshot} when not is_nil(current.terminal) ->
          record_reply_custody(state, reply, current, sequence, snapshot)

        :unavailable ->
          {{:error, :unavailable}, state}

        _ ->
          {{:blocked, :reply_custody}, %{state | poison: {:reply_custody_mismatch, key}}}
      end
    else
      failure -> unconfirmed_delivery(state, failure)
    end
  rescue
    _ ->
      {{:unknown, :reply_ack},
       %{state | poison: {:reply_ack, item.idempotency_key, item.nonce, :unknown}}}
  catch
    _, _ ->
      {{:unknown, :reply_ack},
       %{state | poison: {:reply_ack, item.idempotency_key, item.nonce, :unknown}}}
  end

  defp acknowledge_reply_v2(state), do: {{:blocked, :reply_state}, state}

  # The current Run's custody facts as the channel resource holds them:
  # `:persisted` when they name this reply item with its sequence, `{:record,
  # sequence, snapshot}` when they hold no reply yet, `:mismatch` for other
  # facts and `:unavailable` when the resource or the delivered reply input
  # cannot be read.
  defp reply_custody_state(state, reply, current) do
    item = reply.item

    with {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         {:ok, metadata} when is_map(metadata) <-
           Intents.metadata(snapshot.fields, state.profile.tenant),
         true <- metadata.run_id == current.run_id and metadata.primary_key == current.item.key,
         {:ok, sequence} <- input_sequence(state, item.idempotency_key, reply.ticket) do
      cond do
        is_nil(metadata.reply_key) ->
          {:record, sequence, snapshot}

        metadata.reply_key == item.idempotency_key and metadata.reply_nonce == item.nonce and
            metadata.reply_sequence == sequence ->
          :persisted

        true ->
          :mismatch
      end
    else
      false -> :mismatch
      {:ok, nil} -> :mismatch
      {:error, :metadata} -> :mismatch
      _ -> :unavailable
    end
  end

  defp record_reply_custody(state, reply, current, sequence, snapshot) do
    operation = reply_custody_operation(reply.operation_id, reply.ticket, state.profile)

    request =
      command_request(
        state.profile,
        state.profile.conversation_id,
        snapshot.revision,
        operation,
        %{"message_id" => reply.ticket}
      )

    facts =
      reply_custody_facts(
        current.run_id,
        current.item.key,
        reply.item.idempotency_key,
        reply.item.nonce,
        sequence
      )

    {result, state} = execute_checked(state, :reply_custody, reply.event, request, facts)

    case result do
      {:completed, %{revision: revision}} when revision == snapshot.revision + 1 ->
        {{:reply_custody, revision}, state}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

      {:unknown, _} ->
        {{:unknown, :reply_custody}, %{state | poison: {:reply_custody, operation}}}

      other ->
        {{:blocked, :reply_custody}, %{state | poison: {:reply_custody_refused, other}}}
    end
  end

  # An unknown custody command is reconciled read-only, by its own retained
  # result: a completed command lets the acknowledgement proceed. An
  # unobserved result is not proof that nothing will commit (an append paused
  # after its head compare-and-set reads exactly so while its writer lives),
  # so the command is never submitted again here. The host stays fenced until
  # the original command is confirmed, or until a fenced reopen has ended its
  # writer and recovery decides from the durable custody facts.
  defp reconcile_reply_custody(state, operation) do
    case CheckedCommand.result(
           state.handles.reply_custody,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: revision}} ->
        {{:reply_custody, revision}, %{state | poison: nil}}

      _ ->
        {{:unknown, :reply_custody}, state}
    end
  rescue
    _ -> {{:unknown, :reply_custody}, state}
  catch
    _, _ -> {{:unknown, :reply_custody}, state}
  end

  defp acknowledge(state) do
    c = state.current

    if is_nil(c.answer) and is_nil(c.terminal) do
      {{:blocked, :unresolved_result}, state}
    else
      case deliveries_confirmed(state) do
        :ok ->
          if reply_profile?(state.profile),
            do: acknowledge_primary_v2(state, c),
            else: acknowledge_primary_v1(state, c)

        failure ->
          unconfirmed_delivery(state, failure)
      end
    end
  end

  defp acknowledge_primary_v2(state, c) do
    key = c.item.key
    nonce = c.item.nonce

    case acknowledge_original_item(state, key, nonce, @destination) do
      :ok ->
        finish_input(state)

      {:not_sent, :superseded} ->
        {{:blocked, :ack_superseded}, %{state | poison: {:ack, key, nonce, :superseded}}}

      {:not_sent, _reason} ->
        {{:error, :unavailable}, state}

      {:error, reason} ->
        {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, reason}}}
    end
  rescue
    _ -> {{:unknown, :ack}, %{state | poison: {:ack, c.item.key, c.item.nonce, :unknown}}}
  catch
    _, _ -> {{:unknown, :ack}, %{state | poison: {:ack, c.item.key, c.item.nonce, :unknown}}}
  end

  # The first acknowledgement of an item with its original key and nonce:
  # `:ok` once it is acknowledged with that receipt; `{:not_sent, reason}`
  # when no write was dispatched (the item could not be read, `:unavailable`,
  # or another nonce already acknowledged it, `:superseded`); `{:error,
  # reason}` when a write was dispatched and its outcome is not proven, after
  # which only read-only confirmation by the original receipt may follow.
  defp acknowledge_original_item(state, key, nonce, destination) do
    case read_original_item(state, key, destination) do
      {:ok, %{state: :acked, nonce: ^nonce, ack_nonce: ^nonce}} ->
        :ok

      {:ok, %{state: :acked, nonce: ^nonce}} ->
        {:not_sent, :superseded}

      {:ok, %{state: :pending, nonce: ^nonce}} ->
        dispatch_ack(state, key, nonce, destination)

      {:ok, _other} ->
        {:not_sent, :identity}

      _ ->
        {:not_sent, :unavailable}
    end
  end

  defp dispatch_ack(state, key, nonce, destination) do
    case Outbox.ack(state.command_store, key, nonce) do
      {:committed, _} ->
        case acknowledged_outbox_item(state, key, nonce, destination) do
          :ok -> :ok
          _ -> {:error, :unknown}
        end

      {:indeterminate, receipt} ->
        request = Elzoo.DurableLog.Codec.ack_receipt(key, nonce)

        if ack_evidence_matches?(receipt, request) and
             match?({:committed, _}, DurableLog.confirm_ack(state.command_store, request)) and
             match?(:ok, acknowledged_outbox_item(state, key, nonce, destination)) do
          :ok
        else
          {:error, :unknown}
        end

      other ->
        {:error, other}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  # An indeterminate native acknowledgement is confirmed read-only by its
  # original receipt (key, nonce and digest): `:ok` when committed with it,
  # `:superseded` when another nonce won, `:unknown` otherwise (still
  # pending, unreadable or mismatching). The host never writes the
  # acknowledgement again in this lifetime: its writer may still be alive, so
  # only a fenced reopen acknowledges again.
  defp confirm_native_ack(state, key, nonce, destination) do
    case DurableLog.confirm_ack(state.command_store, Elzoo.DurableLog.Codec.ack_receipt(key, nonce)) do
      {:committed, _} ->
        if acknowledged_outbox_item(state, key, nonce, destination) == :ok,
          do: :ok,
          else: :unknown

      :superseded ->
        :superseded

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp acknowledge_primary_v1(state, c) do
    key = c.item.key
    nonce = c.item.nonce

    case Outbox.ack(state.command_store, key, nonce) do
      {:committed, _} ->
        finish_input(state)

      {:indeterminate, receipt} ->
        confirm_ack(state, receipt, key, nonce)

      {:conflict, _reason} ->
        {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, :no_receipt}}}

      {:rejected, _reason} ->
        {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, :no_receipt}}}

      other ->
        {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, other}}}
    end
  end

  defp confirm_ack(state, receipt, key, nonce), do: reconcile_ack(state, key, nonce, receipt)

  defp reconcile_ack(state, key, nonce, receipt) do
    if reply_profile?(state.profile) and match?(%{item: %{key: ^key, nonce: ^nonce}}, state.current) do
      case confirm_native_ack(state, key, nonce, @destination) do
        :ok -> finish_input(state)
        :superseded -> {{:blocked, :ack_superseded}, state}
        :unknown -> {{:unknown, :ack}, state}
      end
    else
      reconcile_ack_legacy(state, key, nonce, receipt)
    end
  end

  defp reconcile_ack_legacy(state, key, nonce, receipt) do
    request = Elzoo.DurableLog.Codec.ack_receipt(key, nonce)

    if ack_evidence_matches?(receipt, request) do
      case DurableLog.confirm_ack(state.command_store, request) do
        {:committed, _} ->
          finish_input(state)

        :superseded ->
          {{:blocked, :ack_superseded}, %{state | poison: {:ack, key, nonce, receipt}}}

        _other ->
          {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, receipt}}}
      end
    else
      {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, receipt}}}
    end
  rescue
    _ -> {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, receipt}}}
  catch
    _, _ -> {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, receipt}}}
  end

  defp ack_evidence_matches?(:no_receipt, _request), do: true

  defp ack_evidence_matches?(receipt, request) when is_map(receipt) do
    Enum.all?([:operation, :stream, :expected, :target, :nonce, :digest], fn key ->
      Map.get(receipt, key) == Map.get(request, key)
    end)
  end

  defp ack_evidence_matches?(_, _), do: false

  # This host acknowledged the round's primary item, and its reply item
  # before it when the round has one: neither is held any longer.
  defp finish_input(state) do
    c = state.current
    state = release_held(state, [c.item.key])

    cond do
      reply_profile?(state.profile) and not is_nil(c.terminal) ->
        finish_terminal_input(state, c)

      reply_profile?(state.profile) and is_map(state.reply) and is_nil(c.terminal) and
          not is_nil(c.answer) ->
        completed = %{c.input_id => %{run_id: c.run_id, outcome: :completed}}

        pair = %{
          tenant: state.profile.tenant,
          run_id: c.run_id,
          operation_id: c.operation_id,
          input_id: c.input_id,
          answer_operation: c.answer_operation,
          answer_id: answer_id(c.input_id),
          answer: c.answer,
          answer_revision: c.answer_revision,
          primary_key: c.item.key,
          primary_nonce: c.item.nonce,
          primary_sequence: custody_sequence(state, c.item.key, c.input_id),
          reply_operation: state.reply.operation_id,
          reply_ticket: state.reply.ticket,
          reply_key: state.reply.item.idempotency_key,
          reply_nonce: state.reply.item.nonce,
          reply_sequence:
            custody_sequence(state, state.reply.item.idempotency_key, state.reply.ticket)
        }

        latest_native = %{
          run_id: c.run_id,
          engine: state.engine,
          wait: state.native_wait,
          unit_id: unit_id(c.run_id, state)
        }

        {{:acknowledged, c.input_id},
         %{
           release_held(state, [state.reply.item.idempotency_key])
           | current: nil,
             phase: :idle,
             completed: completed,
             completed_pair: pair,
             latest_native: latest_native,
             poison: nil
         }}

      true ->
        finish_input_fenced(state, c)
    end
  end

  defp finish_terminal_input(state, c) do
    reply_ack = reply_ack_eligibility(state)

    pair = %{
      tenant: state.profile.tenant,
      terminal: c.terminal,
      operation_id: native_operation(c.run_id, state),
      attempt_id: attempt_id(c.run_id, state),
      run_id: c.run_id,
      primary_key: c.item.key,
      primary_nonce: c.item.nonce,
      reply_committed: reply_ack == :committed,
      reply_pending: reply_ack == :none and is_map(state.reply),
      reply_key: if(reply_ack == :committed, do: state.reply.item.idempotency_key),
      reply_nonce: if(reply_ack == :committed, do: state.reply.item.nonce)
    }

    latest_native = %{
      run_id: c.run_id,
      engine: state.engine,
      wait: state.native_wait,
      unit_id: unit_id(c.run_id, state),
      terminal: c.terminal
    }

    completed = Map.put(state.completed, c.input_id, %{run_id: c.run_id, outcome: c.terminal})

    {{:acknowledged, c.input_id},
     %{
       release_held(state, if(pair.reply_committed, do: [pair.reply_key], else: []))
       | current: nil,
         phase: :idle,
         approval: nil,
         completed: completed,
         completed_pair: pair,
         latest_native: latest_native,
         reply: if(pair.reply_committed, do: nil, else: state.reply),
         poison: nil
     }}
  end

  defp finish_input_fenced(state, c) do
    case fence_native(state) do
      :ok ->
        completed =
          Map.put(state.completed, c.input_id, %{
            run_id: c.run_id,
            outcome: c.terminal || :completed
          })

        {{:acknowledged, c.input_id},
         %{
           state
           | current: nil,
             phase: :idle,
             completed: completed,
             poison: nil,
             engine: nil,
             async_work: nil,
             writer: nil
         }}

      {:error, reason} ->
        _ = reason
        {{:unknown, :ack}, %{state | poison: {:ack, c.item.key, c.item.nonce, :no_receipt}}}
    end
  end

  defp reconcile_input(state, operation) do
    identity = {state.profile.tenant, state.profile.actor, operation}

    case CheckedCommand.result(state.handles.input, result_scope(state.profile), identity) do
      {:completed, %{revision: revision}} ->
        case state.approval do
          %{event: event, operation_id: ^operation}
          when revision == event.expected_revision + 1 ->
            if reply_profile?(state.profile) and not primary_deadline_live?(state) do
              approval = Map.put(state.approval, :input_state, :committed_expired)
              {{:reconciled, :input}, %{state | poison: nil, approval: approval}}
            else
              {{:reconciled, :input}, %{state | poison: nil, approval: nil}}
            end

          _ ->
            {{:unknown, :input}, state}
        end

      {:approval_pending, pending} ->
        case state.approval do
          %{event: event, operation_id: ^operation} ->
            approval =
              if reply_profile?(state.profile) do
                state.approval
                |> Map.merge(%{
                  event: event,
                  operation_id: operation,
                  key: pending.key,
                  requirement: pending.requirement,
                  request: Map.get(state.approval, :request, input_request(event, operation)),
                  facts: Map.get(state.approval, :facts, input_facts()),
                  release_state: :pending
                })
              else
                %{
                  event: event,
                  operation_id: operation,
                  key: pending.key,
                  requirement: pending.requirement
                }
              end

            {{:reconciled, :approval_pending}, %{state | poison: nil, approval: approval}}

          _ ->
            {{:unknown, :input}, state}
        end

      {:denied, {reason, _}} when reason in [:gate, :authorization] ->
        reconcile_input_terminal(state, operation)

      {:conflict, :stale_revision} ->
        reconcile_input_terminal(state, operation)

      {:conflict, {:domain, _}} ->
        reconcile_input_terminal(state, operation)

      {:refused, :domain_failure} ->
        reconcile_input_terminal(state, operation)

      _ ->
        {{:unknown, :input}, state}
    end
  rescue
    _ -> {{:unknown, :input}, state}
  end

  defp reconcile_input_terminal(state, operation) do
    case state.approval do
      %{event: _event, operation_id: ^operation} ->
        {{:reconciled, :input_terminal}, %{state | poison: nil, approval: nil}}

      _ ->
        {{:unknown, :input}, state}
    end
  end

  defp reconcile_release(state, operation) do
    case CheckedCommand.result(
           state.handles.input,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: revision}} ->
        case state.approval do
          %{event: event, operation_id: ^operation}
          when revision == event.expected_revision + 1 ->
            {{:reconciled, :release}, %{state | poison: nil, approval: nil}}

          _ ->
            {{:unknown, :release}, state}
        end

      {:conflict, :stale_revision} ->
        case state.approval do
          %{event: _event, operation_id: ^operation} ->
            {{:reconciled, :release_conflict}, %{state | poison: nil, approval: nil}}

          _ ->
            {{:unknown, :release}, state}
        end

      _ ->
        {{:unknown, :release}, state}
    end
  rescue
    _ -> {{:unknown, :release}, state}
  end

  defp reconcile_reply_input(state, operation) do
    case state.reply do
      %{event: event, operation_id: ^operation, request: _request, wait: _wait} = reply ->
        case CheckedCommand.result(
               state.handles.reply_input,
               result_scope(state.profile),
               {state.profile.tenant, state.profile.actor, operation}
             ) do
          {:completed, %{revision: revision, response: response}}
          when revision == event.expected_revision + 1 ->
            with {:ok, ticket, ^revision} <- receipt_input(response),
                 true <- ticket == event.input_id do
              live_state = reply_release_live?(state, event, reply)

              input_state =
                if live_state == :live,
                  do: :committed,
                  else: if(live_state == :expired, do: :committed_expired, else: :unknown)

              release_state = if live_state == :live, do: nil, else: :input_committed

              reply =
                Map.merge(reply, %{
                  ticket: ticket,
                  resource_revision: revision,
                  item: nil,
                  text: nil,
                  association_operation: association_operation(operation, ticket, state.profile),
                  association_revision: nil,
                  pending: nil,
                  release_state: release_state,
                  input_state: input_state
                })

              phase = if live_state == :live, do: :reply_observe, else: state.phase

              if live_state == :unknown do
                {{:unknown, :reply_input},
                 %{state | poison: {:reply_input, operation}, reply: reply}}
              else
                result = if live_state == :live, do: :reply_input, else: :reply_input_expired
                {{:reconciled, result}, %{state | poison: nil, reply: reply, phase: phase}}
              end
            else
              _ -> {{:unknown, :reply_input}, state}
            end

          {:approval_pending, pending} ->
            if is_nil(Map.get(reply, :pending)) or v2_pending_matches?(reply, pending) do
              reply =
                Map.merge(reply, %{
                  pending: pending,
                  key: pending.key,
                  requirement: pending.requirement,
                  release_state: :pending
                })

              {{:reconciled, :approval_pending}, %{state | poison: nil, reply: reply}}
            else
              {{:unknown, :reply_input}, state}
            end

          _ ->
            {{:unknown, :reply_input}, state}
        end

      _ ->
        {{:unknown, :reply_input}, state}
    end
  rescue
    _ -> {{:unknown, :reply_input}, state}
  catch
    _, _ -> {{:unknown, :reply_input}, state}
  end

  defp reconcile_v2_release(state, kind, operation) do
    record = if kind == :primary, do: state.approval, else: state.reply

    if is_map(record) and Map.get(record, :operation_id) == operation do
      handle = release_handle(state, kind)

      case CheckedCommand.result(
             handle,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, operation}
           ) do
        {:completed, %{revision: revision, response: response}}
        when revision == record.event.expected_revision + 1 ->
          case record_v2_release_completion(
                 state,
                 kind,
                 record.event,
                 operation,
                 record,
                 revision,
                 response
               ) do
            {:ok, state} when state.poison == {:reply_release_live, operation} ->
              {{:unknown, :release_live}, state}

            {:ok, state} ->
              {{:reconciled, :release}, %{state | poison: nil}}

            :error ->
              {{:unknown, :release}, state}
          end

        {:approval_pending, pending} ->
          if v2_pending_matches?(record, pending) do
            record = Map.merge(record, %{release_state: :pending, pending: pending})
            state = put_v2_release_record(%{state | poison: nil}, kind, record)
            {{:reconciled, :approval_pending}, state}
          else
            {{:unknown, :release}, state}
          end

        {:conflict, :stale_revision} ->
          record = Map.put(record, :release_state, :conflict)
          state = put_v2_release_record(%{state | poison: nil}, kind, record)
          {{:reconciled, :release_conflict}, state}

        _ ->
          {{:unknown, :release}, state}
      end
    else
      {{:unknown, :release}, state}
    end
  rescue
    _ -> {{:unknown, :release}, state}
  catch
    _, _ -> {{:unknown, :release}, state}
  end

  defp put_v2_release_record(state, :primary, record), do: %{state | approval: record}
  defp put_v2_release_record(state, :reply, record), do: %{state | reply: record}

  defp reconcile_association(state, operation) do
    c = state.current

    case CheckedCommand.result(
           state.handles.association,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 1 ->
        if association_receipt?(response, c.input_id, c.run_id) do
          case association_delivery(%{state | poison: nil}, c, revision) do
            {{:associated, _run_id}, state} -> {{:reconciled, :association}, state}
            other -> other
          end
        else
          {{:unknown, :association}, state}
        end

      _ ->
        {{:unknown, :association}, state}
    end
  rescue
    _ -> {{:unknown, :association}, state}
  catch
    _, _ -> {{:unknown, :association}, state}
  end

  defp reconcile_run_create(state) do
    c = state.current

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: operation}} ->
        if operation == native_operation(c.run_id, state),
          do: {{:reconciled, :run_create}, %{state | poison: nil, phase: :begin_attempt}},
          else: {{:unknown, :run_create}, state}

      _ ->
        {{:unknown, :run_create}, state}
    end
  rescue
    _ -> {{:unknown, :run_create}, state}
  catch
    _, _ -> {{:unknown, :run_create}, state}
  end

  defp reconcile_attempt(state) do
    c = state.current

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: operation, current_attempt: attempt}} ->
        if operation == native_operation(c.run_id, state) and attempt == attempt_id(c.run_id, state),
          do: {{:reconciled, :attempt}, %{state | poison: nil, phase: :start_engine}},
          else: {{:unknown, :attempt}, state}

      _ ->
        {{:unknown, :attempt}, state}
    end
  rescue
    _ -> {{:unknown, :attempt}, state}
  catch
    _, _ -> {{:unknown, :attempt}, state}
  end

  defp reconcile_answer(state) do
    if reply_profile?(state.profile),
      do: reconcile_v2_answer(state),
      else: reconcile_answer_v1(state)
  end

  defp reconcile_v2_answer(
         %{
           current: current,
           reply: %{
             association_operation: association_operation,
             association_revision: association_revision,
             ticket: ticket
           }
         } = state
       )
       when is_map(current) and is_integer(association_revision) and is_binary(ticket) do
    association_identity =
      {state.profile.tenant, state.profile.actor, association_operation}

    case CheckedCommand.result(
           state.handles.reply_association,
           result_scope(state.profile),
           association_identity
         ) do
      {:completed, %{revision: ^association_revision, response: association_response}} ->
        if association_receipt?(association_response, ticket, current.run_id) do
          case CheckedCommand.result(
                 state.handles.answer,
                 result_scope(state.profile),
                 {state.profile.tenant, state.profile.actor, current.answer_operation}
               ) do
            {:completed, %{revision: revision, response: response}}
            when revision == association_revision + 1 ->
              with true <-
                     answer_receipt?(
                       response,
                       current.input_id,
                       current.run_id,
                       answer_id(current.input_id)
                     ),
                   {:ok, key, nonce} <-
                     delivery_receipt(state, :answer, current.answer_operation, revision) do
                current =
                  current
                  |> Map.put(:answer_revision, revision)
                  |> carry_delivery(:answer, key, nonce)

                {{:reconciled, :answer},
                 %{state | current: current, poison: nil, phase: :reply_ack}}
              else
                {:superseded, key, nonce} ->
                  {{:blocked, :delivery_ack_superseded},
                   %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

                {:error, {:held, held}} ->
                  {{:unknown, :answer}, hold_item(state, held)}

                _ ->
                  {{:unknown, :answer}, state}
              end

            _ ->
              {{:unknown, :answer}, state}
          end
        else
          {{:unknown, :answer}, state}
        end

      _ ->
        {{:unknown, :answer}, state}
    end
  rescue
    _ -> {{:unknown, :answer}, state}
  catch
    _, _ -> {{:unknown, :answer}, state}
  end

  defp reconcile_v2_answer(state), do: {{:unknown, :answer}, state}

  defp reconcile_answer_v1(state) do
    c = state.current

    case CheckedCommand.result(
           state.handles.answer,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, c.answer_operation}
         ) do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 2 ->
        if answer_receipt?(response, c.input_id, c.run_id, answer_id(c.input_id)),
          do: reconcile_answer_v1_delivery(state, c, revision),
          else: {{:unknown, :answer}, state}

      _ ->
        {{:unknown, :answer}, state}
    end
  rescue
    _ -> {{:unknown, :answer}, state}
  catch
    _, _ -> {{:unknown, :answer}, state}
  end

  # A reconciled answer's delivery receipt is carried like a fresh one's: the
  # primary acknowledgement waits for its positive confirmation.
  defp reconcile_answer_v1_delivery(state, c, revision) do
    case delivery_receipt(state, :answer, c.answer_operation, revision) do
      {:ok, key, nonce} ->
        current = c |> Map.put(:answer_revision, revision) |> carry_delivery(:answer, key, nonce)
        {{:reconciled, :answer}, %{state | current: current, poison: nil, phase: :ack}}

      {:superseded, key, nonce} ->
        {{:blocked, :delivery_ack_superseded},
         %{state | poison: {:delivery_ack, key, nonce, :superseded}}}

      {:error, {:held, held}} ->
        {{:unknown, :answer}, hold_item(state, held)}

      _ ->
        {{:unknown, :answer}, state}
    end
  end

  # `{result, state}`: a Conversation-writing command's admission reads the
  # window, which holds what it shows (`admission_intent/3`).
  defp execute_checked(state, mode, event, request, facts) do
    # Host-generated Conversation-writing commands are checked against the
    # ordered admitted state like signed commands: a conflict is a definite
    # host-level contradiction, never committed.
    if mode in [:association, :reply_association, :answer] do
      case admission_intent(state, request, facts) do
        {:ok, state} -> {checked_execute(state, mode, event, request, facts), state}
        {{:error, {:conflict, code}}, state} -> {{:intent_conflict, code}, state}
        {{:error, _reason}, state} -> {{:unavailable, :admission}, state}
      end
    else
      {checked_execute(state, mode, event, request, facts), state}
    end
  rescue
    _ -> {{:unavailable, :context}, state}
  catch
    _, _ -> {{:unavailable, :context}, state}
  end

  defp checked_execute(state, mode, event, request, facts) do
    case command_context(state, mode, event, request, facts) do
      {:ok, context} ->
        try do
          CheckedCommand.execute(state.handles[mode], context, request)
        rescue
          _ -> {:unknown, :exception}
        catch
          _, _ -> {:unknown, :exception}
        end

      {:error, reason} ->
        {:unavailable, reason}
    end
  rescue
    _ -> {:unavailable, :context}
  catch
    _, _ -> {:unavailable, :context}
  end

  defp command_context(state, mode, event, request, facts) do
    handle =
      case mode do
        :release -> state.handles.input
        :reply_release -> state.handles.reply_input
        _ -> state.handles[mode]
      end

    with {:ok, snapshot} <-
           CheckedCommand.resource(
             handle,
             resource_scope(state.profile),
             state.profile.conversation_id
           ) do
      prepared =
        if mode == :reply_custody,
          do: Intents.prepare_custody(snapshot, request, prepare_facts(state.profile, facts)),
          else: Intents.prepare(snapshot, request, prepare_facts(state.profile, facts))

      writes =
        case prepared do
          {:ok, writes, _} -> writes
          _ -> []
        end

      base = %{
        tenant: state.profile.tenant,
        actor: state.profile.actor,
        policy: state.policy.(mode, event, state.clock.()),
        own: writes,
        parent: :none,
        facts: facts
      }

      {:ok, Map.merge(base, state.authority.(mode, event, request, facts))}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp read_view(state, trusted_scope) do
    case valid_read_scope(state.profile, trusted_scope) do
      :forbidden ->
        {:error, :forbidden}

      :unavailable ->
        {:error, :unavailable}

      :ok ->
        scope = resource_scope(state.profile, trusted_scope.resources)

        with {:ok, snapshot} <-
               CheckedCommand.resource(state.handles.input, scope, state.profile.conversation_id),
             {:ok, %{entries: entries}} <-
               Conversation.tail(
                 state.conversation.store,
                 resource_scope(state.profile),
                 %{
                   target_tenant: state.profile.tenant,
                   conversation_id: state.profile.conversation_id
                 },
                 @view_entries
               ),
             messages = view_messages(entries),
             associations = view_associations(entries),
             {:ok, summaries} <- run_summaries(state, associations),
             {:ok, event_waits} <- native_event_waits_view(state, snapshot),
             view <- %{
               tenant: state.profile.tenant,
               resource: state.profile.conversation_id,
               revision: snapshot.revision,
               messages: messages,
               associations: associations,
               runs: summaries
             },
             view <-
               if(reply_profile?(state.profile),
                 do: Map.put(view, :event_waits, event_waits),
                 else: view
               ),
             {:ok, response} <- Jason.encode(%{status: "ok", view: view}),
             true <- byte_size(response) <= @max_view_bytes do
          {:ok, view}
        else
          _ -> {:error, :unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # View entries shape: inputs read as their source/user messages and answers
  # as assistant messages; associations read as run attachments. Delivered
  # sequence positions are not part of the view.
  defp view_messages(entries) do
    for entry <- entries, entry.kind in [:input, :answer] do
      case entry do
        %{kind: :input} ->
          Map.take(entry, [:message_id, :role, :actor, :text])

        %{kind: :answer} ->
          entry
          |> Map.take([:message_id, :actor, :text, :run_id, :input_message_id])
          |> Map.put(:role, "assistant")
      end
    end
  end

  defp view_associations(entries) do
    for entry <- entries,
        entry.kind == :association,
        do: %{input_message_id: entry.input_message_id, run_id: entry.run_id}
  end

  defp native_event_waits_view(%{profile: profile} = state, snapshot) do
    metadata_present? = Map.has_key?(snapshot.fields, "wave4_reply")

    cond do
      not reply_profile?(profile) ->
        {:ok, nil}

      match?({:ok, _}, native_reader(state)) and metadata_present? ->
        {:ok, reader} = native_reader(state)
        native_event_waits_for_live_reader(state, reader)

      known_pre_native?(state) and
          (not metadata_present? or
             pre_native_metadata_matches?(snapshot, state.current, profile.tenant)) ->
        {:ok, nil}

      true ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp native_reader(%{current: %{run_id: run_id}, engine: engine} = state) when is_pid(engine),
    do: {:ok, %{run_id: run_id, engine: engine, wait: state.native_wait}}

  defp native_reader(%{latest_native: %{run_id: run_id, engine: engine, wait: wait}})
       when is_pid(engine),
       do: {:ok, %{run_id: run_id, engine: engine, wait: wait}}

  defp native_reader(_), do: :unavailable

  defp native_event_waits_for_live_reader(state, %{run_id: run_id, engine: engine, wait: known_wait}) do
    if Process.alive?(engine) and Process.alive?(state.native.run_owner) and is_nil(state.poison) do
      scope = %{tenant: state.profile.tenant, principal: state.profile.actor, run_id: run_id}

      case RunEngine.event_waits(engine, scope, @result_limits) do
        {:ok, %{waits: waits} = result} when is_list(waits) ->
          ticket = if is_map(known_wait), do: known_wait.correlation_id, else: nil

          valid? =
            Enum.all?(waits, fn wait ->
              wait.status in [:waiting, :settled, :closed] and
                wait.action_id == "reply" and
                wait.source_id == state.profile.reply_source_id and
                (is_nil(ticket) or wait.correlation_id == ticket) and
                is_tuple(wait.occurrence)
            end)

          if valid? do
            {:ok,
             Map.update!(result, :waits, fn entries ->
               Enum.map(
                 entries,
                 &Map.update!(&1, :occurrence, fn occurrence -> Tuple.to_list(occurrence) end)
               )
             end)}
          else
            {:error, :unavailable}
          end

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp known_pre_native?(%{
         engine: nil,
         native_wait: nil,
         latest_native: nil,
         poison: nil,
         current: nil,
         phase: phase
       }),
       do: phase in [:idle, :observe, :association, :create_run, :begin_attempt, :start_engine]

  defp known_pre_native?(%{
         engine: nil,
         native_wait: nil,
         latest_native: nil,
         poison: nil,
         current: current,
         phase: phase
       })
       when is_map(current),
       do: phase in [:association, :create_run, :begin_attempt, :start_engine]

  defp known_pre_native?(_), do: false

  defp pre_native_metadata_matches?(snapshot, %{run_id: run_id, item: %{key: primary_key}}, tenant) do
    case Intents.metadata(snapshot.fields, tenant) do
      {:ok, metadata} when is_map(metadata) ->
        metadata.run_id == run_id and metadata.primary_key == primary_key and
          is_nil(metadata.reply_key)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp pre_native_metadata_matches?(_, _, _), do: false

  defp native_event_waits(state) do
    c = state.current
    scope = %{tenant: state.profile.tenant, principal: state.profile.actor, run_id: c.run_id}
    RunEngine.event_waits(state.engine, scope, @result_limits)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp run_summaries(state, associations) do
    associations =
      if reply_profile?(state.profile),
        do: Enum.uniq_by(associations, & &1.run_id),
        else: associations

    associations
    |> Enum.reduce_while({:ok, []}, fn association, {:ok, acc} ->
      run_id = association.run_id

      case RunApprovalRelease.status(state.native.run_owner, run_id) do
        {:ok, status} ->
          case run_summary(state, run_id, status) do
            {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
            :error -> {:halt, {:error, :unavailable}}
          end

        {:error, :not_found} ->
          if known_not_created?(state, run_id) do
            {:cont, {:ok, [%{run_id: run_id, outcome: :not_recorded} | acc]}}
          else
            {:halt, {:error, :unavailable}}
          end

        _ ->
          {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp run_summary(state, run_id, status) when is_map(status) and not is_struct(status) do
    operation_id = Map.get(status, :operation_id)
    outcome = Map.get(status, :outcome)
    revision = Map.get(status, :revision)

    if Enum.all?([:id, :operation_id, :outcome, :revision], &Map.has_key?(status, &1)) and
         Map.get(status, :id) == run_id and operation_id == native_operation(run_id, state) and
         (is_nil(outcome) or RunApprovalRelease.outcome?(outcome)) and is_integer(revision) and
         revision in 0..9_223_372_036_854_775_807 do
      {:ok,
       %{
         run_id: run_id,
         operation_id: operation_id,
         outcome: public_outcome(outcome),
         revision: revision
       }}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp run_summary(_, _, _), do: :error

  defp known_not_created?(state, run_id),
    do:
      is_nil(state.poison) and state.phase == :create_run and is_map(state.current) and
        state.current.run_id == run_id

  defp profile(profile) when is_map(profile) and not is_struct(profile) do
    base = [:tenant, :actor, :conversation_id, :source_id, :deadline_ms, :native_target]
    immediate? = Enum.sort(Map.keys(profile)) == Enum.sort(base)
    reply? = Enum.sort(Map.keys(profile)) == Enum.sort(base ++ [:reply_source_id])

    valid_target? =
      (immediate? and profile.native_target == Elzoo.Wave4ChannelExample.NativeBindings.target()) or
        (reply? and
           profile.native_target == Elzoo.Wave4ChannelExample.NativeBindings.reply_target())

    valid_reply_source? =
      not reply? or
        (bounded_text?(profile.reply_source_id) and profile.reply_source_id != profile.source_id)

    if (immediate? or reply?) and valid_target? and valid_reply_source? and
         Enum.all?([profile.tenant, profile.actor, profile.source_id], &bounded_text?/1) and
         Elzoo.Conversation.Record.segment?(profile.tenant) and
         Elzoo.Conversation.Record.segment?(profile.conversation_id) and
         is_integer(profile.deadline_ms) and profile.deadline_ms > 0 and
         is_map(profile.native_target) do
      {:ok, profile}
    else
      {:error, :profile}
    end
  end

  defp profile(_), do: {:error, :profile}

  defp reply_profile?(profile),
    do: is_map(profile) and Map.has_key?(profile, :reply_source_id)

  defp select_target(profile, bindings) do
    scope = %{tenant: profile.tenant, source: profile.source_id}
    schema = %{"schema_id" => "elzoo.message/v1", "schema_version" => 1}
    expected_target = profile.native_target

    case TriggerBinding.select(bindings, scope, schema) do
      {:ok, %{target: ^expected_target} = selected} when profile.native_target == expected_target ->
        {:ok, selected}

      _ ->
        {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end

  defp handles?(handles, profile) do
    required =
      if reply_profile?(profile),
        do: [:input, :reply_input, :association, :reply_association, :answer, :reply_custody],
        else: [:input, :association, :answer]

    Enum.all?(required, &match?(%CheckedCommand.Handle{}, handles[&1]))
  end

  defp native(native, profile, target) when is_map(native) do
    required = [
      :run_owner,
      :held,
      :lease,
      :lease_owner,
      :lease_stream,
      :directory,
      :registry,
      :unit_registry,
      :supervisor,
      :task_supervisor,
      :unit_store,
      :evidence_store,
      :engine
    ]

    if Enum.all?(required, &Map.has_key?(native, &1)) and
         is_pid(native.run_owner) and is_pid(native.directory) and is_atom(native.registry) and
         not is_nil(Process.whereis(native.registry)) and is_atom(native.unit_registry) and
         not is_nil(Process.whereis(native.unit_registry)) and
         engine_configuration?(native.engine, profile) do
      {:ok, Map.merge(native, %{target: target.target, profile: profile})}
    else
      {:error, :native}
    end
  end

  defp native(_, _, _), do: {:error, :native}

  defp engine_configuration?(configuration, profile) when is_map(configuration) do
    {binding_keys, schema_keys} =
      if reply_profile?(profile) do
        {["finish", "local_work", "wait_event"],
         [
           {"answer/v1", 1},
           {"finish/v1", 1},
           {"message/v1", 1},
           {"wait/v1", 1},
           {"work/v1", 1}
         ]}
      else
        {["finish", "local_work"], [{"answer/v1", 1}, {"finish/v1", 1}, {"work/v1", 1}]}
      end

    Map.keys(configuration) |> Enum.sort() == [:bindings, :context, :gate, :policy, :schemas] and
      Map.keys(configuration.bindings) |> Enum.sort() == binding_keys and
      Map.keys(configuration.schemas) |> Enum.sort() == schema_keys and
      is_function(configuration.context, 0) and is_map(configuration.gate) and
      is_function(Map.get(configuration.gate, :call), 2) and
      match?({:ok, _}, Elzoo.Authorization.validate_policy(configuration.policy))
  rescue
    _ -> false
  end

  defp engine_configuration?(_, _), do: false

  defp engine_options(state, c, _attempt_id, unit_id, engine_name, async, writer) do
    native = state.native
    engine = native.engine
    run_id = c.run_id

    options = [
      name: engine_name,
      identity: unit_id,
      directory: native.directory,
      store: native.unit_store,
      run_owner: native.run_owner,
      run_id: run_id,
      tenant: state.profile.tenant,
      principal: state.profile.actor,
      pattern: {__MODULE__.Pattern, :step, %{stage: :work, text: c.text}},
      schemas: engine.schemas,
      gate: engine.gate,
      clock: state.clock,
      bindings: engine.bindings,
      context: engine.context,
      async_work: async,
      resources: %{},
      effect_intent: %{},
      request_cap: 8,
      budget: %{id: budget_id(run_id, state), incarnation: "fixed-v1", cap: 4, unit: "work"},
      budget_rule: :finish,
      run_deadline: state.profile.deadline_ms,
      evidence: %{writer: writer, stream: evidence_stream(run_id)},
      result_reader: %{evidence_store: native.evidence_store, retention_count: 1_024}
    ]

    if reply_profile?(state.profile) do
      Keyword.merge(options,
        pattern: {__MODULE__.WaitThenHash, :step, %{stage: :wait}},
        protocol_version: 2,
        event_source: reply_event_source(state, c)
      )
    else
      options
    end
  end

  defp reply_event_source(state, c) do
    profile = state.profile
    store = state.command_store
    conv_store = state.conversation.store
    handles = state.handles
    run_id = c.run_id
    primary = %{key: c.item.key, operation_id: c.operation_id, input_id: c.input_id, run_id: run_id}

    %{
      id: profile.reply_source_id,
      version: 1,
      head: fn scope ->
        Elzoo.Wave4ChannelExample.ReplySource.head(scope, profile, run_id, store)
      end,
      read: fn scope, event_id ->
        Elzoo.Wave4ChannelExample.ReplySource.read(
          scope,
          event_id,
          profile,
          run_id,
          store,
          conv_store,
          handles,
          primary
        )
      end
    }
  end

  defp start_evidence_writer(state, run_id) do
    fold = %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }

    limits = %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

    Elzoo.DurableLog.Writer.start_link(
      store: state.native.evidence_store,
      stream: evidence_stream(run_id),
      fold: fold,
      limits: limits
    )
  end

  defp fence_native(state) do
    if reply_profile?(state.profile),
      do: fence_native_v2(state),
      else: fence_native_v1(state)
  end

  defp fence_native_v2(state) do
    with :ok <- stop_native_process(state.engine),
         :ok <- stop_native_process(state.async_work),
         :ok <- stop_native_process(state.writer),
         :ok <- stop_native_unit(state),
         :ok <- no_live_native_processes([state.engine, state.async_work, state.writer]),
         :ok <- no_native_tasks(state),
         :ok <- no_live_native_unit(state),
         :ok <- no_native_unit_children(state) do
      demonitor_native(state)
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exit}
  end

  defp fence_native_v1(state) do
    with :ok <- stop_native_process(state.engine),
         :ok <- stop_native_process(state.async_work),
         :ok <- stop_native_process(state.writer),
         :ok <- stop_native_unit(state),
         :ok <- no_live_native_processes([state.engine, state.async_work, state.writer]),
         :ok <- no_live_native_unit(state) do
      demonitor_native(state)
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exit}
  end

  defp stop_native_unit(%{native: %{directory: directory}} = state) do
    case native_run_id(state) do
      nil ->
        :ok

      run_id ->
        if Process.alive?(directory),
          do: DynamicUnits.stop(directory, unit_id(run_id, state)),
          else: {:error, :directory_unavailable}
    end
  end

  defp native_run_id(%{current: %{run_id: run_id}}), do: run_id
  defp native_run_id(%{latest_native: %{run_id: run_id}}), do: run_id
  defp native_run_id(_), do: nil

  defp demonitor_native(state) do
    Enum.each([state.engine_ref, state.async_work_ref, state.writer_ref], fn
      reference when is_reference(reference) -> Process.demonitor(reference, [:flush])
      _ -> :ok
    end)
  end

  defp contain_native_exit(state, pid, reference, _reason) do
    case native_child_kind(state, pid, reference) do
      nil ->
        {:noreply, state}

      child ->
        case fence_native(state) do
          :ok ->
            {:noreply,
             %{
               state
               | poison: {:native_child_exit, child},
                 engine: nil,
                 engine_ref: nil,
                 async_work: nil,
                 async_work_ref: nil,
                 writer: nil,
                 writer_ref: nil
             }}

          {:error, _} ->
            {:noreply, %{state | poison: {:native_child_exit, child, :fencing}}}
        end
    end
  end

  defp native_child_kind(state, pid, reference) do
    Enum.find_value([:engine, :async_work, :writer], fn child ->
      ref = Map.get(state, String.to_existing_atom("#{child}_ref"))

      if Map.get(state, child) == pid or (is_reference(reference) and ref == reference),
        do: child
    end)
  end

  defp stop_native_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
        if Process.alive?(pid), do: {:error, :still_alive}, else: :ok
      rescue
        _ -> if(Process.alive?(pid), do: {:error, :stop_failed}, else: :ok)
      catch
        _, _ -> if(Process.alive?(pid), do: {:error, :stop_failed}, else: :ok)
      end
    else
      :ok
    end
  end

  defp stop_native_process(_), do: :ok

  defp no_live_native_processes(pids) do
    if Enum.any?(pids, &(is_pid(&1) and Process.alive?(&1))),
      do: {:error, :process_alive},
      else: :ok
  end

  defp no_native_tasks(%{native: %{task_supervisor: supervisor}}) do
    if Process.alive?(supervisor) and Task.Supervisor.children(supervisor) == [],
      do: :ok,
      else: {:error, :native_work_alive}
  rescue
    _ -> {:error, :task_supervisor_unavailable}
  catch
    _, _ -> {:error, :task_supervisor_unavailable}
  end

  defp no_native_unit_children(%{native: %{supervisor: supervisor}}) do
    if Process.alive?(supervisor) and DynamicSupervisor.which_children(supervisor) == [],
      do: :ok,
      else: {:error, :native_unit_child_alive}
  rescue
    _ -> {:error, :unit_supervisor_unavailable}
  catch
    _, _ -> {:error, :unit_supervisor_unavailable}
  end

  defp no_live_native_unit(state) do
    case native_run_id(state) do
      nil -> :ok
      run_id -> no_live_native_unit(state, run_id)
    end
  end

  defp no_live_native_unit(state, run_id) do
    id = unit_id(run_id, state)

    with :ok <- no_live_native_registrations(state, id) do
      case DynamicUnits.find(state.native.directory, id) do
        :not_found ->
          no_live_native_registrations(state, id)

        {:ok, pid} when is_pid(pid) ->
          if Process.alive?(pid),
            do: {:error, :unit_alive},
            else: no_live_native_registrations(state, id)

        {:error, :busy} ->
          stale_native_unit_registration(state, id)

        {:error, :unavailable} ->
          {:error, :unit_unavailable}

        _other ->
          {:error, :unit_alive}
      end
    end
  end

  defp no_live_native_registrations(state, id) do
    case {native_registration_status(state.native.registry, id),
          native_registration_status(state.native.unit_registry, id)} do
      {engine, unit} when engine in [:missing, :stale] and unit in [:missing, :stale] ->
        :ok

      {engine, unit} when engine == :unavailable or unit == :unavailable ->
        {:error, :unit_unavailable}

      _ ->
        {:error, :unit_alive}
    end
  end

  defp stale_native_unit_registration(state, id) do
    case {native_registration_status(state.native.registry, id),
          native_registration_status(state.native.unit_registry, id)} do
      {engine, :stale} when engine in [:missing, :stale] ->
        :ok

      {engine, unit} when engine == :unavailable or unit == :unavailable ->
        {:error, :unit_unavailable}

      _ ->
        {:error, :unit_alive}
    end
  end

  defp native_registration_status(registry, id) do
    case Registry.lookup(registry, id) do
      [] -> :missing
      [{pid, _}] when is_pid(pid) -> if(Process.alive?(pid), do: :live, else: :stale)
      _ -> :unavailable
    end
  end

  defp valid_event(event) when is_map(event) and not is_struct(event) do
    required = [:version, :event_id, :conversation_id, :input_id, :expected_revision, :text]

    if Enum.sort(Map.keys(event)) == Enum.sort(required) and event.version == 1 and
         Enum.all?([event.event_id, event.conversation_id, event.input_id], &bounded_ascii?/1) and
         is_integer(event.expected_revision) and
         event.expected_revision in 0..9_223_372_036_854_775_806 and
         is_binary(event.text) and byte_size(event.text) in 1..4_096 and String.valid?(event.text) and
         not String.contains?(event.text, <<0>>) do
      :ok
    else
      {:error, :event}
    end
  end

  defp valid_event(_), do: {:error, :event}

  defp valid_admission_scope(profile, event, scope) do
    case valid_read_scope(profile, scope) do
      :ok ->
        if event.conversation_id in scope.resources, do: :ok, else: {:error, :scope}

      reason ->
        {:error, reason}
    end
  end

  defp valid_read_scope(profile, scope) when is_map(scope) and not is_struct(scope) do
    cond do
      Enum.sort(Map.keys(scope)) != [:actor, :resources, :tenant] ->
        :unavailable

      not bounded_text?(scope.tenant) or not bounded_text?(scope.actor) or
          not is_list(scope.resources) ->
        :unavailable

      length(scope.resources) > 64 or not Enum.all?(scope.resources, &bounded_text?/1) ->
        :unavailable

      scope.tenant != profile.tenant or scope.actor != profile.actor or
          profile.conversation_id not in scope.resources ->
        :forbidden

      true ->
        :ok
    end
  end

  defp valid_read_scope(_, _), do: :unavailable

  defp before_deadline?(state), do: state.clock.() < state.profile.deadline_ms

  defp primary_deadline_live?(state) do
    now = state.clock.()
    is_integer(now) and now < state.profile.deadline_ms
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Admission's busy check: whether the window shows a primary input item.
  # The window read holds the input items that it shows
  # (`pending_window/1`): `{result, state}`.
  defp pending_input?(state) do
    case pending_window(state) do
      {:ok, items, state} ->
        result =
          cond do
            Enum.any?(items, &(&1.destination == @destination)) -> {:ok, true}
            pending_window_full?(items) -> {:error, :unavailable}
            true -> {:ok, false}
          end

        {result, state}

      {:error, _cause} ->
        {{:error, :unavailable}, state}
    end
  end

  defp pending_window_full?(items), do: length(items) >= @outbox_limit

  defp unfinished?(state),
    do:
      not is_nil(state.current) or not is_nil(state.approval) or not is_nil(state.latest_native) or
        state.phase != :idle

  defp fresh_primary_ready?(state) do
    cond do
      not is_nil(state.current) or not is_nil(state.approval) or state.phase != :idle ->
        {:error, :busy}

      reply_profile?(state.profile) and is_map(state.latest_native) ->
        completed_pair_proven?(state)

      reply_profile?(state.profile) and is_nil(state.completed_pair) and is_nil(state.reply) ->
        :ok

      reply_profile?(state.profile) ->
        {:error, :unknown}

      unfinished?(state) ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  defp completed_pair_proven?(%{completed_pair: pair, latest_native: reader} = state)
       when is_map(pair) and is_map_key(pair, :terminal) and is_map(reader),
       do: terminal_pair_proven?(state, pair, reader)

  defp completed_pair_proven?(%{completed_pair: pair, latest_native: reader} = state)
       when is_map(pair) and is_map(reader) do
    with true <- reader.run_id == pair.run_id and reader.unit_id == unit_id(pair.run_id, state),
         engine when is_pid(engine) <- reader.engine,
         true <- Process.alive?(engine),
         scope <- %{
           tenant: state.profile.tenant,
           principal: state.profile.actor,
           run_id: pair.run_id
         },
         {:ok, result} <- RunEngine.result(engine, scope, @result_limits),
         true <-
           result.run_id == pair.run_id and
             result.operation_id == native_operation(pair.run_id, state) and
             result.attempt_id == attempt_id(pair.run_id, state) and result.action_id == "hash" and
             result.schema_id == "answer/v1" and result.schema_version == 1 and
             valid_answer_payload?(result.payload) and result.payload["answer"] == pair.answer,
         {:completed, %{revision: answer_revision, response: answer_response}} <-
           CheckedCommand.result(
             state.handles.answer,
             result_scope(state.profile),
             {state.profile.tenant, state.profile.actor, pair.answer_operation}
           ),
         true <-
           answer_revision == pair.answer_revision and
             answer_receipt?(answer_response, pair.input_id, pair.run_id, pair.answer_id),
         {:ok, :answer, intent} <- Intents.delivery(answer_response),
         true <-
           intent.message_id == pair.answer_id and intent.text == pair.answer and
             intent.run_id == pair.run_id and intent.input_message_id == pair.input_id,
         {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             state.profile.conversation_id
           ),
         true <- snapshot.revision >= answer_revision and completed_pair_metadata?(snapshot, pair),
         :ok <- intent_record(state, :answer, intent),
         :ok <- association_record(state, pair.input_id, pair.run_id),
         :ok <- association_record(state, pair.reply_ticket, pair.run_id),
         :ok <-
           acknowledged_outbox_item(state, pair.reply_key, pair.reply_nonce, @reply_destination),
         :ok <- acknowledged_outbox_item(state, pair.primary_key, pair.primary_nonce, @destination) do
      :ok
    else
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp completed_pair_proven?(_), do: {:error, :unknown}

  defp terminal_pair_proven?(state, pair, reader) do
    operation_id = native_operation(pair.run_id, state)
    expected_attempt = attempt_id(pair.run_id, state)

    with false <- pair.reply_pending,
         true <- pair.operation_id == operation_id and pair.attempt_id == expected_attempt,
         true <- reader.run_id == pair.run_id and reader.unit_id == unit_id(pair.run_id, state),
         engine when is_pid(engine) <- reader.engine,
         true <- Process.alive?(engine) and Process.alive?(state.native.run_owner),
         {:ok,
          %{
            operation_id: ^operation_id,
            current_attempt: ^expected_attempt,
            outcome: terminal
          }} <- RunApprovalRelease.status(state.native.run_owner, pair.run_id),
         true <- terminal == pair.terminal,
         scope <- %{
           tenant: state.profile.tenant,
           principal: state.profile.actor,
           run_id: pair.run_id
         },
         {:terminal, ^terminal} <- RunEngine.result(engine, scope, @result_limits),
         :ok <-
           acknowledged_outbox_item(
             state,
             pair.primary_key,
             pair.primary_nonce,
             @destination
           ),
         :ok <- terminal_reply_ack_proven(state, pair) do
      :ok
    else
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp terminal_reply_ack_proven(state, %{reply_committed: true} = pair),
    do: acknowledged_outbox_item(state, pair.reply_key, pair.reply_nonce, @reply_destination)

  defp terminal_reply_ack_proven(_state, %{reply_committed: false}), do: :ok
  defp terminal_reply_ack_proven(_state, _pair), do: {:error, :unknown}

  # The pair metadata carries the committed custody facts; the pair fields are
  # derived from the same items, so the full comparison is exact.
  defp completed_pair_metadata?(snapshot, pair) do
    case Intents.metadata(snapshot.fields, pair.tenant) do
      {:ok, metadata} ->
        metadata.run_id == pair.run_id and metadata.primary_key == pair.primary_key and
          metadata.reply_key == pair.reply_key and
          metadata.primary_nonce == pair.primary_nonce and
          metadata.primary_sequence == pair.primary_sequence and
          metadata.reply_nonce == pair.reply_nonce and
          metadata.reply_sequence == pair.reply_sequence

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp acknowledged_outbox_item(state, key, nonce, destination) do
    with {:ok, {stream, sequence, position}} <- Outbox.parse_id(key),
         true <- position == 1,
         true <- stream == checked_stream(state.profile.tenant),
         {:ok, item} when is_map(item) <-
           Elzoo.DurableLog.Store.read(state.command_store, :read_ack, [key]),
         canonical <- Outbox.new(stream, sequence, position, destination, item.payload, item.nonce),
         true <-
           item.stream == stream and item.sequence == sequence and item.position == position and
             item.destination == destination and item.idempotency_key == key and
             item.nonce == nonce and item.digest == canonical.digest and item.state == :acked do
      :ok
    else
      _ -> {:error, :ack}
    end
  rescue
    _ -> {:error, :ack}
  catch
    _, _ -> {:error, :ack}
  end

  defp retire_previous_native(%{latest_native: nil} = state), do: {:ok, state}

  defp retire_previous_native(state) do
    with :ok <- completed_pair_proven?(state),
         :ok <- fence_native(state) do
      state = clear_native_children(state)
      {:ok, %{state | latest_native: nil, native_wait: nil, reply: nil}}
    else
      _ -> {:error, :previous_native}
    end
  rescue
    _ -> {:error, :previous_native}
  catch
    _, _ -> {:error, :previous_native}
  end

  defp input_request(event, operation_id),
    do:
      command_request_for_event(event, operation_id, %{
        "message_id" => event.input_id,
        "text" => event.text
      })

  defp command_request_for_event(event, operation_id, payload),
    do: %{
      operation_id: operation_id,
      resource: event.conversation_id,
      expected_revision: event.expected_revision,
      payload: payload
    }

  defp command_request(_profile, resource, revision, operation_id, payload),
    do: %{
      operation_id: operation_id,
      resource: resource,
      expected_revision: revision,
      payload: payload
    }

  defp input_facts,
    do: portable_facts(%{"mode" => {:text, "append_input"}, "input_role" => {:text, "source"}})

  defp association_facts(run_id),
    do: portable_facts(%{"mode" => {:text, "associate_run"}, "run_id" => {:text, run_id}})

  defp reply_primary_association_facts(run_id, primary_key, primary_nonce, primary_sequence),
    do:
      portable_facts(%{
        "mode" => {:text, "associate_run"},
        "run_id" => {:text, run_id},
        "primary_key" => {:text, primary_key},
        "primary_nonce" => {:bytes, primary_nonce},
        "primary_sequence" => primary_sequence
      })

  defp reply_association_facts(run_id, primary_key, reply_key, reply_nonce, reply_sequence),
    do:
      portable_facts(%{
        "mode" => {:text, "associate_run"},
        "run_id" => {:text, run_id},
        "primary_key" => {:text, primary_key},
        "reply_key" => {:text, reply_key},
        "reply_nonce" => {:bytes, reply_nonce},
        "reply_sequence" => reply_sequence
      })

  defp answer_facts(run_id, input_id, completed),
    do:
      portable_facts(%{
        "mode" => {:text, "append_answer"},
        "run_id" => {:text, run_id},
        "input_message_id" => {:text, input_id},
        "completed" => completed
      })

  defp reply_custody_facts(run_id, primary_key, reply_key, reply_nonce, reply_sequence),
    do:
      portable_facts(%{
        "mode" => {:text, "record_reply_custody"},
        "run_id" => {:text, run_id},
        "primary_key" => {:text, primary_key},
        "reply_key" => {:text, reply_key},
        "reply_nonce" => {:bytes, reply_nonce},
        "reply_sequence" => reply_sequence
      })

  defp portable_facts(fields), do: {:record, Enum.sort_by(fields, &elem(&1, 0))}

  defp prepare_facts(profile, facts),
    do: %{tenant: profile.tenant, actor: profile.actor, data: facts}

  defp result_scope(profile), do: %{tenant: profile.tenant, actor: profile.actor}

  defp resource_scope(profile, resources \\ nil),
    do: %{
      tenant: profile.tenant,
      actor: profile.actor,
      resources: resources || [profile.conversation_id]
    }

  defp checked_stream(tenant) do
    "cc1:" <>
      Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]), padding: false)
  end

  defp input_operation(source, event_id), do: stable_id("input", [source, event_id])

  defp association_operation(operation, input_id, profile),
    do: stable_id("association", [profile.tenant, profile.actor, operation, input_id])

  defp answer_operation(operation, input_id, profile),
    do: stable_id("answer", [profile.tenant, profile.actor, operation, input_id])

  defp reply_custody_operation(reply_operation, ticket, profile),
    do: stable_id("reply-custody", [profile.tenant, profile.actor, reply_operation, ticket])

  defp answer_id(input_id), do: stable_id("answer-message", [input_id])

  defp run_id(event, operation_id, state),
    do:
      stable_id("run", [
        state.profile.tenant,
        state.profile.actor,
        operation_id,
        event.input_id,
        state.target.target
      ])

  defp native_operation(run_id, state),
    do: stable_id("native-operation", [run_id, state.profile.native_target])

  defp attempt_id(run_id, _state), do: stable_id("attempt", [run_id])
  defp unit_id(run_id, _state), do: stable_id("unit", [run_id])
  defp budget_id(run_id, _state), do: stable_id("budget", [run_id])
  defp native_input_id(run_id, _state), do: stable_id("native-input", [run_id])

  defp native_expiry_input_id(run_id, wait, state),
    do:
      stable_id("native-expiry", [
        run_id,
        wait.correlation_id,
        wait.occurrence,
        state.profile.deadline_ms
      ])

  defp evidence_stream(run_id), do: stable_id("evidence-stream", [run_id])

  defp stable_id(domain, terms) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:wave4_channel, 1, domain, terms}, [:deterministic])
      )

    domain <> ":" <> Base.url_encode64(digest, padding: false)
  end

  defp receipt_input({:record, fields}) do
    with {:text, id} <- record_field(fields, "message_id"),
         revision when is_integer(revision) <- record_field(fields, "revision") do
      {:ok, id, revision}
    else
      _ -> {:error, :receipt}
    end
  end

  defp receipt_input(_), do: {:error, :receipt}
  defp input_id_from_receipt({:record, fields}), do: elem(record_field(fields, "message_id"), 1)

  defp association_receipt?({:record, fields}, input, run) do
    record_field(fields, "message_id") == {:text, input} and
      record_field(fields, "run_id") == {:text, run}
  end

  defp association_receipt?(_, _, _), do: false

  defp answer_receipt?({:record, fields}, input, run, answer) do
    record_field(fields, "input_message_id") == {:text, input} and
      record_field(fields, "run_id") == {:text, run} and
      record_field(fields, "message_id") == {:text, answer}
  end

  defp answer_receipt?(_, _, _, _), do: false

  defp record_field(fields, key) do
    case List.keyfind(fields, key, 0) do
      {^key, value} -> value
      _ -> nil
    end
  end

  defp valid_answer_payload?(%{"answer" => answer} = payload)
       when map_size(payload) == 1 and is_binary(answer) do
    byte_size(answer) == 71 and Regex.match?(~r/^answer:[0-9a-f]{64}$/, answer)
  end

  defp valid_answer_payload?(_), do: false

  defp public_outcome(nil), do: :running

  defp public_outcome(outcome)
       when outcome in [:completed, :failed, :cancelled, :out_of_budget, :out_of_time], do: outcome

  defp public_outcome(_), do: :unknown

  defp bounded_text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp bounded_ascii?(value),
    do: bounded_text?(value) and Regex.match?(~r/^[A-Za-z0-9._-]+$/, value)

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    def call(conn, opts) do
      options = if is_map(opts), do: opts, else: Map.new(opts)
      conn = Plug.Conn.put_private(conn, :wave4_channel, options)
      plug_builder_call(conn, opts)
    end

    post "/elzoo/v1/messages" do
      opts = conn.private[:wave4_channel]
      WebhookIn.call(conn, WebhookIn.init(opts.webhook))
    end

    get "/elzoo/v1/conversations/:conversation_id" do
      opts = conn.private[:wave4_channel]

      if conn.query_string == "" and conversation_id == opts.conversation_id do
        case read_principal(opts.principal, conn) do
          {:ok, scope} ->
            case safe_view(opts.host, scope) do
              {:ok, view} ->
                Plug.Conn.resp(conn, 200, Jason.encode!(%{status: "ok", view: view}))

              {:error, :forbidden} ->
                Plug.Conn.resp(conn, 403, Jason.encode!(%{status: "forbidden"}))

              _ ->
                Plug.Conn.resp(conn, 503, Jason.encode!(%{status: "unavailable"}))
            end

          {:error, :forbidden} ->
            Plug.Conn.resp(conn, 403, Jason.encode!(%{status: "forbidden"}))

          _ ->
            Plug.Conn.resp(conn, 503, Jason.encode!(%{status: "unavailable"}))
        end
      else
        Plug.Conn.resp(conn, 404, Jason.encode!(%{status: "not_found"}))
      end
    end

    match "/elzoo/v1/messages" do
      Plug.Conn.resp(conn, 405, Jason.encode!(%{status: "method_not_allowed"}))
    end

    match "/elzoo/v1/conversations/:conversation_id" do
      Plug.Conn.resp(conn, 405, Jason.encode!(%{status: "method_not_allowed"}))
    end

    match _ do
      Plug.Conn.resp(conn, 404, Jason.encode!(%{status: "not_found"}))
    end

    defp read_principal(callback, conn) when is_function(callback, 1) do
      case callback.(conn) do
        {:ok, scope} -> {:ok, scope}
        {:error, :forbidden} -> {:error, :forbidden}
        _ -> {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    end

    defp read_principal(_, _), do: {:error, :unavailable}

    defp safe_view(host, scope) do
      Elzoo.Wave4ChannelExample.view(host, scope)
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  defmodule Pattern do
    def step(%{stage: :work, text: text} = state, %{"kind" => "wake"})
        when is_binary(text) do
      {:Transition, %{state | stage: :finish},
       {:some, request("work", "local_work", "work/v1", %{"text" => text})}}
    end

    def step(%{stage: :finish} = state, %{
          "action_id" => "work",
          "outcome" => "completed",
          "payload" => %{"answer" => _answer}
        }) do
      {:Transition, %{state | stage: :done},
       {:some, request("finish", "finish", "finish/v1", %{"action_id" => "work"})}}
    end

    def step(state, _), do: {:Transition, state, :none}

    defp request(id, kind, schema_id, payload),
      do: %{
        "type" => "request",
        "version" => 1,
        "actions" => [
          %{
            "id" => id,
            "kind" => kind,
            "schema_id" => schema_id,
            "schema_version" => 1,
            "payload" => payload
          }
        ]
      }
  end

  defmodule WaitThenHash do
    def step(%{stage: :wait} = state, %{"kind" => "wake"}) do
      {:Transition, %{state | stage: :hash},
       {:some, request([action("reply", "wait_event", "wait/v1", %{})])}}
    end

    def step(%{stage: :hash} = state, input) do
      case input do
        %{"kind" => "outside_event", "action_id" => "reply", "payload" => %{"text" => text}}
        when is_binary(text) ->
          {:Transition, %{state | stage: :finish},
           {:some, request([action("hash", "local_work", "work/v1", %{"text" => text})])}}

        %{"action_id" => "reply", "outcome" => "completed", "payload" => %{"text" => text}}
        when is_binary(text) and not is_map_key(input, "kind") ->
          {:Transition, %{state | stage: :finish},
           {:some, request([action("hash", "local_work", "work/v1", %{"text" => text})])}}

        %{
          "kind" => "action_outcome",
          "action_id" => "reply",
          "outcome" => "completed",
          "payload" => %{"text" => text}
        }
        when is_binary(text) ->
          {:Transition, %{state | stage: :finish},
           {:some, request([action("hash", "local_work", "work/v1", %{"text" => text})])}}

        _ ->
          {:Transition, state, :none}
      end
    end

    def step(%{stage: :finish} = state, input) do
      case input do
        %{"action_id" => "hash", "outcome" => "completed", "payload" => %{"answer" => _}}
        when not is_map_key(input, "kind") ->
          {:Transition, %{state | stage: :done},
           {:some, request([action("finish", "finish", "finish/v1", %{"action_id" => "hash"})])}}

        %{
          "kind" => "action_outcome",
          "action_id" => "hash",
          "outcome" => "completed",
          "payload" => %{"answer" => _}
        } ->
          {:Transition, %{state | stage: :done},
           {:some, request([action("finish", "finish", "finish/v1", %{"action_id" => "hash"})])}}

        _ ->
          {:Transition, state, :none}
      end
    end

    def step(state, _), do: {:Transition, state, :none}

    defp action(id, kind, schema_id, payload),
      do: %{
        "id" => id,
        "kind" => kind,
        "schema_id" => schema_id,
        "schema_version" => 1,
        "payload" => payload
      }

    defp request(actions), do: %{"type" => "request", "version" => 2, "actions" => actions}
  end

  defmodule NativeWork do
    def hash(text) when is_binary(text),
      do: %{"answer" => "answer:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)}
  end

  defmodule NativeBindings do
    alias Elzoo.PayloadSchema

    @target %{
      "bot_ref" => "channel-bot",
      "package_digest" => String.duplicate("a", 64),
      "callable" => "hash"
    }

    @reply_target %{
      "bot_ref" => "channel-bot-reply",
      "package_digest" => String.duplicate("b", 64),
      "callable" => "wait_then_hash"
    }

    @work_resource "local-work"
    @work_writes [%{target: @work_resource, field: "result", value: true}]

    def target, do: @target
    def reply_target, do: @reply_target

    def build(profile) do
      policy = policy()

      %{
        schemas: schemas(profile),
        bindings: bindings(profile),
        policy: policy,
        context: fn ->
          %{policy: policy, authority: @work_writes, resource_names: [@work_resource]}
        end,
        gate: %{id: "wave4-fixed-gate", version: 1, call: fn _, _ -> :allow end}
      }
    end

    defp schemas(profile) do
      base = %{
        {"work/v1", 1} =>
          schema("work/v1", %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"],
            "additionalProperties" => false
          }),
        {"answer/v1", 1} =>
          schema("answer/v1", %{
            "type" => "object",
            "properties" => %{"answer" => %{"type" => "string"}},
            "required" => ["answer"],
            "additionalProperties" => false
          }),
        {"finish/v1", 1} =>
          schema("finish/v1", %{
            "type" => "object",
            "properties" => %{"action_id" => %{"type" => "string"}},
            "required" => ["action_id"],
            "additionalProperties" => false
          })
      }

      if profile.native_target == @reply_target do
        base
        |> Map.put(
          {"message/v1", 1},
          schema("message/v1", %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"],
            "additionalProperties" => false
          })
        )
        |> Map.put(
          {"wait/v1", 1},
          schema("wait/v1", %{
            "type" => "object",
            "properties" => %{},
            "required" => [],
            "additionalProperties" => false
          })
        )
      else
        base
      end
    end

    defp schema(id, json_schema) do
      port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
      {:ok, compiled} = PayloadSchema.build(port, json_schema)
      %{compiled: compiled, port: port, digest: :crypto.hash(:sha256, Jason.encode!(json_schema))}
    end

    defp bindings(profile) do
      base = %{
        id: "wave4-local",
        version: 1,
        effect_class: "compute",
        result: {"answer/v1", 1},
        facts: fn _ -> %{estimate: 1, unit: "work", deadline_ms: profile.deadline_ms} end,
        proposal: fn action ->
          %{
            tenant: profile.tenant,
            resource: @work_resource,
            action_id: action["id"],
            payload: {:text, "compute"},
            writes: @work_writes
          }
        end
      }

      work =
        Map.merge(base, %{
          work: fn action ->
            {Elzoo.Wave4ChannelExample.NativeWork, :hash, [action["payload"]["text"]]}
          end
        })

      bindings = %{"local_work" => work, "finish" => Map.put(base, :result, {"finish/v1", 1})}

      if profile.native_target == @reply_target do
        wait_event =
          base
          |> Map.put(:result, {"message/v1", 1})
          |> Map.put(:facts, fn _ ->
            %{estimate: 0, unit: "work", deadline_ms: profile.deadline_ms}
          end)

        Map.put(bindings, "wait_event", wait_event)
      else
        bindings
      end
    end

    defp policy do
      artifact = %{
        id: "wave4-native-policy",
        version: 1,
        effect_classes: ["compute"],
        rules: [%{id: "wave4-compute", effect_class: "compute", verdict: :allow}]
      }

      Map.put(
        artifact,
        :content_hash,
        :crypto.hash(:sha256, :erlang.term_to_binary(artifact, [:deterministic]))
      )
    end
  end
end

defmodule Elzoo.Wave4ChannelExample.ReplySource do
  alias Elzoo.{CheckedCommand, Conversation, DurableLog, Outbox}
  alias Elzoo.DurableLog.Codec
  alias Elzoo.DurableLog.Store

  @destination "wave4-channel-reply"
  @primary_destination "wave4-channel-input"
  @max_records 4_096
  @max_record_bytes 1_048_576
  @max_bytes @max_records * @max_record_bytes

  def head(scope, profile, run_id, store) do
    with :ok <- valid_scope(scope, profile, run_id),
         {:ok, native_head} <- Store.read(store, :head, [stream(profile.tenant)]),
         :ok <- valid_head_shape(native_head, stream(profile.tenant)) do
      if native_head.low_water > 0,
        do: {:error, :gap},
        else: {:ok, Map.take(native_head, [:revision, :low_water])}
    else
      {:error, :gap} -> {:error, :gap}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def read(scope, event_id, profile, run_id, store, conv_store, handles, primary) do
    target_stream = stream(profile.tenant)

    with :ok <- valid_scope(scope, profile, run_id),
         {:ok, sequence} <- key_sequence(event_id, profile.tenant),
         {:ok, before} <- Store.read(store, :head, [target_stream]),
         :ok <- valid_head_shape(before, target_stream) do
      result =
        cond do
          sequence > before.revision ->
            {:error, :not_found}

          before.low_water > 0 ->
            {:error, :gap}

          true ->
            read_event(
              store,
              before,
              event_id,
              sequence,
              profile,
              run_id,
              conv_store,
              handles,
              primary
            )
        end

      stable_result(store, target_stream, before, result)
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp valid_head_shape(%{revision: revision, low_water: low_water} = head, expected_stream)
       when is_integer(revision) and revision in 0..@max_records and is_integer(low_water) and
              low_water in 0..@max_records do
    valid_retention =
      case Map.fetch(head, :last_retention) do
        :error ->
          Enum.sort(Map.keys(head)) == [:low_water, :revision]

        {:ok, receipt} ->
          Enum.sort(Map.keys(head)) == [:last_retention, :low_water, :revision] and
            Codec.receipt_valid?(receipt) and receipt.operation == :retain and
            receipt.stream == expected_stream and receipt.target == low_water and
            receipt.expected <= receipt.target
      end

    if valid_retention and low_water <= revision,
      do: :ok,
      else: {:error, :unavailable}
  end

  defp valid_head_shape(_, _), do: {:error, :unavailable}

  defp key_sequence(key, tenant) do
    case Outbox.parse_id(key) do
      {:ok, {target_stream, sequence, 1}} ->
        if target_stream == stream(tenant) and sequence in 1..@max_records,
          do: {:ok, sequence},
          else: {:error, :key}

      _ ->
        {:error, :key}
    end
  end

  defp read_event(store, before, event_id, sequence, profile, run_id, conv_store, handles, primary) do
    target_stream = stream(profile.tenant)

    with {:ok, records, read_head} <- DurableLog.read(store, target_stream, 1, before.revision),
         true <- Map.delete(read_head, :capabilities) == before,
         :ok <- complete_range(records, before),
         {:ok, :absent} <- Store.read(store, :read_ack, [event_id]) do
      {:error, :not_found}
    else
      {:ok, item} when is_map(item) ->
        with :ok <- valid_item(item, event_id, sequence, profile, @destination),
             {:ok, event} <-
               source_event(item, event_id, profile, run_id, conv_store, handles, primary) do
          {:ok, event}
        else
          _ -> {:error, :unavailable}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp stable_result(store, target_stream, before, result) do
    case Store.read(store, :head, [target_stream]) do
      {:ok, ^before} ->
        case result do
          {:ok, event} ->
            {:ok, %{head: Map.take(before, [:revision, :low_water]), event: event}}

          {:error, reason} when reason in [:not_found, :gap] ->
            {:error, reason}

          _ ->
            {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp complete_range(records, %{revision: revision}) when is_list(records) do
    sequences = Enum.map(records, & &1.sequence)
    expected = if revision == 0, do: [], else: Enum.to_list(1..revision)

    bytes =
      Enum.reduce_while(records, 0, fn row, total ->
        size = if is_binary(row.payload), do: byte_size(row.payload), else: @max_record_bytes + 1
        next = total + size

        if size <= @max_record_bytes and next <= @max_bytes,
          do: {:cont, next},
          else: {:halt, @max_bytes + 1}
      end)

    if sequences == expected and length(records) <= @max_records and bytes <= @max_bytes,
      do: :ok,
      else: {:error, :unavailable}
  rescue
    _ -> {:error, :unavailable}
  end

  defp complete_range(_, _), do: {:error, :unavailable}

  defp valid_item(item, event_id, sequence, profile, destination) when is_map(item) do
    canonical =
      Outbox.new(
        stream(profile.tenant),
        sequence,
        1,
        destination,
        item.payload,
        item.nonce
      )

    if item.stream == canonical.stream and item.sequence == sequence and item.position == 1 and
         item.destination == destination and item.idempotency_key == event_id and
         item.nonce == canonical.nonce and item.digest == canonical.digest and
         is_binary(item.nonce) and byte_size(item.nonce) == 16 and item.state in [:pending, :acked] do
      :ok
    else
      {:error, :item}
    end
  end

  defp source_event(item, event_id, profile, run_id, conv_store, handles, primary) do
    with :ok <- valid_primary_capture(primary, profile, run_id),
         {:ok, reply_notice} <- notice(item, @destination, profile),
         reply_operation when is_binary(reply_operation) <- reply_notice["operation_id"],
         {:completed, reply_result} <-
           CheckedCommand.result(
             handles.reply_input,
             result_scope(profile),
             {profile.tenant, profile.actor, reply_operation}
           ),
         true <- reply_result.revision == reply_notice["revision"],
         {:ok, ticket, reply_response_revision} <- receipt(reply_result.response),
         true <- reply_response_revision == reply_result.revision,
         true <- bounded_id?(ticket),
         {:ok, :input, intent} <-
           Elzoo.Wave4ChannelExample.Intents.delivery(reply_result.response),
         true <- intent.message_id == ticket,
         {:ok, primary_item} <-
           read_item(
             handles.input.store,
             primary.key,
             profile,
             @primary_destination
           ),
         {:ok, primary_notice} <- notice(primary_item, @primary_destination, profile),
         true <- primary_notice["operation_id"] == primary.operation_id,
         {:completed, primary_result} <-
           CheckedCommand.result(
             handles.input,
             result_scope(profile),
             {profile.tenant, profile.actor, primary.operation_id}
           ),
         true <- primary_result.revision == primary_notice["revision"],
         {:ok, primary_id, primary_response_revision} <- receipt(primary_result.response),
         true <- primary_response_revision == primary_result.revision,
         true <- primary_id == primary.input_id,
         {:ok, snapshot} <- resource_snapshot(handles.input, profile),
         {:ok, metadata} when is_map(metadata) <-
           Elzoo.Wave4ChannelExample.Intents.metadata(snapshot.fields, profile.tenant),
         true <-
           metadata.run_id == run_id and metadata.primary_key == primary.key and
             metadata.reply_key == event_id,
         :ok <-
           same_run_associations(
             handles,
             profile,
             run_id,
             primary,
             reply_operation,
             ticket,
             primary_result.revision,
             reply_result.revision
           ),
         :ok <-
           delivered_associations(conv_store, profile, metadata, primary.input_id, ticket, run_id),
         {:ok, text} <-
           conversation_text(conv_store, profile, intent, metadata) do
      {:ok,
       %{
         id: event_id,
         source_id: profile.reply_source_id,
         correlation_id: ticket,
         sequence: item.sequence,
         schema_id: "message/v1",
         schema_version: 1,
         payload: %{"text" => text}
       }}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp valid_primary_capture(primary, profile, run_id) when is_map(primary) do
    expected_run =
      stable_id("run", [
        profile.tenant,
        profile.actor,
        primary.operation_id,
        primary.input_id,
        profile.native_target
      ])

    if Enum.sort(Map.keys(primary)) == [:input_id, :key, :operation_id, :run_id] and
         bounded_id?(primary.operation_id) and bounded_id?(primary.input_id) and
         primary.run_id == run_id and primary.run_id == expected_run and
         match?({:ok, _}, key_sequence(primary.key, profile.tenant)),
       do: :ok,
       else: {:error, :identity}
  rescue
    _ -> {:error, :identity}
  end

  defp valid_primary_capture(_, _, _), do: {:error, :identity}

  # The custody facts bind the run and the items; the conversation records are
  # proven by the sequence reads, so the remaining check is the committed
  # association receipts of both commands.
  defp same_run_associations(
         handles,
         profile,
         run_id,
         primary,
         reply_operation,
         ticket,
         primary_revision,
         reply_revision
       ) do
    with true <-
           association_result?(
             handles.association,
             profile,
             primary.operation_id,
             primary.input_id,
             run_id,
             primary_revision + 1
           ),
         true <-
           association_result?(
             handles.reply_association,
             profile,
             reply_operation,
             ticket,
             run_id,
             reply_revision + 1
           ) do
      :ok
    else
      _ -> {:error, :association}
    end
  end

  defp association_result?(handle, profile, operation, message_id, run_id, revision) do
    association = association_operation(operation, message_id, profile)

    case CheckedCommand.result(
           handle,
           result_scope(profile),
           {profile.tenant, profile.actor, association}
         ) do
      {:completed, %{revision: ^revision, response: {:record, fields}}} ->
        length(Enum.uniq_by(fields, &elem(&1, 0))) == length(fields) and
          field_value(fields, "message_id") == {:text, message_id} and
          field_value(fields, "revision") == revision and
          field_value(fields, "run_id") == {:text, run_id}

      _ ->
        false
    end
  end

  # The committed association receipts are not visibility: the reply is an
  # event only once both input-to-Run associations of the round are delivered
  # to the conversation. Both follow the primary input, so the bounded page
  # scan starts at its custody sequence.
  defp delivered_associations(store, profile, metadata, primary_id, ticket, run_id) do
    reference = %{target_tenant: profile.tenant, conversation_id: profile.conversation_id}

    with from when is_integer(from) and from >= 1 <- metadata.primary_sequence do
      scan_associations(
        store,
        profile,
        reference,
        from,
        MapSet.new([{primary_id, run_id}, {ticket, run_id}])
      )
    else
      _ -> {:error, :association}
    end
  rescue
    _ -> {:error, :association}
  catch
    _, _ -> {:error, :association}
  end

  defp scan_associations(store, profile, reference, from, wanted) do
    case Conversation.page(store, resource_scope(profile), reference, from, 1_000) do
      {:ok, %{revision: revision, entries: entries}} ->
        remaining =
          Enum.reduce(entries, wanted, fn
            %{kind: :association, input_message_id: id, run_id: run}, acc ->
              MapSet.delete(acc, {id, run})

            _entry, acc ->
              acc
          end)

        cond do
          MapSet.size(remaining) == 0 ->
            :ok

          entries != [] and revision >= from + length(entries) ->
            scan_associations(store, profile, reference, from + length(entries), remaining)

          true ->
            {:error, :association}
        end

      _ ->
        {:error, :association}
    end
  end

  # The reply input's text is its retained intent. Its delivered record at
  # the sequence the custody facts carry must equal that intent (kind,
  # message ID, role, actor and text): the reply was delivered before the
  # engine could observe it, so the row exists.
  defp conversation_text(store, profile, intent, metadata) do
    reference = %{target_tenant: profile.tenant, conversation_id: profile.conversation_id}
    fields = [:message_id, :role, :actor, :text]

    with sequence when is_integer(sequence) and sequence >= 1 <- metadata.reply_sequence,
         {:ok, %{entries: [%{kind: :input} = entry]}} <-
           Conversation.page(store, resource_scope(profile), reference, sequence, 1),
         true <- intent.role == "source" and Map.take(entry, fields) == Map.take(intent, fields),
         true <- is_binary(intent.text) and byte_size(intent.text) in 1..4_096 do
      {:ok, intent.text}
    else
      _ -> {:error, :message}
    end
  rescue
    _ -> {:error, :message}
  catch
    _, _ -> {:error, :message}
  end

  defp resource_snapshot(handle, profile),
    do: CheckedCommand.resource(handle, resource_scope(profile), profile.conversation_id)

  defp notice(%{payload: payload, destination: item_destination}, destination, profile) do
    with {:ok, notice} <- Jason.decode(payload),
         true <- item_destination == destination,
         true <-
           Map.keys(notice) |> Enum.sort() == [
             "actor",
             "operation_id",
             "resource",
             "revision",
             "tenant",
             "type",
             "version"
           ],
         true <-
           notice["type"] == "checked_command" and is_integer(notice["version"]) and
             notice["version"] == 1,
         true <- notice["tenant"] == profile.tenant and notice["actor"] == profile.actor,
         true <- notice["resource"] == profile.conversation_id,
         true <- bounded_id?(notice["operation_id"]),
         true <- is_integer(notice["revision"]) and notice["revision"] > 0 do
      {:ok, notice}
    else
      _ -> {:error, :notice}
    end
  end

  defp read_item(store, key, profile, destination) do
    with {:ok, sequence} <- key_sequence(key, profile.tenant) do
      case Store.read(store, :read_ack, [key]) do
        {:ok, item} when is_map(item) ->
          with :ok <- valid_item(item, key, sequence, profile, destination), do: {:ok, item}

        {:ok, :absent} ->
          {:error, :not_found}

        _ ->
          {:error, :unavailable}
      end
    else
      _ -> {:error, :item}
    end
  end

  # The response carries the intent record and digest next to the receipt
  # fields; only the fields the source needs are compared.
  defp receipt({:record, fields}) when is_list(fields) do
    with true <- length(Enum.uniq_by(fields, &elem(&1, 0))) == length(fields),
         {:text, id} <- field_value(fields, "message_id"),
         true <- bounded_id?(id),
         revision when is_integer(revision) and revision > 0 <- field_value(fields, "revision") do
      {:ok, id, revision}
    else
      _ -> {:error, :receipt}
    end
  end

  defp receipt(_), do: {:error, :receipt}

  defp field_value(fields, key) do
    case List.keyfind(fields, key, 0) do
      {^key, value} -> value
      _ -> nil
    end
  end

  defp association_operation(operation, message_id, profile),
    do: stable_id("association", [profile.tenant, profile.actor, operation, message_id])

  defp stable_id(domain, terms) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:wave4_channel, 1, domain, terms}, [:deterministic])
      )

    domain <> ":" <> Base.url_encode64(digest, padding: false)
  end

  defp stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )

  defp result_scope(profile), do: %{tenant: profile.tenant, actor: profile.actor}

  defp resource_scope(profile),
    do: %{tenant: profile.tenant, actor: profile.actor, resources: [profile.conversation_id]}

  defp valid_scope(scope, profile, run_id) when is_map(scope) and not is_struct(scope) do
    if map_size(scope) == 3 and Map.keys(scope) |> Enum.sort() == [:principal, :run_id, :tenant] and
         scope.tenant == profile.tenant and scope.principal == profile.actor and
         scope.run_id == run_id,
       do: :ok,
       else: {:error, :scope}
  end

  defp valid_scope(_, _, _), do: {:error, :scope}

  defp bounded_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)
end

defmodule Elzoo.Wave4ChannelExample.Intents do
  @moduledoc """
  The channel's Conversation intents.

  `prepare/3` is the pure CheckedCommand preparer of every Conversation-writing
  command. It derives the exact intent from the request and the trusted facts,
  binds the intent's digest into a write of the channel-owned resource (field
  `"wave4_intent"`) that Authorization and Approval check, and returns a
  response that carries the same intent and digest. CheckedCommand retains the
  write and the response under one mutation binding, so `delivery/1` can
  rebuild the intent from a retained response and verify it against that
  digest before the channel appends it through the conversation owner.

  The version 2 associations also write the `"wave4_reply"` custody facts: the
  Run, the primary input and the original key and nonce of its outbox item,
  and after the reply association the reply ticket, the original key and nonce
  of the reply item and the reply's conversation sequence. A terminal reply
  that is acknowledged without a reply association records the same reply
  facts with `prepare_custody/3` first. The channel resource holds them
  independently of compactable CheckedCommand rows.
  """
  alias Elzoo.Conversation.Record
  alias Elzoo.Outbox

  @intent_field "wave4_intent"
  @metadata_field "wave4_reply"
  @max_command_sequence 4_096

  def intent_field, do: @intent_field
  def metadata_field, do: @metadata_field

  @doc "Prepare one Conversation-writing command: `{:ok, writes, response}` or `{:refused, code}`."
  def prepare(snapshot, request, facts) do
    with {:ok, metadata} <- snapshot_metadata(snapshot, facts),
         {:ok, mode, dto, custody} <- derive(request, facts),
         {:ok, metadata_writes} <- metadata_writes(mode, dto, custody, metadata, request, facts) do
      intent = portable(mode, dto)
      digest = digest(intent)

      writes = [
        %{target: request.resource, field: @intent_field, value: {:bytes, digest}}
        | metadata_writes
      ]

      {:ok, writes, response(mode, dto, request.expected_revision + 1, intent, digest)}
    end
  rescue
    _ -> {:refused, "invalid_request"}
  catch
    _, _ -> {:refused, "invalid_request"}
  end

  @doc """
  Prepare the reply custody command of a terminal reply round: it completes
  the current Run's `"wave4_reply"` facts with the reply item's original key
  and nonce and the reply input's conversation sequence, binds no
  Conversation intent and has no outbox item. `{:ok, writes, response}` or
  `{:refused, code}`.
  """
  def prepare_custody(snapshot, request, %{data: {:record, pairs}} = facts)
      when is_list(pairs) do
    fields = Map.new(pairs)

    with true <- map_size(fields) == length(pairs),
         {:text, "record_reply_custody"} <- fields["mode"],
         %{"message_id" => ticket} = payload when map_size(payload) == 1 <- request.payload,
         true <- Record.id?(ticket),
         {:text, run_id} <- fields["run_id"],
         {:ok, %{reply_key: _} = custody} <- association_custody(fields, facts.tenant),
         {:ok, %{reply_key: nil, run_id: ^run_id} = metadata} <-
           snapshot_metadata(snapshot, facts),
         true <- metadata.primary_key == custody.primary_key do
      next =
        Map.merge(metadata, %{
          reply_key: custody.reply_key,
          reply_nonce: custody.reply_nonce,
          reply_sequence: custody.reply_sequence
        })

      revision = request.expected_revision + 1

      {:ok, [%{target: request.resource, field: @metadata_field, value: metadata_record(next)}],
       record([
         {"message_id", {:text, ticket}},
         {"revision", revision},
         {"run_id", {:text, run_id}}
       ])}
    else
      _ -> {:refused, "invalid_facts"}
    end
  rescue
    _ -> {:refused, "invalid_request"}
  catch
    _, _ -> {:refused, "invalid_request"}
  end

  def prepare_custody(_, _, _), do: {:refused, "invalid_facts"}

  @doc """
  The intent that a command with this request and these prepare facts
  (`%{tenant, actor, data}`) binds: `{:ok, mode, dto}` with the DTO of the
  conversation owner's call, or `:error`.
  """
  def candidate(request, facts) do
    case derive(request, facts) do
      {:ok, mode, dto, _custody} -> {:ok, mode, dto}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Rebuild the intent of a retained response and verify it against the digest
  that the command wrote: `{:ok, mode, dto}` or `{:error, :binding}`.
  """
  def delivery({:record, pairs}) when is_list(pairs) do
    fields = Map.new(pairs)

    with true <- map_size(fields) == length(pairs),
         {:record, _} = intent <- Map.get(fields, "intent"),
         {:bytes, digest} <- Map.get(fields, "intent_digest"),
         true <- digest(intent) == digest,
         {:ok, mode, dto} <- from_portable(intent),
         {:ok, _entry, _completed} <- Record.intent(mode, dto) do
      {:ok, mode, dto}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end

  def delivery(_), do: {:error, :binding}

  @doc """
  The custody facts of a channel resource's fields: `{:ok, nil}`, `{:ok,
  metadata}` or `{:error, :metadata}`. The metadata map has `run_id`,
  `primary_input`, `primary_key`, `primary_nonce` and, after the reply
  association, `reply_ticket`, `reply_key`, `reply_nonce` and
  `reply_sequence` (else `nil`).
  """
  def metadata(fields, tenant) when is_map(fields) do
    case Map.fetch(fields, @metadata_field) do
      :error -> {:ok, nil}
      {:ok, value} -> parse_metadata(value, tenant)
    end
  end

  def metadata(_, _), do: {:error, :metadata}

  @doc "The portable custody facts record of a metadata map."
  def metadata_record(metadata) do
    primary = [
      {"primary_key", {:text, metadata.primary_key}},
      {"primary_nonce", {:bytes, metadata.primary_nonce}},
      {"primary_sequence", metadata.primary_sequence},
      {"run_id", {:text, metadata.run_id}},
      {"version", {:text, "2"}}
    ]

    reply =
      if is_binary(metadata.reply_key),
        do: [
          {"reply_key", {:text, metadata.reply_key}},
          {"reply_nonce", {:bytes, metadata.reply_nonce}},
          {"reply_sequence", metadata.reply_sequence}
        ],
        else: []

    record(primary ++ reply)
  end

  @doc "The canonical digest of a portable intent record."
  def digest({:record, pairs}) do
    bytes =
      IO.iodata_to_binary([
        "wave4-intent/1",
        Enum.map(pairs, fn {name, value} -> [length_prefixed(name), value_bytes(value)] end)
      ])

    :crypto.hash(:sha256, bytes)
  end

  defp value_bytes({:text, text}), do: [<<1>>, length_prefixed(text)]
  defp value_bytes(true), do: <<2, 1>>
  defp value_bytes(false), do: <<2, 0>>
  defp length_prefixed(binary), do: [<<byte_size(binary)::32>>, binary]

  # The mode, the owner DTO and the custody facts of a request and its facts.
  defp derive(request, %{tenant: tenant, actor: actor, data: {:record, pairs}})
       when is_map(request) and is_list(pairs) do
    facts = Map.new(pairs)

    with true <- map_size(facts) == length(pairs),
         {:text, mode} <- Map.get(facts, "mode"),
         {:ok, mode, dto, custody} <- derive_mode(mode, request, facts, actor, tenant),
         {:ok, _entry, _completed} <- Record.intent(mode, dto) do
      {:ok, mode, dto, custody}
    else
      _ -> {:refused, "invalid_facts"}
    end
  end

  defp derive(_, _), do: {:refused, "invalid_facts"}

  defp derive_mode("append_input", request, facts, actor, _tenant) do
    with true <- Enum.sort(Map.keys(facts)) == ["input_role", "mode"],
         {:text, role} when role in ["user", "source"] <- facts["input_role"],
         %{"message_id" => id, "text" => text} = payload when map_size(payload) == 2 <-
           request.payload do
      {:ok, :input, %{message_id: id, role: role, actor: actor, text: text}, nil}
    else
      _ -> :error
    end
  end

  defp derive_mode("associate_run", request, facts, _actor, tenant) do
    with %{"message_id" => id} = payload when map_size(payload) == 1 <- request.payload,
         {:text, run_id} <- facts["run_id"],
         {:ok, custody} <- association_custody(facts, tenant) do
      {:ok, :association, %{input_message_id: id, run_id: run_id}, custody}
    else
      _ -> :error
    end
  end

  defp derive_mode("append_answer", request, facts, actor, _tenant) do
    with true <-
           Enum.sort(Map.keys(facts)) == ["completed", "input_message_id", "mode", "run_id"],
         {:text, run_id} <- facts["run_id"],
         {:text, input_id} <- facts["input_message_id"],
         completed when is_boolean(completed) <- facts["completed"],
         %{"message_id" => id, "text" => text} = payload when map_size(payload) == 2 <-
           request.payload do
      {:ok, :answer,
       %{
         message_id: id,
         actor: actor,
         text: text,
         run_id: run_id,
         input_message_id: input_id,
         completed: completed
       }, nil}
    else
      _ -> :error
    end
  end

  defp derive_mode(_, _, _, _, _), do: :error

  # Version 1 associations carry no custody facts; the version 2 primary
  # association carries the primary item's key, nonce and conversation
  # sequence, and the reply association the reply item's key, nonce and the
  # reply input's conversation sequence.
  defp association_custody(facts, tenant) do
    case Enum.sort(Map.keys(facts)) do
      ["mode", "run_id"] ->
        {:ok, nil}

      ["mode", "primary_key", "primary_nonce", "primary_sequence", "run_id"] ->
        with {:text, key} <- facts["primary_key"],
             {:bytes, nonce} <- facts["primary_nonce"],
             sequence when is_integer(sequence) and sequence >= 1 <- facts["primary_sequence"],
             true <- canonical_key?(key, tenant) and nonce?(nonce) do
          {:ok, %{primary_key: key, primary_nonce: nonce, primary_sequence: sequence}}
        else
          _ -> :error
        end

      ["mode", "primary_key", "reply_key", "reply_nonce", "reply_sequence", "run_id"] ->
        with {:text, primary_key} <- facts["primary_key"],
             {:text, reply_key} <- facts["reply_key"],
             {:bytes, nonce} <- facts["reply_nonce"],
             sequence when is_integer(sequence) and sequence >= 1 <- facts["reply_sequence"],
             true <-
               canonical_key?(primary_key, tenant) and canonical_key?(reply_key, tenant) and
                 nonce?(nonce) do
          {:ok,
           %{
             primary_key: primary_key,
             reply_key: reply_key,
             reply_nonce: nonce,
             reply_sequence: sequence
           }}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp snapshot_metadata(%{fields: fields}, %{tenant: tenant}) when is_map(fields) do
    known? = Enum.all?(Map.keys(fields), &(&1 in [@intent_field, @metadata_field]))

    intent_ok? =
      case Map.fetch(fields, @intent_field) do
        :error -> true
        {:ok, {:bytes, digest}} -> byte_size(digest) == 32
        _ -> false
      end

    with true <- known? and intent_ok?,
         {:ok, metadata} <- metadata(fields, tenant) do
      {:ok, metadata}
    else
      _ -> {:refused, "invalid_snapshot"}
    end
  end

  defp snapshot_metadata(_, _), do: {:refused, "invalid_snapshot"}

  defp metadata_writes(:association, dto, %{reply_key: _} = custody, metadata, request, _facts) do
    # The reply association completes the custody facts of the current Run.
    with %{reply_key: nil, run_id: run_id, primary_key: primary_key} <- metadata,
         true <- run_id == dto.run_id and primary_key == custody.primary_key do
      next =
        Map.merge(metadata, %{
          reply_key: custody.reply_key,
          reply_nonce: custody.reply_nonce,
          reply_sequence: custody.reply_sequence
        })

      {:ok, [%{target: request.resource, field: @metadata_field, value: metadata_record(next)}]}
    else
      _ -> {:refused, "invalid_facts"}
    end
  end

  defp metadata_writes(:association, dto, %{primary_key: _} = custody, metadata, request, _facts) do
    # A new primary association starts the custody facts of a new Run. The
    # association of a round is committed exactly once, so replacement only
    # ever applies to a different Run; a terminal round's reply facts may be
    # absent.
    replaceable? =
      case metadata do
        nil -> true
        %{run_id: run_id} -> run_id != dto.run_id
        _ -> false
      end

    if replaceable? do
      next = %{
        run_id: dto.run_id,
        primary_key: custody.primary_key,
        primary_nonce: custody.primary_nonce,
        primary_sequence: custody.primary_sequence,
        reply_key: nil,
        reply_nonce: nil,
        reply_sequence: nil
      }

      {:ok, [%{target: request.resource, field: @metadata_field, value: metadata_record(next)}]}
    else
      {:refused, "invalid_facts"}
    end
  end

  defp metadata_writes(_mode, _dto, nil, _metadata, _request, _facts), do: {:ok, []}

  defp parse_metadata({:record, pairs} = value, tenant) when is_list(pairs) do
    fields = Map.new(pairs)

    with true <- map_size(fields) == length(pairs),
         {:text, "2"} <- fields["version"],
         {:text, run_id} <- fields["run_id"],
         {:text, primary_key} <- fields["primary_key"],
         {:bytes, primary_nonce} <- fields["primary_nonce"],
         primary_sequence when is_integer(primary_sequence) and primary_sequence >= 1 <-
           fields["primary_sequence"],
         true <- Record.id?(run_id),
         true <- canonical_key?(primary_key, tenant) and nonce?(primary_nonce),
         {:ok, reply} <- parse_reply(fields, tenant) do
      metadata =
        Map.merge(
          %{
            run_id: run_id,
            primary_key: primary_key,
            primary_nonce: primary_nonce,
            primary_sequence: primary_sequence
          },
          reply
        )

      if metadata_record(metadata) == value, do: {:ok, metadata}, else: {:error, :metadata}
    else
      _ -> {:error, :metadata}
    end
  rescue
    _ -> {:error, :metadata}
  end

  defp parse_metadata(_, _), do: {:error, :metadata}

  defp parse_reply(fields, tenant) do
    case fields["reply_key"] do
      nil ->
        {:ok, %{reply_key: nil, reply_nonce: nil, reply_sequence: nil}}

      {:text, key} ->
        with {:bytes, nonce} <- fields["reply_nonce"],
             sequence when is_integer(sequence) and sequence >= 1 <- fields["reply_sequence"],
             true <- canonical_key?(key, tenant) and nonce?(nonce) do
          {:ok, %{reply_key: key, reply_nonce: nonce, reply_sequence: sequence}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp portable(:input, dto),
    do:
      record([
        {"actor", {:text, dto.actor}},
        {"kind", {:text, "input"}},
        {"message_id", {:text, dto.message_id}},
        {"role", {:text, dto.role}},
        {"text", {:text, dto.text}}
      ])

  defp portable(:association, dto),
    do:
      record([
        {"input_message_id", {:text, dto.input_message_id}},
        {"kind", {:text, "association"}},
        {"run_id", {:text, dto.run_id}}
      ])

  defp portable(:answer, dto),
    do:
      record([
        {"actor", {:text, dto.actor}},
        {"completed", dto.completed},
        {"input_message_id", {:text, dto.input_message_id}},
        {"kind", {:text, "answer"}},
        {"message_id", {:text, dto.message_id}},
        {"run_id", {:text, dto.run_id}},
        {"text", {:text, dto.text}}
      ])

  defp from_portable({:record, pairs}) do
    fields = Map.new(pairs)

    case {Enum.sort(Map.keys(fields)), fields["kind"]} do
      {["actor", "kind", "message_id", "role", "text"], {:text, "input"}} ->
        with {:text, actor} <- fields["actor"],
             {:text, id} <- fields["message_id"],
             {:text, role} <- fields["role"],
             {:text, text} <- fields["text"] do
          {:ok, :input, %{message_id: id, role: role, actor: actor, text: text}}
        end

      {["input_message_id", "kind", "run_id"], {:text, "association"}} ->
        with {:text, input_id} <- fields["input_message_id"],
             {:text, run_id} <- fields["run_id"] do
          {:ok, :association, %{input_message_id: input_id, run_id: run_id}}
        end

      {["actor", "completed", "input_message_id", "kind", "message_id", "run_id", "text"],
       {:text, "answer"}} ->
        with {:text, actor} <- fields["actor"],
             completed when is_boolean(completed) <- fields["completed"],
             {:text, input_id} <- fields["input_message_id"],
             {:text, id} <- fields["message_id"],
             {:text, run_id} <- fields["run_id"],
             {:text, text} <- fields["text"] do
          {:ok, :answer,
           %{
             message_id: id,
             actor: actor,
             text: text,
             run_id: run_id,
             input_message_id: input_id,
             completed: completed
           }}
        end

      _ ->
        :error
    end
  end

  defp response(:input, dto, revision, intent, digest),
    do:
      record([
        {"intent", intent},
        {"intent_digest", {:bytes, digest}},
        {"message_id", {:text, dto.message_id}},
        {"revision", revision}
      ])

  defp response(:association, dto, revision, intent, digest),
    do:
      record([
        {"intent", intent},
        {"intent_digest", {:bytes, digest}},
        {"message_id", {:text, dto.input_message_id}},
        {"revision", revision},
        {"run_id", {:text, dto.run_id}}
      ])

  defp response(:answer, dto, revision, intent, digest),
    do:
      record([
        {"input_message_id", {:text, dto.input_message_id}},
        {"intent", intent},
        {"intent_digest", {:bytes, digest}},
        {"message_id", {:text, dto.message_id}},
        {"revision", revision},
        {"run_id", {:text, dto.run_id}}
      ])

  defp record(pairs), do: {:record, Enum.sort_by(pairs, &elem(&1, 0))}

  defp canonical_key?(key, tenant) when is_binary(key) do
    case Outbox.parse_id(key) do
      {:ok, {stream, sequence, 1}} ->
        stream == stream(tenant) and sequence in 1..@max_command_sequence

      _ ->
        false
    end
  end

  defp canonical_key?(_, _), do: false

  defp nonce?(nonce), do: is_binary(nonce) and byte_size(nonce) == 16

  defp stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )
end

defmodule Elzoo.Wave4ChannelExample.CommandBindings do
  @moduledoc """
  The channel's CheckedCommand handles. Every Conversation-writing command
  writes the channel-owned resource through
  `Elzoo.Wave4ChannelExample.Intents.prepare/3`; the inputs notify their own
  destinations and the associations and answers the delivery destination, so
  each Conversation-writing command has an outbox item that the channel
  delivers. The reply profile's custody command writes only the reply
  custody facts through `Intents.prepare_custody/3` and has no outbox item.
  """
  alias Elzoo.{CheckedCommand, PayloadSchema}
  alias Elzoo.Wave4ChannelExample.Intents

  @destination "wave4-channel-input"
  @reply_destination "wave4-channel-reply"
  @delivery_destination "wave4-channel-delivery"

  def destination, do: @destination
  def reply_destination, do: @reply_destination
  def delivery_destination, do: @delivery_destination

  def build(store, gates) when is_map(gates) do
    with input_gate when is_function(input_gate, 2) <- Map.get(gates, :input),
         association_gate when is_function(association_gate, 2) <- Map.get(gates, :association),
         answer_gate when is_function(answer_gate, 2) <- Map.get(gates, :answer),
         {:ok, input_schema} <- command_schema("wave4/channel-input", ["message_id", "text"]),
         {:ok, association_schema} <- command_schema("wave4/channel-association", ["message_id"]),
         {:ok, answer_schema} <- command_schema("wave4/channel-answer", ["message_id", "text"]),
         {:ok, input} <-
           CheckedCommand.new(
             store,
             descriptor("wave4/input", input_schema, @destination, input_gate)
           ),
         {:ok, association} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/association",
               association_schema,
               @delivery_destination,
               association_gate
             )
           ),
         {:ok, answer} <-
           CheckedCommand.new(
             store,
             descriptor("wave4/answer", answer_schema, @delivery_destination, answer_gate)
           ) do
      {:ok, %{input: input, association: association, answer: answer}}
    else
      _ -> {:error, :commands}
    end
  end

  def build(_, _), do: {:error, :commands}

  def build_reply(store, gates) when is_map(gates) do
    with input_gate when is_function(input_gate, 2) <- Map.get(gates, :input),
         reply_gate when is_function(reply_gate, 2) <- Map.get(gates, :reply),
         {:ok, input_schema} <- command_schema("wave4/channel-input", ["message_id", "text"]),
         {:ok, reply_schema} <- command_schema("wave4/channel-reply", ["message_id", "text"]),
         {:ok, association_schema} <- command_schema("wave4/channel-association", ["message_id"]),
         {:ok, reply_association_schema} <-
           command_schema("wave4/channel-reply-association", ["message_id"]),
         {:ok, answer_schema} <- command_schema("wave4/channel-answer", ["message_id", "text"]),
         {:ok, reply_custody_schema} <-
           command_schema("wave4/channel-reply-custody", ["message_id"]),
         {:ok, input} <-
           CheckedCommand.new(
             store,
             descriptor("wave4/input", input_schema, @destination, input_gate)
           ),
         {:ok, reply_input} <-
           CheckedCommand.new(
             store,
             descriptor("wave4/reply", reply_schema, @reply_destination, reply_gate)
           ),
         always_allow <- fn _, _ -> :allow end,
         {:ok, association} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/association",
               association_schema,
               @delivery_destination,
               always_allow
             )
           ),
         {:ok, reply_association} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/reply-association",
               reply_association_schema,
               @delivery_destination,
               always_allow
             )
           ),
         {:ok, answer} <-
           CheckedCommand.new(
             store,
             descriptor("wave4/answer", answer_schema, @delivery_destination, always_allow)
           ),
         {:ok, reply_custody} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/reply-custody",
               reply_custody_schema,
               nil,
               always_allow,
               &Intents.prepare_custody/3
             )
           ) do
      {:ok,
       %{
         input: input,
         reply_input: reply_input,
         association: association,
         reply_association: reply_association,
         answer: answer,
         reply_custody: reply_custody
       }}
    else
      _ -> {:error, :commands}
    end
  end

  def build_reply(_, _), do: {:error, :commands}

  defp command_schema(id, required) do
    port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}

    schema = %{
      "type" => "object",
      "properties" => %{
        "message_id" => %{"type" => "string"},
        "text" => %{"type" => "string"}
      },
      "required" => required,
      "additionalProperties" => false
    }

    with {:ok, compiled} <- PayloadSchema.build(port, schema),
         do: {:ok, %{port: port, compiled: compiled}}
  end

  # Version 2: the preparation now binds an intent instead of rewriting a
  # conversation field, and the descriptor identity changes with it.
  defp descriptor(id, schema, outbox, gate),
    do: descriptor(id, schema, outbox, gate, &Intents.prepare/3)

  defp descriptor(id, %{port: port, compiled: schema}, outbox, gate, prepare) do
    %{
      id: id,
      version: 2,
      content_hash: :crypto.hash(:sha256, id),
      effect_class: "conversation.write",
      port: port,
      schema: schema,
      prepare: prepare,
      gate: %{call: gate},
      approval: %{verifiers: ["wave4-command-approver"], max_age: 60_000},
      outbox: outbox
    }
  end
end
