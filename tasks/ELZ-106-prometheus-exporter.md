# ELZ-106 — Prometheus exporter

- Phase: V1 Pieces (RC-03)
- Catalogue IDs: `integration/observability`
- Dependencies: ELZ-033, ELZ-004, ELZ-052 and ELZ-107.

Admit one opt-in Prometheus text-format pull exporter for counts and total durations of the accepted telemetry family. Use prometheus 6.1.3 public counters/formatter directly; no reporter process, event queue, HTTP client or custom wire protocol.

## Caller, dependencies and reuse

Concrete caller: a consumer application's operator observes job/effect event counts and accumulated terminal duration for the accepted durable-job/http-job telemetry family. The application mounts the returned standard text body on its own scrape endpoint. This Piece ships no server or dashboard and requires no existing Adapter adoption or changes.

Retain RC-03 historical planning dependencies ELZ-033 and ELZ-004; add accepted ELZ-052 for runtime/telemetry and the separately admitted prometheus provider prerequisite (reserved ELZ-107). ELZ-033/#55, ELZ-004/#4 and ELZ-052/#108 are closed with accepted merges bc14b246c49f7bb31574321250d9583b8f91c5e5, 81d7d21d8c0a86aae8d47ce9b0e0389b15ca865d and 7d3b9161fee5eb8b3745b3e7d4946b23bd1f4258. Source dependency: runtime/telemetry. Direct providers: prometheus, telemetry, Elixir and OTP; register required ddskerl closure. Preserve platform/Cure/current provider pins.

