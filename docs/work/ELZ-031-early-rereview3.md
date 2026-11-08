# ELZ-031 focused independent early re-review, round 3

Redacted for publication; SHA-256 of the reviewer's original report: b480da4d3316f4ed63e0f8b9978c35ecbe954eb4c9494c147fdb2bac3d96b4b8

Reviewer: Codex, the independent reviewer (Codex), independent of proposal the implementation worker. Reviewed `origin/task/ELZ-031` at `d9cbc1299f9aa4a265a4498ad51d2cfe1cf9c48a`, against prior review at `97d93124fdaecbe2d32deac56459adfed29d45c8`, current live issue #48 and `origin/main` at `f4e328319ec23fa7bc6d8c8f0a19c2a3122bd938`. This is a design review; it does not verify the implementation, provider experiments, or legal rights. No Mix command was run.

## New required correction

**R3-1 — the proposed Cure dropped-residual negative control cannot be grounded by the stated laws.** `docs/work/ELZ-031.md` §6 says a mutated dropped residual is rejected by Cure at a named law. Section 8 expressly says the allocation-sum law is not provable on this pin and the planned allocation laws establish count and currency, not the units sum. A mutation that leaves all shares and their currencies intact but omits adding the residual preserves both those properties, so those laws will not reject it. Either identify and actually check a production-connected Cure law that detects that precise mutation, or remove the asserted Cure control and use the already planned finite executable sum control, with explicit scope and the compiler limitation. This corrects evidence wording; it does not weaken the sum invariant. The actual selected laws and their controls remain G7/G10 implementation gates.

**R3-2 — derivation command needs a consistent hash source.** §7.2 says the two-argument `elixir ...iso4217_derive.exs LIST_ONE LIST_THREE` command checks source hashes against the extract header, but the displayed invocation does not identify the extract whose header it must read. Define how the command locates the header or pass `--check EXTRACT` explicitly, and require hashes, nonzero drift exit, and the recorded run. This is an actionable design clarification before claiming reproducible evidence, not an assertion that the extract already exists.

Minor wording: §6 says to test “atoms or strings as rounding mode or placement,” although the supported valid settings are atoms; specify invalid atoms and strings. The final implementation must use the actual Decimal 3.2.0 API/context behavior and reject malformed struct fields, not only NaN/infinity.

## Disposition of prior findings

| Finding | Design disposition |
| --- | --- |
| BLOCKING 1, dataset/version law | Addressed as a **proposed deliberate replacement**, not an already amended law: A2 admits explicit missing fields; A3 states current and historical row coverage and calls numeric history enumeration. Membership is version-specific. G1 remains unsatisfied until reviewed live issue and task copy are updated. |
| BLOCKING 2, scope/SQL | Main coordinator has authorized the exact Decimal dependency, provider entry and root SQL test conditional on G3 choosing Decimal; A5 publishes proposed wording. G3's two-candidate SQL comparison is still open, with no outcome inferred from attempt 1. G1/G2/G3 remain gates. |
| REQUIRED 3, public rejection/value contract | A1 supplies rejection variants and operation table; A2/A3 explicitly change mandatory-field and dataset laws. These are decisions pending G1, not live issue behavior. |
| REQUIRED 4, forgery/replay | Addressed by design: version-specific identity and status at every public currency boundary, explicit cross-version equality, synthetic V2-as-V1 and V1-as-V2 forgery, invalid status, unknown version and old-byte tests. No production evidence yet; G4 remains. |
| REQUIRED 5, allocations/evidence | Signed property corrected to `abs(part - share) <= abs(residual)`; positive-ratio placement, signed examples, bounded exhaustive test and C9 fixture planned. Cure dropped-residual control is inconsistent with stated laws (R3-1), and all tests remain unexecuted. |
| REQUIRED 6, packaging/rights | Repository SQL test keeps the copied Piece pure. Option 2 is chosen; rights/terms for extract creation and redistribution remain open, and extract fidelity relies on recorded derivation, not `mix check` against SIX. Resolve R3-2 and terms before committing an extract; execute G5/G8. |
| REQUIRED 7, context/categories | The design bounds strings and Decimal coefficient/exponent, uses exact integer arithmetic, isolates any Decimal arithmetic in a trapped local context and plans >34 digit and non-default-context tests; pure Piece has no monitored behavior. These are proposed checks, not results. See R3-1 and G7/G9. |
| LOW 8, provider rationale | Appropriately conditional and distinguishes library capability from necessity; record delegates selection to the actual G3 comparison. No source copy or AshMoney requirement without its condition. |

## Amendments

