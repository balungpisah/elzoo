# ELZ-028 focused independent early re-review

Reviewer: Codex, Orca session `orca_session_id:7ac9a0a1-26ca-41b6-ae35-b1bd3bef9cb7`, dispatch `task_385318bb60de`. Reviewed `origin/task/ELZ-028` at `c32e62c0e34922e4a20686ee9d6aa054f5151058`; live #45 and `origin/main` at `f4e3283` after fetch. This is a read-only design review, not implementation or execution evidence. No Mix or database commands were run.

## Findings

| Finding | Disposition |
| --- | --- |
| B1 | **OPEN, blocking.** The separate clock read and revision CAS do not atomically check time. A per-statement or client transaction timeout does not bound physical commit latency: scheduling, pool checkout, pauses, a delayed/lost commit response, and server-side work can outlast the claimed bound; the ready Store's `write/3` transaction timeout is not evidence of an upper bound on when PostgreSQL can commit. LS8b explicitly permits a renewal to commit after expiry and then applies it because its earlier stamp was live. That violates the live-only rule at the actual change; recording the old stamp does not cure it. A backward wall-clock step between stale evaluation and CAS can turn stale into active at the CAS even when the next persisted stamp is not regressive; the later regression detector is not an atomic guard. Also `claim` by the active holder permits a fresh claim without the renewal grace, providing another path to extend a lease after a pre-CAS expiry. Redesign the Store-level serialization/clock condition with an upstream-grounded linearization point or seek a deliberate ownership and Contract decision without claiming the present bound. |
| B2 | **PARTIAL, G3 open.** Appendix contains a production-shaped `classify/2` and 37 named proposed laws, including a link from it to the ordering table, with declared negative controls. The reviewer did not run these or inspect generated production code. The boundary laws C4–C9 quantify over ordering constructors rather than establish that the production integer comparison yields the correct constructor for each inequality; the explicit `compare/2` proof limitation is honest, but the claimed complete timestamp classification law is not yet established. Obtain a reviewed resolution preserving the requested status law, wire the exact classifier into the shell and `mix check`, and run the controls. |
| B3 | **OPEN, blocking.** Reading/classifying candidates and reading the clock happen outside the Store's write transaction; a revision CAS validates a prior revision, not selection and clock predicate inside that transaction. A1/A2 do not turn this into the issue's required claim-next-ready under one transaction. In addition, §2.8 permits the same key in results from concurrent invocations after release/reclaim, which conflicts with the unqualified disjoint-result invariant in #45. A lost-CAS test is useful but insufficient. Define and test a real transaction containing ready selection and claim on Memory and PostgreSQL, or secure an explicit reviewed Contract/ownership decision; do not silently weaken the law. |
| B4 | **PARTIAL.** The dispatch specifically authorizes only the `state/lease` registry row and release-plan entry as shared edits. §3 additionally proposes regenerating roadmap views via `scripts/check-roadmap.py --write`; this is not authorized by the stated scope and needs explicit coordination before any such shared edit. No edits to merged tests/checks/scripts or other registry rows are proposed. |
| B5 | **OPEN, blocking.** `retain/5` changes `low_water` without changing `revision`; a double head read does not fence retention between the last read and CAS. The proposed bound keeps only the latest lease record, yet the fold requires prior history: claim at sequence 1 followed by renewal at sequence 2, then retaining through 1, leaves `EvRenew` as the first visible lease event; starting from `NoHolder(0)`, the proposed fold returns `Unreadable`, not the previously active state. In a concurrent version, retention after the double read but before a renewal CAS can produce this same result despite successful CAS, contradicting LS16's fresh-status agreement. Neither the latest-record bound nor a statement that earlier rows were once committed supplies a replay anchor or fences `low_water`. Specify an enforceable retention protocol or atomic guard, preserve sufficient validated history or a compatible checkpoint, and test this interleaving on both stores. Do not change a ready Store's Contract under its existing ID. |
| R1 | **PARTIAL.** Candidate discovery and bounds are specified, and A1/A6 can be reviewed; A2's transaction and overlapping result semantics leave B3 open. |
| R2 | **ADDRESSED in design, pending A3 and tests.** Explicit same-batch attributable release, known/unknown holder, closed reasons and seizure-only ambiguous recovery are described. Verify separate tests on both stores and that payload classification remains accurate. |
| R3 | **PARTIAL.** `complete/4`, terminal-kind routing and bypass exclusion are described; A4 conflicts with the unconditional acceptance wording and needs deliberate resolution. Further, §2.6 returns `{:held, held'}` after `complete/4` with an advanced fence: a consumer using that returned fence may write after terminal release. Specify a terminal result that cannot be used as an active lease and test the returned value, not merely an old fence. The Store fence does not enforce caller identity. |
| R4 | **PARTIAL.** Operational declarations, Store/Repo clock binding, caller-transaction check, bounded inputs, and nonce/digest confirmation are planned. Confirm all construction and operation paths comply with the existing Store's no-statement caller-transaction behavior, and ground actual declarations in bundle tests; no implementation exists. |
| R5 | **PARTIAL.** Pins, provenance, comparisons, scenario plan and evidence categories are clearer. The missing real expiry-before-CAS, clock regression during selection, transactional ready selection, and retention/replay races above remain; LS8b's described crossing result is not a passing control for live-only renewal. Actual tests/proofs and reproducible evidence remain future work. |
| R6 | **OPEN.** The proposal accepts any reachable database in `ELZOO_TEST_DATABASE_URL`; this dispatch authorizes **only `elzoo_pieces_test`**. Before any setup, migration or test, parse and verify the effective database target is exactly `elzoo_pieces_test`, fail closed for absent, mismatched, overridden or unreachable configuration, and report target and commands without credentials. A URL being supplied is not sufficient. |
| L1 | **PARTIAL.** Status meanings, held mapping, limits and refusal paths are described, subject to the issues above and review of newly chosen bounds. |

