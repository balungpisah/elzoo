# Dependency register

This register separates an upstream contract from an Elzoo contract. A
dependency is **adopted** only when its exact version is pinned and an Elzoo
runtime check exercises the API and the failure path that our boundary relies
on. A HexDocs page, a GitHub star, or a successful compile in an unrelated
spike is not adoption evidence.

The research links below were checked on 2026-11-05. Versions shown for
candidates are the versions displayed by their documentation pages at that
time; they are observations, not lockfile choices.

## Pinning and boundary policy

1. `mix.lock` is the source of truth for Hex dependencies. `mix setup` must
   resolve from a clean checkout without a local Zoo or Cure checkout.
2. Cure is pinned by commit, not a moving branch or an ambiguous tag. The
   repository has both a branch and a tag named `v0.35.0`; the exact SHA avoids
   selecting the wrong tree.
3. A dependency's public API and documented guarantees are upstream
   grounding (`U`). Elzoo still owns validation, error translation,
   correlation, redaction and the behavior of its unit when the dependency
   fails.
4. Effectful or untyped third-party calls stay in an adapter. Pure upstream
   functions such as `Enum`, `Stream` or a hash routine may be called directly
   when their input/output contract is sufficient; the dependency remains
   upstream-grounded and any Cure proof stops at that call. Do not pretend to
   prove the external implementation.
5. A candidate may be compared in an isolated task. Do not add two libraries
   for one boundary “just in case”; choose one after the executable check or
   defer the boundary.

## Bootstrap dependencies