All six `Before` blocks appear byte-for-byte exactly once in live #48 (automated check). A1 and A2 share an adjacent line and must be applied together carefully. The approved A6 Scope text and A2–A4 replacement wording match the earlier re-review's wording apart from line wrapping; A5 incorporates the reviewer’s lock and generated-view limitations and the specified conditional shared paths.

| Amendment | Verdict |
| --- | --- |
| A1 | Acceptable proposal, subject to G1 and complete operation-specific behavior. |
| A2 | Acceptable replacement for coordinator decision; explicitly changes the mandatory numeric/exponent law and preserves retirement/versioned replay wording. |
| A3 | Acceptable replacement for coordinator decision; honestly narrows/replaces the old all-row law, including honest historic enumeration rather than as-of parse. |
| A4 | Acceptable replacement, preserves allocation-sum law and defines sign, truncation, zeros and placement. |
| A5 | Acceptable scope wording reflecting explicit conditional authorization; publish it under G1/G2 and report actual lock result. Own catalogue row and release entry plus required regenerated LEDGER/views remain scoped. |
| A6 | Exact coordinator-approved option 2 Scope wording; publish with other accepted changes. Verify applicable terms independently before committing the factual extract; no SIX file. R3-2 applies to derivation. |

## ELZ-027 cross-check requested in dispatch

Read revision 4 on `origin/task/ELZ-027` at `957e2f598056d038f80fff753f37ada904e6562b`, live #44, and task copy at `bbc0eff` (byte-equal to live body). A1-rev2 is live and the composition statement stands. Revision 4 plans executable tests against `Elzoo.Envelope.validate_result/1`, `Cure.Elzoo.Idempotency.receiver/2`, and the real `delivery/time` recipe's shell clock/timer pattern; these are plans, not executed results. Identity laws call production `identify`, with generation and instant mutations aimed at field laws and a separate production-transition mutation. `already_recorded{slot}` never fabricates an ID and has replay scenarios after skip, settlement and redefinition. This focused check is not an implementation review or a separate full ELZ-027 verdict.

## Scope, remaining gates and evidence

The three-dot branch-only diff lists only `.claims/ELZ-031.md` and six ELZ-031 work documents; no implementation, shared registry/provider/lock, Mix or test code is committed. The claim marker must be removed before PR. The large `97d9312..d9cbc12` diff also includes the normally merged main changes, not task-authored ELZ-050 changes; merge commit `2b5be28` includes main. Both copied review files are byte-identical to their `/tmp` originals. G1–G10 are adopted verbatim (all ten exact comparisons pass), and none is complete merely by adoption. G1 needs reviewed issue/task updates; G2 published scope and precise authorization; G3 both actual provider comparisons on assigned disposable DB; G4–G9 implementation, rights, tests, proof and packaging evidence; G10 pinned `mix setup`, applicable ledger regeneration, full `mix check`, and independent final review. Do not claim ready status or full evidence from this proposal. The current checkout already contained untracked `.reticle-setup-crash.log`, untouched.

## Commands and exit codes

- `git fetch origin --prune`: 0. `git rev-parse origin/main origin/task/ELZ-031`, `git diff --stat 97d9312 d9cbc12`, `git diff --name-status origin/main...d9cbc12`, and relevant `git show`, `git log`, `git status`: 0.
- `gh issue view 48 -R balungpisah/elzoo --json body` and the equivalent for issue 44: 0; bodies saved under `/tmp`.
- `git show d9cbc12:docs/work/ELZ-031-early-review.md | cmp - the reviewer's original report (early review)`: 0. Equivalent compare of `ELZ-031-early-rereview.md` against `the reviewer's original report (early re-review)`: 0.
- Python exact before-block and G1–G10 comparison: 0, six before blocks each present once and ten gates equal. `git diff --check origin/main...d9cbc12`: 0. Task #44 copy at `bbc0eff` against live issue body with `diff -u`: 0.
- `curl -fsSL --max-time 20 https://hexdocs.pm/decimal/3.2.0/Decimal.html | rg -o ... | sort -u`: 0, docs list `new/1`, `new/2`, `new/3`; this does not execute Decimal. Attempt to inspect local `deps/decimal` with `rg`: 2, files absent; no dependency setup run.
- `orca skills get orchestration` and `orca skills get orca-cli` via bare symlink: 1 (`Unable to determine application path from symlink: the orchestration CLI symlink`); both through session the session CLI-path variable: 0. Only the report and captured issue bodies outside the repository were written.

NOT CLEAR — correct R3-1 in the proposed evidence plan and resolve R3-2's derivation invocation; G1 and all other execution gates still apply.
