# ELZ-023 (#37): focused amendment and probe re-review (implementation permission only)

- Reviewer: Orca session `orca_session_id:0f974e4c-75e1-4daf-9a19-7720ad2b1633` (task `task_add87fbffb16`, dispatch `ctx_d44dba661673`). The same independent reviewer as the early review; I authored none of the changes. No helpers.
- Reviewed head: **`82287cadde03351745415a46ad6e2c190d2bb0dd`** on `task/ELZ-023` (previous reviewed head `c90a7385baafa1eadc4da30945dcf0312c521ec9`; claim `5f62e64`). Worktree `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-023`: `git status --short` empty before and after. I changed no tracked file, issue, label or pin.
- Diff `c90a738..82287ca`: 12 files, all under `docs/work/ELZ-023*`, `tasks/ELZ-023-dispatched-effect-intent.md` and one line of `docs/plans/release-plan.json` (the ELZ-023 `issue_body_sha256`). No production code, protected file, existing test or pin changed. Old `policy.cure` and `probe.exs` hashes equal the ones I reviewed (`b0d0a263…`, `7db4a6c8…`). `docs/work/ELZ-023-early-review.md` is my earlier report, line-for-line.
- Cure pin: `git -C deps/cure rev-parse HEAD` = `208248063d64e621782cd26dd30698ee42850a89`. Scratch files: `/tmp/elz023-focused/`.

## 1. Verdict

**CONDITIONAL.** The amendment process, the Contract text, the numeric arithmetic and the policy probe are sound enough to start implementation, **if the root records one acknowledgement (R-C restart breadth) and the coordinator records the binding implementation gates G1 to G9 below.** I did not find a defect that needs a new Contract amendment, and nothing here weakens a Contract. I did find one real unsafe sequence in the probe's own policy (ground laundering, F1); it is a state-design gap with a small fix inside the already-authorised "attempt state", not a text change.

This is clearance for implementation only. It is not production acceptance. If root accepts the acknowledgement and the gates, my clearance is effective without a further review of the same documents.

| Item | Disposition |
| --- | --- |
| R-A three grounds, unconditional law | **CLEAR** |
| R-B narrow replay | **CONDITIONAL** (gate G1: replay dependence must survive later grounds) |
| R-C old attempts, contradiction, read-only restart, host interface | **CONDITIONAL** (root acknowledgement A1; gates G3, G4, G5) |
| R-D bounded priority retention and numbers | **CLEAR** (numbers independently recomputed; gates G7, G8) |
| R-E recovery grace | **CLEAR** (gate G6 for the production call site) |
| R-F reuse of Store/Memory, append AND checkpoint barriers | **CLEAR** |
| Mandatory evidence correction | **CLEAR** as written (literal bullet met); G1 and G2 extend it |
| Host-interface realizability | **CONDITIONAL** on A1 and G4/G5 |
| Numeric reservation arithmetic | **CLEAR** |

## 2. Amendment process and equality (checked)

1. Amendment comment `6715823301` created `2026-11-08T01:49:39Z`. GraphQL `userContentEdits` shows the issue body edit at `2026-11-08T01:49:52Z` (13 seconds later), and `lastEditedAt` is that time. The comment says it precedes the body edit.
2. I extracted the fenced diff from the comment and applied it with `patch` to the pre-amendment task text (`tasks/…` at the claim commit, byte-identical at `c90a738`): the result equals the live issue body byte for byte.
3. Live issue body and `tasks/ELZ-023-dispatched-effect-intent.md` at HEAD: both **16,210 bytes**, equal, SHA-256 `52f2312c013f75a7ae98d8bbb2c5e076c38354ebc1d4646f5b31426d90a5e539` (the "after" hash in the comment). Issue open, labels `task`, `ready`.
4. `docs/plans/release-plan.json` ELZ-023 `issue_body_sha256` equals that hash; it is the only line changed in that file.
5. Cited authority matches the packet: three grounds with an unconditional law, NARROW replay, bounded priority retention, `recovery_grace_ms`, Store/Memory reuse. Nothing in the task body contradicts the accepted packet (`docs/work/ELZ-023-decisions.md`). The amended acceptance list adds the nine bullets I checked against the probes below.

## 3. R-A to R-F and evidence correction

