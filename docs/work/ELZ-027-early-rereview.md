# ELZ-027 focused independent early re-review

Reviewer: Orca session `orca_session_id:c936d728-5e2f-40e7-b225-7df6c98f0b18`, independent of the proposal author and first reviewer. Reviewed `origin/task/ELZ-027` at `957bd593e9fc871e134bc8e341a34428739cc0c0`, live issue #44, the first review and the ELZ-050 disposition. This is a design review, not an implementation review or proof execution.

## Findings and conditions

1. **BLOCKING — Actual identity law and control remain insufficiently specified.** `identity_is_schedule_and_slot` equates `created` with `identify`, while the live-identity laws also use `identify` as their expected value. A faulty production `identify` that increments generation internally, ignores the scheduled instant, or otherwise returns the wrong tuple can satisfy all of these laws. The listed identity mutation changes `created`, not necessarily the identity computation itself. State a quantified law directly relating the actual production `identify(sid, gen, slot)` to `{sid, gen, slot}` (and, if an encoded value is the actual identity, its correct encoding), with a production-connected control mutating `identify` itself and required to fail; demonstrate actual identity independence from arrival across admissible calls. Cure feasibility and executable controls remain G4, not established evidence now.
2. **BLOCKING — Composition cannot be silently narrowed.** Issue #44 explicitly says the slice depends on `core/envelope` result schema and consumer-side `delivery/idempotency` and names `delivery/time` as a clock port. The revised proposal only describes an untested adapter and reinterprets `delivery/time` as a timer recipe. The first review permits narrowing the composition *statement*, but the proposed amendments contain no exact before/after for this live issue paragraph. Either plan executable composition/translation at the named real boundaries while accurately describing `delivery/time`, or supply a separately reviewed exact Contract amendment to the coordinator specifying the intended external adapter Needs, removing only the unsupported dependency/clock claim and retaining the actual consumer-side responsibility. Do not treat a README disclaimer as an amendment to the live issue. This decision must precede implementation.
3. **BLOCKING — Watermark cannot recover an occurrence ID from a previously decided slot.** A slot at/below the watermark may have been skipped, or decided under an older generation; `already_recorded{occurrence id}` constructed from the current generation misrepresents that historical outcome and does not establish an occurrence existed. Use `already_recorded{slot}` or an explicitly labeled *candidate* identity, with no assertion of prior admission, unless retaining an actual decision/identity history; test skipped and pre-redefinition replay as well as replay after settlement. This preserves a recorded result without inventing historical state.
4. **Contract precision — single availability boundary is an assumption about a whole interval.** It only classifies the interval correctly if the caller can establish uninterrupted availability from the supplied boundary through now, and all earlier unrecorded slots in the complete sequence were offline; a single timestamp cannot represent arbitrary multiple availability intervals or missed live slots. Fail closed when the caller cannot establish this predicate, not merely when the number is absent or after `now`. The caller is responsible for truth, which cannot be proven by integer validation. See A1 below.

## First-review finding dispositions

| Finding | Disposition |
| --- | --- |
| BLOCKING 1 | Grace removed, A1 proposes a distinction and preserves queue-only admission; **conditional**, A1 needs rewording/publication and the single-boundary precondition above. Numeric validation alone does not establish a correct boundary. |
| BLOCKING 2 | Production `admit_slot` bound laws, preconditions and placement controls are designed, but unexecuted; identity law/control gap in finding 1 above remains. **Not yet addressed**. |
| BLOCKING 3 | Proposed paths fit the updated dispatch, including only the trigger row/entry and permitted regeneration; authorization is supplied by this re-review dispatch. Claim-marker cleanup remains required. **Addressed for scope**, subject to shared-change coordination and issue record required by AGENTS.md. |
| REQUIRED 4 | Ordered complete sequence, refusal, watermark, redefinition, settlement and serialized owner are described; tests planned and appropriately scoped. **Conditional** on resolving false historical occurrence IDs in finding 3, and executing G3/G5. Completeness and retention are assumptions, not proofs. |
| REQUIRED 5 | Payload, stale delivery/settlement, generations and external idempotency ownership are planned; live required composition has not been exercised or amended. **Not yet addressed**; resolve finding 2 and execute corresponding tests. |
| REQUIRED 6 | Properly distinguishes wider WRAP decision, optional unexercised Crontab 1.2.1 and Oban 2.24.2, Jido no-copy, timer recipe and supplied DST fixtures. **Addressed in design**, subject to truthful issue reconciliation and G6. |
| REQUIRED 7 | Proof/type/test/observation/upstream/assumption categories and operational applicability are planned. **Conditional** on G5/G7/G8: copied-source consumer, meaningful foreign boundary and all referenced evidence must actually run; there is no proof, instrumentation or test result yet. |
| LOW 8 | `coverage: subset` and excluded webhook/event scope and caller distinction are explicit; first promotion of deferred ID does not change a ready Contract. **Addressed in design**; future behavioral changes require the new-ID process. |

