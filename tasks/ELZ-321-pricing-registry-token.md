# ELZ-321 — domain/pricing checks a custom registry once per call and accepts a checked registry

- Dependencies: ELZ-319

## Outcome and scope

Owner decision of 21 November 2026, before the first release: a custom money
registry is validated once, not on every call. Today `price/3` and
`difference/3` pass a custom `registry:` to every `Elzoo.Money` call they
make, and each call walks it, so a 1024-line card with a custom registry took
about 205 ms locally instead of about 17 ms with the default (ELZ-316, PR
#733). ELZ-319 adds `Elzoo.Money.Registry.check/1` and a checked value that
every money function accepts in constant time.

This changes the `domain/pricing` Contract in place (same Piece ID, before
the first release): `registry:` also accepts a checked value. Owned paths:
`pieces/domain/pricing/**`; then, in the last commit, the Piece's
`docs/plans/release-plan.json` entry (`manifest_sha256`, and `note` equal to
the new `contract`) and the generated views (`AGENTS.md` section 3). No other
Piece changes.

## Required behavior

1. `price/3` and `difference/3` accept as `registry:` the compiled default, a
   raw registry or a checked value from `Elzoo.Money.Registry.check/1`.
2. A raw registry is checked once per call with `check/1`, and the checked
   value is passed to every money call the call makes, so the registry is
   walked once per call, not once per line. A checked value is passed on as
   it is.
3. A forged raw map and a forged checked value are refused with
   `{:error, :invalid}`, as today. Every other result is unchanged.
4. The pricing `limits` state the cost per call of each form, with the
   figures of acceptance 2.

## Acceptance and evidence

1. Pricing tests:
   - A checked value prices like its raw registry, in `price/3` and in
     `difference/3`.
   - A forged raw map and a forged checked value are both `{:error, :invalid}`.
2. Measurement, recorded in the PR body and the pricing limits: `price/3`
   of the same 1024-line card with the default, with a checked custom
   registry, and with the same custom registry as a raw map, three runs each
   in one session. The checked value and the raw map are each within 25
   percent of the default's time in that session.
3. Negative control, a temporary edit reverted and never committed: pass the
   raw map to every money call again. The raw-map time of acceptance 2 is
   outside its bound; record it.
4. `mix test pieces/domain/pricing/test`, the local small gate, `git diff
   --check`, and the index step 3 checks. The hosted substitution for the
   small gate does not apply to money arithmetic.
5. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
