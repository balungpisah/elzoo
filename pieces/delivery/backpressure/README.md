# delivery/backpressure

Pure Cure admission policy with an Elixir validating boundary. Apache-2.0.
Construction: `Elzoo.Backpressure.new(capacity)` returns `{:ok, state}` for a
positive integer; otherwise `{:error, :invalid_capacity}`.
`admit(state)` returns `{:ok, next, :admitted | :saturated}`.
`release(state)` returns `{:ok, next}` or `{:error, :release_underflow}`.
Malformed foreign states return `{:error, :invalid_state}`.

Capacity counts in-flight operations, with **queue length zero**. At saturation
nothing is admitted, evicted or queued and state is unchanged. There is no
shedding or reconstructable-storage claim. The caller retains state and
releases once per operation. A process mailbox is not bounded by this policy.

Cure `CapacityState` erases to `{:CapacityState, capacity, in_flight}`.
`classify_admit` selects Admitted/Saturated/CapacityInvalid;
`admit_step` consumes that decision. `classify_release` selects
Released/ReleaseUnderflow; `release_step` consumes it. Direct erased callers
must supply valid types/states.

Grounding: three selected helper laws (`saturated_keeps_state`,
`invalid_keeps_state`, `underflow_keeps_state`), not proofs of classification
or the full invariant. Seeded ExUnit traces exercise the actual classify +
step boundary against an independent count model. Cure audit and production
saturation mutation run in mix check. Config is construction-time; no hot
updates, telemetry, lifecycle, storage or distributed credit supplied.
