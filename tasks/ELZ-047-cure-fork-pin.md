# ELZ-047 — Pin Cure to the balungpisah fork with the import source-scan fix

- Phase: P0 harness (toolchain pin; `mix.exs`, `mix.lock`, `docs/dependencies/forks/cure.md`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-045 (#80, merged b2dcdeb) for the stage stamps that measure this. ELZ-046 (#82) is independent.
- Source: CI speed assessment 2026-11-08, item 4. Upstream-first per docs/development/08-upstream-and-forks.md.

## Outcome

Cure at `a004c335` resolves every `use` import of a project module by globbing, lexing and parsing
every `.cure` file under the source roots, on every lookup. Compiling the 25 owned Elzoo sources
took 82.3 s / 79.8 s on upstream `main` without the fix, 13.2 s / 13.4 s with it on `main`, and
17.6 s / 14.6 s at the fork pin commit (same laptop, two samples each). Every copied consumer repeats this compile, 27 times per full CI run.

The fix is written against upstream (`balungpisah/cure-lang` branch `elzoo/user-source-index`,
PR https://github.com/cure-lang/cure-lang/pull/82, open). Upstream has no timeline. This task moves Elzoo's pin to a
fork branch that is the exact pin commit `a004c335` plus only that fix, so CI gets the gain now and
no other upstream change.

## Scope

- `mix.exs` / `mix.lock`: Cure git dependency points at the fork URL and the immutable commit of
  `elzoo/pin-a004c335-user-source-index`. Nothing else in the lock changes.
- `docs/dependencies/forks/cure.md`: the fork record the rule requires (problem, upstream URL and
  base revision, license and notices, fork URL and consumed revision, patch summary, consumers,
  tests, monitoring owner, return-upstream conditions).
- AGENTS.md "mix setup must use Cure commit a004c335..." sentence and `docs/development/10-symbolic-ci.md`
  updated to the new pin and its reason. Any other place that names the pin commit.
- Piece manifests and READMEs: only the `upstream` reference URL/revision and the pin named in
  prose change; no Contract, law or behavior changes. One existing assertion changes, approved by the
  owner in the ELZ-047 session (quoted on #84): `test/export_test.exs:42` asserts the exact pinned revision in the
  consumer install instructions, and now names the fork commit (same intent). Cure's own tests
  for the fix live in the fork.

## Acceptance

- [ ] Full `mix setup` and `mix check` pass locally on the new pin; counts unchanged (root 526 or 528 if #83 merged first, Ash 32).
- [ ] CI on both backend runners: one first run each after the lock change (the cache restores
      by prefix key, `mix deps.get` refetches Cure and rebuilds it; record `mix setup` and cache
      save), then one warm run each on the same SHA. Record run and job IDs. Compare `ELZOO TIMING consumer=aggregate(40)` and the sum of per-ID consumers against the baselines on #81 (machine A 472 s / 350 s; macbook 562 s / 428 s).
- [ ] Independent review of the actual diff (toolchain pin + evidence claims).
- [ ] Fork record complete; upstream PR link recorded.

## Limits

The gain is measured locally and is hypothetical on CI until the warm runs land. The fork carries one
patch; returning upstream is the goal once the PR merges and a release includes it.