### R-A: CLEAR
Task Admission 2/5 now say: eight exact Envelope pairs (I enumerated the validator earlier; `unknown/not_dispatched` is invalid), attempt-identity match, three grounds, reservation-first `adapter_no_send` through `failed_definite`, pre-reservation failure creates no attempt, `adapter_no_send` is an Adapter-attested upstream Need, `provider_no_effect` needs an authenticated attempt-bound final certificate, and rearm is explicit. The unconditional law is stated in the Contract and proved as step laws (below).

### R-B: CONDITIONAL on G1
The narrow text is exactly what the policy implements: `ProviderUnknown` yields `Definite(ProviderReplaySafe)` only when the Cure guard `replay_valid(config)` is true, otherwise `Stranded`; `Pending`, `Lost`, `TimedOut`, `Failed`, `Resume` only poll.

**F1 (HIGH, gate): ground laundering.** The state keeps only the last ground (`Intended(After(ground), n)`). I ran the committed `provenance.cure` through this sequence (script `/tmp/elz023-focused/launder.exs`, exit 0):
attempt 1 sent, poll `ProviderUnknown` under a valid replay capability → `Definite(ReplaySafe,1)` → rearm → attempt 2 sent → `NoSend` → `Definite(AdapterNoSend,2)` → rearm and `Arm` with the replay horizon expired (`replay_valid` false). Result: `Arm` returns `Dispatch` and attempt 3 is sent (`Dispatched(After(AdapterNoSend), 3)`).
Why this is unsafe: attempt 1 was possibly sent and was resolved only by replay safety. Its delayed request can still arrive; once the horizon expired, a new send is not protected by key de-duplication. The accepted text requires the horizon to be "anchored at the earliest possibly-sent attempt's dispatched record" and root's R-B wording says "a new send is admissible only when its maximum in-flight lifetime plus clock allowance fits within that horizon". The policy forgets the dependence after any later `adapter_no_send`.
Required (inside the existing "attempt state carried in the pure policy's state", no text change): a monotone `replay_dependent` flag (set when a `Definite(ProviderReplaySafe)` is rearmed, never cleared) checked by `can_arm` and `can_rearm` for **every** later send whatever the current ground; add a step law (arm only when the flag is clear or `replay_valid`) and a scenario that fails on the sequence above. The same history carrier also serves the revision rule (G2).

### R-C: CONDITIONAL on A1, G3, G4, G5
**What is met.** Task Scope now states: one decisive settlement per attempt by CAS; older authenticated completion confirms a nonterminal intent only when every intervening rearm was replay-safe and key/payload/binding match; contradiction of a no-send/no-effect ground freezes rearm; confirmed/stranded stay terminal; an unretained contradiction cannot leave rearm enabled; restart after an uncertain halt is read-only until host reconciliation; the host persists the obligation.

**A1 (root acknowledgement needed): the realised interface is broader than the sentence it implements.** The Contract says restart is read-only "after an uncertain halt". The design in `docs/work/ELZ-023.md:176-203` and the probe (`recovery.exs`, `activate/4`) makes **every** recovery startup read-only: the host marker is created before any intent mutation, it survives owner death, and `:recovery` (or an existing marker, or `:fresh` on an existing marker) returns `{:read_only, :host_reconciliation_required}`. The reason is sound (a halted owner cannot write a quarantine flag, so the owner cannot tell a clean crash from an uncertain one), and the doc says "No automatic clean-release/reset path is proposed". The consequence is that **any unclean owner death (deploy, OOM, crash) needs a host reconciliation grant before the Piece can poll or settle again**. That is consistent with acceptance bullet 2 only if "resumes the existing intent" means "found, status readable, resumable after reconcile". Please record one of:
 (a) *Acknowledge:* "Any owner restart is treated as potentially uncertain; every recovery startup is read-only until the host grants activation; no clean-release path in this subset." I recommend this for the first subset: it is the conservative reading you chose.
 (b) *Require a release path:* the marker holds `active | quiescent`; the owner CASes to `quiescent` only after its last write has a certain result and no Adapter task is in flight; recovery from `quiescent` needs no proof. This adds one host CAS per graceful stop.