## Amendment verdicts

The "before" check is against the literal live body, including its newlines and three-space continuation indents. The coordinator alone decides and applies changes. Text below is a review proposal, not an applied issue edit.

| Amendment | Verdict | Reason |
| --- | --- | --- |
| A1 | **ACCEPTABLE**, subject to coordinator decision | Its quoted before text is byte-exact and occurs once. Adding bounded caller candidates makes the new discovery Need explicit without removing a law; it does not solve B3. |
| A2 | **REJECT** | `Before: (sentence kept unchanged)` is not byte-exact before text, and the worker's accompanying claim that prior external selection and a later per-key CAS share one transaction is false. The proposal also allows overlapping invocation results, contradicting the live disjointness law. Keep the original evidence requirement and resolve the actual transaction/overlap design before proposing a substitute. |
| A3 | **REWORD** | Its displayed before text is not byte-exact because the issue wraps and indents the invariant differently. The addition is narrowly useful and keeps explicit attribution; use the exact replacement below. |
| A4 | **REJECT** | The before sentence is byte-exact, but an appended no-takeover success directly conflicts with the unconditional acceptance checkbox. The replacement is not merely additive clarification and would narrow its literal guarantee. Ask for a deliberate reviewed reconciliation of both statements; do not call this acceptance-preserving or claim the checkbox is satisfied. |
| A5 | **REJECT** | The displayed before text omits the actual newline and indentation, and the after substitutes recorded earlier time and an unsupported timeout bound for the atomic clock condition and live-only renewal. This weakens the practical guarantee and is not a minimal clarification. Fix the boundary and then propose a separately reviewed change if necessary. |
| A6 | **REWORD** | A new Need/behavior is a reasonable narrow choice for coordinator review, but `(no statement)` is not an exact insertion anchor. Use the exact append anchor and text below; this does not decide B3 or change disjointness. |

A3 exact before (literal line breaks and spaces):

```text
stale and
   ambiguous (`renew` timestamp in the future or
   unreadable) fail closed and their
   release is an explicit, attributable record
```

A3 exact after:

