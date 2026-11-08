# ELZ-023 (#37): final independent implementation review

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

- Reviewer: Orca session `orca_session_id:0f974e4c-75e1-4daf-9a19-7720ad2b1633` (task `task_5390ac87ff86`, dispatch `ctx_ba3927238e5e`). The same independent reviewer as the early and focused reviews; I authored none of the code, tests or documents. No helpers. I will not claim GitHub approval.
- Reviewed head: **`196d0881cd80a878029ff582e87c786732c2cbbf`** on `task/ELZ-023`, base `origin/main` `0a423705784f2c0223ed67d6f75bfdb5412845ce` (ancestor, no rebase). Worktree `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-023`: `git status --short` empty before, during and after. I changed no tracked file, issue, label, pin, test or protected file. Only `docs/work/ELZ-023-production.md` and `docs/work/ELZ-023.md` differ from the fully checked commit `fed4026ce85c5df3dae5fbf8126f5529ee61389a`.
- Pin `git -C deps/cure rev-parse HEAD` = `208248063d64e621782cd26dd30698ee42850a89`. Database: only `ecto://elzoo_elz024:…@localhost/elzoo_pieces_test`. Scratch files: `/tmp/elz023-final/`.

## 1. Verdict

**CONDITIONAL. No Contract change is needed and I found no unsafe-send defect, but I found two code defects with runnable counterexamples that I recommend fixing before the PR (F1 major, F2 medium).** Everything else in the live Contract, the acceptance list, A1 and G1 to G9 is met on the actual source. If root prefers to accept F1 or F2 as documented limits instead, that is a Contract/README clarification that only root can approve; exact wording is in section 6.

Safety properties I attacked and could not break: no second send without a durable `failed_definite` ground (160,000 random event sequences against my own oracle: 0 mismatches), no send from a recovered reservation, no send before both barriers, no activation without a nonce, generation, revision and digest bound grant, no caller Boolean authority, no forged internal Adapter tag.

## 2. Authority and equality (checked)

1. Live issue #37 body and `tasks/ELZ-023-dispatched-effect-intent.md` at HEAD: both **16,468 bytes**, equal, SHA-256 `b3fae2e02e9ee8789320e76491568759f9e9f28693b8cf5561bb086ccffeee58`; open, labels `task`, `ready`. `docs/plans/release-plan.json` carries that hash.
2. A1 comment `6716149455` (02:25:12Z) precedes the body edit (`lastEditedAt` 02:25:58Z). Its diff applied with `patch` to the task text at the focused-review head `82287ca` gives the HEAD task text exactly. The first amendment `6715823301` was verified in the earlier review.
3. I read every issue comment through `6716849647` (the production hand-off). Comments after the focused review are consistent with the repository documents.
4. Diff against main: 37 files. Modified (not added) files are only `LEDGER.md`, `docs/plans/release-plan.json`, `docs/plans/views.md`, `registry/catalogue.json` and the task file. No protected path (`.github/`, `scripts/`, root `lib/` or `test/`, `mix.exs`, `mix.lock`, `config/`, symbolic CI doc) is touched; no file is deleted; `.claims` has no tracked file, the original claim `5f62e64` is in history; `git diff --check origin/main HEAD` exit 0.
5. Test preservation: between the first production commit `dae4acf` and `fed4026` the only test change is `effect_intent_test.exs`, **119 insertions, 0 deletions**.

## 3. Acceptance bullets (live Contract)

| Bullet | Verdict | Evidence on the actual source |
| --- | --- | --- |
| Timeout never re-dispatches without a definite failure or reconciliation | Met | Cure `step`/`decide`; owner test `first dispatch…timeout does not resend`; oracle (below) |
| Restart finds the intent read-only; active polling only after a bound grant; recovered reservation never sends (A1 text) | Met | `init` and `activate` (`effect_intent.ex:25-134`); tests `every restart is read-only…`, `checkpoint failure…recovered reservation only polls`, SQL tests |
| `stranded` distinct, tested, documented operator path | Met | policy `Stranded` terminal; test `no-replay unknown-to-provider strands and late completion is operator evidence`; README "Recovery" section |
| Build-time total failure mapping, late-settlement-once, transport re-send negative | Met | `Binding.compile!` (`binding.ex`); storage test `binding refuses partial/extra mappings…`; tests `owner settles completion once…`, `transport hidden re-send negative control…` |
| Selected law and scenarios run through `mix check` | Met by recorded run; I reran the Piece suite | see section 7 |
| Provider idempotency and store durability labelled upstream | Met | README "Binding and provider Needs"; manifest `upstream` and `assumption` entries |
| Eight result pairs, attempt identity, no-send rearm through `failed_definite`, pre-reservation failure, permanent disarm, positive first dispatch | Met | test `all eight Envelope pairs…`; `Binding.compile!` pair list; `observe_envelope` requires a recorded attempt id |
| Narrow replay, partial effect, pending/unavailable, horizon/lifetime/clock bounds, revision, duplicate terminal admission | Met | Cure `replay_valid`, `replay_guard`, `can_revise`; tests `owner keeps replay horizon…`, policy tests |
| Both orders of late completion and reconciliation; old replay-safe completion; contradiction; failed evidence writes; read-only restart; paused old owner | Met | tests `late no-effect versus completion in both owner orders…`, `paused old task…`, SQL `uncertain contradictory completion…` |
| Encoding at every numeric boundary and limit+1, reserved priority evidence and witnesses, undersized Store startup, saturation, refused writes, cumulative snapshot storage | Met for the three reserved categories; **see F1** for the unreserved decisive transitions | storage tests; README accounting |
| Admission expiry, recovery none/finite grace, checked overflow, late completion after stranded never send | Met | `Binding.recovery_deadline`, `Policy.config`, Cure `live`/`recovery_expired`; tests |
| Strengthened policy probe: provenance, attempt state, initial state, silent-return mutants, groundless rearm, always-stop | Met on production | `effect_intent_policy_test.exs`; I re-audited and regenerated |
| Restart host interface and numeric arithmetic cleared before implementation | Met (focused review) | now implemented and tested |