G1–G8 in the revised document are byte-for-byte identical to the first review's gates and explicitly binding; adoption does not satisfy their execution. The brief expressly authorizes the trigger registry row, release-plan entry and generated roadmap/ledger, but no broader registry or protected files. No proposal commits contain implementation: diff from `origin/main` consists only of `.claims/ELZ-027.md` and three `docs/work/ELZ-027*.md` files. The claim file must be removed before PR. The pre-existing untracked `.reticle-setup-crash.log` was untouched.

## Amendment decisions

| Amendment | Verdict and reason |
| --- | --- |
| A1 offline/live | **REWORD.** The conceptual clarification is necessary and preserves queue-only catch-up, but its current text leaves the actual one-boundary classification assumptions and fail-closed behavior implicit, and calls the quoted before text exact although the issue has a newline after `those`. Use the exact raw before text and replacement below. This is a deliberately constrained caller Need; it does not make a grace interval infer downtime or weaken the law. The coordinator must decide and publish it, synchronize the task copy/hash, and may choose a richer caller-supplied classification if the stated availability precondition cannot be met. |

A1 exact before (issue source, including the line break):

```text
due slots that passed while offline (those
   between the last recorded instant and now) become occurrences only under
   `queue`
```

A1 proposed exact after:

```text
The caller supplies an availability boundary for each admission call and is
responsible for establishing that every unrecorded due slot before that boundary
passed while the scheduler was offline and that the scheduler was continuously
available from the boundary through the current instant. A due slot before the
boundary is an offline catch-up slot and becomes an occurrence only under
`queue`, subject to its bound; a due slot at or after the boundary follows the
declared overlap policy. If the caller cannot establish this classification or
supply a valid boundary no later than the current instant, the call is refused
without classifying slots or changing state. Elapsed time or a grace period alone
does not establish whether a slot was offline.
```

This proposed text makes the assumption visible, not mechanically verifiable; it does not imply that the piece can know the caller's uptime. The other bullet points in `ELZ-027-contract-proposed.md` are presented as clarifications rather than before/after amendments: the occurrence-ID clarification is unacceptable as written for the reason above; misfire terminology and caller distinctions are reasonable. The composition discrepancy requires its own explicit coordinator decision and exact amendment if the issue is to change; no such amendment is currently proposed, and I do not approve one by inference.

## Remaining gates

Before implementation: reconcile findings 1–3, decide and publish A1 with synchronized task copy, and resolve actual versus amended composition. Preserve G1–G8 verbatim. During implementation/review: prove actual production identity and bound laws and fail the production-connected controls, validate all named scenarios and copied consumer/composition as decided, document Config and boundary assumptions, run pinned `mix setup` and `mix check` with the assigned disposable database, report evidence categories honestly, and obtain independent implementation review. Neither the Peano representation nor whole-batch not-due refusal is inherently problematic if boundary validation and tests establish their specified behavior; their chosen numeric bound and failure result must remain explicit in the approved Contract.

## Commands and results

- `git status --short && git rev-parse HEAD && git rev-parse origin/main && git rev-parse origin/task/ELZ-027 && git diff --name-only ba2fc53 957bd59 && git diff --name-only origin/main 957bd59` — exit 0; branch head `957bd593e9fc871e134bc8e341a34428739cc0c0`.
- `git diff ba2fc53 957bd59` — exit 0; reviewed all changed proposal files via `git show` as well.
- `cat /tmp/elz027-early-review-ad53de29-7162-4ff2-b848-05f18f2ec5c0.md` — exit 0.
- `git show 957bd59:docs/work/ELZ-027-early-review.md | cmp - /tmp/elz027-early-review-ad53de29-7162-4ff2-b848-05f18f2ec5c0.md` — exit 0, byte-equal.
- `git show 957bd59:docs/work/ELZ-027.md`, `git show 957bd59:docs/work/ELZ-027-contract-proposed.md`, `git show origin/task/ELZ-050:docs/plans/catalogue-dispositions.md | rg -n -A 36 -B 6 'delivery/trigger'`, `cat AGENTS.md`, `rg --files | rg 'ELZ-027|AGENTS.md|CONTEXT.md'` — each exit 0.
- Python comparison of the two complete G1–G8 blocks extracted from the original review and `git show 957bd59:docs/work/ELZ-027.md` — exit 0, byte-equal.
- `gh issue view 44 -R balungpisah/elzoo --json body` — exit 0; whitespace-normalized A1 before matches, literal contiguous line does not because the issue wraps lines. Subsequent `gh issue view 44 -R balungpisah/elzoo --json body --jq .body` piped to the exact/normalized Python check — exit 0; results false/true respectively.
- `git show origin/main:tasks/ELZ-027.md` — exit 128, no such path; actual task path is `tasks/ELZ-027-schedule-occurrence.md`. No conclusion depends on the failed lookup.
- `orca skills get orchestration` using `/usr/local/bin/orca` — exit 1, `Unable to determine Orca.app path from symlink: /usr/local/bin/orca`; `ORCA_CLI_COMMAND` resolves the session binary to `/Applications/Orca.app/Contents/Resources/bin/orca`, whose `skills get orchestration` returned exit 0.
- No Mix commands run, as instructed. No repository edits, switches, commits, pushes, labels or comments.

NOT CLEAR