**G3 (policy): old-completion and contradiction are not in the Cure policy yet.** In the probe `Definite + Completed` returns `keep` (no freeze), and the classification of old completions exists only as a finite Elixir function (`completion/3` in `recovery.exs`). Production must model the old-completion event and the contradiction freeze in Cure with per-attempt ground history (the 426-byte entry already holds `ground`), and prove the same style of step laws. Note the probe's classification looks at all intervening grounds, including grounds of attempts later than the completing one; mixed histories (for example replay-safe then `adapter_no_send`) freeze. That is safe and conservative; keep it, and document it as operator burden.

**G4 (host grant binding).** The probe grant is `{:active, %{key, generation, nonce[, intent_revision, intent_digest]}}`; the nonce is echoed from the argument. Production must: (i) have the **owner** compare the grant's nonce with its fresh startup nonce, the generation with the host response, and `intent_revision`/`intent_digest` with the snapshot the owner recovered from the Store head (an unexpected head or digest refuses), none of which the fixture exercises; (ii) define the digest and revision for "marker exists, intent absent" (marker commit then crash before the first intent append, which leaves a permanent read-only state with nothing to reconcile); (iii) ship a reference host callback over the existing Store with conformance tests so consumers do not write an unsafe `{:active, …}` that always succeeds.

**G5 (proof is an upstream Need, not a boolean).** `reconcile/5` in the fixture accepts a map of three booleans (`authoritative`, `writes_resolved`, `old_owner_safe`); I confirmed a caller-built map is accepted (`/tmp/elz023-focused/hostrace2.exs`, exit 0). That is acceptable only as a **test stand-in for the host's own verification**. The Piece must never expose a `reconcile` function that takes such a map; the only grant it accepts is the synchronous return of the host-owned callback (as the doc says at lines 198-203). Label the fixture so.

**Race check (supports realizability).** With activation A paused (`Memory` pause fault) and activation B started: B returns `{:active, generation: 1}`; releasing A returns `{:conflict, %{expected: 0, observed: 1}}` and A returns `{:read_only, …}`; marker head revision 1; a third `:fresh` is `read_only`. Exactly one active owner per generation (script `hostrace2.exs`).

### R-D: CLEAR
I recomputed the arithmetic independently from the Contract ceilings with the **real** `Elzoo.DurableLog.Codec.checkpoint_bytes/1` (script `/tmp/elz023-focused/cap.exs`, exit 0):
- Attempt entry 426 bytes, evidence record 512, worst domain model **706,224**, checkpoint with 4,096 witnesses **870,226** (margin to 1 MiB **178,350**, about 696 spare bytes per entry), maximum opaque model at 4,096 events 884,574 (so "valid domain max 870,226" and "opaque Store boundary 1 MiB" are different, as the document says). All equal the author's numbers.
- Cumulative checkpoint bytes, one per event, worst model: **3,228,983,296** (equal). If only the two barrier checkpoints per attempt are taken (512 snapshots, worst model): **374,756,352** bytes. A typical 3-attempt model is 73,694 bytes (checkpoint at 20 events 74,656). The Contract's "no capacity claim is admitted solely from these numbers" is honoured; the README must state the cumulative figure.
- Canonical record at the 131,072-byte payload limit is 131,194 bytes; Store `max_record_bytes` limits **payload**. The largest legal domain delta is 68,568 bytes, so either reading fits. State "payload" in the Contract text of the README.
- Reservation functions (`admit_budget`, `routine_budget`, `priority_budget`) are consistent: 256 attempts hold 768 slots and 768 priority events (plus 512 barrier events), 256 routine slots remain, priority writes still succeed after routine saturation, and event saturation at 4,091/4,092 is exact. Start-time Store limits are enforced one by one (each minus one refuses).
These functions are probe code, not the production owner; the production versions must be driven by the same tests (G7).

### R-E: CLEAR
`recovery_deadline/2` implements none, zero, finite grace and rejects `deadline < 0`, `> 2^63-1`, negative grace and overflow (`grace > max - deadline`); boundary `2^63-2 + 1` accepted, `2^63-1 + 1` refused. The Cure policy has `live` (`now >= admission` blocks sends), `recovery_expired` (`now >= deadline`) and the `Expired` event: with `NoRecovery` it only polls; at the recovery deadline it strands; neither creates a ground. The runtime and the guards live in Cure. G6: production must call one validated function for the checked addition.

