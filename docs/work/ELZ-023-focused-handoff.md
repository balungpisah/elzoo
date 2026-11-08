# ELZ-023 focused review handoff

ELZ-023: focused review **CONDITIONAL**, no production implementation permission yet.
Branch/PR: `task/ELZ-023`; [issue #37](https://github.com/balungpisah/elzoo/issues/37); no PR; independently reviewed SHA `82287cadde03351745415a46ad6e2c190d2bb0dd`.
Checks: all three focused commands in [exact reproduction](ELZ-023-focused-probes.md) exited 0: provenance `Result: 11 passed`, capacity `Result: 7 passed`, recovery `Result: 7 passed`; independently reproduced; roadmap write/plain/live and diff checks exit 0; recorded full unchanged-baseline setup/check exit 0, `Result: 32 passed`, `Result: 564 passed`, `ELZOO CHECK PASSED`.
Grounding: seven Cure step-label laws with clean audit; independent 13/13 policy mutants and 12/12 guard scenario mutations rejected; actual codec arithmetic independently agrees; Memory process-boundary tests; upstream host/provider/store Needs remain.
Limits: reviewer found a real unsafe replay-history sequence in the reduced probe; its label laws do not establish the complete replay-horizon invariant; no production, decoder/fold, machine-crash or exactly-once claim.
Open work: root A1 acknowledgement/choice below; binding G1–G9 implementation gates; full production validation and independent actual-diff review; no PR/merge.

Reviewer `orca_session_id:0f974e4c-75e1-4daf-9a19-7720ad2b1633`,
dispatch `ctx_d44dba661673`, task `task_add87fbffb16`.
The [complete independent report](ELZ-023-focused-review.md) is preserved verbatim.
No helper remains active. Report prepared 2026-11-08 WIB.

## Disposition and decision needed

| Item | Independent verdict |
| --- | --- |
| R-A, R-D, R-E, R-F | CLEAR for implementation scope only |
| Evidence correction and numeric arithmetic | CLEAR |
| R-B | CONDITIONAL on G1 monotone replay dependence |
| R-C and host-interface realizability | CONDITIONAL on root A1, G3–G5 |

The reviewer explicitly allows implementation after root records A1 and the
coordinator records G1–G9, without another review of these same documents.
All G1–G9 are adopted here as binding production requirements. No claim that
G1 is already fixed: the current probe remains a reproducible counterexample.
No Contract or existing assertion is changed by this handoff.

### A1 — recommend conservative acknowledgement

The host activation marker has to be durable **before** any uncertain operation.
The realized interface cannot distinguish a clean crash from a crash during an
uncertain write, so it makes **every** recovery startup read-only, including
deploy/OOM/crash. It can find/read status but cannot poll or settle until host
activation. This is broader than the Contract's explicit “after an uncertain
halt” sentence.

Recommended root acknowledgement, verbatim:

> Any owner restart is treated as potentially uncertain; every recovery startup
> is read-only until the host grants activation; no clean-release path in this
> subset. “Resumes the existing intent” means it is found and status-readable
> by derived key, with active polling/settlement resumed only after host/operator
> reconciliation and a bound activation grant.

Concrete before/after interpretation for review (NOT applied to body or task):

**Scope before:**
> after an uncertain halt, restart is read-only
> until host/operator reconciliation re-establishes an authoritative outcome
> and valid ground; the host must preserve/deliver this recovery obligation
> across restart, because an in-memory flag is not durable quarantine;

**Proposed scope after, if root wants an explicit Contract amendment:**
> every recovery startup is treated as potentially uncertain and is read-only
> until host/operator reconciliation re-establishes an authoritative outcome
> and valid ground and grants activation; no clean-release path is supplied
> in this subset; the host must preserve/deliver this recovery obligation
> across restart, because an in-memory flag is not durable quarantine;

**Acceptance before:**
> Restart at each boundary resumes the existing intent by derived key.

**Proposed acceptance after:**
> Restart at each boundary finds the existing intent by derived key in read-only
> mode; active polling/settlement resumes only after a bound host activation
> grant, and a recovered dispatched reservation never authorizes a local send.

Root may instead require a quiescent-release path: only after all writes have
certain results and no Adapter task remains in flight, the owner CASes the host
marker to quiescent; recovery from that state can activate without operator
proof. This adds host state and a graceful-stop CAS and is not in the current
probe. The recommended conservative acknowledgement avoids adding this path.

## Binding implementation gates

1. **G1 — monotone replay history.** Carry `replay_dependent` and
   `ever_possibly_sent` in Cure state. Replay dependence is set on rearming a
   replay-safe ground and never cleared; both arm and rearm check its horizon
   regardless of the latest ground. Extend step laws and add the exact
   counterexample regression: attempt 1 possibly sent → replay-safe rearm →
   attempt 2 adapter_no_send → expired horizon → attempted third send **refused**.
   This fixes behavior within the approved Contract; no weaker law or new
   no-send exception is authorized.
2. **G2 — revision.** A pure revise event requires every previous attempt's
   durable adapter_no_send and the binding's same-key changed-argument semantics;
   history cannot be erased and permanent disarm cannot be cleared otherwise.
3. **G3 — completion history in Cure.** Model old completion and contradiction
   freeze with per-attempt grounds, not only an Elixir classifier; add checked
   step laws and mixed-history/race cases. Mixed replay/no-send/no-effect history
   freezes conservatively and is documented as operator burden.
4. **G4 — host grant binding.** Owner verifies fresh startup nonce, generation,
   recovered Store revision and exact digest; stale or inconsistent head refuses.
   Define marker-without-intent recovery as an explicit snapshot convention.
   Supply a reference callback over the existing Store with conformance tests.
5. **G5 — no public boolean authority.** Fixture booleans stand in for the
   host's own verified facts only. No Piece API accepts caller booleans as
   reconciliation proof; only the synchronous trusted callback return can grant
   the current nonce-bound activation. Authenticity and physical fencing are Needs.
6. **G6 — recovery deadline.** One validated checked-addition call site derives
   the finite deadline; overflow refuses and neither expiry creates a ground.
7. **G7 — codec/fold and budgets.** Full validation, decode/roundtrip and replay
   correspondence; actual owner uses the tested reservation arithmetic.
   Recompute sizes after adding history fields; current checkpoint margin is
   178,350 bytes and is not implicit permission for unbounded fields.
8. **G8 — README storage.** State payload versus canonical record size,
   startup limits, no pruning, retention Need, worst cumulative checkpoint
   bound 3,228,983,296 encoded bytes (barrier-only upper bound 374,756,352);
   SQL/index/replica/log overhead is additional.
9. **G9 — remaining acceptance.** Both completion/reconciliation orders,
   delayed old-owner send, failed evidence writes, boundary/limit+1 and physical
   send-count negatives, binding build failures, copied/renamed exports,
   fresh pinned `mix setup` and full `mix check` with the own database,
   independent actual-diff review, claim removal before PR and authorized queue.

The current provenance probe's safety-label argument remains valid in its
stated scope, but it does not prove the history-dependent replay horizon.
The independent `/tmp/elz023-focused/launder.exs` reproducer is described in
the full review; production must turn this sequence into a committed regression.
