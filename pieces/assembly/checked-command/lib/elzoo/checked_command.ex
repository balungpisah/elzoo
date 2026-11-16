# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckedCommand do
  @moduledoc """
  Caller-held checked commands over one atomic DurableLog Store.

  The host owns identity authentication, serialization of domain callbacks,
  duplicate-JSON-key rejection and the freshness of authority and revocation
  facts. This module never starts a process or performs a remote effect.
  """

  alias Elzoo.CheckedCommand.Codec
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Record, Store}
  alias Elzoo.DurableLog.Codec, as: StoreCodec
  alias Elzoo.{Approval, Authorization, PayloadSchema, PatternStep}

  @kind "checked_command"
  @version 1
  @max_i64 9_223_372_036_854_775_807
  @max_expected_revision @max_i64 - 1
  @max_resources 64
  @max_fields 64
  @max_writes 16
  @max_operations 1_024
  @max_records 4_096
  @max_identity_bytes 128
  @max_field_bytes 128
  @max_value_depth 16
  @max_value_nodes 4_096
  @max_resource_bytes 65_536
  @max_response_bytes 8_192
  @max_record_bytes 1_048_576
  @page_size 128
  @fold %{kinds: %{@kind => :state_bearing}, versions: [@version]}

  defmodule Handle do
    @moduledoc false
    defstruct [:store, :descriptor]
  end

  @doc "Build a validated immutable handle over a caller-owned atomic Store."
  def new(store, descriptor) do
    with :ok <- validate_store(store),
         :ok <- validate_descriptor(descriptor),
         %{append_visibility: :atomic} <- Store.read(store, :capabilities, []) do
      {:ok, %Handle{store: store, descriptor: descriptor}}
    else
      _ -> {:error, :invalid_descriptor}
    end
  rescue
    _ -> {:error, :invalid_descriptor}
  catch
    _, _ -> {:error, :invalid_descriptor}
  end

  @doc "Execute one checked command or return its retained identity result."
  def execute(handle, context, request) do
    with {:ok, handle} <- validate_handle_local(handle),
         {:ok, context} <- validate_context(context, handle.descriptor, :execute),
         {:ok, request} <- validate_request(request),
         {:ok, portable_payload} <- json_payload(request.payload),
         :ok <- schema_check(handle.descriptor, request.payload),
         {:ok, pattern} <- gate_frame(handle.descriptor, request),
         {:ok, canonical} <-
           canonical_request(handle.descriptor, context, request, portable_payload) do
      execute_attempt(handle, context, request, portable_payload, pattern, canonical, 0)
    else
      {:error, :context} ->
        {:unavailable, :context}

      {:error, {:schema, reason}} ->
        {:refused, {:schema, reason}}

      _ ->
        {:refused, :invalid_request}
    end
  rescue
    _ -> {:refused, :invalid_request}
  catch
    _, _ -> {:refused, :invalid_request}
  end

  @doc "Release one retained ASK using fresh command-purpose evidence."
  def release(handle, context, identity, envelope) do
    with {:ok, handle} <- validate_handle_local(handle),
         {:ok, context} <- validate_context(context, handle.descriptor, :release),
         {:ok, identity} <- validate_identity(identity),
         true <- elem(identity, 0) == context.tenant and elem(identity, 1) == context.actor,
         {:ok, evidence} <-
           validate_evidence_envelope(
             envelope,
             context.tenant,
             handle.descriptor.approval.verifiers
           ),
         true <-
           elem(evidence.request, 0) == approval_owner(identity) and
             elem(evidence.request, 1) == elem(identity, 2) do
      release_attempt(handle, context, identity, envelope, 0)
    else
      {:error, :context} -> {:unavailable, :context}
      _ -> {:release_refused, :invalid_request}
    end
  rescue
    _ -> {:release_refused, :invalid_request}
  catch
    _, _ -> {:release_refused, :invalid_request}
  end

  @doc "Return a retained terminal or pending result within the exact identity scope."
  def result(handle, scope, identity) do
    with {:ok, scope} <- validate_result_scope(scope),
         {:ok, identity} <- validate_identity(identity),
         {:ok, handle} <- validate_handle_local(handle) do
      if elem(identity, 0) == scope.tenant and elem(identity, 1) == scope.actor do
        case read_history(handle.store, scope.tenant) do
          {:ok, history} ->
            case Map.get(history.receipts, identity) do
              nil -> {:unknown, :not_observed}
              receipt -> receipt.outcome
            end

          {:error, reason} ->
            history_error(reason)
        end
      else
        :not_found
      end
    else
      _ -> {:refused, :invalid_request}
    end
  rescue
    _ -> {:unknown, :storage}
  catch
    _, _ -> {:unknown, :storage}
  end

  @doc "Read one host-authorized resource snapshot."
  def resource(handle, scope, resource_id) do
    with {:ok, scope} <- validate_resource_scope(scope),
         {:ok, resource_id} <- identity(resource_id),
         true <- resource_id in scope.resources,
         {:ok, handle} <- validate_handle_local(handle) do
      case read_history(handle.store, scope.tenant) do
        {:ok, history} ->
          value = Map.get(history.resources, resource_id, %{revision: 0, fields: %{}})

          {:ok,
           %{
             tenant: scope.tenant,
             resource: resource_id,
             revision: value.revision,
             fields: value.fields
           }}

        {:error, reason} ->
          history_error(reason)
      end
    else
      false -> :not_found
      _ -> {:refused, :invalid_request}
    end
  rescue
    _ -> {:unknown, :storage}
  catch
    _, _ -> {:unknown, :storage}
  end

  defp execute_attempt(handle, context, request, portable_payload, pattern, canonical, reloads) do
    case read_history(handle.store, context.tenant) do
      {:ok, history} ->
        identity = {context.tenant, context.actor, request.operation_id}

        case Map.get(history.receipts, identity) do
          %{canonical: ^canonical, outcome: outcome} ->
            outcome

          %{canonical: _} ->
            {:conflict, :identity}

          nil ->
            if capacity?(history) do
              {:refused, :capacity}
            else
              case execute_new(
                     handle,
                     context,
                     request,
                     portable_payload,
                     pattern,
                     canonical,
                     history,
                     reloads
                   ) do
                :retry when reloads < 3 ->
                  execute_attempt(
                    handle,
                    context,
                    request,
                    portable_payload,
                    pattern,
                    canonical,
                    reloads + 1
                  )

                :retry ->
                  {:refused, :contended}

                outcome ->
                  outcome
              end
            end
        end

      {:error, :changed} when reloads < 3 ->
        execute_attempt(handle, context, request, portable_payload, pattern, canonical, reloads + 1)

      {:error, reason} ->
        history_error(reason)
    end
  end

  defp execute_new(handle, context, request, portable_payload, pattern, canonical, history, reloads) do
    case gate(handle.descriptor, pattern, context) do
      {:deny, code} ->
        retained(
          handle,
          context,
          request,
          portable_payload,
          canonical,
          history,
          nil,
          {:denied, {:gate, code}},
          :none,
          [],
          reloads
        )

      :allow ->
        snapshot = snapshot(context.tenant, request.resource, history)

        if snapshot.revision != request.expected_revision do
          retained(
            handle,
            context,
            request,
            portable_payload,
            canonical,
            history,
            nil,
            {:conflict, :stale_revision},
            :none,
            [],
            reloads
          )
        else
          prepare_and_decide(
            handle,
            context,
            request,
            portable_payload,
            canonical,
            pattern,
            history,
            snapshot,
            reloads
          )
        end
    end
  end

  defp prepare_and_decide(
         handle,
         context,
         request,
         portable_payload,
         canonical,
         _pattern,
         history,
         snapshot,
         reloads
       ) do
    case prepare(handle.descriptor, context, request, snapshot) do
      {:refused, code} ->
        retained(
          handle,
          context,
          request,
          portable_payload,
          canonical,
          history,
          nil,
          {:conflict, {:domain, code}},
          :none,
          [],
          reloads
        )

      :domain_failure ->
        retained(
          handle,
          context,
          request,
          portable_payload,
          canonical,
          history,
          nil,
          {:refused, :domain_failure},
          :none,
          [],
          reloads
        )

      {:ok, writes, response} ->
        proposal = proposal(context, handle.descriptor, request, portable_payload, writes)

        case Authorization.decide(context.policy, proposal, context.authority) do
          {:ok, %{verdict: :allow, permitted: ^writes} = decision} ->
            complete_mutation(
              handle,
              context,
              request,
              portable_payload,
              canonical,
              history,
              {writes, response},
              snapshot,
              decision,
              reloads
            )

          {:ok, %{verdict: :allow}} ->
            retained(
              handle,
              context,
              request,
              portable_payload,
              canonical,
              history,
              nil,
              {:refused, :domain_failure},
              :none,
              [],
              reloads
            )

          {:ok, %{verdict: :deny, reason: reason} = decision} ->
            retained(
              handle,
              context,
              request,
              portable_payload,
              canonical,
              history,
              {writes, response},
              {:denied, {:authorization, reason}},
              :none,
              [],
              reloads,
              decision
            )

          {:ok, %{verdict: :ask, requirement: %{scope: :once} = requirement} = decision} ->
            owner = approval_owner({context.tenant, context.actor, request.operation_id})

            case Approval.request(history.approval, owner, decision) do
              {:ok, _state, %{key: key}, event} when not is_nil(event) ->
                expected_key =
                  {owner, request.operation_id, requirement.name, requirement.version, 1}

                case approval_key(key) do
                  {:ok, ^expected_key} ->
                    result = {:approval_pending, %{key: key, requirement: requirement}}

                    retained(
                      handle,
                      context,
                      request,
                      portable_payload,
                      canonical,
                      history,
                      {writes, response},
                      result,
                      :none,
                      [event],
                      reloads,
                      decision
                    )

                  _ ->
                    {:unavailable, :context}
                end

              _ ->
                {:refused, :unsupported_approval_scope}
            end

          {:ok, %{verdict: :ask}} ->
            {:refused, :unsupported_approval_scope}

          {:error, {:unavailable_context, _}} ->
            {:unavailable, :context}

          _ ->
            retained(
              handle,
              context,
              request,
              portable_payload,
              canonical,
              history,
              nil,
              {:refused, :domain_failure},
              :none,
              [],
              reloads
            )
        end
    end
  end

  defp complete_mutation(
         handle,
         context,
         request,
         portable_payload,
         canonical,
         history,
         {writes, response},
         snapshot,
         decision,
         reloads
       ) do
    with :ok <- resource_capacity(history.resources, request.resource),
         {:ok, fields} <- apply_writes(snapshot.fields, writes),
         :ok <- resource_size(snapshot.revision + 1, fields) do
      resource_revision = snapshot.revision + 1
      result = {:completed, %{revision: resource_revision, response: response}}
      delta = {request.resource, snapshot.revision, resource_revision, writes}

      retained(
        handle,
        context,
        request,
        portable_payload,
        canonical,
        history,
        {writes, response},
        result,
        delta,
        [],
        reloads,
        decision
      )
    else
      _ -> {:refused, :capacity}
    end
  end

  defp retained(
         handle,
         context,
         request,
         portable_payload,
         canonical,
         history,
         prepared,
         outcome,
         delta,
         events,
         reloads
       ),
       do:
         retained(
           handle,
           context,
           request,
           portable_payload,
           canonical,
           history,
           prepared,
           outcome,
           delta,
           events,
           reloads,
           :none
         )

  defp retained(
         handle,
         context,
         request,
         portable_payload,
         canonical,
         history,
         prepared,
         outcome,
         delta,
         events,
         reloads,
         decision
       ) do
    identity = {context.tenant, context.actor, request.operation_id}
    descriptor = descriptor_identity(handle.descriptor)

    binding =
      if prepared, do: Codec.mutation_binding(canonical, elem(prepared, 0), elem(prepared, 1))

    prepared_record = if prepared, do: prepared, else: :none

    record = %{
      identity: identity,
      descriptor: descriptor,
      canonical: canonical,
      canonical_digest: :crypto.hash(:sha256, canonical),
      resource: request.resource,
      expected_revision: request.expected_revision,
      payload: request.payload,
      portable_payload: portable_payload,
      facts: context.facts,
      prepared: prepared_record,
      mutation_binding: binding,
      decision: decision,
      outcome: outcome,
      delta: delta,
      approval_events: events
    }

    append_record(handle, context, record, history, reloads)
  end

  defp append_record(handle, context, record, history, reloads) do
    with {:ok, payload} <- Codec.encode_record(record) do
      expected = history.revision
      target = expected + 1
      nonce = :crypto.strong_rand_bytes(16)

      row = %Record{
        stream: Codec.stream(context.tenant),
        sequence: target,
        kind: @kind,
        schema_version: @version,
        payload: payload,
        nonce: nonce
      }

      row = %{row | digest: Log.digest(row)}
      items = outbox_items(handle.descriptor, record, row)
      digest = StoreCodec.hash([Log.canonical_bytes(row)])

      request = %{
        operation: :append,
        stream: row.stream,
        expected: expected,
        target: target,
        nonce: nonce,
        digest: digest
      }

      case Store.write(handle.store, :append, [row.stream, expected, [row], items], request) do
        {:committed, ^target} -> record.outcome
        {:conflict, _} when reloads < 3 -> :retry
        {:conflict, _} -> {:refused, :contended}
        {:indeterminate, _} -> confirm_record(handle.store, row, expected, record.outcome)
        {:rejected, :caller_transaction} -> {:unknown, :storage}
        {:rejected, _} -> {:unknown, :storage}
      end
    else
      _ -> {:refused, :capacity}
    end
  rescue
    _ -> {:unknown, :storage}
  catch
    _, _ -> {:unknown, :storage}
  end

  defp confirm_record(store, row, expected, outcome) do
    case Log.confirm(store, row.stream, expected, row.nonce, [row]) do
      {:committed, _} -> outcome
      :superseded -> {:unknown, :not_observed}
      {:unknown, _} -> {:unknown, :unresolved}
      _ -> {:unknown, :storage}
    end
  rescue
    _ -> {:unknown, :storage}
  catch
    _, _ -> {:unknown, :storage}
  end

  defp release_attempt(handle, context, identity, envelope, reloads) do
    case read_history(handle.store, context.tenant) do
      {:ok, history} ->
        case Map.get(history.receipts, identity) do
          nil ->
            :not_found

          %{outcome: {:approval_pending, _}} = receipt ->
            if history.revision >= @max_records do
              {:release_refused, :capacity}
            else
              case release_pending(handle, context, identity, envelope, receipt, history, reloads) do
                :retry when reloads < 3 ->
                  release_attempt(handle, context, identity, envelope, reloads + 1)

                :retry ->
                  {:refused, :contended}

                outcome ->
                  outcome
              end
            end

          %{outcome: outcome} = receipt ->
            if receipt_bound?(handle, context, identity, receipt),
              do: outcome,
              else: {:release_refused, :binding_mismatch}
        end

      {:error, :changed} when reloads < 3 ->
        release_attempt(handle, context, identity, envelope, reloads + 1)

      {:error, reason} ->
        history_error(reason)
    end
  end

  defp receipt_bound?(handle, context, identity, receipt) do
    request = %{
      operation_id: elem(identity, 2),
      resource: receipt.resource,
      expected_revision: receipt.expected_revision,
      payload: receipt.payload
    }

    with true <- receipt.descriptor == descriptor_identity(handle.descriptor),
         true <- receipt.facts == context.facts,
         {:ok, portable_payload} <- json_payload(request.payload),
         true <- portable_payload == receipt.portable_payload,
         {:ok, canonical} <-
           canonical_request(handle.descriptor, context, request, portable_payload) do
      canonical == receipt.canonical
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp release_pending(handle, context, identity, envelope, receipt, history, reloads) do
    request = %{
      operation_id: elem(identity, 2),
      resource: receipt.resource,
      expected_revision: receipt.expected_revision,
      payload: receipt.payload
    }

    with {:ok, portable_payload} <- json_payload(request.payload),
         true <- portable_payload == receipt.portable_payload,
         {:ok, canonical} <-
           canonical_request(handle.descriptor, context, request, portable_payload),
         true <- canonical == receipt.canonical,
         :ok <- schema_check(handle.descriptor, request.payload),
         {:ok, pattern} <- gate_frame(handle.descriptor, request),
         {:ok, evidence} <-
           validate_evidence_envelope(
             envelope,
             context.tenant,
             handle.descriptor.approval.verifiers
           ),
         true <-
           elem(evidence.request, 0) == approval_owner(identity) and
             elem(evidence.request, 1) == elem(identity, 2) do
      case gate(handle.descriptor, pattern, context) do
        {:deny, code} ->
          {:release_refused, {:gate, code}}

        :allow ->
          snapshot = snapshot(context.tenant, receipt.resource, history)

          if snapshot.revision != receipt.expected_revision do
            append_stale_release(handle, context, receipt, history, reloads)
          else
            release_reprepared(
              handle,
              context,
              identity,
              evidence,
              request,
              portable_payload,
              receipt,
              history,
              snapshot,
              reloads
            )
          end
      end
    else
      false -> {:release_refused, :binding_mismatch}
      {:error, {:schema, reason}} -> {:release_refused, {:schema, reason}}
      _ -> {:release_refused, :invalid_request}
    end
  end

  defp release_reprepared(
         handle,
         context,
         identity,
         evidence,
         request,
         portable_payload,
         receipt,
         history,
         snapshot,
         reloads
       ) do
    case prepare(handle.descriptor, context, request, snapshot) do
      {:ok, writes, response} when receipt.prepared == {writes, response} ->
        release_approval(
          handle,
          context,
          identity,
          evidence,
          request,
          portable_payload,
          receipt,
          history,
          snapshot,
          writes,
          response,
          reloads
        )

      {:ok, _writes, _response} ->
        {:release_refused, :binding_mismatch}

      {:refused, code} ->
        {:release_refused, {:domain, code}}

      :domain_failure ->
        {:release_refused, :domain_failure}
    end
  end

  defp release_approval(
         handle,
         context,
         identity,
         evidence,
         request,
         portable_payload,
         receipt,
         history,
         snapshot,
         writes,
         response,
         reloads
       ) do
    proposal = proposal(context, handle.descriptor, request, portable_payload, writes)
    owner = approval_owner(identity)
    run = %{id: owner, root: owner, ancestry: []}

    approval_context = %{
      now: context.now,
      max_age: handle.descriptor.approval.max_age,
      verifiers: handle.descriptor.approval.verifiers,
      run: run,
      policy: context.policy,
      proposal: proposal,
      authority: context.authority,
      approver: context.approver
    }

    with {:ok, state} <- apply_revocations(history.approval, context.revoked),
         {:approval_pending, %{key: key}} <- receipt.outcome do
      case Approval.release(state, key, evidence, approval_context) do
        {:released, _next, ^writes, event} when not is_nil(event) ->
          next_revision = snapshot.revision + 1

          with :ok <- resource_capacity(history.resources, request.resource),
               {:ok, fields} <- apply_writes(snapshot.fields, writes),
               :ok <- resource_size(next_revision, fields) do
            result = {:completed, %{revision: next_revision, response: response}}
            delta = {request.resource, snapshot.revision, next_revision, writes}
            record = record_update(receipt, result, delta, [event])
            append_record(handle, context, record, history, reloads)
          else
            _ -> {:release_refused, :capacity}
          end

        {:released, _next, _other_writes, _event} ->
          {:release_refused, :binding_mismatch}

        {:refused, _reason, _state} ->
          {:release_refused, :evidence}

        {:error, _reason, _state} ->
          {:release_refused, :evidence}
      end
    else
      _ -> {:release_refused, :evidence}
    end
  end

  defp append_stale_release(handle, context, receipt, history, reloads) do
    record = record_update(receipt, {:conflict, :stale_revision}, :none, [])
    append_record(handle, context, record, history, reloads)
  end

  defp record_update(receipt, outcome, delta, events) do
    %{
      identity: receipt.identity,
      descriptor: receipt.descriptor,
      canonical: receipt.canonical,
      canonical_digest: receipt.canonical_digest,
      resource: receipt.resource,
      expected_revision: receipt.expected_revision,
      payload: receipt.payload,
      portable_payload: receipt.portable_payload,
      facts: receipt.facts,
      prepared: receipt.prepared,
      mutation_binding: receipt.mutation_binding,
      decision: receipt.decision,
      outcome: outcome,
      delta: delta,
      approval_events: events
    }
  end

  defp read_history(store, tenant) do
    stream = Codec.stream(tenant)

    with %{append_visibility: :atomic} <- Store.read(store, :capabilities, []),
         {:ok, head} <- Store.read(store, :head, [stream]),
         true <- head.low_water == 0,
         true <- head.revision <= @max_records,
         {:ok, rows, stable_head} <- read_pages(store, stream, head.revision),
         true <- stable_head.revision == head.revision and stable_head.low_water == 0,
         {:ok, same_head} <- Store.read(store, :head, [stream]),
         true <- same_head.revision == head.revision and same_head.low_water == 0,
         true <- length(rows) == head.revision,
         {:ok, history} <- replay_rows(rows, head.revision, tenant) do
      {:ok, %{history | revision: head.revision}}
    else
      false -> {:error, :malformed}
      {:error, :changed} -> {:error, :changed}
      {:error, {:pruned, _}} -> {:error, :malformed}
      {:error, :unavailable} -> {:error, :storage}
      {:error, :caller_transaction} -> {:error, :storage}
      {:error, :malformed} -> {:error, :malformed}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :storage}
  end

  defp read_pages(_store, _stream, 0), do: {:ok, [], %{revision: 0, low_water: 0}}

  defp read_pages(store, stream, revision) do
    read_pages(store, stream, 1, revision, nil, [])
  end

  defp read_pages(_store, _stream, from, revision, head, rows) when from > revision,
    do: {:ok, rows, head || %{revision: 0, low_water: 0}}

  defp read_pages(store, stream, from, revision, head, rows) do
    limit = min(@page_size, revision - from + 1)

    case Log.read(store, stream, from, limit) do
      {:ok, page, page_head} ->
        stable = %{revision: page_head.revision, low_water: page_head.low_water}

        with {:ok, page_length} <- bounded_list_length(page, limit),
             true <-
               (head == nil or head == stable) and page_head.revision == revision and
                 page_head.low_water == 0 and page_length > 0 do
          read_pages(store, stream, from + page_length, revision, stable, rows ++ page)
        else
          _ -> {:error, :changed}
        end

      {:error, :unavailable} ->
        {:error, :storage}

      _ ->
        {:error, :malformed}
    end
  end

  defp replay_rows(rows, revision, tenant) do
    initial = %{resources: %{}, receipts: %{}, approval: Approval.new(), operations: 0, revision: 0}

    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, initial}, fn {row, sequence}, {:ok, state} ->
      with true <- row_sequence(row) == sequence,
           true <- row_stream(row) == Codec.stream(tenant),
           :ok <- validate_log_row(row),
           {:ok, record} <- Codec.decode_record(row.payload),
           :ok <- validate_record(record, tenant),
           {:ok, next} <- apply_record(state, record) do
        {:cont, {:ok, %{next | revision: sequence}}}
      else
        _ -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, %{revision: ^revision} = state} -> {:ok, state}
      _ -> {:error, :malformed}
    end
  end

  defp validate_log_row(row) do
    row = row_map(row)

    if exact_map_keys?(row, [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]) do
      Log.validate_row(row, @fold, %{max_record_bytes: @max_record_bytes})
    else
      {:error, :malformed_row}
    end
  rescue
    _ -> {:error, :malformed_row}
  end

  defp row_sequence(%Record{sequence: n}), do: n
  defp row_sequence(%{sequence: n}), do: n
  defp row_sequence(_), do: nil

  defp row_stream(%Record{stream: stream}), do: stream
  defp row_stream(%{stream: stream}), do: stream
  defp row_stream(_), do: nil

  defp row_map(%Record{} = row), do: Map.from_struct(row)
  defp row_map(row) when is_map(row) and not is_struct(row), do: row
  defp row_map(_), do: %{}

  defp validate_record(record, tenant) do
    with {:ok, identity} <- validate_identity(record.identity),
         true <- elem(identity, 0) == tenant,
         {:ok, {descriptor_id, descriptor_version, descriptor_hash}} <-
           valid_descriptor_identity(record.descriptor),
         {:ok, resource} <- identity(record.resource),
         true <- uint?(record.expected_revision, 0, @max_expected_revision),
         {:ok, portable_payload} <- json_payload(record.payload),
         true <- portable_payload == record.portable_payload,
         {:ok, facts} <- portable_value(record.facts),
         true <- facts == record.facts,
         {:ok, canonical} <-
           Codec.canonical_request(
             elem(identity, 0),
             elem(identity, 1),
             elem(identity, 2),
             {descriptor_id, descriptor_version, descriptor_hash},
             resource,
             record.expected_revision,
             portable_payload,
             facts
           ),
         true <- canonical == record.canonical,
         true <- record.canonical_digest == :crypto.hash(:sha256, record.canonical),
         :ok <- valid_prepared(record.prepared, record.mutation_binding, canonical, resource),
         :ok <-
           valid_decision(
             record.decision,
             record.prepared,
             identity,
             resource,
             portable_payload
           ),
         :ok <- valid_outcome(record.outcome, record.prepared, record.delta, record.decision),
         :ok <- valid_delta(record.delta, record.prepared, resource, record.expected_revision),
         {:ok, _event_count} <- bounded_list_length(record.approval_events, 2) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp apply_record(state, record) do
    identity = record.identity

    with {:ok, approval} <- apply_events(state.approval, record.approval_events),
         {:ok, resources} <- apply_delta(state.resources, record.delta) do
      case Map.get(state.receipts, identity) do
        nil ->
          with :ok <- valid_initial_events(record, record.approval_events),
               true <- state.operations < @max_operations do
            receipt = receipt(record)

            {:ok,
             %{
               state
               | resources: resources,
                 receipts: Map.put(state.receipts, identity, receipt),
                 approval: approval,
                 operations: state.operations + 1
             }}
          else
            _ -> {:error, :malformed}
          end

        %{outcome: {:approval_pending, _}} = prior ->
          if prior.canonical == record.canonical and prior.descriptor == record.descriptor and
               prior.prepared == record.prepared and
               valid_release_transition?(record, prior, state.resources, state.approval) do
            {:ok,
             %{
               state
               | resources: resources,
                 receipts: Map.put(state.receipts, identity, receipt(record)),
                 approval: approval
             }}
          else
            {:error, :malformed}
          end

        _ ->
          {:error, :malformed}
      end
    end
  end

  defp apply_events(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
      case Approval.apply_event(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp valid_initial_events(
         %{outcome: {:approval_pending, %{key: key, requirement: requirement} = pending}} = record,
         [{:requested, request}]
       )
       when is_map(request) and map_size(request) == 3 do
    with true <- map_size(pending) == 2,
         {:ok, key} <- approval_key(key),
         {:ok, requirement} <- Authorization.validate_requirement(requirement),
         {tenant, actor, operation_id} <- record.identity,
         true <-
           key ==
             {approval_owner(record.identity), operation_id, requirement.name, requirement.version,
              1},
         true <- request.key == key and request.status == :open,
         binding when is_map(binding) and not is_struct(binding) <- request.binding,
         true <- exact_map_keys?(binding, [:action, :escrowed, :policy, :requirement]),
         {:ok, action} <- Authorization.validate_action(binding.action),
         {:ok, _} <- Authorization.validate_identity(binding.policy),
         decision when is_map(decision) <- record.decision,
         {writes, _response} <- record.prepared,
         true <- decision.verdict == :ask and decision.action == action,
         true <- decision.policy == binding.policy and decision.escrowed == binding.escrowed,
         true <- decision.requirement == requirement,
         true <- binding.requirement == requirement and binding.escrowed == writes,
         true <- action.proposer == actor and action.tenant == tenant,
         true <- action.resource == record.resource and action.action_id == operation_id,
         true <- action.payload == record.portable_payload and action.writes == writes,
         {:ok, _state, expected_request, expected_event} <-
           Approval.request(Approval.new(), approval_owner(record.identity), decision),
         true <- expected_request == request and expected_event == {:requested, request} do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_initial_events(%{outcome: {:approval_pending, _}}, _), do: {:error, :malformed}
  defp valid_initial_events(%{decision: %{verdict: :ask}}, []), do: {:error, :malformed}
  defp valid_initial_events(_record, []), do: :ok
  defp valid_initial_events(_, _), do: {:error, :malformed}

  defp valid_release_transition?(record, prior, resources, approval_state) do
    case {record.outcome, record.delta, record.approval_events, prior.outcome} do
      {{:completed, %{revision: revision, response: response}},
       {resource, old_revision, new_revision, writes}, [{:released, release, nil}],
       {:approval_pending, %{key: key, requirement: requirement}}} ->
        owner = approval_owner(prior.identity)
        {prepared_writes, prepared_response} = prior.prepared
        decision = prior.decision
        binding = release.binding
        evidence = release.evidence
        approval_view = Approval.inspect_state(approval_state)

        expected_binding = %{
          action: decision.action,
          escrowed: decision.escrowed,
          policy: decision.policy,
          requirement: decision.requirement
        }

        open_request =
          Enum.any?(approval_view.requests, fn request ->
            request.key == key and request.status == :open and request.binding == expected_binding
          end)

        record.resource == prior.resource and resource == prior.resource and
          record.decision == decision and
          record.expected_revision == prior.expected_revision and
          old_revision == prior.expected_revision and new_revision == old_revision + 1 and
          revision == new_revision and response == prepared_response and
          writes == prepared_writes and release.key == key and
          release.writes == prepared_writes and binding == expected_binding and
          binding.requirement == requirement and binding.escrowed == prepared_writes and
          release.run == owner and release.root == owner and evidence.request == key and
          evidence.decision == :approve and evidence.scope == :once and
          open_request and not Enum.any?(approval_view.releases, &(&1.key == key)) and
          {evidence.verifier, evidence.evidence_id} not in approval_view.consumed

      {{:conflict, :stale_revision}, :none, [], {:approval_pending, _}} ->
        current = Map.get(resources, record.resource, %{revision: 0, fields: %{}})

        record.decision == prior.decision and record.resource == prior.resource and
          record.expected_revision == prior.expected_revision and
          current.revision != prior.expected_revision

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp apply_delta(resources, :none), do: {:ok, resources}

  defp apply_delta(resources, {resource, old_revision, new_revision, writes}) do
    current = Map.get(resources, resource, %{revision: 0, fields: %{}})

    with true <- current.revision == old_revision and new_revision == old_revision + 1,
         {:ok, fields} <- apply_writes(current.fields, writes),
         :ok <- resource_size(new_revision, fields),
         true <- Map.has_key?(resources, resource) or map_size(resources) < @max_resources do
      {:ok, Map.put(resources, resource, %{revision: new_revision, fields: fields})}
    else
      _ -> {:error, :malformed}
    end
  end

  defp apply_delta(_, _), do: {:error, :malformed}

  defp receipt(record) do
    %{
      identity: record.identity,
      descriptor: record.descriptor,
      canonical: record.canonical,
      canonical_digest: record.canonical_digest,
      resource: record.resource,
      expected_revision: record.expected_revision,
      payload: record.payload,
      portable_payload: record.portable_payload,
      facts: record.facts,
      prepared: record.prepared,
      mutation_binding: record.mutation_binding,
      decision: record.decision,
      outcome: record.outcome
    }
  end

  defp valid_prepared(:none, nil, _canonical, _resource), do: :ok

  defp valid_prepared({writes, response}, binding, canonical, resource) do
    with {:ok, normalized} <- normalize_writes(writes, resource),
         true <- normalized == writes,
         {:ok, value} <- portable_value(response),
         true <- value == response,
         true <- binding == Codec.mutation_binding(canonical, writes, response),
         true <-
           byte_size(:erlang.term_to_binary(response, [:deterministic])) <= @max_response_bytes do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_prepared(_, _, _, _), do: {:error, :malformed}

  defp valid_decision(:none, _prepared, _identity, _resource, _portable_payload), do: :ok

  defp valid_decision(decision, prepared, identity, resource, portable_payload)
       when is_map(decision) and not is_struct(decision) do
    with true <-
           exact_map_keys?(
             decision,
             [:verdict, :reason, :policy, :action, :permitted, :escrowed, :requirement, :rules]
           ),
         true <- decision.verdict in [:allow, :ask, :deny],
         {:ok, _} <- Authorization.validate_identity(decision.policy),
         {:ok, permitted} <- Authorization.validate_writes(decision.permitted, 0),
         true <- permitted == decision.permitted,
         {:ok, escrowed} <- Authorization.validate_writes(decision.escrowed, 0),
         true <- escrowed == decision.escrowed,
         :ok <- valid_decision_requirement(decision.requirement),
         {:ok, _rule_count} <- bounded_list_length(decision.rules, Authorization.bounds().rules),
         true <-
           Enum.all?(decision.rules, fn rule ->
             match?({:ok, _}, Authorization.identity_field(rule, :rule_id, :invalid_input))
           end),
         :ok <- valid_decision_action(decision, prepared, identity, resource, portable_payload),
         :ok <- valid_decision_shape(decision) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp valid_decision(_, _, _, _, _), do: {:error, :malformed}

  defp valid_decision_requirement(nil), do: :ok

  defp valid_decision_requirement(requirement) do
    case Authorization.validate_requirement(requirement) do
      {:ok, ^requirement} -> :ok
      _ -> {:error, :malformed}
    end
  end

  defp valid_decision_action(%{action: nil} = decision, _prepared, _identity, _resource, _payload) do
    if decision.verdict == :deny and match?({:control_field, _}, decision.reason) and
         decision.permitted == [] and decision.escrowed == [] and decision.requirement == nil and
         decision.rules == [],
       do: :ok,
       else: {:error, :malformed}
  end

  defp valid_decision_action(decision, prepared, identity, resource, portable_payload) do
    with {:ok, action} <- Authorization.validate_action(decision.action),
         {writes, _response} <- prepared,
         true <- action.tenant == elem(identity, 0),
         true <- action.proposer == elem(identity, 1),
         true <- action.action_id == elem(identity, 2),
         true <- action.resource == resource,
         true <- action.payload == portable_payload,
         true <- action.writes == writes do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_decision_shape(%{verdict: :allow} = decision) do
    if decision.reason == :allowed and decision.requirement == nil and decision.escrowed == [] and
         is_map(decision.action) and decision.permitted == decision.action.writes,
       do: :ok,
       else: {:error, :malformed}
  end

  defp valid_decision_shape(%{verdict: :ask} = decision) do
    if decision.reason == {:ask, decision.requirement} and
         match?(%{scope: :once}, decision.requirement) and is_map(decision.action) and
         decision.permitted == [] and decision.escrowed == decision.action.writes,
       do: :ok,
       else: {:error, :malformed}
  end

  defp valid_decision_shape(%{verdict: :deny} = decision) do
    with :ok <- valid_authorization_reason(decision.reason),
         true <-
           decision.permitted == [] and decision.escrowed == [] and decision.requirement == nil,
         true <- decision.action != nil or match?({:control_field, _}, decision.reason) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_authorization_reason(:no_matching_rule), do: :ok
  defp valid_authorization_reason(:authority_exceeded), do: :ok

  defp valid_authorization_reason({:rule, rule}) do
    case Authorization.identity_field(rule, :rule_id, :invalid_input) do
      {:ok, _} -> :ok
      _ -> {:error, :malformed}
    end
  end

  defp valid_authorization_reason({:control_field, key}) do
    if key in Authorization.control_keys(), do: :ok, else: {:error, :malformed}
  end

  defp valid_authorization_reason(_), do: {:error, :malformed}

  defp valid_outcome(
         {:completed, %{revision: revision, response: response} = result},
         prepared,
         delta,
         decision
       ) do
    with true <- map_size(result) == 2,
         true <- uint?(revision, 1, @max_i64),
         true <- prepared != :none,
         true <- match?({_, ^response}, prepared),
         true <- match?({_, _, ^revision, _}, delta),
         true <- decision_verdict?(decision, [:allow, :ask]),
         {:ok, portable_response} <- portable_value(response),
         true <- portable_response == response do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_outcome(
         {:approval_pending, %{key: key, requirement: req} = pending},
         prepared,
         :none,
         %{verdict: :ask, requirement: req}
       ) do
    with true <- prepared != :none,
         true <- map_size(pending) == 2,
         {:ok, _} <- approval_key(key),
         {:ok, req} <- Authorization.validate_requirement(req),
         true <- req.scope == :once do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_outcome({:denied, {:gate, code}}, _prepared, :none, :none), do: valid_code(code)

  defp valid_outcome(
         {:denied, {:authorization, reason}},
         prepared,
         :none,
         %{verdict: :deny, reason: reason}
       )
       when prepared != :none,
       do: valid_authorization_reason(reason)

  defp valid_outcome({:conflict, :stale_revision}, _prepared, :none, decision),
    do:
      if(decision == :none or decision_verdict?(decision, [:ask]),
        do: :ok,
        else: {:error, :malformed}
      )

  defp valid_outcome({:conflict, {:domain, code}}, :none, :none, :none), do: valid_code(code)
  defp valid_outcome({:refused, :domain_failure}, _prepared, :none, :none), do: :ok
  defp valid_outcome(_, _, _, _), do: {:error, :malformed}

  defp decision_verdict?(%{verdict: verdict}, allowed), do: verdict in allowed
  defp decision_verdict?(_, _), do: false

  defp valid_delta(:none, _prepared, _resource, _expected), do: :ok

  defp valid_delta(
         {delta_resource, old_revision, new_revision, delta_writes},
         {prepared_writes, _response},
         resource,
         expected
       ) do
    if delta_resource == resource and delta_writes == prepared_writes and old_revision == expected and
         new_revision == old_revision + 1 and new_revision <= @max_i64,
       do: :ok,
       else: {:error, :malformed}
  end

  defp valid_delta(_, _, _, _), do: {:error, :malformed}

  defp history_error(:storage), do: {:unknown, :storage}
  defp history_error(_), do: {:unknown, :unresolved}

  defp capacity?(history),
    do: history.operations >= @max_operations or history.revision >= @max_records

  defp snapshot(tenant, resource, history) do
    current = Map.get(history.resources, resource, %{revision: 0, fields: %{}})
    %{tenant: tenant, resource: resource, revision: current.revision, fields: current.fields}
  end

  defp gate(descriptor, pattern, context) do
    frame_context = %{
      proposer: context.actor,
      effect_class: descriptor.effect_class,
      tenant: context.tenant
    }

    try do
      case descriptor.gate.call.(pattern, frame_context) do
        :allow -> :allow
        {:deny, code} -> {:deny, if(valid_code(code) == :ok, do: code, else: "gate_failure")}
        _ -> {:deny, "gate_failure"}
      end
    rescue
      _ -> {:deny, "gate_failure"}
    catch
      _, _ -> {:deny, "gate_failure"}
    end
  end

  defp prepare(descriptor, context, request, snapshot) do
    facts = %{tenant: context.tenant, actor: context.actor, data: context.facts}

    try do
      case descriptor.prepare.(snapshot, request, facts) do
        {:ok, writes, response} ->
          with {:ok, writes} <- normalize_writes(writes, request.resource),
               {:ok, response} <- portable_value(response),
               true <-
                 byte_size(:erlang.term_to_binary(response, [:deterministic])) <=
                   @max_response_bytes do
            {:ok, writes, response}
          else
            _ -> :domain_failure
          end

        {:refused, code} ->
          if valid_code(code) == :ok, do: {:refused, code}, else: :domain_failure

        _ ->
          :domain_failure
      end
    rescue
      _ -> :domain_failure
    catch
      _, _ -> :domain_failure
    end
  end

  defp proposal(context, descriptor, request, portable_payload, writes) do
    %{
      tenant: context.tenant,
      resource: request.resource,
      action_id: request.operation_id,
      payload: portable_payload,
      writes: writes,
      proposer: context.actor,
      effect_class: descriptor.effect_class
    }
  end

  defp gate_frame(descriptor, request) do
    frame = %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => request.operation_id,
          "kind" => "local_work",
          "schema_id" => descriptor.port["schema_id"],
          "schema_version" => descriptor.port["schema_version"],
          "payload" => request.payload
        }
      ]
    }

    case PatternStep.decode(frame) do
      {:ok, checked} ->
        {:ok, checked}

      _ ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp schema_check(descriptor, payload) do
    case PayloadSchema.check(descriptor.schema, descriptor.port, payload) do
      :ok -> :ok
      {:error, {:violations, _}} -> {:error, {:schema, :schema_mismatch}}
      {:error, reason} -> {:error, {:schema, reason}}
    end
  end

  defp canonical_request(descriptor, context, request, portable_payload) do
    Codec.canonical_request(
      context.tenant,
      context.actor,
      request.operation_id,
      descriptor_identity(descriptor),
      request.resource,
      request.expected_revision,
      portable_payload,
      context.facts
    )
  end

  defp validate_context(context, descriptor, mode)
       when is_map(context) and not is_struct(context) do
    required =
      [:tenant, :actor, :policy, :own, :parent, :facts] ++
        if(mode == :release, do: [:approver, :now, :revoked], else: [])

    with true <- exact_keys?(context, required, []),
         {:ok, tenant} <- identity(context.tenant),
         {:ok, actor} <- identity(context.actor),
         {:ok, facts} <- portable_value(context.facts),
         {:ok, policy} <- Authorization.validate_policy(context.policy),
         :ok <- command_approval_requirements(policy),
         {:ok, authority} <-
           Authorization.validate_context(
             %{
               proposer: actor,
               effect_class: descriptor.effect_class,
               own: context.own,
               parent: context.parent
             },
             policy
           ),
         :ok <- release_context(context, mode) do
      {:ok,
       Map.merge(context, %{
         tenant: tenant,
         actor: actor,
         facts: facts,
         policy: policy,
         authority: authority
       })}
    else
      _ -> {:error, :context}
    end
  end

  defp validate_context(_, _, _), do: {:error, :context}

  defp command_approval_requirements(%{rules: rules}) do
    if Enum.all?(rules, fn
         %{verdict: :ask, requirement: %{scope: :once, name: name, version: version}} ->
           match?({:ok, _}, identity(name)) and uint?(version, 1, 2_147_483_647)

         _ ->
           true
       end) do
      :ok
    else
      {:error, :context}
    end
  end

  defp release_context(_context, :execute), do: :ok

  defp release_context(context, :release) do
    approver = context.approver

    with true <- is_map(approver) and not is_struct(approver),
         true <- exact_keys?(approver, [:identity, :authority], []),
         {:ok, _} <- identity(approver.identity),
         {:ok, _} <- Authorization.validate_authority(approver.authority),
         true <- uint?(context.now, 0, @max_i64),
         true <- valid_revocations?(context.revoked) do
      :ok
    else
      _ -> {:error, :context}
    end
  end

  defp valid_revocations?(list) when is_list(list) do
    case bounded_list_length(list, 256) do
      {:ok, count} ->
        count == length(Enum.uniq(list)) and
          Enum.all?(list, fn
            {verifier, evidence_id} ->
              match?({:ok, _}, identity(verifier)) and match?({:ok, _}, identity(evidence_id))

            _ ->
              false
          end)

      _ ->
        false
    end
  end

  defp valid_revocations?(_), do: false

  defp validate_request(request) when is_map(request) and not is_struct(request) do
    with true <- exact_keys?(request, [:operation_id, :resource, :expected_revision, :payload], []),
         {:ok, operation_id} <- identity(request.operation_id),
         {:ok, resource} <- identity(request.resource),
         true <- uint?(request.expected_revision, 0, @max_expected_revision),
         {:ok, _portable} <- json_payload(request.payload) do
      {:ok,
       %{
         operation_id: operation_id,
         resource: resource,
         expected_revision: request.expected_revision,
         payload: request.payload
       }}
    else
      _ ->
        {:error, :invalid_request}
    end
  end

  defp validate_request(_), do: {:error, :invalid_request}

  defp validate_descriptor(descriptor) when is_map(descriptor) and not is_struct(descriptor) do
    required = [
      :id,
      :version,
      :content_hash,
      :effect_class,
      :port,
      :schema,
      :prepare,
      :gate,
      :approval
    ]

    with true <- exact_keys?(descriptor, required, [:outbox]),
         {:ok, _} <- identity(descriptor.id),
         true <- uint?(descriptor.version, 1, 2_147_483_647),
         true <- is_binary(descriptor.content_hash) and byte_size(descriptor.content_hash) == 32,
         {:ok, _} <- identity(descriptor.effect_class),
         {:ok, {:Descriptor, _, _, _, _}} <- Elzoo.Port.decode(descriptor.port),
         true <- is_function(descriptor.prepare, 3),
         true <- valid_gate?(descriptor.gate),
         true <- valid_approval?(descriptor.approval),
         true <- valid_outbox?(Map.get(descriptor, :outbox)),
         true <- schema_boundary?(descriptor.schema, descriptor.port) do
      :ok
    else
      _ -> {:error, :invalid_descriptor}
    end
  rescue
    _ -> {:error, :invalid_descriptor}
  catch
    _, _ -> {:error, :invalid_descriptor}
  end

  defp validate_descriptor(_), do: {:error, :invalid_descriptor}

  defp schema_boundary?(schema, port) do
    case PayloadSchema.check(schema, port, nil) do
      :ok -> true
      {:error, {:violations, violations}} when is_list(violations) -> true
      _ -> false
    end
  end

  defp valid_gate?(gate) when is_map(gate) and not is_struct(gate),
    do: exact_keys?(gate, [:call], []) and is_function(gate.call, 2)

  defp valid_gate?(_), do: false

  defp valid_approval?(approval) when is_map(approval) and not is_struct(approval) do
    with true <- exact_keys?(approval, [:verifiers, :max_age], []),
         true <- is_list(approval.verifiers),
         {:ok, verifier_count} <- bounded_list_length(approval.verifiers, 64),
         true <- verifier_count in 1..64,
         true <- Enum.all?(approval.verifiers, &match?({:ok, _}, identity(&1))),
         true <- uint?(approval.max_age, 1, @max_i64) do
      true
    else
      _ -> false
    end
  end

  defp valid_approval?(_), do: false

  defp valid_outbox?(nil), do: true
  defp valid_outbox?(destination), do: StoreCodec.destination?(destination)

  defp validate_store({module, config}) when is_atom(module) and not is_struct(config), do: :ok
  defp validate_store(_), do: {:error, :store}

  defp validate_handle_local(%Handle{store: store, descriptor: descriptor} = handle) do
    if exact_map_keys?(Map.from_struct(handle), [:store, :descriptor]) and
         validate_store(store) == :ok and validate_descriptor(descriptor) == :ok do
      {:ok, handle}
    else
      {:error, :invalid_handle}
    end
  end

  defp validate_handle_local(_), do: {:error, :invalid_handle}

  defp validate_identity({tenant, actor, operation_id}) do
    with {:ok, tenant} <- identity(tenant),
         {:ok, actor} <- identity(actor),
         {:ok, operation_id} <- identity(operation_id) do
      {:ok, {tenant, actor, operation_id}}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp validate_identity(_), do: {:error, :invalid_identity}

  defp validate_result_scope(scope) when is_map(scope) and not is_struct(scope) do
    with true <- exact_keys?(scope, [:tenant, :actor], []),
         {:ok, tenant} <- identity(scope.tenant),
         {:ok, actor} <- identity(scope.actor) do
      {:ok, %{tenant: tenant, actor: actor}}
    else
      _ -> {:error, :scope}
    end
  end

  defp validate_result_scope(_), do: {:error, :scope}

  defp validate_resource_scope(scope) when is_map(scope) and not is_struct(scope) do
    with true <- exact_keys?(scope, [:tenant, :actor, :resources], []),
         {:ok, tenant} <- identity(scope.tenant),
         {:ok, actor} <- identity(scope.actor),
         true <- is_list(scope.resources),
         {:ok, count} <- bounded_list_length(scope.resources, @max_resources),
         {:ok, resources} <- normalize_id_list(scope.resources),
         true <- count == length(resources) do
      {:ok, %{tenant: tenant, actor: actor, resources: resources}}
    else
      _ -> {:error, :scope}
    end
  end

  defp validate_resource_scope(_), do: {:error, :scope}

  defp normalize_id_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case identity(value) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        _ -> {:halt, {:error, :identity}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp validate_evidence_envelope(
         %{purpose: :command, tenant: tenant, evidence: evidence} = envelope,
         expected,
         verifiers
       )
       when map_size(envelope) == 3 and is_map(evidence) and not is_struct(evidence) do
    required = [
      :verifier,
      :evidence_id,
      :reviewer,
      :request,
      :decision,
      :scope,
      :issued_at,
      :expiry
    ]

    with true <- exact_keys?(evidence, required, []),
         {:ok, tenant} <- identity(tenant),
         true <- tenant == expected,
         {:ok, verifier} <- identity(evidence.verifier),
         true <- verifier in verifiers,
         {:ok, _} <- identity(evidence.evidence_id),
         {:ok, _} <- identity(evidence.reviewer),
         {:ok, _} <- approval_key(evidence.request),
         true <- evidence.decision in [:approve, :reject],
         true <- evidence.scope == :once,
         true <- uint?(evidence.issued_at, 0, @max_i64),
         true <- uint?(evidence.expiry, 0, @max_i64) and evidence.expiry > evidence.issued_at do
      {:ok, evidence}
    else
      _ -> {:error, :evidence}
    end
  end

  defp validate_evidence_envelope(_, _, _), do: {:error, :evidence}

  defp approval_key({owner, action_id, requirement, version, revision}) do
    with {:ok, owner} <- identity(owner),
         {:ok, action_id} <- identity(action_id),
         {:ok, requirement} <- identity(requirement),
         true <- uint?(version, 1, 2_147_483_647),
         true <- uint?(revision, 1, 2_147_483_647) do
      {:ok, {owner, action_id, requirement, version, revision}}
    else
      _ -> {:error, :evidence}
    end
  end

  defp approval_key(_), do: {:error, :evidence}

  defp apply_revocations(state, revoked) do
    Enum.reduce_while(revoked, {:ok, state}, fn key, {:ok, current} ->
      case Approval.revoke(current, key) do
        {:ok, next, _event} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :revocation}}
      end
    end)
  end

  defp descriptor_identity(descriptor),
    do: {descriptor.id, descriptor.version, descriptor.content_hash}

  defp approval_owner({tenant, actor, operation_id}) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:checked_command_owner, 1, tenant, actor, operation_id}, [
          :deterministic
        ])
      )

    "command:" <> Base.encode16(digest, case: :lower)
  end

  defp outbox_items(%{outbox: destination}, %{delta: delta, identity: identity}, row)
       when is_binary(destination) and delta != :none do
    {resource, _old_revision, new_revision, _writes} = delta
    {tenant, actor, operation_id} = identity

    notification = %{
      "type" => "checked_command",
      "version" => 1,
      "tenant" => tenant,
      "actor" => actor,
      "operation_id" => operation_id,
      "resource" => resource,
      "revision" => new_revision
    }

    payload = Jason.encode!(notification)

    item = %{
      stream: row.stream,
      sequence: row.sequence,
      position: 1,
      destination: destination,
      payload: payload,
      nonce: row.nonce,
      state: :pending,
      ack_nonce: nil,
      ack_digest: nil,
      idempotency_key: StoreCodec.item_key(row.stream, row.sequence, 1)
    }

    [Map.put(item, :digest, StoreCodec.hash(StoreCodec.item_bytes(item)))]
  end

  defp outbox_items(_, _, _), do: []

  defp apply_writes(fields, writes) when is_map(fields) and is_list(writes) do
    next = Enum.reduce(writes, fields, fn write, acc -> Map.put(acc, write.field, write.value) end)

    if map_size(next) <= @max_fields and
         Enum.all?(Map.keys(next), &match?({:ok, _}, field_name(&1))) do
      {:ok, next}
    else
      {:error, :capacity}
    end
  end

  defp apply_writes(_, _), do: {:error, :invalid_writes}

  defp resource_size(revision, fields) do
    bytes = :erlang.term_to_binary(%{revision: revision, fields: fields}, [:deterministic])

    if map_size(fields) <= @max_fields and byte_size(bytes) <= @max_resource_bytes,
      do: :ok,
      else: {:error, :capacity}
  rescue
    _ -> {:error, :capacity}
  end

  defp resource_capacity(resources, resource) do
    if Map.has_key?(resources, resource) or map_size(resources) < @max_resources,
      do: :ok,
      else: {:error, :capacity}
  end

  defp normalize_writes(writes, resource) when is_list(writes) do
    with {:ok, _count} <- bounded_list_length(writes, Authorization.bounds().authority),
         {:ok, normalized} <- Authorization.validate_authority(writes),
         true <- length(normalized) in 1..@max_writes,
         {:ok, canonical} <- Authorization.validate_writes(normalized),
         true <- canonical == normalized,
         true <- Enum.all?(canonical, &match?({:ok, _}, field_name(&1.field))),
         true <- Enum.all?(canonical, &(&1.target == resource)) do
      {:ok, normalized}
    else
      _ -> {:error, :writes}
    end
  end

  defp normalize_writes(_, _), do: {:error, :writes}

  defp portable_value(value) do
    with {:ok, _nodes} <- bounded_value(value, 1, 0),
         {:ok, normalized} <- Authorization.validate_value(value) do
      {:ok, normalized}
    else
      _ -> {:error, :portable}
    end
  rescue
    _ -> {:error, :portable}
  catch
    _, _ -> {:error, :portable}
  end

  defp json_payload(value) do
    with {:ok, _nodes} <- bounded_value(value, 1, 0),
         {:ok, portable} <- json_value(value, 1),
         {:ok, normalized} <- Authorization.validate_value(portable) do
      {:ok, normalized}
    else
      _ -> {:error, :portable}
    end
  rescue
    _ -> {:error, :portable}
  catch
    _, _ -> {:error, :portable}
  end

  defp json_value(_value, depth) when depth > @max_value_depth, do: {:error, :portable}

  defp json_value(value, _depth) when is_nil(value) or is_boolean(value) or is_integer(value),
    do: {:ok, value}

  defp json_value(value, _depth) when is_binary(value),
    do: if(String.valid?(value), do: {:ok, {:text, value}}, else: {:error, :portable})

  defp json_value(value, depth)
       when is_map(value) and not is_struct(value) and depth < @max_value_depth do
    pairs = Map.to_list(value)

    if Enum.all?(pairs, fn {key, _} -> is_binary(key) and String.valid?(key) end) do
      Enum.sort_by(pairs, &elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {key, child}, {:ok, acc} ->
        case json_value(child, depth + 1) do
          {:ok, normalized} -> {:cont, {:ok, [{key, normalized} | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fields} -> {:ok, {:record, Enum.reverse(fields)}}
        error -> error
      end
    else
      {:error, :portable}
    end
  end

  defp json_value(value, depth) when is_list(value) and depth < @max_value_depth do
    if proper_list?(value) do
      Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
        case json_value(child, depth + 1) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, {:list, Enum.reverse(items)}}
        error -> error
      end
    else
      {:error, :portable}
    end
  end

  defp json_value(_, _), do: {:error, :portable}

  defp bounded_value(_value, depth, _nodes) when depth > @max_value_depth,
    do: {:error, :portable}

  defp bounded_value(_value, _depth, nodes) when nodes >= @max_value_nodes,
    do: {:error, :portable}

  defp bounded_value(value, _depth, nodes)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_binary(value),
       do: {:ok, nodes + 1}

  defp bounded_value(value, depth, nodes) when is_map(value) and not is_struct(value) do
    if map_size(value) > @max_value_nodes - nodes - 1 do
      {:error, :portable}
    else
      bounded_pairs(Map.to_list(value), depth, nodes + 1)
    end
  end

  defp bounded_value(value, depth, nodes) when is_list(value),
    do: bounded_list(value, depth + 1, nodes + 1)

  defp bounded_value({tag, _value}, _depth, nodes) when tag in [:text, :bytes],
    do: {:ok, nodes + 1}

  defp bounded_value({:list, values}, depth, nodes) when is_list(values),
    do: bounded_list(values, depth + 1, nodes + 1)

  defp bounded_value({:record, pairs}, depth, nodes) when is_list(pairs),
    do: bounded_pairs(pairs, depth, nodes + 1)

  defp bounded_value(_, _, _), do: {:error, :portable}

  defp bounded_list([], _depth, nodes), do: {:ok, nodes}

  defp bounded_list([head | tail], depth, nodes) do
    with {:ok, next} <- bounded_value(head, depth, nodes), do: bounded_list(tail, depth, next)
  end

  defp bounded_list(_, _, _), do: {:error, :portable}

  defp bounded_pairs([], _depth, nodes), do: {:ok, nodes}

  defp bounded_pairs([{key, value} | rest], depth, nodes) do
    with {:ok, next} <- bounded_value(key, depth, nodes),
         {:ok, next} <- bounded_value(value, depth + 1, next),
         do: bounded_pairs(rest, depth, next)
  end

  defp bounded_pairs(_, _, _), do: {:error, :portable}

  defp valid_descriptor_identity({id, version, hash}) do
    with {:ok, id} <- identity(id),
         true <- uint?(version, 1, 2_147_483_647),
         true <- is_binary(hash) and byte_size(hash) == 32 do
      {:ok, {id, version, hash}}
    else
      _ -> {:error, :descriptor}
    end
  end

  defp valid_descriptor_identity(_), do: {:error, :descriptor}

  defp identity(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..@max_identity_bytes and
         :binary.match(value, <<0>>) == :nomatch,
       do: {:ok, value},
       else: {:error, :identity}
  end

  defp identity(_), do: {:error, :identity}

  defp field_name(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..@max_field_bytes and
         :binary.match(value, <<0>>) == :nomatch, do: {:ok, value}, else: {:error, :field}
  end

  defp field_name(_), do: {:error, :field}

  defp valid_code(code) when is_binary(code) and byte_size(code) in 1..64 do
    if Regex.match?(~r/\A[a-z0-9_]+\z/, code), do: :ok, else: {:error, :code}
  end

  defp valid_code(_), do: {:error, :code}

  defp exact_keys?(map, required, optional) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)
    Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in required or &1 in optional))
  end

  defp exact_keys?(_, _, _), do: false

  defp exact_map_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp uint?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp bounded_list_length(list, max) when is_list(list) and is_integer(max) and max >= 0,
    do: bounded_list_length(list, 0, max)

  defp bounded_list_length([], count, _max), do: {:ok, count}

  defp bounded_list_length([_ | tail], count, max) when count < max,
    do: bounded_list_length(tail, count + 1, max)

  defp bounded_list_length(_, _count, _max), do: {:error, :bound}

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false
end
