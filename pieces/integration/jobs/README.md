# integration/jobs

Oban 2.24.2 translation: a unique job per `(queue, job_key)`, `Elzoo.Jobs.enqueue/2` that reports only persisted job ids, a per-queue runner registration with `Elzoo.Jobs.Worker` (traps exits, maps an escaping exit to a snooze, refuses unknown args versions), and `Elzoo.Jobs.Relay` over one ELZ-009 outbox stream.

## Copy and providers

Select `integration/jobs` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`, `state/outbox`.
Providers: `oban`, `ecto_sql`, `postgrex`, `elixir`, `otp`; exact versions, source lists
and claim-level grounding are in [piece.json](piece.json). The consumer owns the
Oban instance, queues, Lifeline settings and runs `Oban.Migration` itself.

## Boundary and limits

- `enqueue/2` returns `{:ok, id}` only for a persisted job (new or `conflict?: true` with an id); `conflict?: true, id: nil` (unique advisory lock held by an uncommitted inserter) is `{:retry, :unique_lock_held}`.
- The Relay acks an item only when `handle` returns `:done`; `{:skip, reason}` (or a raise) leaves it pending and the pass continues with the next item of the page. `Elzoo.Outbox.pending/3` returns the oldest `limit` items without an offset, so a full page of permanently skipped items blocks later items (stated limit). Delivery is at-least-once.
- Oban uniqueness is an advisory lock plus query, not a constraint; Lifeline rescue is time-based and can re-run live jobs (upstream).
- No general Oban wrapper, cron, Pro feature or cross-stream outbox discovery.

## Evidence and operations

- `test/elzoo/jobs_test.exs`: unique changesets, the persisted-id rule under a held lock, worker dispatch/exit trapping/version refusal, a real Oban execution, relay ack/skip/in-page continuation, the full-page limit and option validation.

- telemetry: **inherited** (oban) — Oban job and plugin events; Elzoo adds none.
- config: **supported** — Construction-time Relay store, stream, handle, limit and interval; per-insert queue, key and provider budget; no hot change.
- control: **inherited** (oban) — Oban queue pause/resume and cancellation; the Relay has OTP start/stop only.

See [ELZ-010](../../../docs/work/ELZ-010.md). No exactly-once delivery is claimed.