### R-F: CLEAR
Store and Memory reuse is explicit in the Scope. The barrier rule (append AND checkpoint acknowledged for both `intended` and `dispatched`) is in the task and in the policy table; a committed append followed by a failed checkpoint does not send and recovery polls. Capacity preflight uses `Log.preflight/3` and the real checkpoint size before append (`capacity.exs` tests undersized limits, exact threshold, and head unchanged after refusal).

### Mandatory evidence correction: CLEAR
- I regenerated `provenance.cure` with the committed `generate_provenance.py` and `provenance.template` in a scratch directory: **byte-identical** (SHA-256 `6f6f5ab9…f244b`, 108,841 bytes, 2,641 lines). Expected relations come from the generator's `expected()` function and take the guard results as parameters; they do not call `step`.
- Own Cure check and audit: `check_source` ok; axioms, holes, opaque, unresolved, unaudited, not_proven_total all empty; absurd 0.
- Seven public laws `empty_never_recreated`, `dispatch_action_only_after_arm`, `definite_only_with_ground`, `dispatch_only_after_arm`, `fresh_only_from_empty`, `after_only_from_definite`, `attempt_changes_only_on_send`: each is proved first as a `*_gated` lemma for every Boolean guard value, then instantiated with the actual Cure guard computations (`can_arm`, `can_rearm`, `replay_valid`, `recovery_expired`). This is real: the public law's statement mentions `step(...)`, which unfolds to `step_gated(... can_arm(...) ...)`, so a wrong wiring (for example swapped guards) fails conversion.
- I re-ran the author's 11 mutations with named failing laws (`/tmp/elz023-focused/pmut2.exs`): silent returns on Pending, Resume, Lost, TimedOut, Failed → `fresh_only_from_empty_gated`; Expired → `empty_never_recreated_gated`; Groundless, WrongGround → `definite_only_with_ground_gated`; Reset → `empty_never_recreated_gated`; Count → `attempt_changes_only_on_send_gated`; StrayDispatch → `dispatch_action_only_after_arm_gated`. All `conversion_failure`. Extra mutants I wrote also fail at named laws: stray dispatch on Pending, dispatch on a non-Arm event, arm ignoring its guard, rearm ignoring its guard, unknown ignoring replay validity, quarantine bypass, rearm resetting the count, rearm from `Stranded`, `Confirmed` reopening, `Expired` to `Definite`, permanent no-send to `Intended` (`pmut.exs`, 9 of 9 attempted rejected; the tenth pattern was mine and not found, so it is not counted).
- The laws do **not** constrain the content of the guards (they take the guard result as given). I killed 12 guard mutants with the probe's scenario tests alone (`/tmp/elz023-focused/guard/`, scenarios without the proof tests): disarmed ignored at arm, arm ceiling removed, replay ignored in `ground_live`, horizon check removed, anchor order removed, rearm ceiling removed, `live` `>=` to `>`, recovery `>=` to `>`, fresh count unchecked, rearm ignoring disarm, replay capability ignored, `live` removed from arm: **12 of 12 killed**, each by a named boundary scenario. So guard correctness is test-grounded, as the document says; the sentence "expected relations share the real arithmetic guard functions" is slightly loose (they share via instantiation), but the limit is stated correctly.
- Initial condition, positive first dispatch, all three ground paths, always-stop non-vacuity (even the proofs reject an always-stop arm because the expected label requires `Dispatch`; the scenario test also shows it) are present and pass. The reachable-trace argument (no `Empty` recreation, `Fresh` only from `Empty`, `After(g)` only from `Definite(g)`, counter only on send) follows from the checked one-step laws; I checked the argument and it holds. It is correctly labelled as not a mechanised induction.
- The old `policy.cure`/`probe.exs` stay as historical evidence and are not renamed.

## 4. Remaining findings and implementation gates

