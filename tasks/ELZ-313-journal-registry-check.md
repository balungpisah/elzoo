# ELZ-313 — Elzoo.Journal.new/1 refuses a value that is not a money registry

- Dependencies: ELZ-297, ELZ-316

## Outcome and scope

Repair a Contract defect in `domain/journal`, found by the one-time
other-family recheck that `AGENTS.md` section 6 owes this Piece. The
Contract is unchanged and the Piece ID stays. Task ELZ-297 (Interface) and
the `contract` of `piece.json` say that `Elzoo.Journal.new/1` takes
`registry:` as "an `Elzoo.Money.Registry` value" and otherwise raises one
fixed `ArgumentError`. On `main`, `registry?/1` in
`pieces/domain/journal/lib/elzoo/journal.ex` accepts any map that has a
non-empty `versions` list and a `snapshots` map. The recheck reproduced this
with `%{versions: ["bogus"], snapshots: %{}}`: `new/1` returned a journal
value instead of raising.

By owner decision, the journal uses the shared check that ELZ-316 adds to
`domain/money` (`Elzoo.Money.Registry.valid?/1`), the same check that
`domain/money` and `domain/pricing` use. `domain/money` is already a
declared dependency of the journal, so a copied consumer has the check.

Owned paths: `pieces/domain/journal/lib/**` and `pieces/domain/journal/test/**`;
then, in the last commit, the Piece's `docs/plans/release-plan.json` entry
(`manifest_sha256` when `piece.json` changes) and the generated views
(`AGENTS.md` section 3). The README and the `contract` of `piece.json` do
not change; only the `limits` may gain the sentence of requirement 2. Do not edit another Piece.

## Required behavior

1. `new/1` raises the existing fixed `ArgumentError` when
   `Elzoo.Money.Registry.valid?/1` is false for the `registry:` value. It
   accepts `Elzoo.Money.Registry.default/0` and every value
   `Elzoo.Money.Registry.build!/1` returns.
2. The journal's own deep check runs once, in `new/1`. Its per-call check
   of the journal value (`journal/1`) stays cheap: it checks that the value
   is a journal struct and does not walk the registry again. The
   `Elzoo.Money` calls the journal makes still apply ELZ-316's check, which
   costs nothing for the default registry and walks any other registry on
   each call. When that applies, say so in the `limits` of `piece.json` and
   refresh its `manifest_sha256`.
3. Every other behavior of `new/1` and of the Piece is unchanged.

## Acceptance and evidence

1. A regression test: the recheck's malformed value, a forged map that has
   all four registry keys (`versions`, `snapshots`, `active_numeric`,
   `sources`) but values `build!/1` could not give, and a map that lacks
   `active_numeric` or `sources` each raise the fixed message. The default
   registry and a `build!/1` test registry (as in case 6 of ELZ-297) are
   accepted.
2. Negative control: a temporary edit back to the key-only check makes the
   regression test fail. Revert it and never commit it.
3. `mix test pieces/domain/journal/test`, the local small gate (this Piece
   holds durable money state), `git diff --check`, and the index step 3
   checks.
4. One independent review, a green exact-head hosted `check-piece`, the PR
   marked ready, and the automated reviewer's gate of `AGENTS.md` section 6.
