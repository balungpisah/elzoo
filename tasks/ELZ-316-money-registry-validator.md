# ELZ-316 — One money registry check, used by domain/money and domain/pricing

- Dependencies: ELZ-031, ELZ-304

## Outcome and scope

Owner decision of 21 November 2026, before the first release: a `registry:`
value is checked the same way in `domain/money`, `domain/pricing` and
`domain/journal`, by one shared check in `domain/money`. Today `domain/money`
does not check an explicit `registry:` option at all. `domain/pricing`
checks only that the four keys exist (`pricing.ex`, `registry/1`). The
other-family recheck found the same gap in `domain/journal` (ELZ-313, which
depends on this task). So a forged map, such as `%{versions: ["bogus"],
snapshots: %{}, active_numeric: %{}, sources: %{}}`, passes.

This changes the `domain/money` Contract in place (same Piece ID, before the
first release): a new public function and a new typed rejection.
`domain/pricing` keeps its Contract; it only uses the shared check. Owned
paths: `pieces/domain/money/**` and `pieces/domain/pricing/lib/**`,
`pieces/domain/pricing/test/**`, the pricing README sentence on `registry:`
if it describes the check; then, in the last commit, both Pieces'
`docs/plans/release-plan.json` entries (`manifest_sha256`, and the money
`note` equal to its new `contract`) and the generated views (`AGENTS.md`
section 3). `docs/choices.md` makes no statement about the registry check
and does not change. `domain/quota` takes no registry and does not change.

## Required behavior

1. `Elzoo.Money.Registry.valid?/1` is a pure function with no I/O. It
   returns `true` for `Elzoo.Money.Registry.default/0` and for every value
   that `Elzoo.Money.Registry.build!/1` returns, and `false` at least for
   these terms: a term that is not a map with exactly
   the keys `versions`, `snapshots`, `active_numeric` and `sources`;
   `versions` that is not a non-empty list of distinct binaries in ascending
   (oldest-first) order; `snapshots`, `active_numeric` or `sources` that is
   not a map whose keys are exactly the versions; a snapshot that is not a
   map from alpha code to an entry map whose `alpha` equals its key and that
   holds the `numeric`, `minor_unit` and `status` fields and the `rows` list
   of maps with `numeric` that `Elzoo.Money` reads (`build!/1` writes plain entry maps, not `%Elzoo.Money.Currency{}`);
   and an `active_numeric` value for a version that is not exactly the map
   from the integer numeric code of each active entry of that snapshot to
   its alpha (`build!/1` builds it so; an entry missing from it would make
   `parse_numeric/2` call an active currency unknown).
2. Every public function of `Elzoo.Money` and `Elzoo.Money.Codec` that takes
   a `registry:` option returns an error when `valid?/1`
   is false for an explicit value, before any other check of the call, as
   `{:error, {:invalid_registry, nil}}`: the money error shape of the README,
   with a detail that never echoes the registry. `Elzoo.Money.Registry`
   functions that take the registry as a positional argument (such as
   `entry/3` and `held?/2`) are out of scope.
   A value identical to the compiled default (`Elzoo.Money.Registry.default/0`,
   compared first with `===`, exact term equality, so the Pieces that pass
   the default on every call pay nothing) is not walked again. `==` must not
   be used there: it equates integer and float map values, so a copy of the
   default with float fields would skip the check. `invalid_registry` joins the
   typed rejections in the README and the `contract` of `piece.json`. Another
   explicit registry is walked on every call; state that cost in the
   `limits`, with a figure measured for a registry the size of the default.
3. `domain/pricing` replaces its key-only check in `registry/1` with
   `Elzoo.Money.Registry.valid?/1`. Its refusal stays `{:error, :invalid}`,
   and its Contract does not change.
4. Every other behavior of both Pieces is unchanged.

## Acceptance and evidence

1. Money tests: `valid?/1` is true for the default and for a `build!/1` test
   registry, and false for one value per failure in requirement 1, the
   forged map above included. Every public `Elzoo.Money` and `Elzoo.Money.Codec`
   function that takes `registry:` returns `{:error, {:invalid_registry, nil}}`
   for that forged map, also when the same call names an unknown explicit
   version (the registry rejection comes first), and for a copy of the
   default whose `numeric` and `minor_unit` fields are floats.
2. Pricing tests: `price/3` and `difference/3` with the forged map return
   `{:error, :invalid}`; the default and a built registry still price.
3. Negative controls, one per change, each a temporary edit reverted and
   never committed: removing the money option check lets the forged map
   through and fails test 1; restoring pricing's key-only check lets the
   forged map through and fails test 2.
4. `mix test pieces/domain/money/test pieces/domain/pricing/test`, the local
   small gate, `git diff --check`, and the index step 3 checks.
5. One independent review, a green exact-head hosted `check-piece`, the PR
   marked ready, and the automated reviewer's gate of `AGENTS.md` section 6.