Binding gates for the coordinator to record (none is a Contract text change except A1):
- **A1** root acknowledgement of restart breadth (R-C), or the quiescent-release alternative.
- **G1** monotone `replay_dependent` (and `ever_possibly_sent`) history in the policy state, checked at every arm and rearm; scenario "replay-safe, then adapter_no_send, horizon expired → arm refused"; extend the step laws.
- **G2** argument revision: the pure policy needs a revise event allowed only when every earlier attempt ended `adapter_no_send` (the probe has no revise event and cannot clear `disarmed`); the state must carry that history (same carrier as G1).
- **G3** Cure model of old completion and contradiction freeze with per-attempt ground history; mixed-history freeze documented.
- **G4** owner-side verification of grant nonce, generation, recovered revision and digest against the Store head; the "marker without intent" convention; a reference host callback with conformance tests.
- **G5** no public `reconcile` taking caller booleans; label the fixture as a stand-in; the proof stays an upstream Need.
- **G6** one validated call site for the recovery-deadline addition.
- **G7** production codec and fold with full decode and round-trip tests (the capacity encoder is a layout measurement, not the fold); owner uses the same budget arithmetic; the history flags fit in the 696 spare bytes per entry; rerun sizes if the layout changes.
- **G8** README states: cumulative checkpoint disk (3,228,983,296 bytes worst case, 374,756,352 for barrier-only snapshots), payload versus canonical record size, the start-time Store-limit check, no pruning, and the retention Need.
- **G9** all other gates already listed in the amended acceptance (both orders of late completion versus reconciliation, pause-after-reservation, failed evidence writes, boundary and limit+1 tests, physical-send count for the transport re-send negative control, binding build failures, copied and renamed source checks, fresh pinned `mix setup`, full `mix check`, independent actual-diff review).

Notes (no action beyond the README): the Memory fixtures prove process-boundary behaviour only, not machine death; physical old-owner fencing, authentication, Adapter no-send truth and provider finality remain upstream Needs; the checkpoint-only-at-barriers choice (rather than one per event) is allowed by the Contract and reduces disk.

## 5. Commands, exits and counts

Required locale and scheduler flags on every Mix/Elixir command; `MIX_ENV=test`; database only `elzoo_pieces_test`; no pin, protected file or existing test touched.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `git rev-parse HEAD`; `git status --short`; `git diff --stat c90a738 82287ca`; Cure pin | 0 | `82287cad…`; empty; 12 files, docs/task/one release-plan line; pin `20824806…` |
| 2 | issue #37 vs task file; comment list; GraphQL edit times; patch of comment diff; release-plan hash | 0 | 16,210 bytes equal, sha `52f2312c…e5a5e539`; comment 01:49:39Z before body edit 01:49:52Z; patched text equals live body |
| 3 | `elixir -pa '_build/test/lib/*/ebin' docs/work/ELZ-023-probes/provenance.exs` | 0 | **`Result: 11 passed`** |
| 4 | same for `capacity.exs` | 0 | **`Result: 7 passed`** |
| 5 | same for `recovery.exs` | 0 | **`Result: 7 passed`** |
| 6 | Probe source hashes (`shasum -a 256`) | 0 | all eight equal to the table in `ELZ-023-focused-probes.md` |
| 7 | Generator run in a scratch copy; `cmp` with committed `provenance.cure` | 0 | byte-identical |
| 8 | `audit.exs` (`check_source` + `audit_env`) | 0 | clean; absurd 0 |
| 9 | `pmut2.exs` (author's 11 + 2 extra mutants) | 0 | 13 of 13 rejected, each at a named law |
| 10 | `pmut.exs` (extra policy mutants) | 0 | 9 of 9 attempted rejected |
| 11 | `guard/run.sh` over 12 guard mutants with scenario tests only | 1 each (expected) | 12 of 12 killed by scenarios |
| 12 | `launder.exs` | 0 | unsafe sequence reproduced: attempt 3 dispatched with expired replay horizon |
| 13 | `cap.exs` (real `Codec`) | 0 | 426, 512, 706,224, 870,226, margin 178,350, cumulative 3,228,983,296, barrier-only 374,756,352 |
| 14 | `hostrace2.exs` (activation race, boolean proof) | 0 | one active owner; loser conflict; boolean proof accepted by fixture |

## 6. Not rerun and limits

- Not rerun: `mix setup`, full `mix check` (the delta from my last review is documents plus probes and no runtime source; the recorded baseline `32 + 564 passed` predates the amendment and is not production evidence), and the historical `probe.exs` (hash-identical to what I reproduced at `c90a738`).
- Probes: Memory only; `capacity.exs` is a layout and arithmetic measurement, not a decoder; `recovery.exs` is a host-marker fixture; the policy laws are one-step, over well-typed inputs, with guards shared and tested rather than proved. Nothing here is an exactly-once, durability, authenticity or physical-fencing claim.
- This report approves nothing beyond starting implementation under A1 and G1 to G9, and it does not decide any owner question: A1 is the one decision I need root to record.