| Dependency | Exact baseline | Status | What was actually exercised | Boundary/limit |
| --- | --- | --- | --- | --- |
| [Cure](https://github.com/cure-lang/cure-lang/tree/a004c335cc4e9f2203ba6f51fc31e8540b66378d) | commit `a004c335cc4e9f2203ba6f51fc31e8540b66378d` (release line v0.35.0) | adopted for bootstrap | Elzoo compiles the selected source modules through `compile_file/2`; runtime tests check selected laws, typed negatives, independent imports and model traces | Cure compiler/kernel/runtime remain trusted infrastructure; the spike is not an independent soundness audit |
| [Elixir](https://github.com/elixir-lang/elixir) | 1.20.4 | adopted platform baseline | Elzoo runs the GenServer shell, Supervisor and ExUnit on the matching toolchain | Elzoo owns only its shell callbacks and contracts |
| [Erlang/OTP](https://www.erlang.org/doc/system/design_principles.html) | OTP 29.1.2 (BEAM reports OTP 29 in the spike) | adopted platform baseline for ordinary supervision | Elzoo tests `GenServer`, `Supervisor`, process messaging and restart behavior | OTP process isolation is not an OS/security sandbox; no distributed/crash theorem |
| [Jason](https://hexdocs.pm/jason/Jason.html) / [source](https://github.com/michalmuskala/jason) | 1.4.5 in `mix.lock` | adopted adapter dependency | Real `Jason.encode!` calls round-tripped strings, quotes, Unicode and empty input; invalid input and a failing stand-in became explicit errors | Jason encoding/decoding is upstream-owned; Cure `@extern` signature is a foreign assumption |

Elzoo now adopts Req 0.7.5 for a narrow direct HTTP client recipe. Finch is its
transitive implementation, not a separate Elzoo abstraction. Ecto, Postgrex,
Oban and OpenTelemetry remain candidates. Telemetry is transitive, with no
adopted business-event contract. Cure's transitive dependency graph remains
in `mix.lock`; “not adopted” means Elzoo does not rely on that package's API
or behavior as a contract.

## Source distribution and authoritative pins

`registry/providers.json` records direct provider versions/licenses and is
checked against mix.lock and .tool-versions. Each ready bundle records its
own usage/evidence in piece.json; [LEDGER.md](../LEDGER.md) is generated from
those records. Libraries are installed by Mix/OTP, never copied as Elzoo-owned
implementations. Elzoo-owned copied sources use Apache-2.0.

Req was chosen for its ordinary request API, explicit response/error values
and configurable retry/redirect/timeout behavior. Its recipe tests a real
loopback HTTP 200 and 503, plus a deterministic injected transport timeout.
TLS, network failure modes, authentication and durable job/effect policy are
not proved by those tests. See [the recipe](../pieces/integration/http/README.md).

## OTP API reuse candidates

OTP is part of the pinned platform, but each behavior still needs an Elzoo
usage check when it enters a contract. “Spike-tested” means the prior Cure
spike exercised the exact behavior; “planned reuse” means no adoption claim is
made yet.

| API | Authoritative API | Status | Intended Elzoo use |
| --- | --- | --- | --- |
| `GenServer` | [Elixir GenServer docs](https://hexdocs.pm/elixir/1.20.4/GenServer.html) | bootstrap-tested reuse | Unit shell serialises a unit's state transition and replies |
| `Supervisor` | [Elixir Supervisor docs](https://hexdocs.pm/elixir/1.20.4/Supervisor.html) | bootstrap-tested reuse | Unit restart policy and lifecycle boundary |
| `Application` | [Elixir Application docs](https://hexdocs.pm/elixir/1.20.4/Application.html) | bootstrap-tested reuse | Start one host supervision tree from the Mix app |
| `DynamicSupervisor` | [Elixir DynamicSupervisor docs](https://hexdocs.pm/elixir/1.20.4/DynamicSupervisor.html) | planned reuse | Bounded dynamic units only when an assembly needs them |
| `Registry` | [Elixir Registry docs](https://hexdocs.pm/elixir/1.20.4/Registry.html) | recipe-tested reuse | Local name lookup; never the durable message identity |
| `:pg` | [Erlang process groups docs](https://www.erlang.org/doc/apps/kernel/pg.html) | planned reuse | Local broadcast/group membership only; subscriber loss and replay are not implied |
| `Task` | [Elixir Task docs](https://hexdocs.pm/elixir/1.20.4/Task.html) | planned reuse | Bounded adapter work with an explicit caller/result |
| `gen_statem` | [Erlang state machine docs](https://www.erlang.org/doc/system/statem.html) | planned reuse | Circuit-breaker/workflow lifecycle shell when a pure state transition is not enough |
| `:timer`/`Process.send_after` | [Elixir Process docs](https://hexdocs.pm/elixir/1.20.4/Process.html) | recipe-tested reuse | Clock adapter for time messages and deadlines |
| `:disk_log` | [Erlang disk_log docs](https://www.erlang.org/doc/apps/kernel/disk_log.html) | evaluate for P2, not adopted | Candidate append/rotate/recover primitive for `state/event-log`; test corruption, truncation, fsync/repair and crash ordering before adapting |
| `Enum` / `Stream` | [Elixir Enum docs](https://hexdocs.pm/elixir/1.20.4/Enum.html) and [Stream docs](https://hexdocs.pm/elixir/1.20.4/Stream.html) | recipe-tested reuse | Ordinary finite/lazy transformations should use the platform; own only a missing domain/state policy rather than rebuilding Rx's long tail |
| `:crypto` | [Erlang crypto docs](https://www.erlang.org/doc/apps/crypto/crypto.html) | recipe-tested reuse | SHA-256 known-vector recipe only; other hashes, HMAC, key/secrets and TLS contracts are not adopted by this recipe |

## External library candidates

These are real maintained libraries with authoritative API documentation. The
API names below were visible in the linked docs; documentation alone is not adoption. The Req row now has the scoped executable
evidence described above; other rows retain their stated candidate status.

| Candidate | Observed API/docs | Why it may fit | Contract risk and adoption test |
| --- | --- | --- | --- |
| [Req](https://hexdocs.pm/req/Req.html) · [source](https://github.com/wojtekmach/req) | docs page showed `Req.request/2` and `Req.request!/2` (v0.7.5 page) | High-level HTTP client with request/response conveniences for the P3 edge assembly | Adopted narrow client recipe at 0.7.5; local 200/503 and injected transport failure are checked. Effect/job policy remains ELZ-011 |
| [Finch](https://hexdocs.pm/finch/Finch.html) · [source](https://github.com/sneako/finch) | docs page showed `Finch.start_link/1`, `request/2-3`, `async_request/2-3` (v0.24.0 page) | Supervised, pool-oriented HTTP client when explicit connection ownership/backpressure matters | Transitive Req dependency at 0.24.0; its direct API is not adopted as a second abstraction. Application-specific pool policy remains future work |
| [Ecto](https://hexdocs.pm/ecto/Ecto.Repo.html) · [source](https://github.com/elixir-ecto/ecto) | docs page showed `Ecto.Repo.start_link/1`, `insert/2`, `transaction/2` (v3.14.3 page) | Transaction/query boundary for a durable unit and an outbox | Need migration, isolation, rollback and connection-loss tests; Ecto does not make an Elzoo hop durable automatically; no adoption yet |
| [Postgrex](https://hexdocs.pm/postgrex/Postgrex.html) · [source](https://github.com/elixir-ecto/postgrex) | docs page showed `Postgrex.start_link/1`, `transaction/2-3` (v0.22.4 page) | Direct PostgreSQL adapter if the first durable piece needs less ORM surface | Must specify SQL/schema ownership and transaction scope; choose direct Postgrex or Ecto, not both by default; no adoption yet |
| [Oban](https://hexdocs.pm/oban/Oban.html) · [source](https://github.com/oban-bg/oban) | docs page showed `Oban.start_link/1`, `insert/1-3`, `insert_all/1-3` (v2.24.2 page) | PostgreSQL-backed jobs and retry/scheduling for `assembly/durable-job` | Oban's job retry is not the Elzoo outbox; test uniqueness, retry, pruning, queue backpressure, transaction handoff and shutdown; no adoption yet |
| [Telemetry](https://hexdocs.pm/telemetry) · [source](https://github.com/beam-telemetry/telemetry) | official HexDocs package page | Lightweight event interface for adapter/unit metrics | Elzoo owns field names, redaction and sampling; telemetry delivery is not business delivery; no adoption yet |
| [OpenTelemetry API](https://hexdocs.pm/opentelemetry_api/OpenTelemetry.html) · [source](https://github.com/open-telemetry/opentelemetry-erlang) | official API docs | Standard traces/metrics at the P3 edge | Verify context propagation, exporter failure and sensitive-field filtering; no adoption yet |
| [Plug](https://hexdocs.pm/plug/Plug.html) · [source](https://github.com/elixir-plug/plug) | official API docs | HTTP server boundary if an edge assembly needs a small endpoint | Request body limits, streaming, timeout and supervision become Elzoo adapter contracts; no adoption yet |

Candidate documentation versions are not recommendations. The first HTTP,
SQL and job tasks must record the exact lockfile, a successful `mix check`, a
negative-control/failure test, and the claim that the dependency actually
supports before changing a row to `reuse` or `adapt`.

## Cross-domain research leads

ELZ-014's [reference study](research/orchestration-references.md#elixir-candidate-discovery)
records observed Hex candidates for monetary values, identity/policy, quotas,
job/graph execution, agent/model integration and email. They are not dependencies
or adopted providers. Their metadata versions are research snapshots, not a
replacement for mix.lock or registry/providers.json. Adoption still requires
one concrete boundary and its failure checks; reuse-first does not mean
installing every plausible library.

## Deliberately deferred families

The following upstream classes are intentionally not dependencies in the
bootstrap:

* consensus/replicated-log/CRDT libraries, until a product requires a
  multi-writer or multi-host contract;
* Cedar/authorization, identity providers, secrets, payments, brokers and
  object stores, until a threat model and an assembly boundary exist;
* model/agent, dataframe, OCR, media and speech stacks, until a product adds a
  separate resource and data-classification requirement; and
* deployment/discovery helpers, until Elzoo has a real multi-host or OS
  process assembly.

Deferral is safer than adding an untested “standard” dependency. A task may
propose one, but it must include the upstream source/API, exact version, the
Elzoo boundary and an executable acceptance test.

## Trust handoff

| Claim at the boundary | Elzoo evidence | Upstream evidence | What remains outside the claim |
| --- | --- | --- | --- |
| Cure operator returns a typed transition | Cure kernel/type check and selected proof | Cure compiler/kernel | Compiler/kernel soundness and BEAM implementation |
| JSON adapter returns valid JSON or explicit error | Elzoo input validation + runtime round-trip/error test | Jason public API and its own tests | Jason implementation correctness beyond its contract |
| OTP unit restarts according to policy | ExUnit lifecycle test | OTP Supervisor/GenServer contract | OS process isolation, durable replay |
| PostgreSQL write participates in a transaction (future) | Adapter integration test and transaction-scope contract | Ecto/Postgrex/Postgres docs/tests | Network, server configuration and operator durability |
| Job retries eventually according to policy (future) | Oban adapter test under bounded failure | Oban job/retry docs | Database availability, scheduler timing and exact-once effects |

When a candidate is adopted, update this register and the relevant catalogue
row in the same change. Do not edit the architecture to turn a failed
integration test into an assumption.