```text
stale and
   ambiguous (`renew` timestamp in the future or
   unreadable) fail closed and their
   release is an explicit, attributable record naming the releasing actor,
   the prior owner when knowable, and the reason; a replacement claim may
   record that release atomically in the same transaction
```

A6 exact insertion anchor (replace the single occurrence below):

```text
   cross-store agreement, authorization.
```

A6 exact after:

```text
   cross-store agreement, authorization. `claim_expired` admits only keys
   whose lease is stale (expired); a key that is free (never held or
   explicitly released) is reported as refused `free` and is claimed with
   `claim`.
```

For future A2 and A5 revisions use byte-exact body substrings rather than normalized prose. A2's evidence sentence in the live body has hard wraps; A5's exact before spans `lease condition and record change are` followed by newline and three spaces before `checked in one atomic step`. A3's exact before/after above preserves the original law rather than replacing it. No amendment has been applied.

## Gates, scope and checks

G1–G7 in revised §9 match the first review byte-for-byte (all seven compared linewise). They are adopted text, not completed evidence. G1–G2 remain blocking on B1, B3, B5, scope and Contract decisions; G3 remains open on the classifier limitation, production wiring, pinned Cure run and negative controls; G4 requires the actual two-store deterministic scenarios, corrected clock/retention/terminal cases, and the exact disposable database; G5 requires actual metadata, operational declarations and grounded evidence; G6 requires limiting edits to authorized paths and removing the claim before PR; G7 requires `mix setup`, full `mix check`, copy-boundary verification and independent diff review after implementation.

The literal requested `git diff --name-only origin/main c32e62c` is **not** limited to `.claims` and `docs/work/ELZ-028*`: it lists 45 paths, mainly because ELZ-050 was merged to main after this branch's base. The merge base is `665d3e07c58fb9a3e7818a037a6910132535fa53`; the branch-only three-dot diff contains only `.claims/ELZ-028.md` and the three `docs/work/ELZ-028*` documents, and `git diff 0b99406 c32e62c` changes only those three documents. Thus no implementation was committed on this branch, but the literal direct-diff criterion fails until normal merge of current main. The appendix contains proposed Cure source in a design document, not a production implementation. The existing untracked `.reticle-setup-crash.log` was untouched.

Commands and exit codes (all run in the stated workspace):

- `git fetch origin --prune` — 0; `git status --short --branch` — 0; `git rev-parse origin/task/ELZ-028` — 0.
- `git diff 0b99406 c32e62c`, `git diff --name-status 0b99406 c32e62c`, `git diff --name-only origin/main c32e62c`, `git diff --name-status origin/main...c32e62c`, `git merge-base origin/main c32e62c`, `git diff --stat origin/main c32e62c`, `git diff --check 0b99406 c32e62c` — each 0.
- `cat /tmp/elz028-early-review-2b4150d0-e531-4448-ba35-cf8087e563c8.md` — 0; `git show c32e62c:docs/work/ELZ-028-early-review.md | cmp - /tmp/elz028-early-review-2b4150d0-e531-4448-ba35-cf8087e563c8.md` — cmp 0; Python comparison of G1–G7 — 0, all identical.
- `git show c32e62c:docs/work/ELZ-028.md`, `git show c32e62c:docs/work/ELZ-028-contract-proposed.md`, `git show origin/main:docs/plans/catalogue-dispositions.md | rg -n -C 5 'state/lease|ELZ-028'`, and reads of ready SQL/event-log README and SQL source via `rg`/`sed` — each 0.
- `gh issue view 45 -R balungpisah/elzoo --json body` and `gh issue view 45 -R balungpisah/elzoo --json body --jq .body` inspections including the Python literal match check — each 0. Literal check found A1 and A4's before substrings once, normalized A3 and A5 zero times.
- `cat AGENTS.md` — 0; `/Applications/Orca.app/Contents/Resources/bin/orca skills get orchestration` — 0. Initial bare `orca skills get orchestration` — 1 (`Unable to determine Orca.app path from symlink: /usr/local/bin/orca`); selected the session-provided executable thereafter.

NOT CLEAR