## 4. Findings (prioritised)

### F1. MAJOR (liveness, fail-closed): the decisive `ProviderUnknown` grounding and the recovery-deadline strand are not reserved; routine observations can starve them
- Where: `lib/elzoo/effect_intent/model.ex:132-146` (`retain/4`: only `Completed`, `NoSend`, `PermanentNoSend`, `NoEffect` map to the reserved `:settlement` slot; `ProviderUnknown` falls to `:optional`); `lib/elzoo/effect_intent.ex:430-456` (`observe_event/4`: `critical` halts only for `Contradiction`, `Completed`, `NoSend`, `PermanentNoSend`, `NoEffect`, so a failed `ProviderUnknown` write returns `{:not_retained, …}` and the owner stays active); `model.ex:122-130` (`held/1`, `capacity?/1`): the event reserve is three per attempt, and each routine `Pending`/`Lost`/`TimedOut`/`Failed` observation appends one event.
- Contract basis: "Reserve before dispatch capacity for each admitted attempt's decisive settlement, first contradictory completion and first refused result; these priority records must be retained when storage commits, not displaced by routine observations." Also "provider_replay_safe arises only from poll/reconcile unknown_to_provider" and "Dispatched becomes stranded at that recovery deadline" (both are the attempt's decisive resolution), and "routine pending/unavailable observations use bounded counters".
- Counterexample A (runnable: `/tmp/elz023-final/adv.exs`, test A, exit 0): start the owner with the shipped test binding; dispatch; send 1,022 attributable invalid observations (`{:refused, :retained}` each, as in the author's own saturation test); then poll returning `{:unknown_to_provider, "trusted"}`. Result: `phase={:Dispatched, :Fresh, 1} active=true evidence=1022`. The replay-safe ground (or `Stranded` for a no-replay binding) is silently not recorded. A reserved `NoSend` at the same saturation still commits (the author's test), so the reservation is real for the three categories.
- Counterexample E (`/tmp/elz023-final/adv_e.exs`, exit 0): 4,090 host polls returning `pending` leave the log at revision 4093 (4096 minus the three reserved). Then `unknown_to_provider` is not recorded (`phase` stays `Dispatched`) and `advance(owner, :expire)` at the finite recovery deadline returns `{:error, :capacity}`, so the intent can never become `Stranded`. A later reserved `NoSend` would also leave a `Definite` that cannot be rearmed (a rearm needs five more events).
- Impact: no unsafe send (everything fails closed), but the intent cannot be resolved by the two routes that the Contract names, and at 1 poll per second the event budget is gone in about 68 minutes. The saturation acceptance bullet is only demonstrated for the three reserved categories.
- Required fix (no arithmetic change): treat `ProviderUnknown` (both outcomes) and the recovery-deadline strand as the attempt's `:settlement` (mutually exclusive with `Completed`/`NoSend`/`NoEffect` for that attempt), give the strand a small evidence record so it consumes the reserved slot, and add both to the halting `critical` list. Also bound routine events: do not append a log event per routine observation beyond a routine allowance (for example persist the counter only at powers of two, or stop appending routine events after a fixed routine budget and return `{:not_retained, :routine_budget}`), so that `events + held` can never be consumed by `Pending`. Add regression tests equal to counterexamples A and E.

### F2. MEDIUM (design hardening): public `observe/2` can mint the `adapter_no_send` ground while the send is still in flight
- Where: `effect_intent.ex:375-413` (`observe_result` public clause, `observe_envelope`, `result_event/1`: a `dispatch: "not_dispatched"` envelope becomes `:NoSend`/`:PermanentNoSend`); `binding.ex` callbacks (`authenticate(result, req)` receives no source). The per-variant `no_send_attestations` only constrain the send-return path (`translate/4`).
- Counterexample B (`adv.exs`, test B, exit 0): no-replay binding; the send task blocks. `Intent.observe(pid, <authenticated timed_out/not_dispatched envelope>)` returns `{:ok, :retained}` and the phase becomes `{:Definite, :AdapterNoSend, 1}`; then `advance(:rearm)` and `advance(:dispatch)` both succeed, and a **second physical send for the same key** is made while the first task is alive. The author's own saturation test also grounds no-send through the public path.
- Contract basis: "The binding attests per typed failure variant that adapter_no_send means no request bytes were handed to transport"; "Authenticated observations, Adapter no-send truth … remain external Needs". The binding cannot tell whether a `not_dispatched` result came from its own send return or from a caller, and a binding that authenticates provider results by correlation or signature accepts it.
- Required fix (small): refuse `dispatch: "not_dispatched"` results at the public `observe/2` (they are valid only from the attested send path), or pass a source tag to `authenticate/2` and document it. If the author keeps the current behaviour, the README Need must say that `authenticate/2` must reject `not_dispatched` results from any non-send source, and the tests that use public no-send (`known-attempt refusals…`, the Envelope-pair test) must keep a send-path variant. Do not weaken or delete existing assertions; add the refusal test.

### F3. LOW: the Store-limits startup check trusts the limits declared in the Store tuple
`effect_intent.ex:33-37` reads `store_opts[:limits]`, not the limits the Store enforces. A mismatch fails closed at write time (rejected append or checkpoint, then halt, before any send), so this is not a safety issue. Document it, or validate through the Store.

### F4. LOW/INFO (documented limits that I confirmed)
- `StoreHost` allows at most 4,096 activations per key (`host.ex`, `head.revision < 4096`); `advance(:expire)` before the deadline appends a no-op event each call (a part of F1).
- Bare Cure record tags `State`, `Config`, `Decision` need coordinated renaming; I found no tag or constructor collision with the other Cure Pieces (only the nullary `Missing` also exists in `workflow/budget`, and no value crosses).
- The Memory fixtures prove process-boundary behaviour only; machine death, physical fencing, provider authenticity and Adapter no-send truth are Needs.

## 5. Gates R-A to R-F and G1 to G9 on the actual source

| Gate | Verdict | Evidence |
| --- | --- | --- |
| R-A three grounds, unconditional law, initial/positive dispatch | CLEAR | Cure `step`; 11 production step laws; `settled`, `rearmed`; test `first dispatch…` |
| R-B narrow replay | CLEAR | only `ProviderUnknown` with `replay_valid` yields `ProviderReplaySafe`; send path cannot mint poll authority (`translate/4`) |
| R-C old completion, contradiction, read-only restart, host interface | CLEAR | `completion/3` per-attempt traversal; quarantine; grant binding |
| R-D bounded retention, numbers | CLEAR except F1 | codec measured 706,230 / 870,232 / reserve 870,758; checked below |
| R-E recovery grace | CLEAR | one call site `Binding.recovery_deadline`; boundary tests |
| R-F Store/Memory reuse, append AND checkpoint barriers | CLEAR | `commit/3`: preflight, append, replay of the row, then `Checkpoint.take` must be `{:committed, revision}` before any send |
| G1 monotone replay and possibly-sent history | CLEAR | `replay_dependent`, `ever_possibly_sent`; exact counterexample is a committed regression (pure and owner level); also rerun at policy level by my oracle |
| G2 revision | CLEAR | `can_revise`: no dependence, all attempts `SentNoBytes`, binding allows same-key changed arguments |
| G3 completion history in Cure | CLEAR | `completion`, `merge_verdict`, `classify_event`; mixed history freezes (conservative, documented) |
| G4 grant binding | CLEAR | `activate/3`: key, nonce, revision, digest equality, generation 1..4096, `head.revision == request.revision`, re-recovery and re-derivation of the request |
| G5 no caller Boolean | CLEAR | no public reconcile API; grant is the trusted callback return; `allow_volatile` is a startup option |
| G6 recovery deadline | CLEAR | checked addition, overflow refused |
| G7 codec, fold, budget arithmetic | CLEAR except F1 | canonical uncompressed ETF, safe decode, roundtrip; fold replays the actual Cure policy |
| G8 README storage | CLEAR | payload versus canonical, startup limits, no pruning, cumulative 3,229,007,872 and hard cap 4,294,967,296 |
| G9 remaining acceptance | CLEAR | see sections 3 and 7 |

## 6. If root prefers to accept F1 or F2 without code change (not recommended)
Only root can approve these Contract/README statements; I do not.
- F1 after (Scope, bounded priority evidence): "Reserved priority records cover Completed, NoSend, PermanentNoSend, NoEffect settlements, the first contradiction and the first refusal. The `unknown_to_provider` grounding and the recovery-deadline strand are not reserved and may fail with capacity exhaustion; the intent then stays `dispatched` until an operator reconciles."
- F2 after (Needs): "`authenticate/2` must reject `not_dispatched` results that do not come from the Adapter's own send return."

## 7. Independent checks I ran (all with the required locale, scheduler flags, `MIX_ENV=test`, own database)

| # | What | Exit | Result |
| --- | --- | --- | --- |
| 1 | `git rev-parse HEAD`, status, diff scope, claim ancestry, `git diff --check`, `scripts/check-claims.py` | 0 | as in section 2 |
| 2 | issue/task equality; A1 diff applied to the focused-review task text; edit times | 0 | equal 16,468 bytes; A1 comment before the body edit |
| 3 | `python3 docs/work/ELZ-023-generate-policy.py` in a scratch tree; `cmp` with committed `effect_intent.cure` | 0 | **byte-identical** (SHA-256 `cb652434…6111ec`, 210,041 bytes) |
| 4 | Cure `check_source` and `audit_env` on the production source | 0 | axioms, holes, opaque, unresolved, unaudited, not_proven_total empty; absurd 0 |
| 5 | `mix test pieces/delivery/effect-intent/test/elzoo/` | 0 | **`Result: 44 passed`** (28.9 s); fixture capacity printed `model=706230 checkpoint=870232 reserved=870758 delta=66376` |
| 6 | `python3 scripts/check-roadmap.py` and `--live` | 0 / 0 | `ROADMAP CHECK PASSED … 137 local links`; live Contracts match |
| 7 | Export plan against a scratch `mix new` project | 0 | pieces `core/envelope`, `state/event-log`, `state/checkpoint`, `state/outbox`, `integration/sql`, `delivery/effect-intent`; 56 files; no Application file; all Piece sources, tests and helper present |
| 8 | Independent policy oracle written from the Contract text (`policy_oracle.exs`, `po_guided.exs`): random and guided event sequences with time, attempts, history, revise, completion targets; compares the full Cure state tuple and action | 0 | 120,000 uniform plus 40,000 guided sequences: **0 mismatches**; coverage tally includes 6,157 dependent states, 120 laundering shapes, 1,349 contradictions; three injected oracle bugs (no dependence guard on arm, on rearm, no later-attempt contradiction) are detected (3, 5, 10 mismatches), so the comparison is not vacuous |
| 9 | Counterexamples A, B and E (`adv.exs`, `adv_e.exs`) against the real owner with Memory | 0 | as in F1 and F2 |
| 10 | Recorded full run `/tmp/elz023-a1/check-reviewed.log` (SHA-256 `9fc00d38…b7`): `Result: 32 passed`, `Result: 608 passed`, `ELZOO CHECK PASSED`, 26 fixed consumers and aggregate(42) | n/a | **read, not rerun** |

## 8. Proof, test, upstream and untested limits

- **Proof (Cure, pinned):** eleven step-projection laws over well-typed inputs, each proved first for all Boolean guard values and then instantiated with the real guards; plus structural helper laws. The expected relations are explicit case tables close to the runtime cases (the README says so). `completion`/`classify_event` and the guard bodies are **tested**, not proved: the helper laws on them are definitional restatements. The reachable-trace argument (no `Empty` recreation, `Fresh` only from `Empty`, `After(g)` only from `Definite(g)`, dispatch only on `Arm`) follows from the step laws plus the initial state; trace induction is **not** mechanized, as disclaimed. My oracle (item 8) is a second, independent check of the history, horizon and completion semantics, but it is a finite test.
- **Test:** 44 Piece tests (pure policy, owner with Memory, real PostgreSQL with random schemas, storage/codec, copy in a separate VM); the author's production mutation and scenario controls.
- **Upstream (named, not proved):** Adapter no-send truth, provider idempotency and final no-effect certificates, authenticity of observations, host activation and old-owner fencing, clock, PostgreSQL and Store durability, ETF encoding, Cure and BEAM arithmetic.
- **Not tested or not rerun by me:** full `mix check` and the 42-Piece aggregate export (recorded, not rerun); machine-death durability; real provider behaviour; guard mutation of the production policy (the author's tests cover horizon removal; my oracle covers guard semantics); the SQL suite beyond what the Piece run executes.

## 9. What is needed before the PR

1. Fix F1 and F2 with regression tests equal to counterexamples A, B and E (new tests only; no existing assertion changed), then a fresh full `mix setup` and `mix check` and a short incremental review of that delta; or root records the clarifications in section 6.
2. F3 as a README note (optional).
3. Then the normal PR checks and recording this review (session, SHA `196d088`, findings).
