# ELZ-319 — A checked money registry: validate a custom registry once, not on every call

- Dependencies: ELZ-316

## Outcome and scope

Owner decision of 21 November 2026, before the first release: since ELZ-316,
every `Elzoo.Money` and `Elzoo.Money.Codec` call walks a non-default
`registry:` with `Elzoo.Money.Registry.valid?/1`. Pricing makes many such
calls per card, so a 1024-line card with a custom registry took about 205 ms
locally instead of about 17 ms with the default (ELZ-316, PR #733). A custom
registry is to be validated once, and a forged registry must still be
refused. No global cache, process, ETS table or other process state may hold
what was validated.

The design: `Elzoo.Money.Registry.check/1` walks a registry once and returns
an opaque checked value. That value holds the registry inside a closure
created by `Elzoo.Money.Registry` itself, so ordinary Elixir code cannot build
one for a registry that was not checked. Every registry-taking function
accepts the checked value in constant time. A raw map is still walked in
full, as today.

This changes the `domain/money` Contract in place (same Piece ID, before the
first release): a new public function and a new accepted form of the
registry. `domain/pricing` gains the same accepted form and states its cost.
Owned paths: `pieces/domain/money/**` and `pieces/domain/pricing/**`; then,
in the last commit, both Pieces' `docs/plans/release-plan.json` entries
(`manifest_sha256`, and `note` equal to `contract` where `contract` changes)
and the generated views (`AGENTS.md` section 3). `domain/journal` is ELZ-320
and does not change here. `domain/quota` takes no registry.

## Required behavior

1. `Elzoo.Money.Registry.check(registry)` is pure. It returns `{:ok, checked}`
   when `valid?/1` is true, else `{:error, {:invalid_registry, nil}}`. It walks
   the registry once. `checked` is an opaque struct whose registry is held in
   a zero-arity closure created inside `Elzoo.Money.Registry`. It has no
   field that holds the registry as data, so there is no field to swap.
   `check/1` of the compiled default may return the default itself or a
   checked value; say which.
2. One shared check decides each registry value in this order:
   - the compiled default, compared with `===`: accepted, as today;
   - a checked value: accepted after a constant-time test that it is the
     struct `check/1` returns and that its closure is a local fun of
     `Elzoo.Money.Registry`, of arity 0, from the function that `check/1`
     uses; then its registry is used;
   - any other term: `valid?/1`, as today.
   Anything else that has the checked struct's shape is refused with the
   existing rejection. That includes a struct literal whose closure comes
   from another module, a closure of the right module built some other way,
   an external capture such as `&Elzoo.Money.Registry.default/0`, and a plain
   map with a `__struct__` key. The test does not walk the registry.
3. Every function of `Elzoo.Money`, `Elzoo.Money.Codec` and
   `Elzoo.Money.Registry` that takes a registry, as a `registry:` option or
   positionally, accepts a checked value. Every result for the default and
   for a raw map is unchanged.
4. `domain/pricing`: `price/3` and `difference/3` accept a checked value as
   `registry:`. A raw map is checked once per call and the checked value is
   passed to the money calls the call makes, so it is walked once per call,
   not once per line. The refusal stays `{:error, :invalid}`.
5. Limits:
   - The money `limits` state the cost of each form: the default, one `===`;
     a checked value, a constant-time test; a raw map, one walk per call,
     with the figure ELZ-316 measured.
   - The money `limits` state what a checked value does not resist: code
     that edits the external term format can build one. It also does not
     outlive a purge of the `Elzoo.Money.Registry` code that made it; using
     it then raises `badfun`, and the host checks again after a code upgrade.
   - The pricing `limits` state its cost per call for each form, with the
     figures of acceptance 3.

## Acceptance and evidence

1. Money tests:
   - `check/1` returns a checked value for a `build!/1` registry, and
     `{:error, {:invalid_registry, nil}}` for the forged map of ELZ-316.
   - Every registry-taking function gives the same results with a checked
     value as with the raw registry.
   - Every `registry:` function still refuses the forged raw map.
   - Each forged checked value of requirement 2 is refused with
     `{:error, {:invalid_registry, nil}}`.
2. Pricing tests:
   - A checked value prices like its raw registry.
   - A forged raw map and a forged checked value are both
     `{:error, :invalid}`.
3. Measurement, recorded in the PR body and the pricing limits: `price/3`
   of the same 1024-line card with the default, with a checked custom
   registry, and with the same custom registry as a raw map, three runs each
   in one session. The checked value and the raw map are each within 25
   percent of the default's time in that session.
4. Negative controls, each a temporary edit reverted and never committed,
   with its failing test recorded:
   - Accept any map as already checked (skip the walk for raw maps): the
     forged raw map passes, and tests 1 and 2 fail.
   - Reduce the checked-value test to the struct shape only: a forged
     checked value whose closure comes from the test module passes, and
     test 1 fails.
   - Make pricing walk the raw map on every money call again: the raw-map
     time of acceptance 3 is outside its bound.
5. `mix test pieces/domain/money/test pieces/domain/pricing/test`, the local
   small gate (`mix check --piece`, which also runs the journal tests that
   depend on money), `git diff --check`, and the index step 3 checks. Money
   is durable-state-adjacent money arithmetic, so the hosted substitution
   does not apply.
6. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
