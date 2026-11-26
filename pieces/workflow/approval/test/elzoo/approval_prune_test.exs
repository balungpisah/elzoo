# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ApprovalPruneTest do
  use ExUnit.Case, async: true
  alias Elzoo.Approval
  alias Elzoo.Approval.State
  alias Elzoo.Authorization, as: Auth

  @source File.read!(Path.expand("../../cure/elzoo/approval.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @max_time Integer.pow(2, 63) - 1
  @parents %{
    "child-1" => "root-1",
    "child-2" => "root-1",
    "child-3" => "root-2",
    "child-4" => "root-3"
  }

  # ------------------------------------------------------------------ fixtures

  defp post, do: %{target: "post:1", field: "state", value: {:text, "published"}}

  # Each policy body has its own identity: the content hash is a stable digest
  # of the body, so one (id, version, content_hash) never names two bodies
  # (the immutable-policy Need of domain/authorization).
  defp policy(scope, name \\ "human") do
    body = %{
      id: "pol",
      version: 1,
      effect_classes: ["publish"],
      rules: [
        %{
          id: "pub",
          effect_class: "publish",
          verdict: :ask,
          requirement: %{name: name, version: 1, scope: scope}
        }
      ]
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(body, [:deterministic]))
    Map.put(body, :content_hash, digest)
  end

  defp proposal(action_id, payload) do
    %{
      tenant: "t1",
      resource: "post:1",
      action_id: action_id,
      payload: {:text, payload},
      writes: [post()]
    }
  end

  defp authority, do: %{proposer: "agent-1", effect_class: "publish", own: [post()], parent: :none}

  defp decision(scope, action_id, payload, name \\ "human") do
    {:ok, %{verdict: :ask} = d} =
      Auth.decide(policy(scope, name), proposal(action_id, payload), authority())

    d
  end

  # A child Run has its root in its ancestry; every other Run is its own root.
  defp run_context(run) do
    case Map.fetch(@parents, run) do
      {:ok, root} -> %{id: run, root: root, ancestry: [root]}
      :error -> %{id: run, root: run, ancestry: []}
    end
  end

  defp context(scope, action_id, payload, run, now) do
    %{
      now: now,
      max_age: @max_time,
      verifiers: ["verifier-a"],
      run: run_context(run),
      policy: policy(scope),
      proposal: proposal(action_id, payload),
      authority: authority(),
      approver: %{identity: "human-1", authority: [post()]}
    }
  end

  defp evidence(key, id, scope, expiry) do
    %{
      verifier: "verifier-a",
      evidence_id: id,
      reviewer: "human-1",
      request: key,
      decision: :approve,
      scope: scope,
      issued_at: 1_000,
      expiry: expiry
    }
  end

  defp ask(s, run, scope, action_id, payload) do
    {:ok, s, request, _event} = Approval.request(s, run, decision(scope, action_id, payload))
    {s, request.key}
  end

  defp release!(s, {run, action_id, _, _, _} = key, source, scope, payload, now) do
    assert {:released, s, [_], _} =
             Approval.release(s, key, source, context(scope, action_id, payload, run, now))

    s
  end

  defp revoke!(s, ids) do
    Enum.reduce(ids, s, fn id, s ->
      {:ok, s, _} = Approval.revoke(s, {"verifier-a", id})
      s
    end)
  end

  defp prune!(s, now) do
    assert {:ok, %State{} = pruned} = Approval.prune(s, now)
    pruned
  end

  defp retire!(s, lines) do
    assert {:ok, %State{} = retired} = Approval.retire(s, lines)
    retired
  end

  defp view(s), do: Approval.inspect_state(s)
  defp keys(s), do: Enum.map(view(s).requests, & &1.key)

  # Each list of `small` is a subsequence of the same list of `big`: entries
  # are only removed, never added, changed or reordered.
  defp subsequence_state?(%State{cure: small}, %State{cure: big}) do
    Enum.zip(lists(small), lists(big)) |> Enum.all?(fn {a, b} -> subsequence?(a, b) end)
  end

  defp lists({:ApprState, rs, cs, rels, consumed, revoked}), do: [rs, cs, rels, consumed, revoked]

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([x | xs], [x | ys]), do: subsequence?(xs, ys)
  defp subsequence?(xs, [_ | ys]), do: subsequence?(xs, ys)

  # ------------------------------------------------------------------ harness history

  # A public-API history that keeps the Verifier Need: every evidence key has
  # one record, and a retained release reuses the stored record. Releases run
  # at 2_000..2_400; short evidence expires at 5_000, long evidence at 100_000.
  defp history do
    s = Approval.new()
    # Line A (once): revision 1 released (short), 2 released (long), 3 open.
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "a1", :once, 5_000), :once, "a", 2_000)
    {s, a2} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a2, evidence(a2, "a2", :once, 100_000), :once, "a", 2_100)
    {s, _a3} = ask(s, "run-1", :once, "act-a", "a")
    # Line B (once): revision 1 superseded by revision 2 (open).
    {s, _b1} = ask(s, "run-1", :once, "act-b", "b1")
    {s, _b2} = ask(s, "run-1", :once, "act-b", "b2")
    # Line C (run): revision 1 released (short) with a consent, revision 2
    # released from that consent, revision 3 open.
    {s, c1} = ask(s, "run-1", :run, "act-c", "c")
    s = release!(s, c1, evidence(c1, "c1", :run, 5_000), :run, "c", 2_000)
    {s, c2} = ask(s, "run-1", :run, "act-c", "c")
    s = release!(s, c2, :retained, :run, "c", 2_200)
    {s, _c3} = ask(s, "run-1", :run, "act-c", "c")
    # Line D (run): revision 1 released (long) with a consent, revision 2 open.
    {s, d1} = ask(s, "run-1", :run, "act-d", "d")
    s = release!(s, d1, evidence(d1, "d1", :run, 100_000), :run, "d", 2_000)
    {s, _d2} = ask(s, "run-1", :run, "act-d", "d")
    # Lines E (root): a root consent (long) serves child-1; child-2 is open.
    {s, e1} = ask(s, "root-1", :root, "act-e", "e")
    s = release!(s, e1, evidence(e1, "e1", :root, 100_000), :root, "e", 2_000)
    {s, ce1} = ask(s, "child-1", :root, "act-e", "e")
    s = release!(s, ce1, :retained, :root, "e", 2_300)
    {s, _ce2} = ask(s, "child-2", :root, "act-e", "e")
    # Lines F (root): a root consent (short); child-3 is open.
    {s, f1} = ask(s, "root-2", :root, "act-f", "f")
    s = release!(s, f1, evidence(f1, "f1", :root, 5_000), :root, "f", 2_000)
    {s, _cf} = ask(s, "child-3", :root, "act-f", "f")
    # Line G (once): revision 1 released (short) is the newest.
    {s, g1} = ask(s, "run-1", :once, "act-g", "g")
    s = release!(s, g1, evidence(g1, "g1", :once, 5_000), :once, "g", 2_000)
    # Lines H (root): a root consent (long) serves child-4; its key is revoked.
    {s, h1} = ask(s, "root-3", :root, "act-h", "h")
    s = release!(s, h1, evidence(h1, "h1", :root, 100_000), :root, "h", 2_000)
    {s, ch} = ask(s, "child-4", :root, "act-h", "h")
    s = release!(s, ch, :retained, :root, "h", 2_400)
    # Revocations: seen and short, seen and long, seen on a root consent, unseen.
    revoke!(s, ["a1", "a2", "h1", "ghost"])
  end

  defp history_lines(s),
    do: keys(s) |> Enum.map(fn {run, aid, _, _, _} -> {run, aid} end) |> Enum.uniq()

  # The record of the unseen revoked key "ghost" (Verifier Need: one record).
  defp ghost, do: evidence({"run-1", "act-a", "human", 1, 3}, "ghost", :once, 200_000)

  # Every input of the harness: each request key of `s` and one unknown key,
  # with its line's scope, action and payload, and one source: each evidence
  # record that `s` stores, the unseen revoked record, fresh evidence for the
  # key, :retained, or the :select and :revalidate calls.
  defp probes(s) do
    v = view(s)
    stored = Enum.uniq(Enum.map(v.releases, & &1.evidence) ++ Enum.map(v.consents, & &1.evidence))

    known =
      for %{key: key, binding: b} <- v.requests do
        {:text, payload} = b.action.payload
        {key, {b.requirement.scope, b.action.action_id, payload}}
      end

    unknown = {{"run-1", "act-z", "human", 1, 1}, {:once, "act-z", "z"}}

    for {{run, aid, _, _, rev} = key, {scope, _, _} = line} <- known ++ [unknown],
        source <- [
          :select,
          :revalidate,
          :retained,
          ghost(),
          evidence(key, "fresh-#{run}-#{aid}-#{rev}", scope, 200_000) | stored
        ] do
      {key, line, source}
    end
  end

  defp outcomes(state, probes, now) do
    Map.new(probes, fn {{run, _, _, _, _} = key, {scope, aid, payload}, source} = probe ->
      {probe, outcome(state, key, source, context(scope, aid, payload, run, now))}
    end)
  end

  defp outcome(s, key, :select, ctx), do: {:select, Approval.select_retained(s, key, ctx)}
  defp outcome(s, key, :revalidate, ctx), do: {:revalidate, Approval.revalidate(s, key, ctx)}

  defp outcome(s, key, source, ctx) do
    case Approval.release(s, key, source, ctx) do
      {:released, _state, writes, event} -> {:release, {:released, writes, event}}
      {:refused, reason, _state} -> {:release, {:refused, reason}}
      {:error, error, _state} -> {:release, {:error, error}}
    end
  end

  # request/3 inputs: every (line, payload) of `s`, a changed payload per
  # line and a new line.
  defp request_probes(s) do
    known =
      for %{key: {run, aid, _, _, _}, binding: b} <- view(s).requests, uniq: true do
        {:text, payload} = b.action.payload
        {run, b.requirement.scope, aid, payload}
      end

    changed = for {run, scope, aid, _} <- known, uniq: true, do: {run, scope, aid, "changed"}
    known ++ changed ++ [{"run-1", :once, "act-new", "n"}]
  end

  defp request_outcomes(state, probes) do
    Map.new(probes, fn {run, scope, aid, payload} = probe ->
      {:ok, _state, request, event} = Approval.request(state, run, decision(scope, aid, payload))
      {probe, {request, event}}
    end)
  end

  # The refusal changes that prune/2 may cause; every other outcome is equal.
  defp allowed_change?({op, {:refused, from}}, {op, {:refused, :unknown_request}})
       when op in [:release, :select],
       do: from in [:superseded, :already_released]

  defp allowed_change?({:revalidate, {:refused, _}}, {:revalidate, {:refused, :not_released}}),
    do: true

  defp allowed_change?(_, _), do: false

  # ------------------------------------------------------------------ direct builders

  # The requests that request/3 builds for n calls on one line whose payload
  # alternates v1, v2, ...: revisions 1..n-1 superseded, revision n open. Built
  # directly: the public API is quadratic in the length of the list.
  defp chain(n) do
    {:ApprState, [{:ApprRequest, key, v1, _}, {:ApprRequest, _, v2, _}], [], [], [], []} =
      public_chain(2).cure

    requests =
      for k <- 1..n do
        {:ApprRequest, put_elem(key, 5, k), if(rem(k, 2) == 1, do: v1, else: v2),
         if(k < n, do: :ApprSuperseded, else: :ApprOpen)}
      end

    %State{cure: {:ApprState, requests, [], [], [], []}}
  end

  defp public_chain(n) do
    Enum.reduce(1..n, Approval.new(), fn k, s ->
      {s, _} = ask(s, "run-1", :once, "act-1", if(rem(k, 2) == 1, do: "v1", else: "v2"))
      s
    end)
  end

  # Line i is ("run-i", "act-1") of scope kind.(i), released with evidence
  # "ev-i" (expiry 100_000); then the evidence ids in `revoked` are revoked.
  defp public_lines(n, kind, revoked) do
    0..(n - 1)
    |> Enum.reduce(Approval.new(), fn i, s ->
      {s, key} = ask(s, "run-#{i}", kind.(i), "act-1", "p")
      release!(s, key, evidence(key, "ev-#{i}", kind.(i), 100_000), kind.(i), "p", 2_000)
    end)
    |> revoke!(revoked)
  end

  # The same state built directly from one public-API line per scope.
  defp lines_state(n, kind, revoked) do
    parts = line_parts(n, kind)

    %State{
      cure:
        {:ApprState, Enum.map(parts, &elem(&1, 0)), Enum.flat_map(parts, &elem(&1, 1)),
         Enum.map(parts, &elem(&1, 2)), Enum.flat_map(parts, &elem(&1, 3)),
         Enum.map(revoked, &ekey/1)}
    }
  end

  # {request, consents, release record, consumed keys} of each line.
  defp line_parts(n, kind) do
    templates =
      Map.new([:once, :run, :root], fn scope ->
        {s, key} = ask(Approval.new(), "run-0", scope, "act-1", "p")
        s = release!(s, key, evidence(key, "ev-0", scope, 100_000), scope, "p", 2_000)
        {:ApprState, [request], consents, [release], consumed, []} = s.cure
        {scope, {request, consents, release, consumed}}
      end)

    for i <- 0..(n - 1) do
      subst(templates[kind.(i)], [{~c"run-0", ~c"run-#{i}"}, {~c"ev-0", ~c"ev-#{i}"}])
    end
  end

  # Replace each byte-list text `from` by `to` inside a Cure term.
  defp subst(term, pairs) when is_list(term) do
    case List.keyfind(pairs, term, 0) do
      {_, to} -> to
      nil -> Enum.map(term, &subst(&1, pairs))
    end
  end

  defp subst(term, pairs) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&subst(&1, pairs)) |> List.to_tuple()

  defp subst(term, _pairs), do: term

  defp ekey(id), do: {:ApprEvidenceKey, ~c"verifier-a", String.to_charlist(id)}

  # ------------------------------------------------------------------ Cure laws: negative controls

  defp mutated(name, from, to) do
    assert String.contains?(@source, from), "mutation anchor missing: #{from}"

    src =
      @source
      |> String.replace("mod Elzoo.Approval", "mod Elzoo.ApprovalNeg" <> name)
      |> String.replace(from, to, global: false)

    refute src == @source
    Cure.Compiler.compile_and_load(src, source_roots: @roots)
  end

  # The mutation is rejected inside the named law: a conversion failure whose
  # line lies in the law's definition (its `fn` line up to the next blank line;
  # a mutation never changes the number of lines).
  defp assert_rejected_by(law, result) do
    assert {:error, {:codegen_error, {:source_context, inner, %{line: line}}}} = result
    assert elem(inner, 0) == :conversion_failure
    lines = String.split(@source, "\n")
    start = Enum.find_index(lines, &String.starts_with?(&1, "  fn #{law}(")) + 1
    stop = start + (lines |> Enum.drop(start) |> Enum.find_index(&(&1 == "")))
    assert line in start..stop, "#{law} spans lines #{start}..#{stop}; the failure is at #{line}"
  end

  test "negative control: a prune decision that drops an open request is rejected" do
    assert_rejected_by(
      :prune_keeps_open,
      mutated(
        "PruneOpen",
        "      ApprOpen() -> True()\n      _ -> either(newest, released)",
        "      ApprOpen() -> either(newest, released)\n      _ -> either(newest, released)"
      )
    )
  end

  test "negative control: a prune decision that drops the newest request of a line is rejected" do
    assert_rejected_by(
      :prune_keeps_newest,
      mutated("PruneNewest", "      _ -> either(newest, released)", "      _ -> released")
    )
  end

  test "negative control: a prune decision that drops a live record is rejected" do
    assert_rejected_by(
      :prune_keeps_live,
      mutated(
        "PruneLive",
        "      KeyRecord(e) -> lt_int(now, expiry_of(e))",
        "      KeyRecord(e) -> False()"
      )
    )
  end

  test "negative control: a prune decision that drops the records of an ambiguous key is rejected" do
    assert_rejected_by(
      :prune_keeps_ambiguous,
      mutated("PruneAmbiguous", "      KeyAmbiguous() -> True()", "      KeyAmbiguous() -> False()")
    )
  end

  test "negative control: a retire decision that drops an entry of another line is rejected" do
    assert_rejected_by(
      :retire_keeps_other_entry,
      mutated(
        "RetireOther",
        "fn retire_keeps_entry(on_line: Bool) -> Bool = not_b(on_line)",
        "fn retire_keeps_entry(on_line: Bool) -> Bool = False()"
      )
    )
  end

  # ------------------------------------------------------------------ prune boundaries

  test "prune: an expiry equal to now is dropped from every list and an expiry one later is kept" do
    s = Approval.new()
    {s, once} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, once, evidence(once, "ev-once", :once, 5_000), :once, "a", 2_000)
    {s, run} = ask(s, "run-1", :run, "act-b", "b")
    s = release!(s, run, evidence(run, "ev-run", :run, 5_000), :run, "b", 2_000)
    s = revoke!(s, ["ev-once", "ev-run"])
    v = view(s)
    assert length(v.releases) == 2 and length(v.consents) == 1
    assert v.consumed == [{"verifier-a", "ev-once"}] and length(v.revoked) == 2

    assert {:ok, ^s} = Approval.prune(s, 4_999)

    pruned = view(prune!(s, 5_000))
    assert pruned.releases == [] and pruned.consents == []
    assert pruned.consumed == [] and pruned.revoked == []
    # Both requests are the newest entries of their lines, so they stay.
    assert pruned.requests == v.requests
  end

  test "prune: a revocation of evidence the state never saw is kept" do
    s = Approval.new()
    {s, key} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, key, evidence(key, "ev-1", :once, 5_000), :once, "a", 2_000)
    s = revoke!(s, ["ev-unseen", "ev-1"])
    pruned = view(prune!(s, @max_time))
    assert pruned.revoked == [{"verifier-a", "ev-unseen"}]
    assert pruned.releases == [] and pruned.consumed == []
  end

  test "prune: the consumed marker of a live once release is kept until its expiry" do
    s = Approval.new()
    {s, key} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, key, evidence(key, "ev-1", :once, 100_000), :once, "a", 2_000)
    assert view(s).consumed == [{"verifier-a", "ev-1"}]
    assert {:ok, ^s} = Approval.prune(s, 99_999)

    pruned = view(prune!(s, 100_000))
    assert pruned.consumed == [] and pruned.releases == []
    assert [%{key: ^key, status: :released}] = pruned.requests
  end

  test "prune: an ambiguous evidence key is never dead; both records and its revocation stay" do
    s = Approval.new()
    {s, k1} = ask(s, "run-1", :run, "act-a", "a")
    s = release!(s, k1, evidence(k1, "ev-same", :run, 5_000), :run, "a", 2_000)
    {s, k2} = ask(s, "run-1", :run, "act-a", "a")
    s = release!(s, k2, evidence(k2, "ev-same", :run, 50_000), :run, "a", 2_100)
    s = revoke!(s, ["ev-same"])
    v = view(s)
    assert [%{evidence: e1}, %{evidence: e2}] = v.releases
    assert e1 != e2 and {e1.verifier, e1.evidence_id} == {e2.verifier, e2.evidence_id}
    assert Enum.map(v.consents, & &1.evidence) == [e1, e2]
    assert v.consumed == [] and v.revoked == [{"verifier-a", "ev-same"}]

    for now <- [20_000, @max_time] do
      assert {:ok, ^s} = Approval.prune(s, now)
    end
  end

  test "prune: request/3 on a released line opens the newest revision plus one" do
    s = Approval.new()
    {s, g1} = ask(s, "run-1", :once, "act-g", "g")
    s = release!(s, g1, evidence(g1, "ev-g1", :once, 5_000), :once, "g", 2_000)
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "ev-a1", :once, 5_000), :once, "a", 2_000)
    {s, a2} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a2, evidence(a2, "ev-a2", :once, 5_000), :once, "a", 2_100)

    pruned = prune!(s, 5_000)
    # The released newest entry of each line stays; the older one leaves.
    assert keys(pruned) == [g1, a2]
    assert view(pruned).releases == [] and view(pruned).consumed == []

    assert {:ok, _, %{key: {"run-1", "act-g", "human", 1, 2}}, {:requested, _}} =
             Approval.request(pruned, "run-1", decision(:once, "act-g", "g"))

    assert {:ok, _, %{key: {"run-1", "act-a", "human", 1, 3}}, {:requested, _}} =
             Approval.request(pruned, "run-1", decision(:once, "act-a", "a"))
  end

  test "prune: every entry at the highest revision of a line and every open entry stay (replayed logs)" do
    # Only apply_event/2 builds these: request/3 keeps one open entry per line,
    # at its highest revision, and never two entries at one revision. Each
    # event comes from a public transition on a fresh state (the "legal"
    # requirement from its own policy); only the open revisions are set here.
    [{human, req_h, rel_h}, {legal, req_l, rel_l}] =
      for name <- ["human", "legal"] do
        {:ok, s, req, requested} =
          Approval.request(Approval.new(), "run-1", decision(:once, "act-a", "a", name))

        ctx = %{context(:once, "act-a", "a", "run-1", 2_000) | policy: policy(:once, name)}
        ev = evidence(req.key, "ev-" <> name, :once, 5_000)
        {:released, _, _, released} = Approval.release(s, req.key, ev, ctx)
        {req.key, requested, released}
      end

    {:ok, _, other, _} = Approval.request(Approval.new(), "run-1", decision(:once, "act-b", "a"))
    b_key = fn rev -> put_elem(other.key, 4, rev) end
    open = fn rev -> {:requested, %{other | key: b_key.(rev)}} end
    assert {:ok, s} = Approval.replay([req_h, req_l, rel_h, rel_l, open.(3), open.(2)])

    assert Enum.map(view(s).requests, &{&1.key, &1.status}) == [
             {human, :released},
             {legal, :released},
             {b_key.(3), :open},
             {b_key.(2), :open}
           ]

    pruned = prune!(s, 5_000)
    assert view(pruned).releases == [] and view(pruned).consumed == []
    assert view(pruned).requests == view(s).requests
    d = decision(:once, "act-a", "a")
    assert {:ok, _, %{key: {_, _, _, _, 2}} = req, ev} = Approval.request(s, "run-1", d)
    assert {:ok, _, ^req, ^ev} = Approval.request(pruned, "run-1", d)
  end

  test "prune at the same time is idempotent and only removes entries, in order" do
    {amb, k1} = ask(Approval.new(), "run-1", :run, "act-a", "a")
    amb = release!(amb, k1, evidence(k1, "ev-same", :run, 5_000), :run, "a", 2_000)
    {amb, k2} = ask(amb, "run-1", :run, "act-a", "a")
    amb = release!(amb, k2, evidence(k2, "ev-same", :run, 50_000), :run, "a", 2_100)

    for s <- [history(), amb, chain(5)], t <- [0, 2_000, 4_999, 5_000, 5_001, 100_000, @max_time] do
      pruned = prune!(s, t)
      assert {:ok, ^pruned} = Approval.prune(pruned, t)
      assert subsequence_state?(pruned, s)
    end
  end

  # ------------------------------------------------------------------ retire boundaries

  test "retiring the same lines twice equals retiring them once" do
    s = history()
    lines = history_lines(s)

    for set <- [[{"run-1", "act-a"}], [{"run-1", "act-c"}, {"root-1", "act-e"}], lines] do
      retired = retire!(s, set)
      assert retired != s
      assert {:ok, ^retired} = Approval.retire(retired, set)
      assert {:ok, ^retired} = Approval.retire(s, set ++ Enum.reverse(set))
      assert subsequence_state?(retired, s)
    end
  end

  test "retiring an absent line changes nothing; a duplicate pair is retired once" do
    s = history()

    assert {:ok, ^s} =
             Approval.retire(s, [{"run-9", "act-z"}, {"run-1", "act-z"}, {"root-1", "act-a"}])

    assert {:ok, ^s} = Approval.retire(s, [])
    retired = retire!(s, [{"run-1", "act-a"}])
    assert {:ok, ^retired} = Approval.retire(s, [{"run-1", "act-a"}, {"run-1", "act-a"}])
  end

  test "request/3 on a retired line opens revision 1 (Retirement Need)" do
    s = history()
    d = decision(:once, "act-a", "a")

    assert {:ok, ^s, %{key: {"run-1", "act-a", "human", 1, 3}}, nil} =
             Approval.request(s, "run-1", d)

    retired = retire!(s, [{"run-1", "act-a"}])

    assert {:ok, _, %{key: {"run-1", "act-a", "human", 1, 1}}, {:requested, _}} =
             Approval.request(retired, "run-1", d)
  end

  test "retire accepts 65,536 pairs and refuses 65,537; a repeated pair is encoded once" do
    s = history()
    line = {"run-1", "act-a"}
    assert {:ok, retired} = Approval.retire(s, List.duplicate(line, 65_536))
    assert {:ok, ^retired} = Approval.retire(s, [line])

    assert {:error, {:invalid_input, {:bound_exceeded, :lines}}} =
             Approval.retire(s, List.duplicate(line, 65_537))

    # Encoding each of 65,536 copies of one pair of 1,024-byte identities would
    # take about 2 GiB; the call finishes under a 32 MiB heap limit.
    long = {String.duplicate("r", 1024), String.duplicate("a", 1024)}

    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false})
        Approval.retire(s, List.duplicate(long, 65_536))
      end)

    assert {:ok, ^s} = Task.await(task, 60_000)
  end

  test "retire retains no encoding of an absent pair: 65,536 distinct absent pairs fit a heap limit" do
    s = history()
    present = {"run-1", "act-a"}
    long = fn prefix, i -> String.pad_trailing(prefix <> Integer.to_string(i), 1024, "x") end

    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: 16_000_000, kill: true, error_logger: false})
        # Encoding each distinct pair of 1,024-byte identities would take about
        # 2 GiB; only the pairs that the state names are kept, under 128 MiB.
        absent = for i <- 1..65_536, do: {long.("r", i), long.("a", i)}
        {Approval.retire(s, absent), Approval.retire(s, [present | tl(absent)])}
      end)

    assert {{:ok, ^s}, {:ok, with_present}} = Task.await(task, 120_000)
    assert {:ok, ^with_present} = Approval.retire(s, [present])
  end

  test "a malformed now, a malformed pair and a value that is not a state are refused" do
    s = history()

    for now <- [-1, @max_time + 1, 5_000.0, "5000", nil] do
      assert {:error, {:invalid_input, {:bound_exceeded, :now}}} = Approval.prune(s, now)
    end

    assert {:ok, _} = Approval.prune(s, 0)
    assert {:ok, _} = Approval.prune(s, @max_time)
    long = String.duplicate("r", 1025)

    cases = [
      {[{"", "act-a"}], {:empty, :run}},
      {[{"run-1", ""}], {:empty, :action_id}},
      {[{long, "act-a"}], {:bound_exceeded, :run}},
      {[{"run-1", long}], {:bound_exceeded, :action_id}},
      {[{<<0xFF>>, "act-a"}], {:invalid_utf8, :run}},
      {[{:run, "act-a"}], {:not_text, :run}},
      {[{"run-1", 1}], {:not_text, :action_id}},
      {[{"run-1", "act-a", 1}], :line},
      {[["run-1", "act-a"]], :line},
      {[{"run-1", "act-a"}, :x], :line},
      {[{"run-1", "act-a"} | :tail], {:not_a_list, :lines}},
      {:all, {:not_a_list, :lines}}
    ]

    for {lines, reason} <- cases do
      assert {:error, {:invalid_input, ^reason}} = Approval.retire(s, lines), inspect(lines)
    end

    assert {:ok, _} = Approval.retire(s, [{String.duplicate("r", 1024), "act-a"}])

    # Outer shape only: the five list spines must be proper lists.
    improper =
      for i <- 1..5, do: %State{cure: put_elem(s.cure, i, elem(s.cure, i) ++ :tail)}

    bad =
      [
        :state,
        nil,
        %{},
        s.cure,
        view(s),
        %State{cure: :bogus},
        %State{cure: {:ApprState, [], [], [], []}},
        %State{cure: {:ApprState, :x, [], [], [], []}}
      ] ++ improper

    for state <- bad do
      assert {:error, {:invalid_input, :state}} = Approval.prune(state, 5_000)
      assert {:error, {:invalid_input, :state}} = Approval.prune(state, -1)
      assert {:error, {:invalid_input, :state}} = Approval.retire(state, [])
      assert {:error, {:invalid_input, :state}} = Approval.retire(state, :all)
    end
  end

  # ------------------------------------------------------------------ changed refusals

  test "after prune a dropped superseded request gives unknown_request instead of superseded" do
    s = Approval.new()
    {s, b1} = ask(s, "run-1", :once, "act-b", "b1")
    {s, b2} = ask(s, "run-1", :once, "act-b", "b2")
    ev = evidence(b1, "ev-b1", :once, 200_000)
    ctx = context(:once, "act-b", "b1", "run-1", 6_000)
    pruned = prune!(s, 6_000)
    assert keys(pruned) == [b2]

    # Checks 0-2 pass; check 3 refuses before, check 1 after.
    assert {:refused, :superseded, ^s} = Approval.release(s, b1, ev, ctx)
    assert {:refused, :unknown_request, ^pruned} = Approval.release(pruned, b1, ev, ctx)
    assert {:refused, :superseded} = Approval.select_retained(s, b1, ctx)
    assert {:refused, :unknown_request} = Approval.select_retained(pruned, b1, ctx)
  end

  test "after prune a dropped non-newest released request gives unknown_request instead of already_released" do
    s = Approval.new()
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "ev-a1", :once, 5_000), :once, "a", 2_000)
    {s, a2} = ask(s, "run-1", :once, "act-a", "a")
    ev = evidence(a1, "ev-fresh", :once, 200_000)
    ctx = context(:once, "act-a", "a", "run-1", 6_000)
    pruned = prune!(s, 5_000)
    assert keys(pruned) == [a2]

    # Checks 0-1 pass; check 2 refuses before, check 1 after.
    assert {:refused, :already_released, ^s} = Approval.release(s, a1, ev, ctx)
    assert {:refused, :unknown_request, ^pruned} = Approval.release(pruned, a1, ev, ctx)
    assert {:refused, :already_released} = Approval.select_retained(s, a1, ctx)
    assert {:refused, :unknown_request} = Approval.select_retained(pruned, a1, ctx)
  end

  test "after prune a restore whose release record was dropped gives not_released instead of expired" do
    s = Approval.new()
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "ev-a1", :once, 5_000), :once, "a", 2_000)
    assert :ok = Approval.revalidate(s, a1, context(:once, "act-a", "a", "run-1", 4_999))
    ctx = context(:once, "act-a", "a", "run-1", 6_000)
    # Checks 0, 5, 6 and 9-11 pass; check 12 refuses.
    assert {:refused, :expired} = Approval.revalidate(s, a1, ctx)
    pruned = prune!(s, 5_000)
    assert view(pruned).releases == []
    assert {:refused, :not_released} = Approval.revalidate(pruned, a1, ctx)
  end

  test "on a retired line release/4 gives unknown_request" do
    s = Approval.new()
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "ev-a1", :once, 100_000), :once, "a", 2_000)
    {s, a2} = ask(s, "run-1", :once, "act-a", "a")
    ctx = context(:once, "act-a", "a", "run-1", 3_000)
    open = evidence(a2, "ev-a2", :once, 100_000)
    again = evidence(a1, "ev-again", :once, 100_000)
    assert {:released, _, [_], _} = Approval.release(s, a2, open, ctx)
    assert {:refused, :already_released, ^s} = Approval.release(s, a1, again, ctx)
    retired = retire!(s, [{"run-1", "act-a"}])
    # Check 0 passes; check 1 refuses. A context of another Run still fails check 0.
    assert {:refused, :unknown_request, ^retired} = Approval.release(retired, a2, open, ctx)
    assert {:refused, :unknown_request, ^retired} = Approval.release(retired, a1, again, ctx)
    elsewhere = context(:once, "act-a", "a", "run-9", 3_000)
    assert {:refused, :run_mismatch, ^s} = Approval.release(s, a2, open, elsewhere)
    assert {:refused, :run_mismatch, ^retired} = Approval.release(retired, a2, open, elsewhere)
  end

  test "on a retired line select_retained/3 gives unknown_request" do
    s = Approval.new()
    {s, d1} = ask(s, "run-1", :run, "act-d", "d")
    s = release!(s, d1, evidence(d1, "ev-d1", :run, 100_000), :run, "d", 2_000)
    {s, d2} = ask(s, "run-1", :run, "act-d", "d")
    ctx = context(:run, "act-d", "d", "run-1", 3_000)
    assert {:ok, %{evidence: %{evidence_id: "ev-d1"}}} = Approval.select_retained(s, d2, ctx)
    retired = retire!(s, [{"run-1", "act-d"}])

    assert view(retired) == %{requests: [], consents: [], releases: [], consumed: [], revoked: []}

    assert {:refused, :unknown_request} = Approval.select_retained(retired, d2, ctx)
    assert {:refused, :unknown_request, ^retired} = Approval.release(retired, d2, :retained, ctx)
    elsewhere = context(:run, "act-d", "d", "run-9", 3_000)
    assert {:refused, :run_mismatch} = Approval.select_retained(s, d2, elsewhere)
    assert {:refused, :run_mismatch} = Approval.select_retained(retired, d2, elsewhere)
  end

  test "on a retired line revalidate/3 gives not_released" do
    s = Approval.new()
    {s, a1} = ask(s, "run-1", :once, "act-a", "a")
    s = release!(s, a1, evidence(a1, "ev-a1", :once, 100_000), :once, "a", 2_000)
    ctx = context(:once, "act-a", "a", "run-1", 3_000)
    assert :ok = Approval.revalidate(s, a1, ctx)
    retired = retire!(s, [{"run-1", "act-a"}])
    assert {:refused, :not_released} = Approval.revalidate(retired, a1, ctx)
  end

  test "below the prune time a consent that the unpruned state selects is gone (Clock Need)" do
    s = Approval.new()
    {s, c1} = ask(s, "run-1", :run, "act-c", "c")
    s = release!(s, c1, evidence(c1, "ev-c1", :run, 5_000), :run, "c", 2_000)
    {s, c2} = ask(s, "run-1", :run, "act-c", "c")
    early = context(:run, "act-c", "c", "run-1", 4_000)
    assert {:ok, %{evidence: %{evidence_id: "ev-c1"}}} = Approval.select_retained(s, c2, early)
    assert {:released, _, [_], _} = Approval.release(s, c2, :retained, early)

    pruned = prune!(s, 6_000)
    assert view(pruned).consents == []
    assert {:refused, :no_retained_consent} = Approval.select_retained(pruned, c2, early)

    assert {:refused, :no_retained_consent, ^pruned} =
             Approval.release(pruned, c2, :retained, early)
  end

  # ------------------------------------------------------------------ equivalence

  test "equivalence: after prune every release, selection, restore and request at a later time agrees" do
    s = history()
    probes = probes(s)
    times = [2_000, 4_999, 5_000, 5_001, 99_999, 100_000, 150_000, @max_time]
    base = Map.new(times, &{&1, outcomes(s, probes, &1)})
    requests = request_probes(s)
    base_requests = request_outcomes(s, requests)

    changes =
      for t <- [2_000, 4_999, 5_000, 5_001, 100_000, @max_time], reduce: [] do
        acc ->
          pruned = prune!(s, t)
          assert subsequence_state?(pruned, s) and pruned != s
          assert request_outcomes(pruned, requests) == base_requests

          for now <- times, now >= t, reduce: acc do
            acc ->
              after_prune = outcomes(pruned, probes, now)

              Enum.reduce(base[now], acc, fn {probe, before}, acc ->
                found = Map.fetch!(after_prune, probe)

                cond do
                  found == before ->
                    acc

                  allowed_change?(before, found) ->
                    [{before, found} | acc]

                  true ->
                    flunk(
                      "prune at #{t}, now #{now}, #{inspect(probe)}: " <>
                        "#{inspect(before)} became #{inspect(found)}"
                    )
                end
              end)
          end
      end

    # The history exercises every kind of outcome and every allowed change.
    all = Enum.flat_map(times, &Map.values(base[&1]))
    released = Enum.filter(all, &match?({:release, {:released, _, _}}, &1))
    assert length(released) > 10
    assert Enum.any?(all, &match?({:select, {:ok, _}}, &1))
    assert Enum.any?(all, &match?({:revalidate, :ok}, &1))
    assert Enum.any?(all, &match?({:release, {:refused, :revoked}}, &1))

    for {op, from} <- [
          {:release, :superseded},
          {:release, :already_released},
          {:select, :superseded},
          {:select, :already_released}
        ] do
      assert {{op, {:refused, from}}, {op, {:refused, :unknown_request}}} in changes
    end

    restores = for {{:revalidate, {:refused, from}}, _} <- changes, uniq: true, do: from
    assert :expired in restores and :revoked in restores
  end

  test "equivalence: retire changes nothing for every input on the lines it keeps" do
    s = history()
    lines = history_lines(s)
    assert length(lines) == 12
    probes = probes(s)
    times = [2_500, 5_000, 99_999, 150_000]
    base = Map.new(times, &{&1, outcomes(s, probes, &1)})
    requests = request_probes(s)
    base_requests = request_outcomes(s, requests)
    sets = Enum.map(lines, &[&1]) ++ Enum.map(lines, &List.delete(lines, &1)) ++ [lines]

    compared =
      for set <- sets, reduce: [] do
        acc ->
          retired = retire!(s, set)
          assert subsequence_state?(retired, s) and retired != s
          kept? = fn {run, aid, _, _, _} -> {run, aid} not in set end
          kept_probes = Enum.filter(probes, fn {key, _, _} -> kept?.(key) end)
          kept_requests = Enum.reject(requests, fn {run, _, aid, _} -> {run, aid} in set end)

          assert request_outcomes(retired, kept_requests) ==
                   Map.take(base_requests, kept_requests)

          for now <- times, reduce: acc do
            acc ->
              found = outcomes(retired, kept_probes, now)
              assert found == Map.take(base[now], kept_probes), "retire #{inspect(set)} at #{now}"
              Map.values(found) ++ acc
          end
      end

    # A retired root line keeps its root consent, which still serves its children.
    retired = retire!(s, [{"root-1", "act-e"}])
    assert Enum.any?(view(retired).consents, &(&1.evidence.evidence_id == "e1"))
    child = {"child-2", "act-e", "human", 1, 1}
    ctx = context(:root, "act-e", "e", "child-2", 3_000)
    assert {:released, _, [_], _} = Approval.release(retired, child, :retained, ctx)
    # A revocation that a surviving root consent names stays.
    assert {"verifier-a", "h1"} in view(retire!(s, [{"root-3", "act-h"}, {"child-4", "act-h"}])).revoked

    assert Enum.count(compared, &match?({:release, {:released, _, _}}, &1)) > 10
    assert Enum.any?(compared, &match?({:select, {:ok, _}}, &1))
    assert Enum.any?(compared, &match?({:revalidate, :ok}, &1))
    assert Enum.any?(compared, &match?({:revalidate, {:refused, :revoked}}, &1))
  end

  # ------------------------------------------------------------------ capacity and scale

  test "capacity: a superseded chain of 65,536 requests refuses request/3 until prune" do
    assert chain(4) == public_chain(4)
    full = chain(65_536)
    adds = decision(:once, "act-1", "v1")

    assert {:error, {:invalid_input, {:bound_exceeded, :state}}} =
             Approval.request(full, "run-1", adds)

    pruned = prune!(full, 10_000)
    assert [{:ApprRequest, {:ApprKey, _, _, _, _, 65_536}, _, :ApprOpen}] = elem(pruned.cure, 1)

    assert {:ok, _, %{key: {"run-1", "act-1", "human", 1, 65_537}},
            {:superseded, {"run-1", "act-1", "human", 1, 65_536}, _}} =
             Approval.request(pruned, "run-1", adds)
  end

  test "request/3 refuses a revision above 2^31-1 and still returns an unchanged request at it" do
    max = Integer.pow(2, 31) - 1
    {s, _} = ask(Approval.new(), "run-1", :once, "act-1", "v1")
    {:ApprState, [{:ApprRequest, key, binding, :ApprOpen}], [], [], [], []} = s.cure
    # Superseding and pruning keep a line at one entry while its revision grows;
    # built directly one revision below the bound.
    below =
      {:ApprState, [{:ApprRequest, put_elem(key, 5, max - 1), binding, :ApprOpen}], [], [], [], []}

    below = %State{cure: below}
    v1 = decision(:once, "act-1", "v1")
    v2 = decision(:once, "act-1", "v2")
    top = {"run-1", "act-1", "human", 1, max}

    assert {:ok, s, %{key: ^top}, {:superseded, _, _} = event} =
             Approval.request(below, "run-1", v2)

    assert {:ok, ^s} = Approval.apply_event(below, event)
    pruned = prune!(s, 0)
    assert keys(pruned) == [top]

    assert {:ok, ^pruned, %{key: ^top, status: :open}, nil} =
             Approval.request(pruned, "run-1", v2)

    assert {:error, {:invalid_input, {:bound_exceeded, :revision}}} =
             Approval.request(pruned, "run-1", v1)

    released = release!(pruned, top, evidence(top, "ev-top", :once, 100_000), :once, "v2", 2_000)

    assert {:error, {:invalid_input, {:bound_exceeded, :revision}}} =
             Approval.request(released, "run-1", v2)
  end

  test "capacity: 65,536 released lines refuse a new line until all of them are retired" do
    once = fn _ -> :once end
    assert lines_state(3, once, []) == public_lines(3, once, [])
    full = lines_state(65_536, once, [])
    {:ApprState, rs, [], rels, consumed, []} = full.cure
    assert length(rs) == 65_536 and length(rels) == 65_536 and length(consumed) == 65_536
    new_line = decision(:once, "act-1", "p")

    assert {:error, {:invalid_input, {:bound_exceeded, :state}}} =
             Approval.request(full, "run-new", new_line)

    # Expiry alone frees no line: the newest request of each line stays.
    expired = prune!(full, @max_time)
    assert length(elem(expired.cure, 1)) == 65_536

    assert {:error, {:invalid_input, {:bound_exceeded, :state}}} =
             Approval.request(expired, "run-new", new_line)

    retired = retire!(full, for(i <- 0..65_535, do: {"run-#{i}", "act-1"}))
    assert retired.cure == {:ApprState, [], [], [], [], []}

    assert {:ok, _, %{key: {"run-new", "act-1", "human", 1, 1}}, {:requested, _}} =
             Approval.request(retired, "run-new", new_line)
  end

  test "retiring 10,000 of 20,000 released lines in one call or in batches keeps every other line in order" do
    kind = fn i -> Enum.at([:once, :run, :root], rem(i, 3)) end
    revoked = fn n -> for(i <- 0..(n - 1), rem(i, 5) == 0, do: "ev-#{i}") ++ ["ghost-1"] end
    assert lines_state(6, kind, revoked.(6)) == public_lines(6, kind, revoked.(6))

    n = 20_000
    s = lines_state(n, kind, revoked.(n))
    lines = for i <- 0..(n - 1), rem(i, 2) == 1, do: {"run-#{i}", "act-1"}
    assert length(lines) == 10_000
    once = retire!(s, lines)
    assert lines |> Enum.chunk_every(1_000) |> Enum.reduce(s, &retire!(&2, &1)) == once

    # Line by line: a retired line keeps only its root consent and the
    # revocation that this consent names; every kept line keeps everything.
    kept? = fn i -> rem(i, 2) == 0 end
    parts = Enum.with_index(line_parts(n, kind))

    expected = {
      :ApprState,
      for({{r, _, _, _}, i} <- parts, kept?.(i), do: r),
      for({{_, cs, _, _}, i} <- parts, kept?.(i) or kind.(i) == :root, c <- cs, do: c),
      for({{_, _, rel, _}, i} <- parts, kept?.(i), do: rel),
      for({{_, _, _, ks}, i} <- parts, kept?.(i), k <- ks, do: k),
      for(
        "ev-" <> digits <- revoked.(n),
        i <- [String.to_integer(digits)],
        kept?.(i) or kind.(i) == :root,
        do: ekey("ev-#{i}")
      ) ++ [ekey("ghost-1")]
    }

    assert once.cure == expected
  end
end
