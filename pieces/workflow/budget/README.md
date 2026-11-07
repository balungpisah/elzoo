# workflow/budget

> **Status: ready subset (ELZ-022, issue #36).** The Contract passed early
> independent review (https://github.com/balungpisah/elzoo/issues/36#issuecomment-6694121963).
> The L3/L4 decision-split form is the coordinator decision recorded at
> https://github.com/balungpisah/elzoo/issues/36#issuecomment-6694407428.

Admit a spend-bearing call under a sealed cap, record its reservation in the
same serialized step, and settle the observed cost afterwards. One pure
transition decides; one volatile OTP owner per budget identity serializes it.

This is a budget of unit-tagged cost (tokens, calls, milliseconds, turns,
cents-as-estimate). It is **not** money settlement, a financial ledger, an
invoice or journal, a tenant quota, or a rate limiter. Pricing, currency
conversion, provider usage collection, durability and cross-node agreement
are out of scope.

Callers: C2 (report Run budget), C6/C7 (bounded agent fan-out cost). C9's
provider-cost reservation is the second-unit challenge.

## Interface

Pure policy `Elzoo.Budget` (Cure module `Elzoo.Budget`, Elixir projection
with the same name). Volatile owner `Elzoo.Budget.Owner`, built on the
unchanged `Elzoo.Unit` from runtime/unit.

```elixir
# Pure
{:ok, state} = Elzoo.Budget.initial("run-42/tokens", incarnation, 10_000, "tokens")
true = Elzoo.Budget.readable?(state)   # the I0 check
{:Transition, next, {:some, result}} = Elzoo.Budget.step(state, {now_ms, input})

# Owner
{:ok, owner} = Elzoo.Budget.Owner.start_link(
  budget_id: "run-42/tokens", cap: 10_000, unit: "tokens")
{:status, %{generation: gen}} = Elzoo.Budget.Owner.status(owner)
Elzoo.Budget.Owner.reserve(owner, %{cap: 10_000, unit: "tokens",
  estimate: 800, cost_ref: "call-1", expiry: now_ms + 30_000})
Elzoo.Budget.Owner.settle(owner, %{cost_ref: "call-1", generation: gen, actual: 650})
Elzoo.Budget.Owner.release(owner, %{cost_ref: "call-1", generation: gen})
Elzoo.Budget.Owner.reset(owner, %{generation: gen})
Elzoo.Budget.Owner.sweep(owner)

# Pure, beside the owner
Elzoo.Budget.critical_path(n, k, b, deadline)
Elzoo.Budget.critical_path_waves(waves, k, deadline)
```

### Inputs

Each input is a map with exactly the listed keys. All keys must be strings or
all keys must be atoms. A map that mixes the two forms (for example both
`"cap"` and `:cap`), or has an unknown or missing key, is
`rejected{invalid_input}`.

| Input | Fields |
|---|---|
| `reserve` | `cap`, `unit`, `estimate`, `cost_ref`, `expiry` |
| `settle` | `cost_ref`, `generation`, `actual` |
| `release` | `cost_ref`, `generation` |
| `reset` | `generation` (the generation the Assembly expects to replace) |
| `status` | none |
| `sweep` | none |

The pure transition receives `{now_ms, input}`. `input` is
`{:reserve, map} | {:settle, map} | {:release, map} | {:reset, map} | :status | :sweep`.

### Outputs

`step/2` always returns `{:Transition, next_state, {:some, result}}`. It is
total: it never raises for any `{now_ms, input}` or state term.

| Result | Meaning |
|---|---|
| `{:reserved, %{cost_ref, generation, estimate, remaining}}` | Admitted and recorded in one step. |
| `{:rejected, reason}` | No admission. State changes only by the expiry sweep (L5). |
| `{:settled, %{cost_ref, generation, refund, late: false}}` | Open entry, `actual <= estimate`; `refund = estimate - actual` (`0` when equal). |
| `{:settled, %{cost_ref, generation, overage, late: false}}` | Open entry, `actual > estimate`; `overage = actual - estimate`. |
| `{:settled, %{cost_ref, generation, refund: 0, late: true}}` | Expired or released entry, `actual <= estimate`. |
| `{:settled, %{cost_ref, generation, overage, late: true}}` | Expired or released entry, `actual > estimate`; `overage = actual - estimate`. |
| `{:released, %{cost_ref, generation}}` | Reservation freed without an actual. |
| `{:reset, %{generation, forfeited}}` | New generation started; `forfeited` is the number of open reservations dropped. |
| `{:status, %{budget_id, generation, cap, unit, committed, reserved, remaining, open}}` | Read after the sweep; `open` is the open-entry count. |
| `{:swept, %{expired}}` | Sweep only; `expired` is the number of entries this sweep expired. |

Every `settled` result, first or repeated, is derived from the stored entry
`settled{estimate, actual, late}`. `refund` and `overage` are never a separate
write. For `late: true`, `refund` is always `0`: the sweep or release already
returned the estimate to headroom, so a positive refund would suggest headroom
that was never given back here.

Rejection reasons: `:unreadable`, `:invalid_input`, `:invalid_amount`,
`:invalid_unit`, `:invalid_cost_ref`, `:invalid_expiry`, `:changed_limits`,
`:stale_generation`, `:cost_ref_conflict`, `:cost_ref_closed`,
`:unknown_cost_ref`, `:actual_conflict`, `:already_settled`, `:overage`,
`:insufficient`. The owner client adds `:owner_unavailable`.

Fixed stage order for every input:

1. shape and I0 (`:unreadable`, then input decoding: `:invalid_input`,
   `:invalid_amount`, `:invalid_unit`, `:invalid_cost_ref`);
2. sweep with `now_ms`;
3. for `reserve` only: `:invalid_expiry`, then `:changed_limits`, then
   `:overage` (when `committed > cap`), then replay or new-entry handling
   (D1), which can give `:cost_ref_conflict`, `:cost_ref_closed` or
   `:insufficient`;
4. for `settle`, `release`, `reset`: `:stale_generation`, then the per-entry
   checks in D5.

The order inside each stage is fixed in the implementation and tested.

### Deltas from the #36 interface

The preflight gives this task the identity, generation and reset decisions.
Each delta below is deliberate and needs no new task.

1. **Budget identity removed from inputs.** It is fixed at owner start
   (and in `initial/4`). One owner serves one identity, so an input cannot
   address a different budget.
2. **`generation` added to `settle` and `release`.** It stops a late settle
   from a replaced budget or an earlier incarnation from mutating the current
   one (preflight reset/generation rule).
3. **`reset{budget identity}` became `reset{generation}`.** The identity is
   implied by the owner. The expected generation is the expected-revision
   guard against a stale or repeated reset.
4. **`remaining` added to `reserved`.** It is derived and saves a status call.
   It is not a separate write.
5. **`{:reset, %{generation, forfeited}}` result added.** The issue lists
   reset only as an input; a caller needs the new generation and the count of
   forfeited reservations.
6. **`status` and `sweep` reads added.** The Assembly needs the current
   generation before its first `reset`. `sweep` is the explicit expiry path
   an Assembly can drive from its own timer.
7. **Cap and unit sealed at owner start.** `reserve` still carries them, as
   the issue requires, and they are compared with the seal.
8. **`late` flag added to `settled`.** It tells the caller that the estimate
   was already freed, so `refund` is `0` and only the actual was committed.
9. **`cost_ref` and `generation` added to `settled` and `released`.** At-least-
   once callers need to match a result to its request and generation.
10. **`{:swept, %{expired}}` result added.** It is the result of the `sweep`
    input (delta 6).

## State invariant I0 (shape check)

A readable state satisfies all of:

- `reserved == sum(estimate of open entries)`;
- `reserved >= 0` and `committed >= 0`;
- `cap` and every stored `estimate` and `actual` are positive integers;
  `unit`, `budget_id`, `incarnation` and every `cost_ref` are nonempty UTF-8
  strings; `counter >= 1`;
- each entry is `open{estimate, expiry}`, `expired{estimate}`,
  `released{estimate}` or `settled{estimate, actual, late}` (`late` is a
  boolean).

`readable?/1` checks I0 first in every `step/2`. A state that fails I0 (for
example a corrupted snapshot or a hand-built term) gives `rejected{unreadable}`
for every input, including `reset`, and is returned unchanged with no sweep. A
broken `reserved` scalar therefore fails closed instead of over-admitting. An
unreadable owner cannot be repaired through its inputs; the Assembly replaces
it with a new start (new incarnation).

## Cure and Elixir split

**Cure (`Elzoo.Budget` in `cure/elzoo/budget.cure`; laws are checked here):**

- state record `BudgetState{budget_id, cap, unit, generation, committed,
  reserved, entries}` with `generation: Generation{incarnation, counter}` and
  `entries: List(EntryRow{cost_ref, entry})`;
- entry type `Entry = Open(estimate, expiry) | Expired(estimate) |
  Released(estimate) | Settled(estimate, actual, late)`; text fields use Cure
  `String` (`{:String, codepoints}` at runtime, as in core/port);
- `initial/4`, `sweep/2`, `sweep_step/2`, `reserve/7` (`state, now, cap,
  unit, cost_ref, estimate, expiry`), `settle/4` (`state, cost_ref,
  generation, actual`), `release/3`, `reset/2`, `status/1`, `remaining/1`,
  `critical_path/4`, `critical_path_waves/3`, plus the reducible decision
  functions they call (`reserve_with`, `admit_new_with`, `replay_with`,
  `settle_with`, `settle_entry`, `settle_repeat_with`, `release_with`,
  `release_entry`, `reset_with`, `derive`);
- result type `BudgetResult = Reserved(estimate, remaining) | Rejected(reason)
  | SettledRefund(refund, late) | SettledOverage(overage, late) | ReleasedOk |
  ResetOk(forfeited) | Status(remaining, open) | Swept(expired)` inside
  `Step{state, result}`.

**Elixir (`Elzoo.Budget` in `lib/elzoo/budget.ex`, `Elzoo.Budget.Owner` in
`lib/elzoo/budget/owner.ex`; test-grounded):**

- `step/2` (the Unit adapter): `readable?/1` (I0), input map/key decoding,
  dispatch to exactly one Cure function after the Cure `sweep`, and
  translation of the Cure result to the Outputs maps (adding `cost_ref` and
  `generation` from the request and next state);
- `initial/4` validation, the owner client functions, clock read, exit
  catching (`owner_unavailable`), `child_spec/1` and incarnation generation.
- Malformed `now_ms`, `expiry` (not a positive integer) and `generation` (not
  `{nonempty UTF-8 string, positive integer}`) are `rejected{invalid_input}`.
  `start_link/1` with missing or unknown options, or an invalid `budget_id`,
  returns `{:error, :invalid_input}`.

The Elixir layer makes no budget decision. A test checks that `step/2` calls
the Cure functions and that its results equal the Cure results for the same
inputs; there is no parallel Elixir reimplementation of the decision.

## Local decisions (preflight "ELZ-022: bounded report and child-run admission")

### D1. Identity, `cost_ref`, generation and reset

- `budget_id`, `unit` and `cost_ref` are nonempty UTF-8 strings. Equality is
  exact; no Unicode normalization. They are caller-supplied references. They
  do not prove uniqueness, authenticity or authority. A Run string inside a
  `budget_id` is a reference, not a Run capability.
- A generation is `{incarnation, counter}`. The owner generates
  `incarnation` on each start as the hex form of 16 bytes from
  `:crypto.strong_rand_bytes/1`. The Assembly cannot supply it. `counter`
  starts at 1. Two starts get different incarnations with overwhelming
  probability; this is a property of the upstream random source, not a proof.
- `reserved` returns the generation. `settle` and `release` must carry it.
  A different generation is `rejected{stale_generation}` with no change.
- `reset{generation}` is accepted only when `generation` equals the current
  one. It increments `counter`, sets `committed` and `reserved` to 0 and
  forgets all entries. The sealed cap and unit stay. A stale or repeated reset
  is `rejected{stale_generation}`.
- **Reset accounting limit.** Reset forfeits every open reservation. The
  `reset` result reports their number as `forfeited`. Their later settles are
  `rejected{stale_generation}`: the actual goes back to the caller in the
  rejection and is not recorded in any generation. Spend across generations
  can therefore exceed one cap. Reset does not show that a forfeited call was
  free.
- Within one generation a `cost_ref` names at most one reservation:
  - `reserve` with an open `cost_ref` and identical `estimate` and `expiry`
    is a replay. It never creates a second reservation. It returns the
    original `reserved` result (with the current `remaining`) only when the
    swept state passes the admission check: `committed <= cap` and
    `committed + reserved <= cap`, where `reserved` already includes this
    entry. Otherwise it returns `rejected{overage}` (when `committed > cap`)
    or `rejected{insufficient}` and leaves the state unchanged. The open entry
    stays open: it can still be settled, released or expire. So every
    `reserved` result, replay or new, leaves `committed + reserved <= cap`,
    and overage admits nothing. Both states are reachable: another entry's
    late settle can cause overage, or (cap 10) A reserves 6 and expires, B
    reserves 6, A late-settles 5, so `5 + 6 > 10` without overage;
  - with a different `estimate` or `expiry` it is `rejected{cost_ref_conflict}`;
  - for a settled, released or expired `cost_ref` it is
    `rejected{cost_ref_closed}`. A `cost_ref` is not reused in a generation.
- **Retry rule.** A retry must resend the same `cost_ref`, the same
  `estimate` and the same absolute `expiry` (not `now + ttl` computed again).
  A recomputed expiry gets `cost_ref_conflict`.
- **Rejected retry.** Any rejected retry (for example `cost_ref_conflict` or
  `insufficient`) means "do not start the call". The earlier attempt may have
  left an open reservation, so the caller should then send
  `release{cost_ref, generation}` (generation from `status` if unknown) to
  free the held estimate instead of waiting for expiry.

### D2. Units, sealed limits, overage, fail-closed admission

- Amounts (`cap`, `estimate`, `actual`) are positive integers in the unit's
  smallest denomination. Floats, zero, negatives and non-integers are
  `rejected{invalid_amount}`. On BEAM every float is finite, so "non-finite"
  is covered by rejecting all floats; JSON-decoded values must be integers.
- `{cap, unit}` is sealed at owner start (static Config) and by `initial/4`.
  An invalid cap or unit makes `start_link/1` return
  `{:error, :invalid_amount | :invalid_unit}`, so no owner exists. There is
  no default cap. Every `reserve` whose `cap` or `unit` differs from the seal
  is `rejected{changed_limits}`, from the first call on.
- A new reserve is admitted only when the state is readable (I0), it is not
  in overage, and `committed + reserved + estimate <= cap`. A replay is
  re-checked as in D1.
- Overage: `committed > cap`. In overage every reserve is
  `rejected{overage}` until reset. Observed overage is kept as recorded;
  `committed` is never capped.
- `remaining = max(cap - committed - reserved, 0)`. Only this reported
  figure is clamped. It is `0` in overage.
- Fail closed:
  - a state that fails I0 gives `rejected{unreadable}` for every input;
  - an owner that is not running, has exited, or does not answer within
    `GenServer.call/2`'s fixed 5000 ms default timeout gives
    `rejected{owner_unavailable}` at the client. After a timeout the reserve
    may still have been applied. The caller must not start the call. A retry
    under the D1 retry rule replays it; otherwise expiry frees it.

### D3. One serialized check-and-reserve transition, through unchanged Unit

- `Elzoo.Budget.step/2` is the arity-2 Unit transition:
  `step(state, {now_ms, input}) -> {:Transition, next, {:some, result}}`.
  It checks and records in the same pure function. No public function returns
  "would fit" without recording.
- Call path: Elixir `step/2` → Elixir `readable?/1` (I0) and input decoding →
  Cure `sweep` (with `now_ms`) → one Cure function: `reserve/7`, `settle/4`,
  `release/3`, `reset/2` or `status/1` (which calls `remaining/1` and
  `count_open/1`); for `sweep` the Elixir layer calls Cure `sweep_step/2`
  instead → Elixir result translation. The laws are stated over the Cure
  functions only (see "Cure and Elixir split"); the Elixir steps are
  test-grounded, and a test checks that `step/2` gives the same next state
  and the translated form of the same Cure result.
- The owner starts `Elzoo.Unit.start_link({Elzoo.Budget, :step, initial_state})`.
  Every client function reads the clock **in the caller process**, then calls
  `Elzoo.Unit.step(owner, {now_ms, input})`. `reserve`, `settle`, `release`,
  `reset`, `status` and `sweep` all go through `Elzoo.Unit.step/2`.
  `Elzoo.Unit.snapshot/1` is not part of the client API; it returns Unit's
  internal `{module, function, state}` tuple and is used only by tests.
- Concurrent callers are serialized by the Unit process mailbox. There is no
  read-then-increment window.
- The Piece does not touch Unit internals. It does not send Unit's private
  `{:step, _}` message, so the timeout is Unit's fixed `GenServer.call/2`
  default (5000 ms) and is not configurable here.

### D4. Expiry and `now`

- `expiry` and `now_ms` are absolute Unix milliseconds (positive integers).
  The pure transition reads no clock.
- Expiry is reached when `now_ms >= expiry`. A reserve with
  `expiry <= now_ms` is `rejected{invalid_expiry}`.
- Every `step/2` sweeps first: each open entry with `now_ms >= expiry` becomes
  `expired` and its estimate leaves `reserved`. This is the explicit release
  path for an abandoned call after a crash between call and settle. The owner
  starts no timer; an Assembly can call `sweep/1` from its own timer.
- The client reads `System.os_time(:millisecond)` (wall clock) in the caller
  before the call. So `now_ms` is **not** monotonic in mailbox order: a call
  with an earlier `now_ms` can arrive after one with a later `now_ms`. This is
  safe because (a) expiry is permanent: a smaller `now_ms` never reopens an
  entry; (b) `expiry <= now_ms` is checked against the caller's own `now_ms`;
  (c) admission depends on `committed`, `reserved` and `cap` only, and I0
  holds whichever order the sweeps run in. The only effect is that an entry
  can expire up to the spread of caller clocks later than a single clock
  would give.
- Clock-skew assumption: callers compute `expiry` in the same wall-clock
  domain. A backward clock step can lengthen a reservation; a forward step can
  expire it early. Skew between nodes is unspecified. No monotonic time
  crosses an owner restart.

### D5. Idempotent release and settle

Delivery of settle is at-least-once.

- `settle` on an open entry: `reserved -= estimate`, `committed += actual`.
  The entry becomes `settled{estimate, actual, late: false}`.
- **Late settle** on an expired or released entry: only `committed += actual`.
  `reserved` is unchanged, because the sweep or release already removed the
  estimate. The entry becomes `settled{estimate, actual, late: true}` and the
  result has `late: true` (`refund: 0`, see Outputs). The observed cost is
  never dropped or capped. A late settle can put the budget into overage.
- A repeat `settle` with the same `actual` changes nothing and returns the
  result derived from the stored `(estimate, actual, late)`, so it equals the
  first result on both paths. A different `actual` is
  `rejected{actual_conflict}`.
- `release` on an open entry: `reserved -= estimate`; the entry becomes
  `released{estimate}`. A repeat `release`, or `release` of an expired entry,
  replays `released` and changes nothing. `release` after `settle` is
  `rejected{already_settled}`.
- `settle` or `release` of an unknown `cost_ref` is
  `rejected{unknown_cost_ref}`.

### D6. Restart

The owner is volatile. `Elzoo.Budget.Owner.child_spec/1` is defined in the
owner itself with `restart: :temporary` (Unit's `use GenServer` default is
`:permanent`). Its child id is `{Elzoo.Budget.Owner, budget_id}`, so distinct
budgets can share one ordinary Supervisor; two owners with the same
`budget_id` under one Supervisor collide, as one identity has one owner.
Options without a valid `budget_id` get the id `Elzoo.Budget.Owner`, and
their start still fails with `{:error, :invalid_input}` (a Supervisor reports
`{:error, {:invalid_input, child}}`). A crash leaves the budget unavailable, so every client call is
`rejected{owner_unavailable}` (fail closed) until the Assembly starts a new
owner on purpose. A new owner has a new incarnation: committed and reserved
start at 0, and every pre-restart generation is `rejected{stale_generation}`.

The seal is per incarnation. It does not survive a restart: the Assembly
chooses `{cap, unit}` again at the next start. Restart cannot show that a
pre-restart external call was free, or that a lost settlement is safe. Total
spend across incarnations can exceed one cap. An Assembly that needs
continuity must not restart the owner, or must wait for durable storage
(ELZ-009), which is not composed here.

### D7. Zero actuals (Contract finding)

The task rejects non-positive amounts, and this Contract keeps that rule. A
call that cost nothing cannot settle with `actual: 0`. It is closed with
`release`, which has the same accounting effect (committed unchanged). No
listed caller (C2, C6, C7, C9) needs a zero settle. The ELZ-025 study says
unreported usage is "never zero", which supports rejection. If a caller later
needs a recorded zero actual, that is a new Contract and a new Piece ID, not a
relaxation here.

### D8. Critical-path time admission (pure, beside the owner)

- `critical_path(n, k, b, deadline)`: `n` tasks, at most `k` in parallel, each
  bounded by `b` time units. `required = ceil(n / k) * b`. Returns
  `{:admit, required}` when `required <= deadline`, else
  `{:reject, :deadline_insufficient, required}`. For uniform worst-case
  bounds, `required` is the least sufficient deadline.
- `critical_path_waves(waves, k, deadline)`: `waves` is a caller-supplied list
  of topological levels, each a nonempty list of positive bounds.
  `required = sum(ceil(|w| / k) * max(w))`. This is sufficient only under two
  assumptions: a barrier between waves (no item of wave `i+1` starts before
  wave `i` ends), and every item taking at most its stated bound (worst case).
  When every wave has at most `k` items this is the per-wave maximum sum. It is
  never claimed to be least.
- `n`, `k`, `b` and each bound are positive integers. `deadline` is a
  non-negative integer duration in the same time unit (the caller computes it;
  no clock read). Other inputs give `{:error, :invalid_input}`.
- Retries are excluded by statement: `b` is one attempt. A caller that retries
  must fold attempts into `n` or `b`. Turns are an admissible time unit. This
  adds no scheduler and no clock read.

## Evidence

### Proof (selected laws, pinned Cure 20824806 (balungpisah fork of a004c335))

Cure checks these laws over the named Cure functions and the Cure
`BudgetState` record (see "Cure and Elixir split"). They run through
`mix check`: the Cure compiler rejects the module if a law does not check,
and `test/elzoo/budget_test.exs` asserts a clean audit (no axioms, holes,
unresolved, unaudited, opaque or unproved-total entries). `s` is any Cure
state (in production, the swept state). Native `Int` operators are used
throughout. A guard such as `committed + (reserved + estimate) <= cap` is
passed to a `_with` function as a Boolean with its own `Equivalent`
evidence, so the post-state sum is the guard itself.

- **L1 admission cap** (`admission_cap`). For every `s` and every argument,
  when `reserve/7` returns `Reserved` (new entry or replay), its post-state
  has `committed + reserved <= cap`. Overage post-states satisfy the law by
  admitting nothing.
- **L2 overage admits nothing** (`overage_admits_nothing`). When
  `over(s)` (`committed > cap`) is `True`, `reserve/7` returns no `Reserved`
  result for any argument, replays included.
- **L3 settle idempotence, decision-split form** (`settle_idempotent`). When
  the lookup of `cost_ref` finds `Settled(estimate, a, late)`, the generation
  is fresh, and the equality decision `actual == a` is `True`, `settle/4`
  returns the identical state and the result `derive(estimate, a, late)`.
- **L4 release idempotence, decision-split form** (`release_idempotent`,
  `release_expired_replays`). When the lookup finds `Released(estimate)` or
  `Expired(estimate)` and the generation is fresh, `release/3` returns the
  identical state and `ReleasedOk`.
- **L5 rejection keeps state** (`reserve_rejection_keeps_state`,
  `settle_rejection_keeps_state`, `release_rejection_keeps_state`,
  `reset_rejection_keeps_state`). A `Rejected` result returns its input state
  unchanged. This holds for every Cure state; the production path only calls
  these on states that pass I0.
- **L6 derived settlement** (`settle_open_derived`, `settle_expired_derived`,
  `settle_released_derived`, `settle_first_derived`, `settle_first_stores`,
  `late_refund_is_zero`, `on_time_refund_is_difference`,
  `overage_is_difference`). A first settle on an `Open` entry stores
  `Settled(estimate, actual, false)` and frees the estimate; on an `Expired`
  or `Released` entry it stores `Settled(estimate, actual, true)` and leaves
  `reserved` unchanged. Its result equals `derive` of the stored triple; with
  L3 the repeat result is `derive` of the same stored triple. For
  `late: false` the refund is `estimate - actual`; for `late: true` it is
  `0`; an overage is `actual - estimate`.

**Proof scope and limits.** The laws cover the named Cure functions only.
They do not cover the full transition. These are test-grounded, not proved:

- **The L3/L4 link.** The step from a first settle or release to "the
  second call finds the closed entry" (lookup by `cost_ref` after `replace`,
  and value equality) is tested, not proved. Pinned Cure 20824806 (balungpisah fork of a004c335) cannot
  reduce native `==` on symbolic values. For
  `fn refl_int(k: Int) -> Equivalent(Bool, k == k, True()) = reflexive(True())`
  (and the same for `String`) it fails with
  `{:conversion_failure, …Equivalent(Bool, True, True)…, …Equivalent(Bool,
  {:napp, {:napp, {:nglobal, :"Std.Builtin#int_eq"}, {:nvar, 0}}, {:nvar, 0}},
  True)…}`. The full error is in
  https://github.com/balungpisah/elzoo/issues/36#issuecomment-6694393314.
- **Sweep idempotence at the same `now` (R2).** Tested over seeded traces,
  not proved. Pinned Cure does not refine the goal when a proof matches on a
  symbolic record projection: a prototype
  `bump_twice(row) : Equivalent(EntryRow, bump(bump(row)), bump(row))` by
  `match row.entry` fails with `conversion_failure` on
  `{:napp, {:nglobal, :"Exp8#bump"}, {:nvar, 0}}` against itself unreduced.
  The sweep guard `now >= expiry` is also a neutral native comparison.
- Preservation of I0 through `sweep`, `settle`, `release` and `reset` over
  the entry collection.
- The Elixir `step/2` dispatch and result translation, map/key decoding and
  the `readable?/1` (I0) fail-closed check.

L1 does not by itself cover the collection; I0 connects the scalar
`reserved` to the open entries, and its preservation is a test claim.

### Type/contract check

Pinned Cure type-checks the declarations. Nothing else is claimed under this
heading. `Elzoo.Budget.readable?/1` (I0) and the input decoder are Elixir
runtime checks; their evidence is the tests below.

### Negative controls

`test/elzoo/budget_test.exs` compiles nine mutated copies of the Cure module.
Each is rejected, and the test asserts the name of the proof that no longer
checks (the first failing proof in file order):

- a guard that forgets the estimate → `new_entry_cap` (L1);
- an overage branch that admits a new entry → `reserve_with_cap` (L1 catches
  it before L2);
- a repeat settle that drops `late` → `settle_repeat_same` (L3);
- a repeat release that frees again → `release_released_with` (L4);
- an `insufficient` rejection that records the entry → `new_entry_kept` (L5);
- a late settle stored as not late → `settle_entry_kept` (L5 catches it
  before L6).

Three more controls also adjust the L1/L5 helper proofs so that they still
check, which leaves the target law as the only one that can reject the copy:

- an overage branch routed to the cap-guarded replay path → `overage_with`
  (L2, `overage_admits_nothing`). This copy never admits on a readable
  overage state: `committed > cap` makes `fits_replay` false. Cure rejects it
  only because the L2 proof is over an abstract `overage` Boolean. So this
  control shows only that the L2 proof requires the overage branch to
  reject. It does not detect overage admission on a readable state. Any
  mutation that does admit under overage violates L1
  (`committed > cap` ⇒ `committed + reserved + estimate > cap`, since
  `reserved >= 0` and `estimate > 0`), and the L1 proof catches it (see the
  `reserve_with_cap` control above);
- a late settle on an `Expired` entry that frees the estimate again →
  `settle_expired_with` (L6, `settle_expired_derived`);
- a release of an `Expired` entry that frees the estimate again →
  `release_expired_with` (L4, `release_expired_replays`).

The other L6 laws (`settle_open_derived`, `settle_released_derived`,
`settle_first_derived`, `settle_first_stores` and the refund/overage
identities) and the L5 laws other than `new_entry_kept` have no
law-specific control.

### Tests (finite ExUnit scenarios)

- concurrent callers race for the last unit: exactly one `reserved`;
- `step/2` dispatch follows the D3 call path, calls the Cure functions, and
  its results equal the Cure results for the same inputs;
- replay under overage: B open, another entry's late settle makes
  `committed > cap`, retry of B gives `rejected{overage}`, state unchanged,
  B still open and later settles;
- replay without overage: cap 10, A reserves 6 and expires, B reserves 6,
  A late-settles 5, retry of B gives `rejected{insufficient}`, state
  unchanged, B still open;
- repeat settle returns the same result for both the normal and the late
  path;
- I0 is preserved over generated sequences of reserve/settle/release/reset/
  sweep; a state with a broken `reserved` scalar gives `rejected{unreadable}`;
- expiry at `now_ms == expiry`; abandoned reservation freed by sweep and by
  release;
- expire → another reserve uses the freed space → late settle → `committed`
  goes past `cap` (overage), `reserved` still equals the open sum, `refund: 0`
  → next reserve `rejected{overage}`;
- out-of-order `now_ms`: an earlier `now_ms` after a later one reopens nothing;
- overage on a normal settle: committed carries the observed figure,
  `remaining` is 0, the next reserve is `rejected{overage}`;
- `changed_limits` for cap and for unit on the first reserve; invalid
  cap/unit at start returns an error and no owner;
- stopped or crashed owner fails closed with `owner_unavailable`; a
  supervised crash leaves the `:temporary` child gone;
- two owners with distinct `budget_id`s start under one ordinary
  Supervisor with distinct child ids and both serve requests;
- restart: a new owner has a different incarnation; pre-restart generations
  are `stale_generation`; two starts give different incarnations;
- reset: needs the current generation, reports `forfeited`, a later settle of
  a forfeited `cost_ref` is `stale_generation`; repeated reset is rejected;
  `status` returns the generation before the first reserve;
- client timeout (owner suspended past the 5000 ms default) then retry with
  the same `cost_ref`, `estimate` and absolute `expiry` replays; with a
  recomputed expiry gets `cost_ref_conflict`; after another entry's overage
  the same retry is `rejected{insufficient}`, and `release` then frees the
  held estimate (R1; the Cure-level insufficient → release case is also in
  `budget_test.exs`);
- the I0 check rejects corrupted text such as `{:String, ["a"]}` (chardata)
  and nested code-point lists;
- a timed-out reset is resolved with `status`;
- repeat settle and repeat release through `step/2`, both late and non-late,
  return the identical state and result (the L3/L4 link); `actual_conflict`;
  `already_settled`; `unknown_cost_ref`;
- seeded random traces (60 traces × 80 steps over 5 `cost_ref`s and random
  amounts): I0 after every step, `committed + reserved <= cap` after every
  `reserved`, rejected steps equal the swept state, a repeated settle/release
  at the same `now` returns the identical state and result, and sweeping
  again at the same `now` changes nothing (R2);
- invalid inputs: zero, negative, float and non-integer amounts; malformed
  `now_ms`, `expiry` and `generation`; mixed string/atom keys; unknown and
  missing keys;
- critical-path formula, least sufficient deadline, wave formula, invalid
  inputs.

### Upstream contract

OTP 29.1.2 `GenServer.call` mailbox serialization, exit and timeout semantics
(default 5000 ms in `GenServer.call/2`); Supervisor `:temporary` restart
semantics; Elixir 1.20.4; `:crypto.strong_rand_bytes/1`; pinned Cure
compilation and reduction checking.

## Operational applicability (docs/operational-contracts.md)

- **Telemetry: planned.** The owner emits no events in this subset. Results
  are returned to the caller.
- **Config: supported (static, per owner start).** `budget_id`, `cap` and
  `unit` are set at start and sealed for that incarnation. The incarnation is
  generated, not configured. The call timeout is Unit's fixed 5000 ms default
  and is not configurable. No hot reconfiguration; a different cap or unit is
  `rejected{changed_limits}`. Tests cover start validation and the seal.
- **Control: supported (narrow).** `reset/2` and `sweep/1`. Holding the owner
  reference (pid or name) is the only authority; there is no principal check.
  The expected-generation guard on `reset` is the expected revision. A
  `reset` that times out (`owner_unavailable`) has an unknown outcome: a
  retry with the same generation gives `stale_generation` whether or not the
  first was applied. The caller resolves it with `status` and compares the
  generation counter. An unreadable owner rejects `reset`; only a new start
  replaces it. An OTP stop is not a business drain: open reservations are
  lost. Tests cover reset, sweep and the timed-out reset resolution.

## Needs

- Pieces: runtime/unit (unchanged).
- Providers: cure, elixir, otp.
- The Assembly supplies: estimate policy, unit choice, supervision placement,
  the owner reference's access control, and (for strict total bounds) a
  provider-enforced maximum charge at or below each estimate.

## Unspecified behavior and limits

- Admission bounds spending permission, not the total charge. A strict total
  needs a provider-enforced maximum charge at or below the estimate.
- Test-grounded, not proved: the L3/L4 link (lookup after `replace`, native
  `==`), sweep idempotence at the same `now`, I0 preservation over the entry
  collection, the Elixir `step/2` dispatch and result translation, map/key
  decoding, and the `readable?/1` (I0) fail-closed check (see Proof scope).
- Closed entries are kept for idempotence until reset, so state size grows
  with distinct `cost_ref`s per generation; each step is linear in that size.
- The seal, committed figure and entries are per incarnation. No durability
  beyond the owner process, no cross-node agreement, no cross-incarnation or
  cross-generation continuity. Reset and restart forfeit open reservations.
- Incarnation uniqueness relies on the upstream random source; it is not
  proved.
- No ordering between different callers beyond mailbox arrival order.
- Wall-clock skew effects on expiry are as stated in D4 and not bounded here.
- `critical_path_waves` assumes wave barriers and worst-case bounds and is not
  an optimal schedule.
- Integer amounts have no upper bound beyond BEAM integers.

## Reuse check

hammer (rate limiting) and a read-then-increment counter do not provide one
serialized check-and-reserve with per-reference settlement. Ash/AshMoney and
ex_money own currency arithmetic if a product needs money; this Piece carries
abstract units. The one-step check-and-reserve, derived refund/overage and
generation guard are Elzoo's policy.

## Reference

Shape observed in Raxol's spend gate and ledger reservations; see the pinned
rows in docs/research/orchestration-references.md. No code is copied.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md)
for copying selected pieces into a project. Copied source is Apache-2.0.
External packages retain their own licenses. Evidence describes the recorded
source bytes and selected laws and scenarios. After customization, rerun or
adapt its checks; the receipt is provenance, not a proof of your modified
application.
