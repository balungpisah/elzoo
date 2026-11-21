# ELZ-313 — Elzoo.Journal.new/1 refuses a value that is not a money registry

- Dependencies: ELZ-297

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

Owned paths: `pieces/domain/journal/lib/**` and `pieces/domain/journal/test/**`;
then, in the last commit, the Piece's `docs/plans/release-plan.json` entry
(`manifest_sha256` only if `piece.json` changes) and the generated views
(`AGENTS.md` section 3). The README and the `contract` of `piece.json` do
not change.

## Required behavior

1. `new/1` raises the existing fixed `ArgumentError` for a `registry:` value
   that `Elzoo.Money.Registry.build!/1` could not have built. At least:
   `versions` is not a non-empty list of distinct version IDs; `snapshots` is
   not a map whose keys are exactly those versions; a snapshot is not a map
   from alpha code to an `%Elzoo.Money.Currency{}` entry with that alpha.
   The check reads the value only, does no I/O, and accepts
   `Elzoo.Money.Registry.default/0` and every value `build!/1` returns.
2. Every other behavior of `new/1` and of the Piece is unchanged.
3. Stop and comment on the issue if requirement 1 cannot be met without
   changing `domain/money`. Do not edit another Piece.

## Acceptance and evidence

1. A regression test: the recheck's malformed value and one value per
   failure in requirement 1 each raise the fixed message; the default
   registry and a `build!/1` test registry (as in case 6 of ELZ-297) are
   accepted.
2. Negative control: a temporary edit back to the key-only check makes the
   regression test fail. Revert it and never commit it.
3. `mix test pieces/domain/journal/test`, the local small gate (this Piece
   holds durable money state), `git diff --check`, and the index step 3
   checks.
4. One independent review, a green exact-head hosted `check-piece`, the PR
   marked ready, and the automated reviewer's gate of `AGENTS.md` section 6.
