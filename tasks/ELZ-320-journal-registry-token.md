# ELZ-320 — domain/journal checks its registry once and keeps the checked value

- Dependencies: ELZ-314, ELZ-319

## Outcome and scope

Owner decision of 21 November 2026, before the first release: a custom money
registry is validated once, not on every call. ELZ-319 adds
`Elzoo.Money.Registry.check/1` and a checked value that every money function
accepts in constant time. The journal still passes its raw registry to every
`Elzoo.Money` call, so a non-default registry is walked up to
2 × limit + held versions times per `history/3` page. That bound is stated in
the journal `limits` by ELZ-313.

This task makes `new/1` check the registry once and keep the checked value.
Owned paths: `pieces/domain/journal/**`; then, in the last commit, the
Piece's `docs/plans/release-plan.json` entry (`manifest_sha256`, and `note`
equal to `contract` if `contract` changes) and the generated views
(`AGENTS.md` section 3). No other Piece changes.

## Required behavior

1. `new/1` accepts as `registry:` the compiled default, a raw registry or a
   checked value from `Elzoo.Money.Registry.check/1`.
   - A raw registry is checked once with `check/1`. A refusal raises the
     existing fixed `ArgumentError`.
   - The journal value keeps the default or a checked value, never a raw
     custom map.
   - A forged checked value is refused with the same `ArgumentError`.
2. Every `Elzoo.Money` call the journal makes passes that kept value.
   - `journal/1`'s per-call checks stay as they are, except that its
     registry check also accepts a checked value.
   - Every result, bound and query is unchanged.
3. The journal `limits` replace the walk-count bound of ELZ-313 with the new
   cost: one walk in `new/1` for a raw custom registry, and constant time per
   call after it. They keep the sentence that `member/2` checks membership
   only. Refresh `manifest_sha256`.

## Acceptance and evidence

1. Journal tests:
   - `new/1` with a raw custom registry, with its checked value and with the
     default all post, balance and page `history/3` with the same results.
   - The forged raw map of ELZ-313 and a forged checked value both raise the
     fixed `ArgumentError`.
2. Negative control, a temporary edit reverted and never committed: keep the
   raw map in the journal value. A test that observes the kept value must
   fail; it asserts that the value is not a raw custom map. Record which
   test failed.
3. `mix test pieces/domain/journal/test`, the local small gate, `git diff
   --check`, and the index step 3 checks. The Piece holds durable state, so
   the hosted substitution does not apply.
4. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
