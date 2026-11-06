# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Approval do
  @moduledoc """
  Pure exact-action consent (workflow/approval) over a caller-held state.

  This module validates and bounds every input, encodes it for the Cure
  module `Cure.Elzoo.Approval` and decodes the result. All release checks,
  the re-decision and the state transition run in Cure. The only outcome
  computed here is the control-key refusal for a current proposal, which is
  test-grounded. No I/O, clock, process, storage or authentication.
  """

  alias Elzoo.Authorization, as: Auth

  @cure :"Cure.Elzoo.Approval"
  @max_time Integer.pow(2, 63) - 1
  @max_revision Integer.pow(2, 31) - 1
  @max_ancestry 64
  @max_verifiers 64
  @max_events 65_536
  @max_state 65_536

  defmodule State do
    @moduledoc "Opaque approval state; build it with `Elzoo.Approval.new/0` or `replay/1`."
    @enforce_keys [:cure]
    defstruct [:cure]
  end

  @doc "Fixed Contract bounds."
  def bounds do
    %{
      time: @max_time,
      revision: @max_revision,
      ancestry: @max_ancestry,
      verifiers: @max_verifiers,
      events: @max_events,
      state: @max_state
    }
  end

  @doc "Empty state."
  def new, do: %State{cure: apply(@cure, :initial, [])}

  # ------------------------------------------------------------------ request

  @doc "Open, keep or supersede the request for an ASK decision."
  def request(%State{} = state, run, decision) do
    with :ok <- state_room(state),
         {:ok, run} <- Auth.identity_field(run, :run, :invalid_input),
         {:ok, binding} <- binding_from_decision(decision) do
      {:ApprRequestStep, next, req, event} =
        apply(@cure, :request, [state.cure, Auth.bytes(run), encode_binding(binding)])

      {:ok, %State{cure: next}, decode_request(req), decode_event_opt(event)}
    end
  end

  def request(_, _, _), do: {:error, {:invalid_input, :state}}

  # The decision is validated fully with the domain/authorization validators and
  # bounds before evaluation; malformed or over-bound input is invalid_input.
  defp binding_from_decision(%{verdict: :ask} = d) do
    with :ok <-
           Auth.exact_keys(
             d,
             [:verdict, :reason, :policy, :action, :permitted, :escrowed, :requirement, :rules],
             [],
             :invalid_input
           ),
         {:ok, b} <-
           validate_binding(%{
             action: d.action,
             escrowed: d.escrowed,
             policy: d.policy,
             requirement: d.requirement
           }),
         :ok <- ask_shape(d) do
      {:ok, b}
    end
  end

  defp binding_from_decision(%{verdict: v}) when v in [:allow, :deny],
    do: {:error, {:invalid_input, :not_ask}}

  defp binding_from_decision(_), do: {:error, {:invalid_input, :decision}}

  # Every key of an ASK decision from decide/3 is checked: the reason names the
  # requirement, nothing is permitted, and rule ids are a bounded identity list.
  defp ask_shape(d) do
    with true <- d.reason == {:ask, d.requirement} || {:error, {:invalid_input, :ask_reason}},
         true <- d.permitted == [] || {:error, {:invalid_input, :ask_permits_writes}},
         :ok <- Auth.proper_list(d.rules, :rules, :invalid_input),
         :ok <- Auth.count_in(d.rules, 0, Auth.bounds().rules, :rules, :invalid_input),
         {:ok, _} <- Auth.map_ok(d.rules, &Auth.identity_field(&1, :rule_id, :invalid_input)) do
      :ok
    end
  end

  defp validate_binding(%{action: a, escrowed: es, policy: p, requirement: r} = b)
       when map_size(b) == 4 do
    with {:ok, _} <- Auth.validate_action(a),
         {:ok, _} <- Auth.validate_writes(es),
         :ok <-
           if(es == a.writes, do: :ok, else: {:error, {:invalid_input, :escrow_not_action_writes}}),
         {:ok, _} <- Auth.validate_identity(p),
         {:ok, _} <- Auth.validate_requirement(r) do
      {:ok, b}
    end
  end

  defp validate_binding(_), do: {:error, {:invalid_input, :binding}}

  # ------------------------------------------------------------------ release

  @doc """
  Release escrowed writes for `key` with fresh `evidence` or `:retained`
  consent. All Elixir validation precedes check 0.
  """
  def release(%State{} = state, key, source, context) do
    with {:ok, ctx} <- release_context(context, :required),
         {:ok, key} <- validate_key(key),
         {:ok, src} <- source(source),
         :ok <- state_room(state) do
      case ctx do
        {:control_field, k} ->
          {:refused, {:deny_at_release, {:control_field, k}}, state}

        ctx ->
          {:ApprStep, next, writes, result, event} =
            apply(@cure, :release, [state.cure, encode_key(key), src, ctx])

          case result do
            {:ApprApproved, _, _, _, _} ->
              {:released, %State{cure: next}, Auth.decode_writes(writes), decode_event_opt(event)}

            {:ApprRefused, r} ->
              {:refused, decode_refusal(r), state}

            {:ApprFailed, c, f} ->
              {:error, {Auth.decode_class(c), Auth.decode_failure(f)}, state}
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def release(state, _, _, _), do: {:error, {:invalid_input, :state}, state}

  @doc """
  Deterministic retained-consent selection. The context may omit `:approver`
  (it is ignored here), unlike every other context field.
  """
  def select_retained(%State{} = state, key, context) do
    with {:ok, ctx} <- release_context(context, :ignored),
         {:ok, key} <- validate_key(key) do
      case ctx do
        {:control_field, k} ->
          {:refused, {:deny_at_release, {:control_field, k}}}

        ctx ->
          case apply(@cure, :select_retained, [state.cure, encode_key(key), ctx]) do
            {:SelectedConsent, c} -> {:ok, decode_consent(c)}
            {:SelectRefused, r} -> {:refused, decode_refusal(r)}
          end
      end
    end
  end

  def select_retained(_, _, _), do: {:error, {:invalid_input, :state}}

  @doc "Recheck a recorded release against current context. Emits no writes."
  def revalidate(%State{} = state, key, context) do
    with {:ok, ctx} <- release_context(context, :required),
         {:ok, key} <- validate_key(key) do
      case ctx do
        {:control_field, k} ->
          {:refused, {:deny_at_release, {:control_field, k}}}

        ctx ->
          case apply(@cure, :revalidate, [state.cure, encode_key(key), ctx]) do
            {:ApprApproved, _, _, _, _} -> :ok
            {:ApprRefused, r} -> {:refused, decode_refusal(r)}
            {:ApprFailed, c, f} -> {:error, {Auth.decode_class(c), Auth.decode_failure(f)}}
          end
      end
    end
  end

  def revalidate(_, _, _), do: {:error, {:invalid_input, :state}}

  @doc "Record a revocation of `{verifier, evidence_id}`."
  def revoke(%State{} = state, {verifier, evidence_id}) do
    with :ok <- state_room(state),
         {:ok, v} <- Auth.identity_field(verifier, :verifier, :invalid_input),
         {:ok, id} <- Auth.identity_field(evidence_id, :evidence_id, :invalid_input) do
      event = {:EvRevoked, {:ApprEvidenceKey, Auth.bytes(v), Auth.bytes(id)}}
      {:ok, %State{cure: apply(@cure, :apply_event, [state.cure, event])}, decode_event(event)}
    end
  end

  def revoke(_, _), do: {:error, {:invalid_input, :revoke}}

  # ------------------------------------------------------------------ replay

  @doc "Fold one recorded event into state. Returns state only."
  def apply_event(%State{} = state, event) do
    with :ok <- state_room(state),
         {:ok, encoded} <- encode_event_checked(event),
         :ok <- release_has_request(state, event) do
      {:ok, %State{cure: apply(@cure, :apply_event, [state.cure, encoded])}}
    end
  end

  def apply_event(_, _), do: {:error, {:invalid_input, :state}}

  @doc "Rebuild state from recorded events. Returns state only, never writes."
  def replay(events) when is_list(events) do
    with :ok <- Auth.proper_list(events, :events, :invalid_input),
         :ok <- Auth.count_in(events, 0, @max_events, :events, :invalid_input) do
      Enum.reduce_while(events, {:ok, new()}, fn event, {:ok, state} ->
        case apply_event(state, event) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def replay(_), do: {:error, {:invalid_input, {:not_a_list, :events}}}

  @doc "Decoded view of the state (for inspection and tests)."
  def inspect_state(%State{cure: {:ApprState, rs, cs, rels, consumed, revoked}}) do
    %{
      requests: Enum.map(rs, &decode_request/1),
      consents: Enum.map(cs, &decode_consent/1),
      releases: Enum.map(rels, &decode_release/1),
      consumed: Enum.map(consumed, &decode_ekey/1),
      revoked: Enum.map(revoked, &decode_ekey/1)
    }
  end

  # ------------------------------------------------------------------ validation

  defp state_room(%State{cure: {:ApprState, rs, cs, rels, consumed, revoked}}) do
    if Enum.all?([rs, cs, rels, consumed, revoked], &(length(&1) < @max_state)),
      do: :ok,
      else: {:error, {:invalid_input, {:bound_exceeded, :state}}}
  end

  defp state_room(_), do: {:error, {:invalid_input, :state}}

  @context_required [:now, :max_age, :verifiers, :run, :policy, :proposal, :authority, :approver]

  defp release_context(ctx, approver) when is_map(ctx) and not is_struct(ctx) do
    {required, optional} =
      case approver do
        :required -> {@context_required, []}
        :ignored -> {@context_required -- [:approver], [:approver]}
      end

    with :ok <- Auth.exact_keys(ctx, required, optional, :unavailable_context),
         :ok <- time(ctx.now, 0, :now, :unavailable_context),
         :ok <- time(ctx.max_age, 1, :max_age, :unavailable_context),
         {:ok, verifiers} <- identities(ctx.verifiers, 1, @max_verifiers, :verifiers),
         {:ok, run} <- run_context(ctx.run),
         {:ok, policy} <- Auth.validate_policy(ctx.policy),
         {:ok, actx} <- Auth.validate_context(ctx.authority, policy),
         {:ok, approver} <- approver(Map.get(ctx, :approver), approver) do
      case Auth.validate_proposal(ctx.proposal, actx) do
        {:deny, {:control_field, k}} ->
          {:ok, {:control_field, k}}

        {:error, _} = error ->
          error

        {:ok, action} ->
          {:ok,
           {:ApprContext, ctx.now, ctx.max_age, Enum.map(verifiers, &Auth.bytes/1),
            Auth.bytes(run.id), Auth.bytes(run.root), Enum.map(run.ancestry, &Auth.bytes/1),
            Auth.encode_policy(policy), Auth.encode_action(action), Auth.encode_writes(actx.own),
            Auth.encode_parent(actx.parent), Auth.bytes(actx.proposer),
            Auth.bytes(approver.identity), Auth.encode_writes(approver.authority)}}
      end
    end
  end

  defp release_context(_, _), do: {:error, {:unavailable_context, :not_a_map}}

  defp approver(nil, :ignored), do: {:ok, %{identity: "-", authority: []}}
  defp approver(_given, :ignored), do: {:ok, %{identity: "-", authority: []}}

  defp approver(%{identity: id, authority: auth} = a, :required) when map_size(a) == 2 do
    with {:ok, id} <- Auth.identity_field(id, :approver, :unavailable_context),
         {:ok, auth} <- Auth.validate_authority(auth) do
      {:ok, %{identity: id, authority: auth}}
    end
  end

  defp approver(_, :required), do: {:error, {:unavailable_context, :approver}}

  defp run_context(%{id: id, root: root, ancestry: ancestry} = r) when map_size(r) == 3 do
    with {:ok, id} <- Auth.identity_field(id, :run, :unavailable_context),
         {:ok, root} <- Auth.identity_field(root, :root, :unavailable_context),
         {:ok, ancestry} <- identities(ancestry, 0, @max_ancestry, :ancestry) do
      {:ok, %{id: id, root: root, ancestry: ancestry}}
    end
  end

  defp run_context(_), do: {:error, {:unavailable_context, :run}}

  defp identities(list, min, max, name) do
    with :ok <- Auth.proper_list(list, name, :unavailable_context),
         :ok <- Auth.count_in(list, min, max, name, :unavailable_context) do
      Auth.map_ok(list, &Auth.identity_field(&1, name, :unavailable_context))
    end
  end

  defp time(t, min, _name, _class) when is_integer(t) and t >= min and t <= @max_time, do: :ok
  defp time(_, _, name, class), do: {:error, {class, {:bound_exceeded, name}}}

  defp validate_key({run, action_id, name, version, revision}) do
    with {:ok, run} <- Auth.identity_field(run, :run, :invalid_input),
         {:ok, action_id} <- Auth.identity_field(action_id, :action_id, :invalid_input),
         {:ok, name} <- Auth.identity_field(name, :requirement_name, :invalid_input),
         :ok <- int_in(version, 1, @max_revision, :requirement_version),
         :ok <- int_in(revision, 1, @max_revision, :revision) do
      {:ok, {run, action_id, name, version, revision}}
    end
  end

  defp validate_key(_), do: {:error, {:invalid_input, :key}}

  defp int_in(v, min, max, _name) when is_integer(v) and v >= min and v <= max, do: :ok
  defp int_in(_, _, _, name), do: {:error, {:invalid_input, {:bound_exceeded, name}}}

  @evidence_keys [
    :verifier,
    :evidence_id,
    :reviewer,
    :request,
    :decision,
    :scope,
    :issued_at,
    :expiry
  ]

  defp source(:retained), do: {:ok, :ApprRetained}

  defp source(%{} = e) when not is_struct(e) do
    with {:ok, ev} <- validate_evidence(e), do: {:ok, {:ApprFresh, encode_evidence(ev)}}
  end

  defp source(_), do: {:error, {:invalid_input, :evidence}}

  defp validate_evidence(%{} = e) when not is_struct(e) do
    with :ok <- Auth.exact_keys(e, @evidence_keys, [], :invalid_input),
         {:ok, _} <- Auth.identity_field(e.verifier, :verifier, :invalid_input),
         {:ok, _} <- Auth.identity_field(e.evidence_id, :evidence_id, :invalid_input),
         {:ok, _} <- Auth.identity_field(e.reviewer, :reviewer, :invalid_input),
         {:ok, _} <- validate_key(e.request),
         :ok <- member(e.decision, [:approve, :reject], :decision),
         :ok <- member(e.scope, [:once, :run, :root], :scope),
         :ok <- time(e.issued_at, 0, :issued_at, :invalid_input),
         :ok <- time(e.expiry, 0, :expiry, :invalid_input),
         :ok <-
           if(e.expiry > e.issued_at,
             do: :ok,
             else: {:error, {:invalid_input, :expiry_not_after_issue}}
           ) do
      {:ok, e}
    end
  end

  defp validate_evidence(_), do: {:error, {:invalid_input, :evidence}}

  defp member(v, allowed, name),
    do: if(v in allowed, do: :ok, else: {:error, {:invalid_input, name}})

  # ------------------------------------------------------------------ codec

  defp b(t), do: Auth.bytes(t)
  defp t(l), do: Auth.text(l)

  defp encode_key({run, aid, name, version, rev}),
    do: {:ApprKey, b(run), b(aid), b(name), version, rev}

  defp decode_key({:ApprKey, run, aid, name, version, rev}),
    do: {t(run), t(aid), t(name), version, rev}

  defp encode_binding(%{action: a, escrowed: es, policy: p, requirement: r}) do
    {:ApprBinding, Auth.encode_action(a), Auth.encode_writes(es), Auth.encode_identity(p),
     Auth.encode_requirement(r)}
  end

  defp decode_binding({:ApprBinding, a, es, p, r}) do
    %{
      action: Auth.decode_action(a),
      escrowed: Auth.decode_writes(es),
      policy: Auth.decode_identity(p),
      requirement: Auth.decode_requirement(r)
    }
  end

  defp encode_status(:open), do: :ApprOpen
  defp encode_status(:released), do: :ApprReleased
  defp encode_status(:superseded), do: :ApprSuperseded
  defp decode_status(:ApprOpen), do: :open
  defp decode_status(:ApprReleased), do: :released
  defp decode_status(:ApprSuperseded), do: :superseded

  defp encode_request(%{key: k, binding: bd, status: s}) when is_map(bd),
    do: {:ApprRequest, encode_key(k), encode_binding(bd), encode_status(s)}

  defp decode_request({:ApprRequest, k, bd, s}),
    do: %{key: decode_key(k), binding: decode_binding(bd), status: decode_status(s)}

  defp encode_evidence(e) do
    {:ApprEvidence, b(e.verifier), b(e.evidence_id), b(e.reviewer), encode_key(e.request),
     if(e.decision == :approve, do: :ApprApprove, else: :ApprReject), Auth.encode_scope(e.scope),
     e.issued_at, e.expiry}
  end

  defp decode_evidence({:ApprEvidence, v, id, r, k, d, s, i, x}) do
    %{
      verifier: t(v),
      evidence_id: t(id),
      reviewer: t(r),
      request: decode_key(k),
      decision: if(d == :ApprApprove, do: :approve, else: :reject),
      scope: Auth.decode_scope(s),
      issued_at: i,
      expiry: x
    }
  end

  defp encode_consent(%{evidence: e, binding: bd, run: run, root: root}),
    do: {:ApprConsent, encode_evidence(e), encode_binding(bd), b(run), b(root)}

  defp decode_consent({:ApprConsent, e, bd, run, root}),
    do: %{evidence: decode_evidence(e), binding: decode_binding(bd), run: t(run), root: t(root)}

  defp encode_release(r) when is_map(r) do
    {:ApprRelease, encode_key(r.key), encode_binding(r.binding), Auth.encode_writes(r.writes),
     encode_evidence(r.evidence), b(r.run), b(r.root), r.released_at}
  end

  defp decode_release({:ApprRelease, k, bd, ws, e, run, root, at}) do
    %{
      key: decode_key(k),
      binding: decode_binding(bd),
      writes: Auth.decode_writes(ws),
      evidence: decode_evidence(e),
      run: t(run),
      root: t(root),
      released_at: at
    }
  end

  defp decode_ekey({:ApprEvidenceKey, v, id}), do: {t(v), t(id)}

  defp decode_event_opt(:none), do: nil
  defp decode_event_opt({:some, e}), do: decode_event(e)

  defp decode_event({:EvRequested, r}), do: {:requested, decode_request(r)}
  defp decode_event({:EvSuperseded, k, r}), do: {:superseded, decode_key(k), decode_request(r)}

  defp decode_event({:EvReleased, rel, c}) do
    consent =
      case c do
        :none -> nil
        {:some, x} -> decode_consent(x)
      end

    {:released, decode_release(rel), consent}
  end

  defp decode_event({:EvRevoked, k}), do: {:revoked, decode_ekey(k)}

  defp encode_event({:requested, r}), do: {:EvRequested, encode_request(r)}
  defp encode_event({:superseded, k, r}), do: {:EvSuperseded, encode_key(k), encode_request(r)}

  defp encode_event({:released, rel, consent}),
    do:
      {:EvReleased, encode_release(rel),
       if(consent, do: {:some, encode_consent(consent)}, else: :none)}

  defp encode_event({:revoked, {v, id}}) when is_binary(v) and is_binary(id),
    do: {:EvRevoked, {:ApprEvidenceKey, b(v), b(id)}}

  # Events come from the owner's own retained log; shape is checked by a
  # strict encode, and re-decoding must reproduce the input exactly.
  # Events are validated with the same validators and bounds as the live
  # transition that produced them, plus the invariants that transition
  # guarantees, before they are encoded. A log entry is never trusted.
  defp encode_event_checked(event) do
    with :ok <- validate_event(event), do: {:ok, encode_event(event)}
  end

  # A live release needs an existing open (or, on re-apply, released) request
  # with the same binding; a release for a never-requested key is rejected.
  defp release_has_request(state, {:released, rel, _}) do
    case Enum.find(inspect_state(state).requests, &(&1.key == rel.key)) do
      nil -> {:error, {:invalid_input, :release_without_request}}
      %{status: :superseded} -> {:error, {:invalid_input, :release_of_superseded_request}}
      %{binding: b} when b != rel.binding -> {:error, {:invalid_input, :release_binding_mismatch}}
      _ -> :ok
    end
  end

  defp release_has_request(_state, _event), do: :ok

  defp validate_event({:revoked, {v, id}}) do
    with {:ok, _} <- Auth.identity_field(v, :verifier, :invalid_input),
         {:ok, _} <- Auth.identity_field(id, :evidence_id, :invalid_input),
         do: :ok
  end

  defp validate_event({:requested, req}), do: validate_request_record(req)

  defp validate_event({:superseded, old, req}) do
    with {:ok, {run, aid, _, _, rev}} <- validate_key(old),
         :ok <- validate_request_record(req),
         {^run, ^aid, _, _, new_rev} <- req.key,
         true <- new_rev == rev + 1 do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_input, :superseded_event}}
    end
  end

  defp validate_event({:released, rel, consent}) do
    with :ok <- validate_release_record(rel),
         :ok <- release_key_binding(rel),
         :ok <- validate_consent(consent, rel),
         do: :ok
  end

  defp validate_event(_), do: {:error, {:invalid_input, :event}}

  defp validate_request_record(%{key: key, binding: b, status: :open} = r) when map_size(r) == 3 do
    with {:ok, {_run, aid, name, version, _rev}} <- validate_key(key),
         {:ok, b} <- validate_binding(b),
         true <-
           aid == b.action.action_id and name == b.requirement.name and
             version == b.requirement.version do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_input, :request_key_binding}}
    end
  end

  defp validate_request_record(_), do: {:error, {:invalid_input, :request}}

  @release_keys [:key, :binding, :writes, :evidence, :run, :root, :released_at]

  defp validate_release_record(%{} = rel) when not is_struct(rel) do
    with :ok <- Auth.exact_keys(rel, @release_keys, [], :invalid_input),
         {:ok, _} <- validate_key(rel.key),
         {:ok, b} <- validate_binding(rel.binding),
         {:ok, _} <- Auth.validate_writes(rel.writes),
         :ok <-
           if(rel.writes == b.escrowed, do: :ok, else: {:error, {:invalid_input, :released_writes}}),
         {:ok, ev} <- validate_evidence(rel.evidence),
         :ok <- approving(ev),
         {:ok, _} <- Auth.identity_field(rel.run, :run, :invalid_input),
         {:ok, _} <- Auth.identity_field(rel.root, :root, :invalid_input),
         :ok <- time(rel.released_at, 0, :released_at, :invalid_input) do
      :ok
    end
  end

  defp validate_release_record(_), do: {:error, {:invalid_input, :release}}

  # Same rule as request events, plus the run: a fresh or :run release records
  # the key's own Run; only a :root release may record another Run (the root's).
  defp release_key_binding(%{key: {run, aid, name, version, _}, binding: b} = rel) do
    if aid == b.action.action_id and name == b.requirement.name and
         version == b.requirement.version and (run == rel.run or rel.evidence.scope == :root),
       do: :ok,
       else: {:error, {:invalid_input, :release_key_binding}}
  end

  defp validate_consent(nil, _rel), do: :ok

  defp validate_consent(%{evidence: ev, binding: b, run: run, root: root} = c, rel)
       when map_size(c) == 4 do
    with {:ok, ev} <- validate_evidence(ev),
         :ok <- approving(ev),
         true <-
           ev.scope in [:run, :root] and ev == rel.evidence and b == rel.binding and run == rel.run and
             root == rel.root do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_input, :consent}}
    end
  end

  defp validate_consent(_, _), do: {:error, {:invalid_input, :consent}}

  # A live release only ever records approving evidence.
  defp approving(%{decision: :approve}), do: :ok
  defp approving(_), do: {:error, {:invalid_input, :not_approving_evidence}}

  defp decode_refusal({:RDenyAtRelease, reason}),
    do: {:deny_at_release, Auth.decode_reason(reason, nil)}

  @refusals %{
    RRunMismatch: :run_mismatch,
    RUnknownRequest: :unknown_request,
    RAlreadyReleased: :already_released,
    RSuperseded: :superseded,
    RStaleRevision: :stale_revision,
    RRequestMismatch: :request_mismatch,
    RVerifierNotAllowed: :verifier_not_allowed,
    RRevoked: :revoked,
    RConsumed: :consumed,
    REvidenceReused: :evidence_reused,
    RRejectedByReviewer: :rejected_by_reviewer,
    RIssuedInFuture: :issued_in_future,
    REvidenceTooOld: :evidence_too_old,
    RExpired: :expired,
    RScopeMismatch: :scope_mismatch,
    RApproverMismatch: :approver_mismatch,
    RSelfApproval: :self_approval,
    RPolicyChanged: :policy_changed,
    RPayloadChanged: :payload_changed,
    RRequirementChanged: :requirement_changed,
    RApproverNotAuthorized: :approver_not_authorized,
    RNoRetainedConsent: :no_retained_consent,
    RNotReleased: :not_released
  }

  defp decode_refusal(atom) when is_atom(atom), do: Map.fetch!(@refusals, atom)
end
