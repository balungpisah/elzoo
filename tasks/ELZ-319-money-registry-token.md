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
accepts the checked value in constant time. A raw map passed as `registry:`
is still walked in full, as today.

This changes the `domain/money` Contract in place (same Piece ID, before the
first release): new public functions and a new accepted form of the
registry. Owned paths: `pieces/domain/money/**`; then, in the last commit,
the Piece's `docs/plans/release-plan.json` entry (`manifest_sha256`, and
`note` equal to the new `contract`) and the generated views (`AGENTS.md`
section 3). `domain/pricing` is ELZ-321 and `domain/journal` is ELZ-320;
neither changes here. `domain/quota` takes no registry.

## Required behavior

1. `Elzoo.Money.Registry.check(registry)` is pure. It returns `{:ok, checked}`
   when `valid?/1` is true, else `{:error, {:invalid_registry, nil}}`. It walks
   the registry once. `checked` is an opaque struct whose registry is held in
   a zero-arity closure created inside `Elzoo.Money.Registry`. It has no
   field that holds the registry as data, so there is no field to swap.
   The closure is made by a private function of `Elzoo.Money.Registry` that
   `check/1` calls only after `valid?/1` is true. `check/1` of the compiled
   default may return the default itself or a checked value; say which.
   `valid?/1` of a genuine checked value is `true` and `check/1` of one is
   `{:ok, same}`, both in constant time, so a caller can pass either form
   to either function.
2. Every function of `Elzoo.Money` and `Elzoo.Money.Codec` that takes a
   `registry:` option decides that value with one shared check, in this order:
   - the compiled default, compared with `===`: accepted, as today;
   - a checked value: accepted after a constant-time test that it is the
     struct `check/1` returns and that its closure, read with
     `:erlang.fun_info/2`, is a `local` fun of module `Elzoo.Money.Registry`,
     of arity 0, whose `name` is that of the private sealing function; then
     its registry is used. `new_uniq` is the same for every fun of the module,
     so it does not identify the function, and the test does not compare it
     with a live reference fun (see the code-purge limit in requirement 5);
   - any other term: `valid?/1`, as today.
   Anything else that has the checked struct's shape is refused with the
   existing rejection. That includes a struct literal whose closure comes
   from another module; a closure of `Elzoo.Money.Registry` from another
   function, which the test builds by editing the index of a genuine
   token's closure in its external term format; an external capture such as
   `&Elzoo.Money.Registry.default/0`; and a plain map with a `__struct__` key
   and a closure that is not genuine. The test does not walk the registry.
3. Functions that take the registry as a positional argument (such as
   `Elzoo.Money.member/2`, `Elzoo.Money.Registry.latest/1`, `entry/3` and
   `held?/2`) do not validate today and do not start to: a checked value that
   passes the constant-time test of requirement 2 is unwrapped and used, and
   any other value is used exactly as today, unchecked, so every result for
   the default and for a raw map is unchanged. A forged checked value is such
   an other value: no positional function ever calls its closure. The README
   names what each positional function returns or raises for one, and a
   test asserts it.
4. A new positional `Elzoo.Money.Registry.versions/1` returns the held
   versions, oldest first, of the default, of a checked value or of a raw
   registry, the way `latest/1` reads them, so that a consumer that
   enumerates versions (`domain/journal`, ELZ-320) need not read the map.
5. The money `limits` state:
   - the cost of each form passed as `registry:`: the default, one `===`; a
     checked value, a constant-time test; a raw map, one walk per call, with
     the figure ELZ-316 measured;
   - what a checked value does not resist: code that edits the external
     term format can build one, and decoding untrusted bytes with
     `:erlang.binary_to_term/2`, `:safe` included, can produce one that is
     accepted, so a host never decodes a registry from untrusted bytes (a
     raw map decoded that way is still walked);
   - that a checked value works only with the `Elzoo.Money.Registry` code
     that made it: after a purge of that code, or sent with
     `term_to_binary` to another node or a later build, it still passes the
     test and using it raises `badfun`, so the host checks again after a code
     upgrade and does not send checked values between nodes.

## Acceptance and evidence

1. Money tests:
   - `check/1` returns a checked value for a `build!/1` registry, and
     `{:error, {:invalid_registry, nil}}` for the forged map of ELZ-316.
   - Every registry-taking function, `registry:` and positional, gives the
     same results with a checked value as with the raw registry, and
     `versions/1` gives the same list for both.
   - Every `registry:` function still refuses the forged raw map.
   - Each forged checked value of requirement 2 is refused by every
     `registry:` function with `{:error, {:invalid_registry, nil}}`.
2. Measurement, recorded in the PR body and the money limits: the time of
   `valid?/1` of a registry the size of the default against the time of the
   constant-time test of a checked value, three runs each in one session.
3. Negative controls, each a temporary edit reverted and never committed,
   with its failing test recorded:
   - Accept any map as already checked (skip the walk for raw maps): the
     forged raw map passes, and test 1 fails.
   - Reduce the checked-value test to the struct shape only: a forged
     checked value whose closure comes from the test module passes, and
     test 1 fails.
   - Drop only the function-name test (keep module, type and arity): the
     closure of `Elzoo.Money.Registry` from another function passes, and
     test 1 fails.
4. `mix test pieces/domain/money/test`, the local small gate (`mix check
   --piece`, which also runs the pricing and journal tests that depend on
   money, unchanged), `git diff --check`, and the index step 3 checks. The
   hosted substitution for the small gate does not apply to money.
5. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
