# workflow/budget

> **Status: Contract draft for early independent review (ELZ-022, issue #36).**
> No implementation, `piece.json` or catalogue promotion exists yet. The
> catalogue row stays `deferred` until the reviewed implementation lands.

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
state = Elzoo.Budget.initial("run-42/tokens", "incarnation-7f3a")
{next, result} = Elzoo.Budget.step(state, input, now_ms)

{:ok, owner} = Elzoo.Budget.Owner.start_link(budget_id: "run-42/tokens")
Elzoo.Budget.Owner.reserve(owner, %{cap: 10_000, unit: "tokens",
  estimate: 800, cost_ref: "call-1", expiry: now_ms + 30_000})
Elzoo.Budget.Owner.settle(owner, %{cost_ref: "call-1", generation: gen, actual: 650})
Elzoo.Budget.Owner.release(owner, %{cost_ref: "call-1", generation: gen})
Elzoo.Budget.Owner.reset(owner, %{generation: gen})
Elzoo.Budget.Owner.remaining(owner)
Elzoo.Budget.critical_path(n, k, b, deadline)
Elzoo.Budget.critical_path_waves(waves, k, deadline)
```

### Inputs (exact string- or atom-keyed maps; unknown keys rejected)

| Input | Fields |
|---|---|
| `reserve` | `cap`, `unit`, `estimate`, `cost_ref`, `expiry` |
| `settle` | `cost_ref`, `generation`, `actual` |
| `release` | `cost_ref`, `generation` |
| `reset` | `generation` (the generation the Assembly expects to replace) |

The budget identity is fixed when the state or owner is created; inputs do not
carry it, so one owner cannot be addressed for another budget.

### Outputs

| Output | Meaning |
|---|---|
| `{:reserved, %{cost_ref, generation, estimate, remaining}}` | Admitted and recorded in one step. |
| `{:rejected, reason}` | No admission. State changes only by the expiry sweep (see below). |
| `{:settled, %{cost_ref, generation, refund, late}}` | `actual <= estimate`; `refund = estimate - actual` (`0` when equal). |
| `{:settled, %{cost_ref, generation, overage, late}}` | `actual > estimate`; `overage = actual - estimate`. |
| `{:released, %{cost_ref, generation}}` | Reservation freed without an actual. |
| `{:reset, %{generation}}` | New generation started (additive output; the issue names `reset` as an input only). |

`refund` and `overage` are derived from the stored `(estimate, actual)` pair at
settlement. They are never a separate write. `late: true` marks a settle that
arrived after the reservation expired or was released.

Rejection reasons, in check order: `:unreadable`, `:invalid_input`,
`:invalid_amount`, `:invalid_unit`, `:invalid_cost_ref`, `:invalid_expiry`,
`:changed_limits`, `:stale_generation`, `:cost_ref_conflict`,
`:cost_ref_closed`, `:unknown_cost_ref`, `:actual_conflict`,
`:already_settled`, `:overage`, `:insufficient`. The owner client adds
`:owner_unavailable`. Exact order per input is fixed in the implementation and
tested.

## Local decisions (preflight "ELZ-022: bounded report and child-run admission")

### D1. Identity, `cost_ref`, generation and reset

- `budget_id`, `unit` and `cost_ref` are nonempty UTF-8 strings. Equality is
  exact; no Unicode normalization. They are caller-supplied references. They
  do not prove uniqueness, authenticity or authority. A Run string inside a
  `budget_id` is a reference, not a Run capability.
- A generation is the pair `{incarnation, counter}`. `incarnation` is a
  nonempty UTF-8 string fixed at owner start. The owner generates it from 16
  bytes of `:crypto.strong_rand_bytes/1` (hex) unless the Assembly supplies one.
  `counter` starts at 1.
- `reserved` returns the generation. `settle` and `release` must carry it.
  A different generation is `rejected{stale_generation}` with no change. This
  stops a late settle from a replaced budget or an earlier owner incarnation
  from mutating the current one.
- `reset{generation}` is accepted only when `generation` equals the current
  one. It increments `counter`, sets `committed` and `reserved` to 0 and
  forgets all `cost_ref` entries. The sealed cap and unit stay. A different
  cap or unit needs a new `budget_id`. A stale reset is
  `rejected{stale_generation}`.
- Within one generation a `cost_ref` names at most one reservation. Retries
  keep the same `cost_ref`:
  - `reserve` with an open `cost_ref` and identical `estimate` and `expiry`
    replays the original `reserved` result without a second reservation;
  - with different values it is `rejected{cost_ref_conflict}`;
  - for a settled, released or expired `cost_ref` it is
    `rejected{cost_ref_closed}`. A `cost_ref` is not reused in a generation.

### D2. Units, sealed limits, overage, fail-closed admission

- Amounts (`cap`, `estimate`, `actual`) are positive integers in the unit's
  smallest denomination. Floats, zero, negatives and non-integers are
  `rejected{invalid_amount}`. On BEAM every float is finite, so "non-finite"
  is covered by rejecting all floats; JSON-decoded values must be integers.
- The first accepted `reserve` seals `{cap, unit}` for the `budget_id`. A later
  reserve naming a different cap or unit is `rejected{changed_limits}`. The
  seal survives `reset`.
- A reserve is admitted only when the state is readable, it is not in
  overage, and `committed + reserved + estimate <= cap`.
- Overage: `committed > cap`. In overage every reserve is
  `rejected{overage}` until reset. Observed overage is kept as recorded;
  `committed` is never capped.
- `remaining = max(cap - committed - reserved, 0)`. Only this reported
  figure is clamped. It is `0` in overage.
- Fail closed:
  - a state that fails shape validation (for example a corrupted snapshot or
    a hand-built term) gives `rejected{unreadable}` for every input and is not
    changed;
  - a missing or invalid cap on the first reserve is `rejected{invalid_amount}`;
    no default cap exists;
  - an owner that is not running, has exited or does not answer within the
    call timeout gives `rejected{owner_unavailable}` at the client. After a
    timeout the reserve may still have been applied. The caller must not
    start the call. A retry with the same `cost_ref` replays it; otherwise
    expiry frees it.

### D3. One serialized check-and-reserve transition

`step/3` checks and records in the same pure function. No public function
returns "would fit" without recording. The owner applies `step/3` inside one
`Elzoo.Unit` `GenServer.call`, so concurrent callers are serialized by the
process mailbox. There is no read-then-increment window.

### D4. Expiry and `now`

- `expiry` and `now` are absolute Unix milliseconds (positive integers). The
  pure transition receives `now`; it reads no clock.
- Expiry is reached when `now >= expiry`. A reserve with `expiry <= now` is
  `rejected{invalid_expiry}`.
- Every `step/3` first sweeps: each open reservation with `now >= expiry`
  becomes expired and its estimate leaves `reserved`. This is the explicit
  release path for an abandoned call after a crash between call and settle.
  `Elzoo.Budget.Owner.sweep/1` sends a sweep-only input; an Assembly can call
  it from its own timer. The owner starts no timer.
- The owner translates `System.os_time(:millisecond)` (wall clock) into `now`
  on each call. Clock-skew assumption: callers compute `expiry` in the same
  wall-clock domain. A backward clock step can lengthen a reservation; a
  forward step can expire it early. Skew between nodes is unspecified. No
  monotonic time crosses an owner restart.

### D5. Idempotent release and settle

Delivery of settle is at-least-once.

- `settle` on an open reservation commits `actual`: `reserved -= estimate`,
  `committed += actual`. The entry keeps `(estimate, actual)`.
- A repeat `settle` with the same `actual` replays the same result and changes
  nothing. A different `actual` is `rejected{actual_conflict}`.
- `settle` on an expired or released reservation still commits `actual`
  (`late: true`). The observed cost is never dropped or capped.
- `release` on an open reservation frees its estimate. A repeat `release`, or
  `release` of an expired reservation, replays `released` and changes nothing.
  `release` after `settle` is `rejected{already_settled}`.
- `settle` or `release` of an unknown `cost_ref` is
  `rejected{unknown_cost_ref}`.

### D6. Restart

The owner is volatile. Its default child spec uses `restart: :temporary`. A
crash leaves the budget unavailable, so every client call is
`rejected{owner_unavailable}` (fail closed) until the Assembly starts a new
owner on purpose. A new owner has a new incarnation: committed and reserved
start at 0, and every pre-restart `cost_ref` is `rejected{stale_generation}`.

Restart cannot show that a pre-restart external call was free, or that a lost
settlement is safe. Total spend across incarnations can exceed one cap. An
Assembly that needs continuity must not restart the owner, or must wait for
durable storage (ELZ-009), which is not composed here.

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
  `{:reject, :deadline_insufficient, required}`. `required` is the least
  sufficient deadline for uniform bounds.
- `critical_path_waves(waves, k, deadline)`: `waves` is a caller-supplied list
  of topological levels, each a nonempty list of positive bounds.
  `required = sum(ceil(|w| / k) * max(w))`. When every wave has at most `k`
  items this is the per-wave maximum sum. For larger waves it is a sufficient
  bound, not claimed to be least.
- `n`, `k`, `b` and each bound are positive integers. `deadline` is a
  non-negative integer duration in the same time unit (the caller computes it;
  no clock read). Other inputs give `{:error, :invalid_input}`.
- Retries are excluded by statement: `b` is one attempt. A caller that retries
  must fold attempts into `n` or `b`. Turns are an admissible time unit. This
  adds no scheduler and no clock read.

## Evidence plan

### Proof (selected laws, pinned Cure a004c335)

Cure checks these over the pure transition. The proof form is reduction plus
`Std.Proof.IntOrder` arithmetic lemmas, as other Elzoo Pieces use.

- **L1 admission cap.** For every readable state and reserve input, a
  `reserved` result leaves `committed + reserved <= cap`. Overage post-states
  are valid inputs: they satisfy the law by admitting nothing.
- **L2 overage admits nothing.** `committed > cap` gives `rejected` for every
  reserve.
- **L3 settle idempotence.** Applying the same settle twice gives the same
  state and result as once.
- **L4 release idempotence.** Same for release.
- **L5 rejection keeps state.** A `rejected` result leaves the swept state
  unchanged.
- **L6 derived settlement.** `refund` / `overage` equal the difference of the
  stored `(estimate, actual)` pair.

Proof scope: the per-entry decision table and the admission arithmetic step.
Lifting through the reservation collection and the expiry sweep is
test-grounded unless the pinned Cure checks it directly. If pinned Cure cannot
discharge L1 over the production `Int` used by the transition, I stop and
report the finding. I do not relabel a test as a proof.

### Type/contract check

Pinned Cure type-checks the production declarations. The Elixir projection
validates input maps and owner state before the transition.

### Tests (finite ExUnit scenarios)

- concurrent callers race for the last unit: exactly one `reserved`;
- expiry at `now == expiry` and abandoned reservation release;
- owner crash and restart with open reservations: unavailable, then a fresh
  incarnation rejects stale generations;
- overage: committed carries the observed figure, `remaining` is 0, the next
  reserve is `rejected{overage}`;
- `changed_limits` for cap and for unit;
- unreadable state and stopped owner fail closed;
- idempotent replay of reserve, settle and release; `actual_conflict`;
  late settle;
- rejection of zero, negative, float and non-integer amounts;
- critical-path formula, least sufficient deadline, invalid inputs;
- negative controls: a deliberately broken transition fails the law audit.

### Upstream contract

OTP 29.1.2 `GenServer.call` mailbox serialization and exit semantics; Elixir
1.20.4; `:crypto.strong_rand_bytes/1`; pinned Cure compilation and reduction
checking.

## Operational applicability (docs/operational-contracts.md)

- **Telemetry: planned.** The owner emits no events in this subset. Results
  are returned to the caller.
- **Config: supported (static, per-owner start).** `budget_id`, optional
  `incarnation` and call timeout are set at start. Cap and unit are sealed
  by the first reserve. No hot reconfiguration; changed limits are rejected.
- **Control: supported (narrow).** `reset/2` by the owning Assembly and
  `sweep/1`. An OTP stop is not a business drain: open reservations are lost.

## Needs

- Pieces: runtime/unit (unchanged).
- Providers: cure, elixir, otp.
- The Assembly supplies: estimate policy, unit choice, supervision placement,
  and (for strict total bounds) a provider-enforced maximum charge at or below
  each estimate.

## Unspecified behavior and limits

- Admission bounds spending permission, not the total charge. A strict total
  needs a provider-enforced maximum charge at or below the estimate.
- No durability beyond the owner process, no cross-node agreement, no
  cross-incarnation continuity.
- No ordering between different callers beyond mailbox arrival order.
- Wall-clock skew effects on expiry are as stated in D4 and not bounded here.
- `critical_path_waves` is not an optimal schedule for waves wider than `k`.
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

Copied source is Apache-2.0. External packages retain their own licenses.
