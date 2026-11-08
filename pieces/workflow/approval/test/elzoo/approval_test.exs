# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ApprovalTest do
  use ExUnit.Case, async: true
  alias Elzoo.Approval
  alias Elzoo.Authorization, as: Auth

  @source File.read!(Path.expand("../../cure/elzoo/approval.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @hash :binary.copy(<<9>>, 32)

  # ------------------------------------------------------------------ fixtures

  defp post, do: %{target: "post:1", field: "state", value: {:text, "published"}}

  defp req(scope \\ :once, name \\ "human", version \\ 1),
    do: %{name: name, version: version, scope: scope}

  defp policy(scope \\ :once, opts \\ []) do
    rules =
      Keyword.get(opts, :rules, [
        %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req(scope)}
      ])

    %{
      id: "pol",
      version: Keyword.get(opts, :version, 1),
      content_hash: Keyword.get(opts, :hash, @hash),
      effect_classes: ["publish"],
      rules: rules
    }
  end

  defp proposal(opts \\ []) do
    %{
      tenant: "t1",
      resource: "post:1",
      action_id: Keyword.get(opts, :action_id, "act-1"),
      payload: Keyword.get(opts, :payload, {:record, [{"title", {:text, "Hi"}}]}),
      writes: [post()]
    }
  end

  defp authority(opts \\ []) do
    %{
      proposer: Keyword.get(opts, :proposer, "agent-1"),
      effect_class: "publish",
      own: [post()],
      parent: Keyword.get(opts, :parent, :none)
    }
  end

  defp decision(scope \\ :once, opts \\ []) do
    {:ok, d} = Auth.decide(policy(scope, opts), proposal(opts), authority(opts))
    assert d.verdict == :ask
    d
  end

  defp setup_request(scope \\ :once, run \\ "run-1", opts \\ []) do
    {:ok, s, request, {:requested, _}} =
      Approval.request(Approval.new(), run, decision(scope, opts))

    {s, request.key}
  end

  defp evidence(key, opts \\ []) do
    %{
      verifier: Keyword.get(opts, :verifier, "verifier-a"),
      evidence_id: Keyword.get(opts, :id, "ev-1"),
      reviewer: Keyword.get(opts, :reviewer, "human-1"),
      request: Keyword.get(opts, :request, key),
      decision: Keyword.get(opts, :decision, :approve),
      scope: Keyword.get(opts, :scope, :once),
      issued_at: Keyword.get(opts, :issued_at, 1_000),
      expiry: Keyword.get(opts, :expiry, 100_000)
    }
  end

  defp context(scope \\ :once, opts \\ []) do
    %{
      now: Keyword.get(opts, :now, 2_000),
      max_age: Keyword.get(opts, :max_age, 10_000),
      verifiers: Keyword.get(opts, :verifiers, ["verifier-a"]),
      run: Keyword.get(opts, :run, %{id: "run-1", root: "root-1", ancestry: ["root-1"]}),
      policy: Keyword.get(opts, :policy, policy(scope, opts)),
      proposal: Keyword.get(opts, :proposal, proposal(opts)),
      authority: Keyword.get(opts, :authority, authority(opts)),
      approver:
        Keyword.get(opts, :approver, %{
          identity: Keyword.get(opts, :reviewer, "human-1"),
          authority: [post()]
        })
    }
  end

  defp refused(result) do
    assert {:refused, reason, _state} = result
    reason
  end

  # ------------------------------------------------------------------ Cure laws

  test "production Cure audit is clean: no axioms, holes, opacity or unproven totality" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total] do
      assert Map.fetch!(report, key) == [], "#{key}: #{inspect(Map.fetch!(report, key))}"
    end

    assert report.absurd == 0
  end

  test "every Cure function and law is marked total" do
    fns = Regex.scan(~r/^  fn (\w+)\(/m, @source, capture: :all_but_first) |> length()
    totals = Regex.scan(~r/^  @total true\n(?:  @reducible\n)?  fn /m, @source) |> length()
    assert fns > 0 and fns == totals
  end

  defp mutated(name, from, to) do
    assert String.contains?(@source, from), "mutation anchor missing: #{from}"

    src =
      @source
      |> String.replace("mod Elzoo.Approval", "mod Elzoo.ApprovalNeg" <> name)
      |> String.replace(from, to, global: false)

    refute src == @source
    Cure.Compiler.compile_and_load(src, source_roots: @roots)
  end

  test "negative control: a refused release that emits writes is rejected" do
    assert {:error,
            {:codegen_error, {:source_context, inner, %{checking: :finish_blocked_emits_nothing}}}} =
             mutated(
               "Refused",
               "ApprRefused(r) -> ApprStep{state: s, writes: [],",
               "ApprRefused(r) -> ApprStep{state: s, writes: release_writes(ctx),"
             )

    assert elem(inner, 0) == :conversion_failure
  end

  test "negative control: releasing without the approver-authority guard is rejected" do
    assert {:error,
            {:codegen_error, {:source_context, inner, %{checking: :finish_within_approver}}}} =
             mutated(
               "Guard",
               "    guard(subset(escrowed_of(current(ctx)), approver_authority_of(ctx)), escrowed_of(current(ctx)))",
               "    escrowed_of(current(ctx))"
             )

    assert elem(inner, 0) == :branch_type
  end

  test "negative control: a self-approval gate that passes is rejected" do
    assert {:error, {:codegen_error, {:source_context, inner, %{checking: :self_gate_blocks}}}} =
             mutated(
               "Self",
               "refuse_if(eq_ints(reviewer_of(e), proposer_of(ctx)), RSelfApproval())",
               "pass_if(eq_ints(reviewer_of(e), proposer_of(ctx)), RSelfApproval())"
             )

    assert elem(inner, 0) == :conversion_failure
  end

  test "negative control: an unfinished law is a hole, not a proof" do
    assert {:error, {:codegen_error, {:unfilled_hole, info}}} =
             mutated(
               "Hole",
               "    finish_within_approver(release_check(s, k, src, ctx), s, k, src, ctx)",
               "    ?unfinished"
             )

    assert info.definition == :"Elzoo.ApprovalNegHole#release_within_approver"
  end

  # ELZ-062 (owner approval 2026-11-08, time limit only): this Cure proof check (the stack of its timeout is
  # in Cure.Core.Normalise and Cure.Core.Conv) exceeded the 120 s default on contabo-elzoo-1 in both full
  # runs of the same tree: runs 42484236992 and 42492726966. Measured under the full suite with the limits
  # raised (branch measure/ELZ-062, `mix test --slowest`): 39.1 s on symbolic-elzoo (run 42500718766),
  # 45.3 s on macbook-ubuntu-elzoo-candidate (42497402091) and 93.1 s on contabo-elzoo-1 (42497486307).
  # The spread on the same machine is large (above 120 s twice, 93.1 s once). On the GitHub-hosted runner
  # (ubuntu-24.04, run 42522317222, job 128858289534) it took 40.8 s. 300 s is a margin over these
  # times, not a performance target; the assertions are unchanged.
  @tag timeout: 300_000
  test "negative control: dropping g_self from the gate list is rejected inside self_approval_refused" do
    from = "[g_approver(e, ctx), g_self(e, ctx), g_decide(current(ctx))"

    assert {:error, {:codegen_error, {:source_context, _inner, %{line: line}}}} =
             mutated("Drop", from, "[g_approver(e, ctx), g_decide(current(ctx))")

    lines = String.split(@source, "\n")
    law = Enum.find_index(lines, &String.starts_with?(&1, "  fn self_approval_refused(")) + 1
    assert line in [law, law + 1]
  end

  # ------------------------------------------------------------------ release basics

  test "fresh approval releases exactly the escrowed writes once and records the release" do
    {s, key} = setup_request()
    ev = evidence(key)
    assert {:released, s2, [w], {:released, record, nil}} = Approval.release(s, key, ev, context())
    assert w == post()
    assert record.evidence == ev
    assert record.run == "run-1" and record.root == "root-1"
    assert record.writes == [post()] and record.released_at == 2_000
    view = Approval.inspect_state(s2)
    assert [%{status: :released}] = view.requests
    assert view.consumed == [{"verifier-a", "ev-1"}]
    assert view.consents == []

    assert :already_released = refused(Approval.release(s2, key, ev, context()))

    assert :already_released =
             refused(Approval.release(s2, key, evidence(key, id: "ev-2"), context()))
  end

  test "request/3 is idempotent for an equal open request and rejects non-ASK decisions" do
    {s, key} = setup_request()
    assert {:ok, ^s, %{key: ^key}, nil} = Approval.request(s, "run-1", decision())

    {:ok, allow} =
      Auth.decide(
        policy(:once, rules: [%{id: "a", effect_class: "publish", verdict: :allow}]),
        proposal(),
        authority()
      )

    assert {:error, {:invalid_input, :not_ask}} = Approval.request(s, "run-1", allow)
  end

  test "payload drift invalidates an earlier approval" do
    {s, key} = setup_request()
    ctx = context(:once, proposal: proposal(payload: {:text, "changed"}))
    assert :payload_changed = refused(Approval.release(s, key, evidence(key), ctx))
  end

  test "policy version drift, and a changed hash under the same id/version, invalidate approval" do
    {s, key} = setup_request()

    assert :policy_changed =
             refused(Approval.release(s, key, evidence(key), context(:once, version: 2)))

    hash = :binary.copy(<<8>>, 32)

    assert :policy_changed =
             refused(Approval.release(s, key, evidence(key), context(:once, hash: hash)))
  end

  test "release-time DENY wins over recorded consent" do
    {s, key} = setup_request()

    rules = [
      %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req()},
      %{id: "freeze", effect_class: "publish", verdict: :deny}
    ]

    assert {:deny_at_release, {:rule, "freeze"}} =
             refused(Approval.release(s, key, evidence(key), context(:once, rules: rules)))
  end

  test "stale revision changes nothing; changed requirement supersedes and opens revision + 1" do
    {s, key} = setup_request()

    {:ok, s2, new_req, {:superseded, ^key, _}} =
      Approval.request(s, "run-1", decision(:once, payload: {:text, "v2"}))

    {_, _, _, _, 2} = new_key = new_req.key
    assert [%{status: :superseded}, %{status: :open}] = Approval.inspect_state(s2).requests

    stale = evidence(new_key, request: key)

    assert {:refused, :stale_revision, ^s2} =
             Approval.release(s2, new_key, stale, context(:once, payload: {:text, "v2"}))

    assert :superseded = refused(Approval.release(s2, key, evidence(key), context()))

    assert {:released, _, [_], _} =
             Approval.release(
               s2,
               new_key,
               evidence(new_key),
               context(:once, payload: {:text, "v2"})
             )

    {:ok, s3, req3, {:superseded, ^key, _}} =
      Approval.request(
        s,
        "run-1",
        decision(:once,
          rules: [
            %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req(:once, "legal")}
          ]
        )
      )

    assert {_, _, "legal", 1, 2} = req3.key

    assert :request_mismatch =
             refused(
               Approval.release(
                 s3,
                 req3.key,
                 evidence(req3.key, request: key),
                 context(:once,
                   rules: [
                     %{
                       id: "pub",
                       effect_class: "publish",
                       verdict: :ask,
                       requirement: req(:once, "legal")
                     }
                   ]
                 )
               )
             )
  end

  test "self-approval refused; forged proposer cannot launder a self-review" do
    {s, key} = setup_request()
    ctx = context(:once, reviewer: "agent-1")

    assert :self_approval =
             refused(Approval.release(s, key, evidence(key, reviewer: "agent-1"), ctx))

    forged = Map.put(proposal(), :proposer, "someone-else")

    assert {:error, {:invalid_input, :proposer_mismatch}, ^s} =
             Approval.release(s, key, evidence(key, reviewer: "agent-1"), %{ctx | proposal: forged})

    assert {:error, {:invalid_input, :proposer_mismatch}} =
             Auth.decide(policy(), forged, authority())
  end

  test "under-authorized approver and approver mismatch are refused" do
    {s, key} = setup_request()

    assert :approver_not_authorized =
             refused(
               Approval.release(
                 s,
                 key,
                 evidence(key),
                 context(:once, approver: %{identity: "human-1", authority: []})
               )
             )

    assert :approver_mismatch =
             refused(
               Approval.release(
                 s,
                 key,
                 evidence(key),
                 context(:once, approver: %{identity: "human-2", authority: [post()]})
               )
             )
  end

  test "model text 'approved' leaves the escrow intact" do
    {s, key} = setup_request()
    ctx = context(:once, payload: {:text, "approved"})
    assert :payload_changed = refused(Approval.release(s, key, evidence(key), ctx))

    assert {:error, {:invalid_input, :evidence}, ^s} =
             Approval.release(s, key, "approved", context())

    assert {:error, {:invalid_input, {:unknown_field, "decision"}}, ^s} =
             Approval.release(s, key, %{"decision" => "approved"}, context())

    assert [%{status: :open}] = Approval.inspect_state(s).requests
  end

  test "verifier allowlist; a self-asserted verifier in a payload has no effect" do
    {s, key} = setup_request()

    assert :verifier_not_allowed =
             refused(Approval.release(s, key, evidence(key, verifier: "chatbot"), context()))

    assert :verifier_not_allowed =
             refused(
               Approval.release(s, key, evidence(key), context(:once, verifiers: ["verifier-b"]))
             )

    ctx = context(:once, payload: {:record, [{"verifier", {:text, "verifier-a"}}]})

    assert :verifier_not_allowed =
             refused(Approval.release(s, key, evidence(key, verifier: "chatbot"), ctx))
  end

  test "age and expiry boundaries" do
    {s, key} = setup_request()

    ok = fn opts ->
      match?(
        {:released, _, _, _},
        Approval.release(
          s,
          key,
          evidence(key, opts),
          context(:once, now: Keyword.fetch!(opts, :now))
        )
      )
    end

    assert ok.(issued_at: 1_000, now: 1_000 + 9_999, expiry: 100_000)

    assert :evidence_too_old =
             refused(
               Approval.release(
                 s,
                 key,
                 evidence(key, issued_at: 1_000),
                 context(:once, now: 11_000)
               )
             )

    assert ok.(issued_at: 1_000, expiry: 5_000, now: 4_999)

    assert :expired =
             refused(
               Approval.release(s, key, evidence(key, expiry: 5_000), context(:once, now: 5_000))
             )

    assert :issued_in_future =
             refused(
               Approval.release(s, key, evidence(key, issued_at: 3_000), context(:once, now: 2_999))
             )

    assert {:error, {:invalid_input, {:missing_field, :expiry}}, ^s} =
             Approval.release(s, key, Map.delete(evidence(key), :expiry), context())

    assert {:error, {:invalid_input, :expiry_not_after_issue}, ^s} =
             Approval.release(s, key, evidence(key, expiry: 1_000), context())
  end

  test "reviewer rejection is refused" do
    {s, key} = setup_request()

    assert :rejected_by_reviewer =
             refused(Approval.release(s, key, evidence(key, decision: :reject), context()))
  end

  test "unavailable context fails closed with no writes, distinct from DENY and invalid input" do
    {s, key} = setup_request()

    assert {:error, {:unavailable_context, {:missing_field, :verifiers}}, ^s} =
             Approval.release(s, key, evidence(key), Map.delete(context(), :verifiers))

    assert {:error, {:unavailable_context, :approver}, ^s} =
             Approval.release(s, key, evidence(key), %{context() | approver: nil})

    assert {:error, {:unavailable_context, {:invalid_policy, _}}, ^s} =
             Approval.release(s, key, evidence(key), %{context() | policy: %{}})
  end

  test "ambiguous requirement at release and revalidate is an unavailable_context error" do
    {s, key} = setup_request()

    rules = [
      %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req()},
      %{id: "law", effect_class: "publish", verdict: :ask, requirement: req(:once, "legal")}
    ]

    assert {:error, {:unavailable_context, {:ambiguous_requirement, [_, _]}}, ^s} =
             Approval.release(s, key, evidence(key), context(:once, rules: rules))

    {:released, s2, _, _} = Approval.release(s, key, evidence(key), context())

    assert {:error, {:unavailable_context, {:ambiguous_requirement, [_, _]}}} =
             Approval.revalidate(s2, key, context(:once, rules: rules))
  end

  test "control key in the current proposal at release and revalidate (test-only outcome)" do
    {s, key} = setup_request()
    ctx = context(:once, proposal: Map.put(proposal(), :approval, true))

    assert {:refused, {:deny_at_release, {:control_field, :approval}}, ^s} =
             Approval.release(s, key, evidence(key), ctx)

    {:released, s2, _, _} = Approval.release(s, key, evidence(key), context())

    assert {:refused, {:deny_at_release, {:control_field, :approval}}} =
             Approval.revalidate(s2, key, ctx)
  end

  test "Elixir validation precedes check 0" do
    {s, key} = setup_request()
    other_run = context(:once, run: %{id: "run-x", root: "root-1", ancestry: []})
    assert :run_mismatch = refused(Approval.release(s, key, evidence(key), other_run))
    bad = %{other_run | proposal: Map.put(proposal(), :extra, 1)}

    assert {:error, {:invalid_input, {:unknown_field, :extra}}, ^s} =
             Approval.release(s, key, evidence(key), bad)

    unknown = {"run-1", "nope", "human", 1, 1}

    assert {:error, {:invalid_input, {:unknown_field, :extra}}, ^s} =
             Approval.release(s, unknown, evidence(key), bad)
  end

  # ------------------------------------------------------------------ scope, revocation, replay

  test "reuse of an evidence id with another binding is rejected" do
    {s, key} = setup_request(:run)

    {:released, s2, _, {:released, _, consent}} =
      Approval.release(s, key, evidence(key, scope: :run), context(:run))

    assert consent.run == "run-1"

    {:ok, s3, other, _} = Approval.request(s2, "run-1", decision(:run, action_id: "act-2"))
    reused = evidence(other.key, scope: :run)

    assert :evidence_reused =
             refused(Approval.release(s3, other.key, reused, context(:run, action_id: "act-2")))
  end

  test "run scope: a new ASK after release opens latest + 1 and the retained run consent releases it" do
    {s, key} = setup_request(:run)
    {:released, s2, _, _} = Approval.release(s, key, evidence(key, scope: :run), context(:run))
    {:ok, s3, again, {:requested, _}} = Approval.request(s2, "run-1", decision(:run))
    {"run-1", "act-1", "human", 1, 2} = again.key
    assert {:ok, consent} = Approval.select_retained(s3, again.key, context(:run))
    assert consent.evidence.evidence_id == "ev-1"

    assert {:released, s4, [_], {:released, rec, nil}} =
             Approval.release(s3, again.key, :retained, context(:run))

    assert rec.evidence == consent.evidence and rec.run == "run-1" and rec.root == "root-1"
    assert length(Approval.inspect_state(s4).consents) == 1

    {:ok, s5, elsewhere, _} = Approval.request(s4, "run-2", decision(:run))
    ctx2 = context(:run, run: %{id: "run-2", root: "root-1", ancestry: ["root-1"]})
    assert :no_retained_consent = refused(Approval.release(s5, elsewhere.key, :retained, ctx2))
  end

  test "once evidence is never retained" do
    {s, key} = setup_request()
    {:released, s2, _, _} = Approval.release(s, key, evidence(key), context())
    {:ok, s3, again, _} = Approval.request(s2, "run-1", decision())
    assert {:refused, :no_retained_consent} = Approval.select_retained(s3, again.key, context())
  end

  test "root scope admits the root and Runs whose ancestry includes it; refuses others" do
    {s, key} = setup_request(:root, "root-1")
    root_ctx = context(:root, run: %{id: "root-1", root: "root-1", ancestry: []})

    {:released, s2, _, {:released, _, consent}} =
      Approval.release(s, key, evidence(key, scope: :root), root_ctx)

    assert consent.root == "root-1"

    {:ok, s3, child, _} = Approval.request(s2, "child-1", decision(:root))
    child_ctx = context(:root, run: %{id: "child-1", root: "root-1", ancestry: ["root-1"]})
    assert {:released, s4, [_], _} = Approval.release(s3, child.key, :retained, child_ctx)

    {:ok, s5, other, _} = Approval.request(s4, "child-2", decision(:root))
    orphan = context(:root, run: %{id: "child-2", root: "root-9", ancestry: ["root-9"]})
    assert :no_retained_consent = refused(Approval.release(s5, other.key, :retained, orphan))

    assert :ok = Approval.revalidate(s4, child.key, child_ctx)

    assert {:refused, :scope_mismatch} =
             Approval.revalidate(s4, child.key, %{
               child_ctx
               | run: %{id: "child-1", root: "root-1", ancestry: []}
             })
  end

  test "evidence scope must equal the requirement scope" do
    {s, key} = setup_request(:once)

    assert :scope_mismatch =
             refused(Approval.release(s, key, evidence(key, scope: :run), context()))
  end

  test "revocation wins over release and revalidate; on the retained path it shows as no_retained_consent" do
    {s, key} = setup_request(:run)
    {:ok, revoked, {:revoked, {"verifier-a", "ev-1"}}} = Approval.revoke(s, {"verifier-a", "ev-1"})

    assert :revoked =
             refused(Approval.release(revoked, key, evidence(key, scope: :run), context(:run)))

    {:released, s2, _, _} = Approval.release(s, key, evidence(key, scope: :run), context(:run))
    {:ok, s3, again, _} = Approval.request(s2, "run-1", decision(:run))
    {:ok, s4, _} = Approval.revoke(s3, {"verifier-a", "ev-1"})
    assert {:refused, :revoked} = Approval.revalidate(s4, key, context(:run))
    assert :no_retained_consent = refused(Approval.release(s4, again.key, :retained, context(:run)))

    assert :no_retained_consent =
             refused(
               Approval.release(
                 s3,
                 again.key,
                 :retained,
                 context(:run, now: 200_000, max_age: 1_000_000)
               )
             )
  end

  test "revalidate: ok while valid; refused after expiry; not_released without a record" do
    {s, key} = setup_request()
    assert {:refused, :not_released} = Approval.revalidate(s, key, context())
    {:released, s2, _, _} = Approval.release(s, key, evidence(key, expiry: 5_000), context())
    assert :ok = Approval.revalidate(s2, key, context())
    assert {:refused, :expired} = Approval.revalidate(s2, key, context(:once, now: 5_000))
  end

  test "replay rebuilds the live state from events and emits no writes" do
    {:ok, s1, r1, e1} = Approval.request(Approval.new(), "run-1", decision(:run))

    {:released, s2, _, e2} =
      Approval.release(s1, r1.key, evidence(r1.key, scope: :run), context(:run))

    {:ok, s3, r3, e3} = Approval.request(s2, "run-1", decision(:run, payload: {:text, "v2"}))
    {:ok, s4, e4} = Approval.revoke(s3, {"verifier-z", "ev-9"})
    events = [e1, e2, e3, e4]

    assert {:ok, replayed} = Approval.replay(events)
    assert replayed == s4
    assert {:ok, ^s4} = Approval.replay(events ++ [e2])

    assert :already_released =
             refused(
               Approval.release(replayed, r1.key, evidence(r1.key, scope: :run), context(:run))
             )

    # The v2 request has a different binding, so the retained v1 consent cannot serve it.
    assert :no_retained_consent =
             refused(
               Approval.release(replayed, r3.key, :retained, context(:run, payload: {:text, "v2"}))
             )

    assert {:error, {:invalid_input, :release}} = Approval.replay([{:released, :bogus, nil}])
    assert {:error, {:invalid_input, {:not_a_list, :events}}} = Approval.replay(:bogus)
  end

  test "restore after replay re-enters the reducer" do
    {:ok, s1, r1, e1} = Approval.request(Approval.new(), "run-1", decision())
    {:ok, restored} = Approval.replay([e1])

    deny = [
      %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req()},
      %{id: "x", effect_class: "publish", verdict: :deny}
    ]

    assert {:deny_at_release, {:rule, "x"}} =
             refused(
               Approval.release(restored, r1.key, evidence(r1.key), context(:once, rules: deny))
             )

    assert restored == s1
  end

  # ------------------------------------------------------------------ retained selection

  defp two_consents(scope \\ :run) do
    {s, k1} = setup_request(scope)

    {:released, s, _, _} =
      Approval.release(
        s,
        k1,
        evidence(k1,
          scope: scope,
          id: "ev-a",
          reviewer: "human-a",
          issued_at: 1_000,
          expiry: 5_000
        ),
        context(scope, reviewer: "human-a")
      )

    {:ok, s, r2, _} = Approval.request(s, "run-1", decision(scope))

    {:released, s, _, _} =
      Approval.release(
        s,
        r2.key,
        evidence(r2.key,
          scope: scope,
          id: "ev-b",
          reviewer: "human-b",
          issued_at: 1_500,
          expiry: 100_000
        ),
        context(scope, reviewer: "human-b")
      )

    {:ok, s, r3, _} = Approval.request(s, "run-1", decision(scope))
    {s, r3.key}
  end

  test "two reviewers: select_retained is deterministic and the owner supplies that reviewer" do
    {s, key} = two_consents()

    assert {:ok, %{evidence: %{reviewer: "human-a"}}} =
             Approval.select_retained(s, key, context(:run))

    assert :approver_mismatch =
             refused(Approval.release(s, key, :retained, context(:run, reviewer: "human-b")))

    assert {:released, _, [_], {:released, rec, nil}} =
             Approval.release(s, key, :retained, context(:run, reviewer: "human-a"))

    assert rec.evidence.reviewer == "human-a"
  end

  test "a stale earliest candidate does not hide a valid later one" do
    {s, key} = two_consents()
    late = context(:run, now: 6_000, reviewer: "human-b")
    assert {:ok, %{evidence: %{reviewer: "human-b"}}} = Approval.select_retained(s, key, late)
    assert {:released, _, [_], _} = Approval.release(s, key, :retained, late)
  end

  test "T1: now changing between select_retained and release fails closed with approver_mismatch" do
    {s, key} = two_consents()

    assert {:ok, %{evidence: %{reviewer: "human-a"}}} =
             Approval.select_retained(s, key, context(:run, now: 2_000))

    assert :approver_mismatch =
             refused(
               Approval.release(s, key, :retained, context(:run, now: 6_000, reviewer: "human-a"))
             )
  end

  test "T2: select_retained accepts a context without an approver key" do
    {s, key} = two_consents()
    ctx = Map.delete(context(:run), :approver)
    assert {:ok, %{evidence: %{reviewer: "human-a"}}} = Approval.select_retained(s, key, ctx)

    assert {:error, {:unavailable_context, {:missing_field, :approver}}, ^s} =
             Approval.release(s, key, :retained, ctx)
  end

  test "equal issued_at falls back to evidence key byte order" do
    {s, k1} = setup_request(:run)

    {:released, s, _, _} =
      Approval.release(
        s,
        k1,
        evidence(k1, scope: :run, id: "ev-z", reviewer: "human-z"),
        context(:run, reviewer: "human-z")
      )

    {:ok, s, r2, _} = Approval.request(s, "run-1", decision(:run))

    {:released, s, _, _} =
      Approval.release(
        s,
        r2.key,
        evidence(r2.key, scope: :run, id: "ev-m", reviewer: "human-m"),
        context(:run, reviewer: "human-m")
      )

    {:ok, s, r3, _} = Approval.request(s, "run-1", decision(:run))

    assert {:ok, %{evidence: %{evidence_id: "ev-m"}}} =
             Approval.select_retained(s, r3.key, context(:run))
  end

  test "retained selection reports checks 0-3 before no_retained_consent" do
    {s, key} = setup_request(:run)

    assert {:refused, :run_mismatch} =
             Approval.select_retained(
               s,
               key,
               context(:run, run: %{id: "x", root: "root-1", ancestry: []})
             )

    assert {:refused, :unknown_request} =
             Approval.select_retained(s, {"run-1", "nope", "human", 1, 1}, context(:run))

    assert {:refused, :no_retained_consent} = Approval.select_retained(s, key, context(:run))
  end

  # ------------------------------------------------------------------ bounds

  test "bounds at limit and limit + 1" do
    {s, key} = setup_request()
    ids = for i <- 1..65, do: "v#{i}"

    assert {:released, _, _, _} =
             Approval.release(
               s,
               key,
               evidence(key),
               context(:once, verifiers: ["verifier-a" | Enum.take(ids, 63)])
             )

    assert {:error, {:unavailable_context, {:bound_exceeded, :verifiers}}, ^s} =
             Approval.release(
               s,
               key,
               evidence(key),
               context(:once, verifiers: ["verifier-a" | Enum.take(ids, 64)])
             )

    assert {:error, {:unavailable_context, {:bound_exceeded, :verifiers}}, ^s} =
             Approval.release(s, key, evidence(key), context(:once, verifiers: []))

    anc = for i <- 1..65, do: "r#{i}"

    assert {:released, _, _, _} =
             Approval.release(
               s,
               key,
               evidence(key),
               context(:once, run: %{id: "run-1", root: "root-1", ancestry: Enum.take(anc, 64)})
             )

    assert {:error, {:unavailable_context, {:bound_exceeded, :ancestry}}, ^s} =
             Approval.release(
               s,
               key,
               evidence(key),
               context(:once, run: %{id: "run-1", root: "root-1", ancestry: anc})
             )

    max = Integer.pow(2, 63) - 1

    assert {:error, {:unavailable_context, {:bound_exceeded, :now}}, ^s} =
             Approval.release(s, key, evidence(key), context(:once, now: max + 1))

    assert {:error, {:unavailable_context, {:bound_exceeded, :max_age}}, ^s} =
             Approval.release(s, key, evidence(key), context(:once, max_age: 0))

    assert {:error, {:invalid_input, {:bound_exceeded, :expiry}}, ^s} =
             Approval.release(s, key, evidence(key, expiry: max + 1), context())

    long = String.duplicate("x", 1025)

    assert {:error, {:invalid_input, {:bound_exceeded, :evidence_id}}, ^s} =
             Approval.release(s, key, evidence(key, id: long), context())

    auth = for i <- 1..4097, do: %{target: "t#{i}", field: "f", value: 1}

    assert {:error, {:unavailable_context, {:bound_exceeded, :authority}}, ^s} =
             Approval.release(
               s,
               key,
               evidence(key),
               context(:once, approver: %{identity: "human-1", authority: auth})
             )

    assert {:error, {:invalid_input, {:bound_exceeded, :events}}} =
             Approval.replay(List.duplicate({:revoked, {"v", "e"}}, 65_537))
  end

  # ------------------------------------------------------------------ input validation (PR review 1-3)

  defp put_target(decision, target) do
    w = %{post() | target: target}
    action = %{decision.action | writes: [w]}
    %{decision | action: action, escrowed: [w]}
  end

  test "request/3 validates the decision fully: malformed input is invalid_input, never a crash" do
    s = Approval.new()

    assert {:error, {:invalid_input, _}} =
             Approval.request(s, "run-1", %{
               verdict: :ask,
               action: %{},
               escrowed: [],
               policy: %{},
               requirement: %{}
             })

    assert {:error, {:invalid_input, :decision}} = Approval.request(s, "run-1", :ask)
    d = decision()

    assert {:error, {:invalid_input, {:unknown_field, :extra}}} =
             Approval.request(s, "run-1", Map.put(d, :extra, 1))

    assert {:error, {:invalid_input, :escrow_not_action_writes}} =
             Approval.request(s, "run-1", %{d | escrowed: [%{post() | value: 1}]})

    assert {:error, {:invalid_input, :writes_not_normalized}} =
             Approval.request(s, "run-1", %{d | escrowed: d.escrowed ++ d.escrowed})

    assert {:error, {:invalid_input, :content_hash}} =
             Approval.request(s, "run-1", %{d | policy: %{d.policy | content_hash: "x"}})

    assert {:error, {:invalid_input, :scope}} =
             Approval.request(s, "run-1", %{d | requirement: %{d.requirement | scope: :forever}})

    assert {:error, {:invalid_input, :value_not_normalized}} =
             Approval.request(s, "run-1", %{
               d
               | action: %{d.action | payload: {:record, [{"b", 1}, {"a", 1}]}}
             })
  end

  test "request/3 validates every ASK decision key: reason, permitted and bounded rule ids" do
    s = Approval.new()
    d = decision()
    assert {:ok, _, _, _} = Approval.request(s, "run-1", d)

    assert {:error, {:invalid_input, :ask_reason}} =
             Approval.request(s, "run-1", %{d | reason: :allowed})

    assert {:error, {:invalid_input, :ask_reason}} =
             Approval.request(s, "run-1", %{d | reason: {:ask, req(:run)}})

    assert {:error, {:invalid_input, :ask_permits_writes}} =
             Approval.request(s, "run-1", %{d | permitted: [post()]})

    assert {:error, {:invalid_input, {:missing_field, :rules}}} =
             Approval.request(s, "run-1", Map.delete(d, :rules))

    assert {:error, {:invalid_input, {:not_a_list, :rules}}} =
             Approval.request(s, "run-1", %{d | rules: :all})

    assert {:error, {:invalid_input, {:empty, :rule_id}}} =
             Approval.request(s, "run-1", %{d | rules: [""]})

    ids = for i <- 1..1025, do: "r#{i}"
    assert {:ok, _, _, _} = Approval.request(s, "run-1", %{d | rules: Enum.take(ids, 1024)})

    assert {:error, {:invalid_input, {:bound_exceeded, :rules}}} =
             Approval.request(s, "run-1", %{d | rules: ids})

    long = String.duplicate("r", 1025)

    assert {:error, {:invalid_input, {:bound_exceeded, :rule_id}}} =
             Approval.request(s, "run-1", %{d | rules: [long]})
  end

  test "release events: key must match binding; a never-requested key is rejected" do
    {s, key} = setup_request()
    {:released, _, _, {:released, rel, nil}} = Approval.release(s, key, evidence(key), context())
    assert {:ok, _} = Approval.apply_event(s, {:released, rel, nil})

    for bad_key <- [
          put_elem(key, 1, "act-9"),
          put_elem(key, 2, "legal"),
          put_elem(key, 3, 2),
          put_elem(key, 0, "run-9")
        ] do
      forged = %{rel | key: bad_key, evidence: %{rel.evidence | request: bad_key}}

      assert {:error, {:invalid_input, :release_key_binding}} =
               Approval.apply_event(s, {:released, forged, nil})
    end

    # Consistent key and binding, but no request with that key exists in state
    # (revision 7 was never requested): rejected before Cure sees it, so no
    # release record can be planted for revalidate/3 to accept.
    unknown = put_elem(key, 4, 7)
    never = %{rel | key: unknown, evidence: %{rel.evidence | request: unknown}}

    assert {:error, {:invalid_input, :release_without_request}} =
             Approval.apply_event(s, {:released, never, nil})

    assert {:error, {:invalid_input, :release_without_request}} =
             Approval.replay([{:released, rel, nil}])

    {:ok, _, _, {:superseded, _, _} = sup} =
      Approval.request(s, "run-1", decision(:once, payload: {:text, "v2"}))

    {:ok, s_sup} = Approval.apply_event(s, sup)

    assert {:error, {:invalid_input, :release_of_superseded_request}} =
             Approval.apply_event(s_sup, {:released, rel, nil})
  end

  test "request/3 bounds: a 1024-byte write target is accepted, 1025 and 5000 bytes are rejected" do
    d = decision()

    assert {:ok, _, _, {:requested, _}} =
             Approval.request(Approval.new(), "run-1", put_target(d, String.duplicate("t", 1024)))

    for n <- [1025, 5000] do
      assert {:error, {:invalid_input, {:bound_exceeded, :target}}} =
               Approval.request(Approval.new(), "run-1", put_target(d, String.duplicate("t", n)))
    end
  end

  test "apply_event validates every event kind with the live bounds (limit and limit + 1)" do
    s = Approval.new()
    big = String.duplicate("v", 1024)
    over = big <> "v"
    assert {:ok, _} = Approval.apply_event(s, {:revoked, {big, "id"}})

    assert {:error, {:invalid_input, {:bound_exceeded, :verifier}}} =
             Approval.apply_event(s, {:revoked, {over, "id"}})

    {:ok, _, req, {:requested, _} = requested} = Approval.request(s, "run-1", decision())
    tenant = fn t -> {:requested, put_in(req, [:binding, :action, :tenant], t)} end
    assert {:ok, _} = Approval.apply_event(s, tenant.(big))

    assert {:error, {:invalid_input, {:bound_exceeded, :tenant}}} =
             Approval.apply_event(s, tenant.(over))

    assert {:error, {:invalid_input, :request_key_binding}} =
             Approval.apply_event(s, {:requested, %{req | key: put_elem(req.key, 1, "other")}})

    assert {:error, {:invalid_input, :request}} =
             Approval.apply_event(s, {:requested, %{req | status: :released}})

    {:ok, s1} = Approval.apply_event(s, requested)

    {:ok, _, _, {:superseded, old, new_req} = sup} =
      Approval.request(s1, "run-1", decision(:once, payload: {:text, "v2"}))

    assert {:ok, _} = Approval.apply_event(s1, sup)

    assert {:error, {:invalid_input, :superseded_event}} =
             Approval.apply_event(
               s1,
               {:superseded, old, %{new_req | key: put_elem(new_req.key, 4, 5)}}
             )

    assert {:error, {:invalid_input, {:bound_exceeded, :run}}} =
             Approval.apply_event(s1, {:superseded, put_elem(old, 0, over), new_req})

    {:released, _, _, {:released, rel, nil} = released} =
      Approval.release(s1, req.key, evidence(req.key), context())

    assert {:ok, _} = Approval.apply_event(s1, released)
    assert {:ok, _} = Approval.apply_event(s1, {:released, %{rel | root: big}, nil})

    assert {:error, {:invalid_input, {:bound_exceeded, :root}}} =
             Approval.apply_event(s1, {:released, %{rel | root: over}, nil})

    max = Integer.pow(2, 63) - 1
    assert {:ok, _} = Approval.apply_event(s1, {:released, %{rel | released_at: max}, nil})

    assert {:error, {:invalid_input, {:bound_exceeded, :released_at}}} =
             Approval.apply_event(s1, {:released, %{rel | released_at: max + 1}, nil})

    assert {:error, {:invalid_input, {:bound_exceeded, :evidence_id}}} =
             Approval.apply_event(
               s1,
               {:released, put_in(rel, [:evidence, :evidence_id], over), nil}
             )

    assert {:error, {:invalid_input, :released_writes}} =
             Approval.apply_event(s1, {:released, %{rel | writes: [%{post() | value: 2}]}, nil})

    assert {:error, {:invalid_input, :consent}} =
             Approval.apply_event(
               s1,
               {:released, rel,
                %{evidence: rel.evidence, binding: rel.binding, run: "other", root: rel.root}}
             )

    assert {:error, {:invalid_input, :event}} = Approval.apply_event(s1, {:unknown, 1})
  end

  test "a forged released or consent event with a rejecting decision is refused" do
    {s, key} = setup_request(:run)

    {:released, s2, _, {:released, rel, consent} = released} =
      Approval.release(s, key, evidence(key, scope: :run), context(:run))

    forged_rel = put_in(rel, [:evidence, :decision], :reject)

    assert {:error, {:invalid_input, :not_approving_evidence}} =
             Approval.replay([
               elem(Approval.request(Approval.new(), "run-1", decision(:run)), 3),
               {:released, forged_rel, nil}
             ])

    forged_consent = put_in(consent, [:evidence, :decision], :reject)

    assert {:error, {:invalid_input, :not_approving_evidence}} =
             Approval.apply_event(
               s,
               {:released, %{rel | evidence: forged_rel.evidence}, forged_consent}
             )

    # Defence in depth: even a state forged below the Elixir boundary fails closed in Cure.
    forged = flip(s2.cure)
    assert {:ok, %{}} = {:ok, Approval.inspect_state(%Approval.State{cure: forged})}

    assert {:refused, :rejected_by_reviewer} =
             Approval.revalidate(%Approval.State{cure: forged}, key, context(:run))

    assert :ok = Approval.revalidate(s2, key, context(:run))

    {:ok, s3, again, _} = Approval.request(s2, "run-1", decision(:run))
    assert {:ok, _} = Approval.select_retained(s3, again.key, context(:run))
    forged3 = %Approval.State{cure: flip(s3.cure)}

    assert {:refused, :no_retained_consent} =
             Approval.select_retained(forged3, again.key, context(:run))

    assert :no_retained_consent =
             refused(Approval.release(forged3, again.key, :retained, context(:run)))

    _ = released
  end

  defp flip(:ApprApprove), do: :ApprReject
  defp flip(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&flip/1) |> List.to_tuple()
  defp flip(l) when is_list(l), do: Enum.map(l, &flip/1)
  defp flip(x), do: x

  # ------------------------------------------------------------------ pinned refusal order (Q5)

  test "pinned refusal order: the first failing check is reported" do
    {s, key} = setup_request()
    ev = evidence(key)
    ctx = context()
    {:released, released, _, _} = Approval.release(s, key, ev, ctx)

    {:ok, superseded, new_req, _} =
      Approval.request(s, "run-1", decision(:once, payload: {:text, "v2"}))

    {:ok, revoked, _} = Approval.revoke(s, {"verifier-a", "ev-1"})
    other_run = %{id: "run-x", root: "root-1", ancestry: []}

    deny_rules = [
      %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req()},
      %{id: "x", effect_class: "publish", verdict: :deny}
    ]

    ambiguous = [
      %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req()},
      %{id: "law", effect_class: "publish", verdict: :ask, requirement: req(:once, "legal")}
    ]

    cases = [
      {"0 before 1", s, {"run-1", "nope", "human", 1, 1}, ev, %{ctx | run: other_run},
       :run_mismatch},
      {"1 before 4", s, {"run-1", "nope", "human", 1, 1}, ev, ctx, :unknown_request},
      {"2 before 3/4", released, key, evidence(key, id: "ev-2", issued_at: 99_999), ctx,
       :already_released},
      {"3 before 4", superseded, key, evidence(new_req.key), ctx, :superseded},
      {"4 before 5", s, key,
       evidence(key, request: {"run-1", "act-1", "human", 1, 7}, verifier: "nope"), ctx,
       :stale_revision},
      {"5 before 6", revoked, key, evidence(key, verifier: "nope"), ctx, :verifier_not_allowed},
      {"6 before 9", revoked, key, evidence(key, decision: :reject), ctx, :revoked},
      {"9 before 10", s, key, evidence(key, decision: :reject, issued_at: 3_000), ctx,
       :rejected_by_reviewer},
      {"10 before 13", s, key, evidence(key, issued_at: 3_000, scope: :run), ctx,
       :issued_in_future},
      {"11 before 12", s, key, evidence(key, issued_at: 0, expiry: 1_500), %{ctx | max_age: 1_000},
       :evidence_too_old},
      {"12 before 13", s, key, evidence(key, expiry: 1_500, scope: :run), ctx, :expired},
      {"13 before 14", s, key, evidence(key, scope: :run, reviewer: "human-2"), ctx,
       :scope_mismatch},
      {"14 before 15", s, key, evidence(key, reviewer: "agent-1"), ctx, :approver_mismatch},
      {"15 before 16", s, key, evidence(key, reviewer: "agent-1"),
       context(:once, reviewer: "agent-1", rules: ambiguous), :self_approval},
      {"17 before 18", s, key, ev, context(:once, rules: deny_rules, version: 3),
       {:deny_at_release, {:rule, "x"}}},
      {"18 before 19", s, key, ev, context(:once, version: 3, payload: {:text, "v2"}),
       :policy_changed},
      {"19 before 20", s, key, ev,
       context(:once,
         payload: {:text, "v2"},
         rules: [
           %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req(:once, "human", 2)}
         ]
       ), :payload_changed},
      {"20 before 21", s, key, ev,
       context(:once,
         rules: [
           %{id: "pub", effect_class: "publish", verdict: :ask, requirement: req(:once, "human", 2)}
         ],
         approver: %{identity: "human-1", authority: []}
       ), :requirement_changed},
      {"21", s, key, ev, context(:once, approver: %{identity: "human-1", authority: []}),
       :approver_not_authorized}
    ]

    for {label, state, k, e, c, expected} <- cases do
      assert {:refused, ^expected, ^state} = Approval.release(state, k, e, c), label
    end

    assert {:error, {:unavailable_context, {:ambiguous_requirement, _}}, ^s} =
             Approval.release(s, key, ev, context(:once, rules: ambiguous, version: 3))
  end
end
