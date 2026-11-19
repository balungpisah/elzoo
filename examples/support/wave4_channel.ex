defmodule Elzoo.Wave4ChannelExample do
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

  @destination "wave4-channel-input"
  @max_view_bytes 1_048_576
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
         true <- Process.alive?(native.run_owner) do
      {:ok,
       %{
         profile: profile,
         target: target,
         command_store: Keyword.fetch!(opts, :command_store),
         handles: handles,
         native: native,
         authority: authority,
         policy: policy,
         clock: clock,
         phase: :idle,
         current: nil,
         reply: nil,
         latest_run: nil,
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
      _ -> {:stop, :invalid_options}
    end
  rescue
    _ -> {:stop, :invalid_options}
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

  defp admit_reply_event(state, _event, _trusted_scope),
    do: {{:error, :unavailable}, state}

  defp release_reply_event(state, _event, _trusted_scope, _evidence),
    do: {{:error, :unavailable}, state}

  @impl true
  def handle_info({:DOWN, reference, :process, pid, reason}, state) do
    contain_native_exit(state, pid, reference, reason)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    contain_native_exit(state, pid, nil, reason)
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fence_native(state)
    :ok
  end

  @impl true
  def format_status(status) do
    Enum.reduce([:state, :message, :reason, :log], status, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, :redacted), else: acc
    end)
  end

  defp admit_event(%{poison: poison} = state, _, _) when not is_nil(poison),
    do: {{:error, :unavailable}, state}

  defp admit_event(state, event, trusted_scope) do
    with :ok <- valid_event(event),
         :ok <- valid_admission_scope(state.profile, event, trusted_scope),
         operation_id <- input_operation(state.profile.source_id, event.event_id),
         identity <- {state.profile.tenant, state.profile.actor, operation_id},
         result <- CheckedCommand.result(state.handles.input, result_scope(state.profile), identity),
         {:ok, decision} <- existing_or_capacity(state, event, operation_id, result) do
      execute_input(state, event, operation_id, decision)
    else
      {:error, :expired} -> {{:rejected, :conflict}, state}
      {:error, :busy} -> {{:error, :unavailable}, state}
      {:error, :scope} -> {{:rejected, :forbidden}, state}
      {:error, :unknown} -> {{:error, :unavailable}, state}
      _ -> {{:rejected, :invalid}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    :exit, _ -> {{:error, :unavailable}, state}
    :throw, _ -> {{:error, :unavailable}, state}
  end

  defp existing_or_capacity(state, event, operation_id, {:unknown, :not_observed}) do
    cond do
      not before_deadline?(state) ->
        {:error, :expired}

      unfinished?(state) ->
        {:error, :busy}

      event.conversation_id != state.profile.conversation_id ->
        {:error, :scope}

      true ->
        case pending_input?(state) do
          {:ok, true} -> {:error, :busy}
          {:ok, false} -> capacity?(state, event, operation_id)
          _ -> {:error, :unknown}
        end
    end
  end

  defp existing_or_capacity(_state, _event, _operation_id, {:unknown, _}),
    do: {:error, :unknown}

  defp existing_or_capacity(_state, _event, _operation_id, _retained), do: {:ok, :replay}

  defp capacity?(state, event, operation_id) do
    if reply_profile?(state.profile) do
      reply_capacity?(state, event, operation_id)
    else
      capacity_v1?(state, event, operation_id)
    end
  end

  defp capacity_v1?(state, event, operation_id) do
    request = input_request(event, operation_id)
    facts = input_facts()

    with {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             event.conversation_id
           ) do
      case Conversation.prepare(snapshot, request, prepare_facts(state.profile, facts)) do
        {:refused, _} ->
          {:ok, :preserve_refusal}

        {:ok, input_writes, _} ->
          input_snapshot = apply_writes(snapshot, input_writes)

          if resource_snapshot_fits?(input_snapshot),
            do: capacity_after_input(state, event, operation_id, snapshot, input_snapshot),
            else: {:ok, :capacity}
      end
    else
      _ -> {:error, :unknown}
    end
  end

  defp reply_capacity?(state, event, operation_id) do
    stream = checked_stream(state.profile.tenant)
    run_id = run_id(event, operation_id, state)
    primary_key = projected_command_key(state.profile, operation_id, 4095, "wave4-channel-input")
    reply_key = projected_reply_key(state.profile, operation_id)

    with {:ok, head} <- Elzoo.DurableLog.Store.read(state.command_store, :head, [stream]),
         true <- fresh_projection_head?(head),
         {:ok, snapshot} <-
           CheckedCommand.resource(
             state.handles.input,
             resource_scope(state.profile),
             event.conversation_id
           ),
         {:ok, input_writes, _} <-
           Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_input(
             snapshot,
             input_request(event, operation_id),
             prepare_facts(state.profile, input_facts())
           ),
         input_snapshot <- apply_writes(snapshot, input_writes),
         true <- resource_snapshot_fits?(input_snapshot),
         {:ok, conversation_snapshot} <-
           Elzoo.Wave4ChannelExample.CommandBindings.conversation_snapshot(
             input_snapshot,
             state.profile.tenant
           ),
         {:ok, conversation} <-
           Conversation.view(conversation_snapshot, resource_scope(state.profile)),
         {:ok, reply_id} <- projected_reply_id(conversation.messages, operation_id),
         reply_operation <- stable_id("reply-input-projection", [operation_id, reply_id]),
         primary_association_request <-
           command_request(
             state.profile,
             event.conversation_id,
             input_snapshot.revision,
             association_operation(operation_id, event.input_id, state.profile),
             %{"message_id" => event.input_id}
           ),
         primary_association_facts <-
           reply_primary_association_facts(run_id, primary_key),
         {:ok, primary_association_writes, _} <-
           Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_association(
             input_snapshot,
             primary_association_request,
             prepare_facts(state.profile, primary_association_facts)
           ),
         primary_snapshot <- apply_writes(input_snapshot, primary_association_writes),
         true <- resource_snapshot_fits?(primary_snapshot),
         reply_request <-
           command_request(
             state.profile,
             event.conversation_id,
             primary_snapshot.revision,
             reply_operation,
             %{"message_id" => reply_id, "text" => String.duplicate("x", 4096)}
           ),
         {:ok, reply_writes, _} <-
           Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_input(
             primary_snapshot,
             reply_request,
             prepare_facts(state.profile, input_facts())
           ),
         reply_snapshot <- apply_writes(primary_snapshot, reply_writes),
         true <- resource_snapshot_fits?(reply_snapshot),
         reply_association_request <-
           command_request(
             state.profile,
             event.conversation_id,
             reply_snapshot.revision,
             association_operation(reply_operation, reply_id, state.profile),
             %{"message_id" => reply_id}
           ),
         {:ok, reply_association_writes, _} <-
           Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_association(
             reply_snapshot,
             reply_association_request,
             prepare_facts(
               state.profile,
               reply_association_facts(run_id, primary_key, reply_key)
             )
           ),
         reply_associated_snapshot <- apply_writes(reply_snapshot, reply_association_writes),
         true <- resource_snapshot_fits?(reply_associated_snapshot),
         answer_request <-
           command_request(
             state.profile,
             event.conversation_id,
             reply_associated_snapshot.revision,
             answer_operation(operation_id, event.input_id, state.profile),
             %{"message_id" => answer_id(event.input_id), "text" => String.duplicate("x", 71)}
           ),
         {:ok, answer_writes, _} <-
           Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_answer(
             reply_associated_snapshot,
             answer_request,
             prepare_facts(state.profile, answer_facts(run_id, event.input_id, true))
           ),
         answer_snapshot <- apply_writes(reply_associated_snapshot, answer_writes),
         true <- resource_snapshot_fits?(answer_snapshot),
         {:ok, after_head} <- Elzoo.DurableLog.Store.read(state.command_store, :head, [stream]),
         true <- stable_projection_heads?(head, after_head) do
      {:ok, :new}
    else
      false -> {:ok, :capacity}
      {:refused, _} -> {:ok, :capacity}
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  end

  defp fresh_projection_head?(%{revision: revision, low_water: 0})
       when is_integer(revision) and revision in 0..1017,
       do: true

  defp fresh_projection_head?(_), do: false

  defp stable_projection_heads?(before, after_head) do
    Map.drop(before, [:capabilities]) == Map.drop(after_head, [:capabilities])
  end

  defp projected_reply_id(messages, operation_id) do
    retained_ids = MapSet.new(messages, & &1.message_id)

    case Enum.find_value(0..4095, fn candidate ->
           digest =
             :crypto.hash(
               :sha256,
               :erlang.term_to_binary({:reply_projection, operation_id, candidate})
             )

           id =
             ("projection-" <> Base.url_encode64(digest, padding: false))
             |> String.pad_trailing(128, "x")

           if MapSet.member?(retained_ids, id), do: nil, else: id
         end) do
      nil -> {:error, :projection_id}
      id -> {:ok, id}
    end
  end

  defp projected_command_key(profile, operation_id, sequence, destination) do
    nonce =
      :crypto.hash(:sha256, :erlang.term_to_binary({profile.tenant, operation_id, sequence}))
      |> binary_part(0, 16)

    Elzoo.Outbox.new(checked_stream(profile.tenant), sequence, 1, destination, "{}", nonce).idempotency_key
  end

  defp capacity_after_input(state, event, operation_id, snapshot, input_snapshot) do
    with association_request <-
           command_request(
             state.profile,
             event.conversation_id,
             snapshot.revision + 1,
             association_operation(operation_id, event.input_id, state.profile),
             %{"message_id" => event.input_id}
           ),
         association_facts <- association_facts(run_id(event, operation_id, state)),
         {:ok, association_writes, _} <-
           Conversation.prepare(
             input_snapshot,
             association_request,
             prepare_facts(state.profile, association_facts)
           ),
         associated_snapshot <- apply_writes(input_snapshot, association_writes),
         true <- resource_snapshot_fits?(associated_snapshot),
         answer_request <-
           command_request(
             state.profile,
             event.conversation_id,
             snapshot.revision + 2,
             answer_operation(operation_id, event.input_id, state.profile),
             %{"message_id" => answer_id(event.input_id), "text" => String.duplicate("x", 71)}
           ),
         answer_facts <- answer_facts(run_id(event, operation_id, state), event.input_id, true),
         {:ok, answer_writes, _} <-
           Conversation.prepare(
             associated_snapshot,
             answer_request,
             prepare_facts(state.profile, answer_facts)
           ),
         answer_snapshot <- apply_writes(associated_snapshot, answer_writes),
         true <- resource_snapshot_fits?(answer_snapshot) do
      {:ok, :new}
    else
      false -> {:ok, :capacity}
      {:refused, _} -> {:ok, :capacity}
    end
  end

  defp execute_input(state, _event, _operation_id, :capacity),
    do: {{:error, :unavailable}, state}

  defp execute_input(state, event, operation_id, decision) do
    request = input_request(event, operation_id)

    case command_context(state, :input, event, request, input_facts()) do
      {:ok, context} ->
        execute_input_command(state, event, operation_id, context, request, decision)

      _ ->
        {{:error, :unavailable}, state}
    end
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
    case release_plan(state, event, trusted_scope, evidence) do
      {:ready, operation_id, facts, request, context} ->
        execute_release(state, event, operation_id, facts, request, context, evidence)

      {:reply, reply} ->
        {reply, state}
    end
  end

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
           true <- before_deadline?(state),
           {:ok, facts, request, context} <-
             release_context(state, event, operation_id, evidence) do
        {:ready, operation_id, facts, request, context}
      else
        false -> {:reply, {:rejected, :conflict}}
        nil -> {:reply, {:rejected, :conflict}}
        {:error, :profile_scope} -> {:reply, {:rejected, :forbidden}}
        {:error, :evidence} -> {:reply, {:error, :unavailable}}
        _ -> {:reply, {:rejected, :invalid}}
      end
    else
      {:reply, {:rejected, :invalid}}
    end
  rescue
    _ -> {:reply, {:error, :unavailable}}
  catch
    _, _ -> {:reply, {:error, :unavailable}}
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

  defp advance_once(%{poison: {:ack, key, nonce, receipt}} = state),
    do: reconcile_ack(state, key, nonce, receipt)

  defp advance_once(%{poison: {:input, operation, _}} = state),
    do: reconcile_input(state, operation)

  defp advance_once(%{poison: {:release, operation, _facts, _request, _}} = state),
    do: reconcile_release(state, operation)

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

  defp advance_once(%{poison: poison} = state) when not is_nil(poison),
    do: {{:blocked, elem(poison, 0)}, state}

  defp advance_once(%{phase: :idle} = state), do: observe_input(state)
  defp advance_once(%{phase: :association} = state), do: associate(state)
  defp advance_once(%{phase: :create_run} = state), do: create_run(state)
  defp advance_once(%{phase: :begin_attempt} = state), do: begin_attempt(state)
  defp advance_once(%{phase: :start_engine} = state), do: start_engine(state)
  defp advance_once(%{phase: :start_input} = state), do: start_input(state)
  defp advance_once(%{phase: :result} = state), do: observe_result(state)
  defp advance_once(%{phase: :answer} = state), do: append_answer(state)
  defp advance_once(%{phase: :ack} = state), do: acknowledge(state)
  defp advance_once(state), do: {{:blocked, :invalid_phase}, state}

  defp observe_input(state) do
    stream = checked_stream(state.profile.tenant)

    case Outbox.pending(state.command_store, stream, @outbox_limit) do
      {:ok, items} ->
        case Enum.find(items, &(&1.destination == @destination)) do
          nil ->
            {{:idle, :no_input}, state}

          item ->
            with {:ok, event, operation_id, resource_revision} <-
                   recover_input(state, item),
                 {:ok, input, text, snapshot, conversation} <-
                   input_from_resource(state, event, resource_revision),
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
                     snapshot,
                     conversation
                   ) do
              {{:observed, input}, %{state | current: current, phase: phase}}
            else
              _ ->
                {{:unknown, :input_observation}, %{state | poison: {:input_observation, :unknown}}}
            end
        end

      _ ->
        {{:unknown, :input_observation}, %{state | poison: {:input_observation, :read}}}
    end
  rescue
    _ -> {{:unknown, :input_observation}, %{state | poison: {:input_observation, :exception}}}
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
         true <- response_id == input_id_from_receipt(response) do
      event = %{
        version: 1,
        event_id: "retained",
        conversation_id: notice["resource"],
        input_id: response_id,
        expected_revision: notice["revision"] - 1,
        text: nil
      }

      {:ok, event, notice["operation_id"], notice["revision"]}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp input_from_resource(state, event, revision) do
    scope = resource_scope(state.profile)

    with true <- event.conversation_id == state.profile.conversation_id,
         {:ok, snapshot} <-
           CheckedCommand.resource(state.handles.input, scope, state.profile.conversation_id),
         {:ok, view} <- Conversation.view(snapshot, scope),
         %{message_id: id, role: "source", text: text} <-
           Enum.find(view.messages, &(&1.message_id == event.input_id)),
         true <- snapshot.revision >= revision do
      {:ok, id, text, snapshot, view}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp retained_phase(state, current, snapshot, conversation) do
    identity = {state.profile.tenant, state.profile.actor, current.association_operation}

    case CheckedCommand.result(state.handles.association, result_scope(state.profile), identity) do
      {:unknown, :not_observed} ->
        {:ok, :association, current}

      {:completed, %{revision: revision, response: response}}
      when revision == current.resource_revision + 1 ->
        associated? =
          Enum.any?(conversation.associations, fn association ->
            Map.get(association, :input_message_id) == current.input_id and
              Map.get(association, :run_id) == current.run_id
          end)

        if association_receipt?(response, current.input_id, current.run_id) and associated? do
          retained_answer_phase(state, current, snapshot, conversation)
        else
          {:error, :association}
        end

      _ ->
        {:error, :association}
    end
  rescue
    _ -> {:error, :association}
  catch
    _, _ -> {:error, :association}
  end

  defp retained_answer_phase(state, current, snapshot, conversation) do
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

        case Enum.find(conversation.messages, &(&1.message_id == message_id)) do
          %{role: "assistant", text: text} when valid_run? ->
            if answer_receipt?(response, current.input_id, current.run_id, message_id) and
                 valid_answer_payload?(%{"answer" => text}) do
              {:ok, :ack, %{current | answer: text}}
            else
              {:error, :answer}
            end

          _ ->
            {:error, :answer}
        end

      _ ->
        {:error, :answer}
    end
  rescue
    _ -> {:error, :answer}
  catch
    _, _ -> {:error, :answer}
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

    facts =
      if reply_profile?(state.profile) do
        reply_primary_association_facts(c.run_id, c.item.key)
      else
        association_facts(c.run_id)
      end

    result = execute_checked(state, :association, c.event, request, facts)
    classify_association(state, c, result)
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
          {{:associated, c.run_id}, %{state | phase: :create_run}}
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

  defp create_run(state) do
    c = state.current
    expected_operation = native_operation(c.run_id, state)

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: ^expected_operation, current_attempt: nil}} ->
        with {:held, held} <-
               Lease.hold(state.native.lease, state.native.lease_stream, state.native.lease_owner) do
          {{:run_recovered, c.run_id},
           %{state | native: %{state.native | held: held}, phase: :begin_attempt}}
        else
          other -> {{:unknown, :run_create}, %{state | poison: {:run_create, other}}}
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

  defp begin_attempt(state) do
    c = state.current

    case RunApprovalRelease.status(state.native.run_owner, c.run_id) do
      {:ok, %{operation_id: operation, revision: revision, current_attempt: nil}} ->
        expected_operation = native_operation(c.run_id, state)

        if operation != expected_operation do
          {{:unknown, :run_identity}, %{state | poison: {:run_status, :identity}}}
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

  defp start_engine(state) do
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
                {{:engine_started, unit_id}, %{owned_state | phase: :start_input}}

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

        if result.run_id == c.run_id and result.operation_id == expected_operation and
             result.attempt_id == attempt_id(c.run_id, state) and result.action_id == "work" and
             result.schema_id == "answer/v1" and result.schema_version == 1 and
             valid_answer_payload?(result.payload) do
          {{:result, :completed},
           %{state | current: Map.put(c, :answer, result.payload["answer"]), phase: :answer}}
        else
          {{:unknown, :result_identity}, %{state | poison: {:result, :identity}}}
        end

      {:pending, reason} ->
        if reply_profile?(state.profile) do
          case native_event_waits(state) do
            {:ok, %{waits: [wait]}}
            when wait.status == :waiting and wait.source_id == state.profile.reply_source_id ->
              {{:pending, :event_waiting}, %{state | native_wait: wait}}

            _ ->
              {{:pending, reason}, state}
          end
        else
          {{:pending, reason}, state}
        end

      {:terminal, outcome} when outcome in [:failed, :cancelled, :out_of_budget, :out_of_time] ->
        current = Map.put(c, :terminal, outcome)
        {{:terminal, outcome}, %{state | current: current, phase: :ack}}

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

  defp append_answer(state) do
    c = state.current

    request =
      command_request(
        state.profile,
        c.event.conversation_id,
        c.resource_revision + 1,
        c.answer_operation,
        %{"message_id" => answer_id(c.input_id), "text" => c.answer}
      )

    facts = answer_facts(c.run_id, c.input_id, true)

    result = execute_checked(state, :answer, c.event, request, facts)
    classify_answer(state, c, result)
  rescue
    _ -> {{:error, :unavailable}, state}
  catch
    _, _ -> {{:error, :unavailable}, state}
  end

  defp classify_answer(state, c, result) do
    case result do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 2 ->
        if answer_receipt?(response, c.input_id, c.run_id, answer_id(c.input_id)) do
          {{:answered, revision}, %{state | phase: :ack}}
        else
          {{:unknown, :answer_receipt}, %{state | poison: {:answer, :receipt}}}
        end

      {:unknown, _} = unknown ->
        {{:unknown, :answer}, %{state | poison: {:answer, c.answer_operation, unknown}}}

      {:unavailable, _} ->
        {{:error, :unavailable}, state}

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

  defp acknowledge(state) do
    c = state.current

    if is_nil(c.answer) and is_nil(c.terminal) do
      {{:blocked, :unresolved_result}, state}
    else
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

        _other ->
          {{:unknown, :ack}, %{state | poison: {:ack, key, nonce, :no_receipt}}}
      end
    end
  rescue
    _ ->
      c = state.current
      {{:unknown, :ack}, %{state | poison: {:ack, c.item.key, c.item.nonce, :no_receipt}}}
  catch
    _, _ ->
      c = state.current
      {{:unknown, :ack}, %{state | poison: {:ack, c.item.key, c.item.nonce, :no_receipt}}}
  end

  defp confirm_ack(state, receipt, key, nonce), do: reconcile_ack(state, key, nonce, receipt)

  defp reconcile_ack(state, key, nonce, receipt) do
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

  defp finish_input(state) do
    c = state.current

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
            {{:reconciled, :input}, %{state | poison: nil, approval: nil}}

          _ ->
            {{:unknown, :input}, state}
        end

      {:approval_pending, pending} ->
        case state.approval do
          %{event: event, operation_id: ^operation} ->
            approval = %{
              event: event,
              operation_id: operation,
              key: pending.key,
              requirement: pending.requirement
            }

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

  defp reconcile_association(state, operation) do
    c = state.current

    case CheckedCommand.result(
           state.handles.association,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, operation}
         ) do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 1 ->
        if association_receipt?(response, c.input_id, c.run_id),
          do: {{:reconciled, :association}, %{state | poison: nil, phase: :create_run}},
          else: {{:unknown, :association}, state}

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
    c = state.current

    case CheckedCommand.result(
           state.handles.answer,
           result_scope(state.profile),
           {state.profile.tenant, state.profile.actor, c.answer_operation}
         ) do
      {:completed, %{revision: revision, response: response}}
      when revision == c.resource_revision + 2 ->
        if answer_receipt?(response, c.input_id, c.run_id, answer_id(c.input_id)),
          do: {{:reconciled, :answer}, %{state | poison: nil, phase: :ack}},
          else: {{:unknown, :answer}, state}

      _ ->
        {{:unknown, :answer}, state}
    end
  rescue
    _ -> {{:unknown, :answer}, state}
  catch
    _, _ -> {{:unknown, :answer}, state}
  end

  defp execute_checked(state, mode, event, request, facts) do
    handle = state.handles[mode]

    case command_context(state, mode, event, request, facts) do
      {:ok, context} ->
        try do
          CheckedCommand.execute(handle, context, request)
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
    handle = if mode == :release, do: state.handles.input, else: state.handles[mode]

    with {:ok, snapshot} <-
           CheckedCommand.resource(
             handle,
             resource_scope(state.profile),
             state.profile.conversation_id
           ) do
      prepared =
        if reply_profile?(state.profile) do
          prepared_facts = prepare_facts(state.profile, facts)

          case mode do
            :input ->
              Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_input(
                snapshot,
                request,
                prepared_facts
              )

            :association ->
              Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_association(
                snapshot,
                request,
                prepared_facts
              )

            :answer ->
              Elzoo.Wave4ChannelExample.CommandBindings.prepare_reply_answer(
                snapshot,
                request,
                prepared_facts
              )

            _ ->
              Conversation.prepare(snapshot, request, prepared_facts)
          end
        else
          Conversation.prepare(snapshot, request, prepare_facts(state.profile, facts))
        end

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
             {:ok, conversation_snapshot} <- read_conversation_snapshot(snapshot, state.profile),
             {:ok, conversation} <- Conversation.view(conversation_snapshot, scope),
             {:ok, summaries} <- run_summaries(state, conversation.associations),
             {:ok, event_waits} <- native_event_waits_view(state, snapshot),
             view <- %{
               tenant: state.profile.tenant,
               resource: state.profile.conversation_id,
               revision: snapshot.revision,
               messages: conversation.messages,
               associations: conversation.associations,
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

  defp read_conversation_snapshot(snapshot, profile) do
    if reply_profile?(profile),
      do:
        Elzoo.Wave4ChannelExample.CommandBindings.conversation_snapshot(
          snapshot,
          profile.tenant
        ),
      else: {:ok, snapshot}
  end

  defp native_event_waits_view(%{profile: profile} = state, snapshot) do
    metadata_present? = Map.has_key?(snapshot.fields, "wave4_reply")

    cond do
      not reply_profile?(profile) ->
        {:ok, nil}

      not is_nil(state.native_wait) ->
        native_event_waits_for_live_reader(state, metadata_present?)

      known_pre_native?(state) and
          (not metadata_present? or pre_native_metadata_matches?(snapshot, state.current)) ->
        {:ok, nil}

      true ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp native_event_waits_for_live_reader(
         %{current: %{run_id: run_id}, engine: engine, native_wait: native_wait} = state,
         true
       )
       when is_pid(engine) do
    if Process.alive?(engine) and is_nil(state.poison) do
      scope = %{tenant: state.profile.tenant, principal: state.profile.actor, run_id: run_id}

      case RunEngine.event_waits(engine, scope, @result_limits) do
        {:ok, %{waits: [wait]} = waits}
        when wait.status == :waiting and wait.correlation_id == native_wait.correlation_id and
               wait.source_id == state.profile.reply_source_id ->
          {:ok,
           Map.update!(waits, :waits, fn entries ->
             Enum.map(entries, fn item ->
               Map.update!(item, :occurrence, &Tuple.to_list/1)
             end)
           end)}

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp native_event_waits_for_live_reader(_, _), do: {:error, :unavailable}

  defp known_pre_native?(%{engine: nil, native_wait: nil, poison: nil, current: nil, phase: phase}),
    do: phase in [:idle, :observe, :associate, :create_run, :begin_attempt, :start_engine]

  defp known_pre_native?(%{
         engine: nil,
         native_wait: nil,
         poison: nil,
         current: current,
         phase: phase
       })
       when is_map(current),
       do: phase in [:associate, :create_run, :begin_attempt, :start_engine]

  defp known_pre_native?(_), do: false

  defp pre_native_metadata_matches?(snapshot, %{run_id: run_id, item: %{key: primary_key}}) do
    case Map.get(snapshot.fields, "wave4_reply") do
      {:record, fields} ->
        List.keyfind(fields, "run_id", 0) == {"run_id", {:text, run_id}} and
          List.keyfind(fields, "primary_key", 0) == {"primary_key", {:text, primary_key}} and
          is_nil(List.keyfind(fields, "reply_key", 0))

      _ ->
        false
    end
  end

  defp pre_native_metadata_matches?(_, _), do: false

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
    Enum.reduce_while(associations, {:ok, []}, fn association, {:ok, acc} ->
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
         bounded_ascii?(profile.conversation_id) and is_integer(profile.deadline_ms) and
         profile.deadline_ms > 0 and is_map(profile.native_target) do
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
        do: [:input, :reply_input, :association, :reply_association, :answer],
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

  defp stop_native_unit(%{current: current, native: %{directory: directory}} = state)
       when not is_nil(current) do
    if Process.alive?(directory),
      do: DynamicUnits.stop(directory, unit_id(current.run_id, state)),
      else: {:error, :directory_unavailable}
  end

  defp stop_native_unit(_state), do: :ok

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

  defp no_live_native_unit(%{current: %{run_id: run_id}} = state) do
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

  defp no_live_native_unit(_), do: :ok

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

  defp pending_input?(state) do
    case Outbox.pending(state.command_store, checked_stream(state.profile.tenant), @outbox_limit) do
      {:ok, items} -> {:ok, Enum.any?(items, &(&1.destination == @destination))}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp unfinished?(state),
    do: not is_nil(state.current) or not is_nil(state.approval) or state.phase != :idle

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

  defp reply_primary_association_facts(run_id, primary_key),
    do:
      portable_facts(%{
        "mode" => {:text, "associate_run"},
        "run_id" => {:text, run_id},
        "primary_key" => {:text, primary_key}
      })

  defp reply_association_facts(run_id, primary_key, reply_key),
    do:
      portable_facts(%{
        "mode" => {:text, "associate_run"},
        "run_id" => {:text, run_id},
        "primary_key" => {:text, primary_key},
        "reply_key" => {:text, reply_key}
      })

  defp projected_reply_key(profile, operation_id) do
    nonce =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({profile.tenant, operation_id, :reply_projection})
      )
      |> binary_part(0, 16)

    Elzoo.Outbox.new(
      checked_stream(profile.tenant),
      4096,
      1,
      "wave4-channel-reply",
      "{}",
      nonce
    ).idempotency_key
  end

  defp answer_facts(run_id, input_id, completed),
    do:
      portable_facts(%{
        "mode" => {:text, "append_answer"},
        "run_id" => {:text, run_id},
        "input_message_id" => {:text, input_id},
        "completed" => completed
      })

  defp portable_facts(fields), do: {:record, Enum.sort_by(fields, &elem(&1, 0))}

  defp prepare_facts(profile, facts),
    do: %{tenant: profile.tenant, actor: profile.actor, data: facts}

  defp apply_writes(snapshot, writes) do
    fields =
      Enum.reduce(writes, snapshot.fields, fn write, acc ->
        Map.put(acc, write.field, write.value)
      end)

    %{snapshot | revision: snapshot.revision + 1, fields: fields}
  end

  defp resource_snapshot_fits?(%{revision: revision, fields: fields}) do
    bytes = :erlang.term_to_binary(%{revision: revision, fields: fields}, [:deterministic])
    map_size(fields) <= 64 and byte_size(bytes) <= 65_536
  rescue
    _ -> false
  end

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
  @metadata_field "wave4_reply"
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

  def read(scope, event_id, profile, run_id, store, handles, primary) do
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
            read_event(store, before, event_id, sequence, profile, run_id, handles, primary)
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

  defp read_event(store, before, event_id, sequence, profile, run_id, handles, primary) do
    target_stream = stream(profile.tenant)

    with {:ok, records, read_head} <- DurableLog.read(store, target_stream, 1, before.revision),
         true <- Map.delete(read_head, :capabilities) == before,
         :ok <- complete_range(records, before),
         {:ok, :absent} <- Store.read(store, :read_ack, [event_id]) do
      {:error, :not_found}
    else
      {:ok, item} when is_map(item) ->
        with :ok <- valid_item(item, event_id, sequence, profile, @destination),
             {:ok, event} <- source_event(item, event_id, profile, run_id, handles, primary) do
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

  defp source_event(item, event_id, profile, run_id, handles, primary) do
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
         :ok <-
           same_run_associations(
             handles,
             profile,
             run_id,
             primary,
             reply_operation,
             ticket,
             event_id,
             primary_notice,
             primary_result.revision,
             reply_notice,
             reply_result.revision
           ),
         {:ok, text} <-
           conversation_text(
             handles.input,
             profile,
             ticket,
             "source",
             run_id,
             primary.key,
             event_id
           ) do
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

  defp same_run_associations(
         handles,
         profile,
         run_id,
         primary,
         reply_operation,
         ticket,
         reply_key,
         primary_notice,
         primary_revision,
         reply_notice,
         reply_revision
       ) do
    with true <- reply_notice["resource"] == profile.conversation_id,
         true <- primary_notice["resource"] == profile.conversation_id,
         {:ok, snapshot} <- resource_snapshot(handles.input, profile),
         true <- metadata_matches?(snapshot, profile, run_id, primary.key, reply_key),
         {:ok, conversation_snapshot} <-
           conversation_snapshot(snapshot, profile, run_id, primary.key, reply_key),
         {:ok, conversation} <- Conversation.view(conversation_snapshot, resource_scope(profile)),
         true <- has_association?(conversation.associations, primary.input_id, run_id),
         true <- has_association?(conversation.associations, ticket, run_id),
         true <-
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
        fields ==
          Enum.sort([
            {"message_id", {:text, message_id}},
            {"revision", revision},
            {"run_id", {:text, run_id}}
          ])

      _ ->
        false
    end
  end

  defp metadata_matches?(snapshot, profile, run_id, primary_key, reply_key) do
    Map.get(snapshot.fields, @metadata_field) ==
      metadata_record(run_id, primary_key, reply_key, profile.tenant)
  end

  defp conversation_text(handle, profile, message_id, role, run_id, primary_key, reply_key) do
    with {:ok, snapshot} <- resource_snapshot(handle, profile),
         {:ok, conversation_snapshot} <-
           conversation_snapshot(snapshot, profile, run_id, primary_key, reply_key),
         {:ok, conversation} <- Conversation.view(conversation_snapshot, resource_scope(profile)),
         %{role: ^role, text: text} <-
           Enum.find(conversation.messages, &(&1.message_id == message_id)),
         true <- is_binary(text) and byte_size(text) in 1..4_096 do
      {:ok, text}
    else
      _ -> {:error, :message}
    end
  end

  defp resource_snapshot(handle, profile),
    do: CheckedCommand.resource(handle, resource_scope(profile), profile.conversation_id)

  defp conversation_snapshot(snapshot, profile, run_id, primary_key, reply_key) do
    if metadata_matches?(snapshot, profile, run_id, primary_key, reply_key),
      do: {:ok, %{snapshot | fields: Map.delete(snapshot.fields, @metadata_field)}},
      else: {:error, :metadata}
  end

  defp metadata_record(run_id, primary_key, reply_key, tenant) do
    with true <- bounded_id?(run_id),
         {:ok, _} <- key_sequence(primary_key, tenant),
         {:ok, _} <- key_sequence(reply_key, tenant) do
      {:record,
       Enum.sort_by(
         [
           {"primary_key", {:text, primary_key}},
           {"reply_key", {:text, reply_key}},
           {"run_id", {:text, run_id}},
           {"version", {:text, "1"}}
         ],
         &elem(&1, 0)
       )}
    else
      _ -> nil
    end
  end

  defp has_association?(associations, message_id, run_id),
    do:
      Enum.any?(associations, fn association ->
        association.input_message_id == message_id and association.run_id == run_id
      end)

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
         true <- notice["type"] == "checked_command" and notice["version"] == 1,
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

  defp receipt({:record, fields}) when is_list(fields) do
    with true <- Enum.sort(Enum.map(fields, &elem(&1, 0))) == ["message_id", "revision"],
         true <- length(Enum.uniq_by(fields, &elem(&1, 0))) == 2,
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

defmodule Elzoo.Wave4ChannelExample.CommandBindings do
  alias Elzoo.{CheckedCommand, Conversation, Outbox, PayloadSchema}

  @destination "wave4-channel-input"
  @reply_destination "wave4-channel-reply"
  @reply_metadata_field "wave4_reply"

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
             descriptor("wave4/association", association_schema, nil, association_gate)
           ),
         {:ok, answer} <-
           CheckedCommand.new(store, descriptor("wave4/answer", answer_schema, nil, answer_gate)) do
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
         {:ok, input} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/input",
               input_schema,
               @destination,
               input_gate,
               &prepare_reply_input/3
             )
           ),
         {:ok, reply_input} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/reply",
               reply_schema,
               @reply_destination,
               reply_gate,
               &prepare_reply_input/3
             )
           ),
         always_allow <- fn _, _ -> :allow end,
         {:ok, association} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/association",
               association_schema,
               nil,
               always_allow,
               &prepare_reply_association/3
             )
           ),
         {:ok, reply_association} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/reply-association",
               reply_association_schema,
               nil,
               always_allow,
               &prepare_reply_association/3
             )
           ),
         {:ok, answer} <-
           CheckedCommand.new(
             store,
             descriptor(
               "wave4/answer",
               answer_schema,
               nil,
               always_allow,
               &prepare_reply_answer/3
             )
           ) do
      {:ok,
       %{
         input: input,
         reply_input: reply_input,
         association: association,
         reply_association: reply_association,
         answer: answer
       }}
    else
      _ -> {:error, :commands}
    end
  end

  def build_reply(_, _), do: {:error, :commands}

  def prepare_reply_input(snapshot, request, facts) do
    with {:ok, clean_snapshot} <- conversation_snapshot(snapshot, facts.tenant),
         do: Conversation.prepare(clean_snapshot, request, facts)
  end

  def prepare_reply_answer(snapshot, request, facts) do
    with {:ok, clean_snapshot} <- conversation_snapshot(snapshot, facts.tenant),
         do: Conversation.prepare(clean_snapshot, request, facts)
  end

  def conversation_snapshot(%{fields: fields} = snapshot, tenant) when is_map(fields) do
    case Map.fetch(fields, @reply_metadata_field) do
      :error ->
        {:ok, snapshot}

      {:ok, metadata} ->
        if valid_metadata?(metadata, tenant),
          do: {:ok, %{snapshot | fields: Map.delete(fields, @reply_metadata_field)}},
          else: {:error, :metadata}
    end
  end

  def conversation_snapshot(_, _), do: {:error, :snapshot}

  def prepare_reply_association(snapshot, request, facts) do
    with {:ok, run_id, primary_key, reply_key, clean_facts} <- association_facts(facts),
         {:ok, clean_snapshot} <- conversation_snapshot(snapshot, facts.tenant),
         {:ok, writes, response} <-
           Conversation.prepare(clean_snapshot, request, clean_facts),
         {:ok, metadata} <- reply_metadata(snapshot, run_id, primary_key, reply_key, facts.tenant) do
      {:ok, writes ++ [%{target: request.resource, field: @reply_metadata_field, value: metadata}],
       response}
    else
      {:refused, _} = refused -> refused
      _ -> {:refused, "invalid_facts"}
    end
  rescue
    _ -> {:refused, "invalid_facts"}
  catch
    _, _ -> {:refused, "invalid_facts"}
  end

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

  defp descriptor(id, %{port: port, compiled: schema}, outbox, gate) do
    %{
      id: id,
      version: 1,
      content_hash: :crypto.hash(:sha256, id),
      effect_class: "conversation.write",
      port: port,
      schema: schema,
      prepare: &Conversation.prepare/3,
      gate: %{call: gate},
      approval: %{verifiers: ["wave4-command-approver"], max_age: 60_000},
      outbox: outbox
    }
  end

  defp descriptor(id, %{port: port, compiled: schema}, outbox, gate, prepare) do
    %{
      id: id,
      version: 1,
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

  defp association_facts(%{tenant: tenant, actor: actor, data: {:record, fields}} = facts)
       when map_size(facts) == 3 and is_list(fields) do
    keys = Enum.map(fields, fn {key, _} -> key end)

    with true <- Enum.all?(fields, &match?({key, _} when is_binary(key), &1)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:text, "associate_run"} <- field_value(fields, "mode"),
         {:text, run_id} <- field_value(fields, "run_id"),
         {:text, primary_key} <- field_value(fields, "primary_key"),
         true <- bounded_id?(run_id) and canonical_key?(primary_key, tenant),
         {:ok, reply_key} <- optional_reply_key(fields, tenant),
         true <-
           keys ==
             if(is_nil(reply_key),
               do: ["mode", "primary_key", "run_id"],
               else: ["mode", "primary_key", "reply_key", "run_id"]
             ),
         clean_data <- {:record, [{"mode", {:text, "associate_run"}}, {"run_id", {:text, run_id}}]},
         clean <- %{tenant: tenant, actor: actor, data: clean_data} do
      {:ok, run_id, primary_key, reply_key, clean}
    else
      _ -> {:error, :facts}
    end
  end

  defp association_facts(_), do: {:error, :facts}

  defp optional_reply_key(fields, tenant) do
    case field_value(fields, "reply_key") do
      nil ->
        {:ok, nil}

      {:text, key} when is_binary(key) ->
        if(canonical_key?(key, tenant), do: {:ok, key}, else: {:error, :facts})

      _ ->
        {:error, :facts}
    end
  end

  defp reply_metadata(snapshot, run_id, primary_key, nil, _tenant) do
    if not Map.has_key?(snapshot.fields, @reply_metadata_field),
      do: {:ok, metadata_record(run_id, primary_key, nil)},
      else: {:error, :metadata}
  end

  defp reply_metadata(snapshot, run_id, primary_key, reply_key, tenant) do
    case snapshot.fields[@reply_metadata_field] do
      {:record, _fields} = metadata ->
        if metadata == metadata_record(run_id, primary_key, nil) and
             valid_metadata?(metadata, tenant) do
          {:ok, metadata_record(run_id, primary_key, reply_key)}
        else
          {:error, :metadata}
        end

      _ ->
        {:error, :metadata}
    end
  end

  defp metadata_record(run_id, primary_key, reply_key) do
    fields = [
      {"primary_key", {:text, primary_key}},
      {"run_id", {:text, run_id}},
      {"version", {:text, "1"}}
    ]

    fields = if is_binary(reply_key), do: [{"reply_key", {:text, reply_key}} | fields], else: fields
    {:record, Enum.sort_by(fields, &elem(&1, 0))}
  end

  defp valid_metadata?({:record, fields} = metadata, tenant) when is_list(fields) do
    run_id = field_value(fields, "run_id")
    primary_key = field_value(fields, "primary_key")
    reply_key = field_value(fields, "reply_key")

    expected =
      case {run_id, primary_key, reply_key} do
        {{:text, run}, {:text, primary}, nil} -> metadata_record(run, primary, nil)
        {{:text, run}, {:text, primary}, {:text, reply}} -> metadata_record(run, primary, reply)
        _ -> nil
      end

    valid_run_id =
      case run_id do
        {:text, value} -> bounded_id?(value)
        _ -> false
      end

    metadata == expected and valid_run_id and canonical_key?(primary_key, tenant) and
      (is_nil(reply_key) or canonical_key?(reply_key, tenant))
  end

  defp valid_metadata?(_, _), do: false

  defp canonical_key?({:text, key}, tenant) when is_binary(key), do: canonical_key?(key, tenant)

  defp canonical_key?(key, tenant) when is_binary(key) do
    case Outbox.parse_id(key) do
      {:ok, {stream, sequence, 1}} -> stream == stream(tenant) and sequence in 1..4_096
      _ -> false
    end
  end

  defp canonical_key?(_, _), do: false

  defp stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )

  defp field_value(fields, key) do
    case List.keyfind(fields, key, 0) do
      {^key, value} -> value
      _ -> nil
    end
  end

  defp bounded_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)
end