Maintained public API selection: prometheus 6.1.3 (MIT), sole required ddskerl 0.4.3 (Apache-2.0). Use prometheus\_counter.new/1, inc/4, values/2, value/3, deregister/2; prometheus\_registry.collectors/1 and deregister\_collector/2; prometheus\_text\_format.format/1 and content\_type/0. Use telemetry 1.4.2 attach\_many/4, detach/1, list\_handlers/1. No private API or copied provider code. Current official documentation and exact package source/licenses: [prometheus archive](https://repo.hex.pm/tarballs/prometheus-6.1.3.tar), [counter documentation](https://hexdocs.pm/prometheus/6.1.3/prometheus_counter.html), [registry documentation](https://hexdocs.pm/prometheus/6.1.3/prometheus_registry.html), [formatter documentation](https://hexdocs.pm/prometheus/6.1.3/prometheus_text_format.html), [ddskerl archive](https://repo.hex.pm/tarballs/ddskerl-0.4.3.tar), and [telemetry documentation](https://hexdocs.pm/telemetry/1.4.2/telemetry.html). An isolated OTP API probe is not repository/provider integration acceptance.

The current owner authorization advances one local-tested exporter now. This task chooses standard Prometheus pull instead of the earlier proposed OTel package set; it does not change the historical TimescaleDB deployment/sink decision. OTel remains separate. The compared OTel and telemetry-metrics reporter facilities require broader queue, logging or lifecycle policy than these counters need; source-predicted risks are not claimed reproduced bugs.

## Closed v1 metric projection

Two fixed counters in an exclusively reserved registry `:elzoo_observability_v1`:

- `elzoo_v1_events_total`, labels exactly adapter, operation, phase.
- `elzoo_v1_duration_microseconds_total`, the same labels, terminal phases only.

Fixed constant HELP text and standard Prometheus `text/plain; version=0.0.4` body. Version is in names, never from input. Five valid adapter/operation/family pairs: assembly/durable-job/perform/job; assembly/durable-job/relay/job; assembly/http-job/perform/job; assembly/http-job/send/effect; assembly/http-job/poll/effect. Phases are start, stop, exception. This gives at most 15 event series and 10 duration series, 25 total; no Cartesian expansion, extra metrics or user labels. Absent series need not be emitted as zero.

One of the six fixed three-atom event names, with matching family/phase and a valid pair, increments event count by one. For stop/exception, an existing duration integer in 0..9,223,372,036,854,775,807 adds that many microseconds to the duration counter. Missing, negative, noninteger or larger duration contributes nothing, but does not suppress the valid event count. Start events never contribute duration. No averaging, conversion to seconds, histogram or claim that missing duration equals zero.

Read only event name, adapter, operation and applicable duration. Drop outcome, reason, tenant, queue, request\_ref, attempt, queue\_wait, payload\_bytes, exception, URL, credentials, payload and all other input fields before provider calls. Invalid event/pair contributes nothing. No string-to-atom conversion or dynamic labels. The immutable v1 table does not broaden if the accepted telemetry schema later grows.

## Exact callable and manual lifecycle boundary

`Elzoo.Observability.initialize/0` declares the two metrics once per prometheus application lifetime, returning `:ok` or `{:error, :conflict | :unsafe_config | :unavailable}`. The registry must initially have no collectors/metrics; use new/1, never declare/1's silent collision adoption. Refuse a preexisting collector or metric without deleting/adopting it. If the first declaration succeeds and the second fails, remove that first metric and the collector introduced by this invocation using public deregister\_collector/2; initialization remains unsuccessful. Collector cleanup is registry-wide and is allowed only after this invocation verified an empty registry and began declaration, under exclusive serialized ownership. Never apply it to an entry-time conflict. If provider loss prevents cleanup, return unavailable without claiming rollback succeeded. The consumer serializes initialization and owns exclusive registry access; concurrent external metric/config mutation violates the Need.

`attach/0` attaches one fixed handler ID `{:elzoo_observability, 1}` to the six accepted events, after safe configuration and initialized registry checks. It returns `:ok` or `{:error, :already_attached | :unsafe_config | :unavailable}`. Duplicate attachment must not reset/delete counters. Callback configuration is fixed and credential-free, with no raw event, caller-supplied function, PID or ETS tid.

`detach/0` removes only that fixed handler, returning `:ok` or `{:error, :not_attached | :unavailable}`. It leaves metrics intact. Already-selected callbacks may finish after detach; this is not a linearizable cutoff or a drain. Reattach preserves totals. The requesting process's death changes neither registration nor provider-owned metrics. Administrative callers must serialize intended attach/detach sequences: delayed detach targets the current singleton, not an owner token. Cleanup means explicit detach, not automatic owner-death cleanup.

`scrape/0` returns `{:ok, %{content_type: binary, body: binary}}` using the maintained formatter, or `{:error, :unsafe_config | :unavailable}`. There is no arbitrary registry argument, label mapper or endpoint option. Scrape may run concurrently with event updates but is not an atomic snapshot across stripes/families.

The consumer starts the provider application before initialize. Provider stop/restart destroys metrics; registrations can remain, updates safely fail and are lost until explicit reinitialization restores the two definitions. Counter state and handler registration are distinct lifetimes. No automatic provider recovery, reset API, owner-generation process or background service is added.

## Provider configuration is an explicit Need

The dedicated registry must contain only these two fixed counter definitions and the counter collector. Before both attach and scrape, require exactly the counter collector and probe each counter with public value/3 using three fixed valid label values. An undefined result is valid for an initialized but unpopulated series; absent definitions or exceptions fail unavailable. These probes check existence/arity only, not HELP, label-name equality or provenance. Successful initialization and exclusive host ownership establish definition identity; values/2 cannot establish it because both missing and unpopulated metrics return an empty list. The provider's application-wide global\_labels must be absent or exactly empty and immutable. Reject nonempty globals before initialize, attach and scrape; reject unexpected collectors before attach/scrape. Use declared install configuration `config :prometheus, global_labels: []` so copied consumers see the requirement.

The host must not mutate global labels, metric definitions or collectors concurrently with validation/formatting; there is no atomic library exclusion setting, same-VM security isolation or guarantee against hostile code. No default registry, VM metrics, constant labels, user-defined collectors or hidden resource attributes enter this boundary. A consumer needing nonempty global labels in this same provider application cannot adopt this slice without separately reviewed scope.

## Failure, loss, bounds and caller effects

The handler contains every catchable raise/throw/exit from projection/provider calls without logging/interpolating raw data, exceptions or stacktraces. Upstream telemetry would otherwise publish handler config/reason/stacktrace on handler failure; the new handler must not leak through that route. Fixed public errors never include provider terms. Untrappable emitter kill, VM termination, unrelated observers and arbitrary host logging remain outside this guarantee.

There is no event queue, mailbox notification, Task, network wait, batching, sampling, retry or spool. Valid observations synchronously update counters. Invalid projection/duration and provider failures lose the corresponding update without replay. Count and duration updates are not transactional: count may succeed while duration fails. There is no guaranteed independent loss counter; an unavailable provider cannot reliably count its own losses.

Slow or absent scrapers create no exporter backlog. Callers still pay projection/ETS CPU and contention; concurrent scrapes may add contention. No hard latency/deadline isolation is promised. No network timeout is needed in the handler; the consumer owns HTTP-serving timeouts. Fixed series and the pinned provider's 16 stripes bound row cardinality, not whole-VM memory or numeric magnitude: counters and formatted decimal output grow with use. Restart loses observations; scrape success is neither durable receipt nor audit/accounting evidence.

## Operations, scope and acceptance

Telemetry supported: these two optional observation families through scrape, with no audit/billing claim. Config supported: immutable provider global-label exclusion and fixed registry, construction/application lifetime only; no hot configuration. Control supported: one-time initialization and explicit manual attach/detach, with the lifetimes and non-barrier semantics above.

Owned paths: pieces/integration/observability/\*\*, task/work record and coordinator-serialized own registry/planning rows/generated views. Provider pins/config prerequisite is separate and accepted first. Preserve runtime/telemetry, all existing Adapter Contracts and excluded durable-job, Store/Writer, Relay, outbox, EffectIntent paths. No paid calls, ELZ-041/044, new Assembly, listener, dashboard or observability platform.

Acceptance must cover exact schema/units and independently calculated counts/sums; all 25 allowed series and invalid cross-products; input duration bounds and absent/invalid distinctions; dropped secret markers in every ignored field at text/log/failure-event boundaries; direct telemetry calls bypassing emitter validation; collisions and unsafe global labels/collectors; partial initialization cleanup without deleting foreign state; duplicate attach, selected callback crossing detach, reattach, attacher death and administrative ordering; provider reset and explicit recovery; partial update failures; concurrent updates/scrapes with exact quiescent totals. Use barriers rather than sleep-only race assertions.

Exercise actual Prometheus text output through a local loopback fixture and local client, including slow/absent scraper controls and no handler network calls. The fixture is not a shipped service. Test source copy in a clean consumer with only declared providers/Piece closure and no root Application. Run pinned setup, Piece tests, affected gate, required full dependency checks, independent exact-SHA review, automated finding dispositions, coordinated queue, exact-head hosted evidence, main merge acceptance and cleanup. Finite runtime/boundary tests and named upstream/host contracts ground the slice; no universal proof of secrecy, timing, delivery or concurrency.
