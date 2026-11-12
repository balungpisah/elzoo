# integration/observability

Opt-in Prometheus text-format pull metrics for the fixed accepted Elzoo
job/effect telemetry family. The operator mounts `scrape/0` on an application
endpoint; this Piece ships no server, transport client, dashboard or platform.
No Adapter must adopt it. It is not tracing, audit, billing or accounting.
The historical TimescaleDB host/sink decision is unchanged; OTel is separate.

## API and host Needs

Start `:prometheus` before `Elzoo.Observability.initialize/0`. Exclusively reserve
`:elzoo_observability_v1`, serialize initialization and administrative attach/
detach calls, and keep application-wide `global_labels` absent or exactly `[]`
and immutable. Install `config :prometheus, global_labels: []`. A host needing
nonempty global labels in that provider application cannot adopt this slice.

- `initialize/0`: `:ok` or `{:error, :conflict | :unsafe_config | :unavailable}`.
  Declare both metrics once per provider lifetime with public `new/1`, not silent
  adoption through `declare/1`. Refuse entry-time foreign collectors/definitions
  without deleting them. After an empty-entry check, partial declaration failure
  deregisters our first metric and the introduced counter collector; provider
  loss may prevent cleanup, in which case unavailable claims no rollback.
- `attach/0`: `:ok` or `{:error, :already_attached | :unsafe_config | :unavailable}`.
  Fixed ID `{:elzoo_observability, 1}`, credential-free constant config `:v1`.
  Duplicate attachment does not reset counters.
- `detach/0`: `:ok` or `{:error, :not_attached | :unavailable}`. Removes only that
  registration, not metrics. Selected callbacks may finish afterward: not a
  drain or linearizable cutoff. Reattach preserves totals. Attacher death has
  no effect. A delayed detach targets the current singleton, not an owner token.
- `scrape/0`: `{:ok, %{content_type: binary, body: binary}}` or
  `{:error, :unsafe_config | :unavailable}`. Maintained standard formatter,
  `text/plain; version=0.0.4`. No arbitrary registry or label mapper. Concurrent
  scrapes/updates do not form an atomic snapshot across stripes or families.

Before attach/scrape, require exactly the counter collector and probe both
definitions with public `value/3` at three fixed valid label values. Undefined
means initialized but unpopulated; missing/incorrect arity is unavailable.
These probes do not validate HELP, label names or provenance. Successful
initialization plus exclusive host ownership establish identity. `values/2`
alone cannot distinguish an absent definition from an unpopulated definition.
External concurrent registry/config mutation violates the Need; no same-VM
security boundary or atomic exclusion from hostile code is promised.

Provider stop/restart destroys metrics but can leave the telemetry handler
registered. Updates safely fail and are lost until explicit initialization.
No automatic recovery, reset API, owner process or generation machinery.

## Closed v1 projection

| Counter | Labels | Values |
| --- | --- | --- |
| `elzoo_v1_events_total` | adapter, operation, phase | one per accepted event |
| `elzoo_v1_duration_microseconds_total` | adapter, operation, phase | sum of existing valid terminal microseconds |

Fixed HELP and names encode v1; no input-derived version, units conversion,
histograms, averages, exemplars, extra metrics or user/global labels.

| Adapter | Operation | Family |
| --- | --- | --- |
| assembly/durable-job | perform | job |
| assembly/durable-job | relay | job |
| assembly/http-job | perform | job |
| assembly/http-job | send | effect |
| assembly/http-job | poll | effect |

Only the six fixed `[:elzoo, family, phase]` events with family job/effect and
phase start/stop/exception, matching one row above, count. At most 15 event
series and 10 terminal duration series: 25, not a Cartesian expansion.
Absent series need not be emitted as zero. For stop/exception, an existing
duration integer in 0..9,223,372,036,854,775,807 adds that many microseconds.
Missing/invalid duration adds nothing but does not suppress the event. Start
never contributes duration. Missing is not asserted equal to zero.

Read only event name, adapter, operation and applicable duration. Drop outcome,
reason, tenant, queue, request_ref, attempt, queue_wait, payload_bytes, exception,
URL, credentials, payload and everything else before provider calls. No dynamic
atoms or labels. The frozen table does not grow with runtime/telemetry's schema.
Direct callers bypassing the emitter validator receive the same projection.
Catchable raises/throws/exits are swallowed inside the handler, without raw
logging or telemetry's handler-failure config/reason/stacktrace path. Untrappable
kill, VM termination, unrelated observers and host logging remain outside scope.

## Loss, caller cost and bounds

Synchronous projection and ETS counter updates only: no queue/mailbox, Task,
network call, timeout, batching, sampling, retry or spool. No scraper or a slow
scraper produces no exporter backlog. Callers still pay CPU and ETS contention,
including concurrent scrape contention; no hard deadline/latency isolation.
The application owns HTTP-serving timeouts. Invalid projection/duration and
provider failures lose the corresponding update without replay. Count and
duration are not transactional; count may succeed while duration fails. There
is no reliable independent loss counter when the provider itself is absent.

Fixed series and prometheus's 16 stripes bound row cardinality, not whole-VM
memory or numeric magnitude. Counters/decimal output grow. Restart loses
observations. Scrape success is not a durable receipt.

## Providers, source copying and grounding

Source dependency: runtime/telemetry. prometheus 6.1.3 (MIT), ddskerl 0.4.3
(Apache-2.0 required closure), telemetry 1.4.2 (Apache-2.0), Elixir 1.20.4 and
OTP 29.1.2. No provider code copied or modified. Public APIs: counter new/inc/
value/deregister, registry collectors/deregister_collector, text format/content
type and telemetry attach_many/detach/list_handlers. Exact pins remain the
separate ELZ-107 prerequisite; local stacked work is not its acceptance.

Tests ground named finite runtime/process/wire/failure scenarios and copied
source without the root Application. The copied fixture is
`examples/observability_copied_consumer.exs`, distinct from other Pieces' examples
when copying the whole catalogue. Upstream ETS/telemetry ordering and host
Needs are named contracts, not Cure proofs or universal secrecy/delivery proofs.
Operational applicability: telemetry supported through the two observation
counters; config supported only at immutable provider/application lifetime;
control supported through explicit initialization and manual attach/detach.
