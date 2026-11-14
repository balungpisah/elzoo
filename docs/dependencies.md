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
| [Cure](https://github.com/balungpisah/cure-lang/tree/208248063d64e621782cd26dd30698ee42850a89) | commit `208248063d64e621782cd26dd30698ee42850a89` on the `balungpisah/cure-lang` fork = upstream `a004c335` (release line v0.35.0) + one import-resolution fix; record in [forks/cure.md](dependencies/forks/cure.md) | adopted; maintained fork (ELZ-047) | Elzoo compiles the selected source modules through `compile_file/2`; runtime tests check selected laws, typed negatives, independent imports and model traces | Cure compiler/kernel/runtime remain trusted infrastructure; the spike is not an independent soundness audit |
| [Elixir](https://github.com/elixir-lang/elixir) | 1.20.4 | adopted platform baseline | Elzoo runs the GenServer shell, Supervisor and ExUnit on the matching toolchain | Elzoo owns only its shell callbacks and contracts |
| [Erlang/OTP](https://www.erlang.org/doc/system/design_principles.html) | OTP 29.1.2 (BEAM reports OTP 29 in the spike) | adopted platform baseline for ordinary supervision | Elzoo tests `GenServer`, `Supervisor`, process messaging and restart behavior | OTP process isolation is not an OS/security sandbox; no distributed/crash theorem |
| [Jason](https://hexdocs.pm/jason/Jason.html) / [source](https://github.com/michalmuskala/jason) | 1.4.5 in `mix.lock` | adopted adapter dependency | Real `Jason.encode!` calls round-tripped strings, quotes, Unicode and empty input; invalid input and a failing stand-in became explicit errors | Jason encoding/decoding is upstream-owned; Cure `@extern` signature is a foreign assumption |

Elzoo now adopts Req 0.7.5 for a narrow direct HTTP client recipe. Finch is its
transitive implementation, not a separate Elzoo abstraction. ELZ-009 adopts
Ecto SQL 3.14.0 and Postgrex 0.22.4 (Ecto 3.14.3 and DBConnection 2.10.2
transitive) for the narrow `integration/sql` PostgreSQL Store translation.
ELZ-010 adopts Oban 2.24.2 for `integration/jobs`. ELZ-029 adopts erlexec
2.6.0 (BSD-2-Clause; the upstream copyright and permission notice is retained
in the package's `LICENSE` as distributed by Hex) for `runtime/os-isolation`:
its port program spawns the command, creates its process group, enforces the
deadline and the SIGTERM→SIGKILL escalation, and stops the group when the
linked owner or the VM exits; Elzoo owns admission, deadline conversion, the
observation and the result schema. OpenTelemetry remains a
candidate. Telemetry is transitive, with no
adopted business-event contract. Cure's transitive dependency graph remains
in `mix.lock`; “not adopted” means Elzoo does not rely on that package's API
or behavior as a contract.

## Source distribution and authoritative pins

ELZ-160 adopts the source-only `lua_source` provider, PUC Lua 5.4.9 at
`312b9efaa1061c2c4cad08554dbc1351c3270eef` (MIT; notices retained in
upstream `lua.h`). The root adoption test compiles the explicit upstream
library sources into a disposable static archive and links a test-only C host.
An OTP Port exercises `luaL_newstate`, `luaL_loadstring`, `lua_pcall` and
`lua_close`: integer 42, zero-result empty source, malformed-source load failure
and protected-call failure. Upstream owns parsing, evaluation and the C API.
This is finite build/API compatibility evidence, not a security proof,
sandbox policy, resource-limit guarantee or production artifact packaging.
The host is test support only; no public Elixir API or runtime Piece is added.

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

## YAML reader for skill frontmatter (ELZ-176)

ELZ-176 adopts `yaml_elixir` 2.12.2 (MIT) and `yamerl` 0.10.0 (BSD-2-Clause;
the notice is retained in the package's `LICENSE` as distributed by Hex) as
the provider of the later RC-67 `workflow/skill` Piece, which reads the YAML
frontmatter of a `SKILL.md` file. Both are pinned exactly in `mix.exs`.
`yamerl` is named although it is transitive, because it is the parser: its
version decides what a document means. No Piece, wrapper, writer or public
Elzoo API is added. The root test `test/elz176_yaml_provider_test.exs` is the
adoption check; it uses only `YamlElixir.read_from_string/2` (and
`read_all_from_string/2` once, to show the second document).

**Upstream contract, quoted.** `yaml_elixir` 2.12.2 has no `@doc` text; its
README is the whole documented contract. It says: "This is a wrapper for
yamerl - a native Erlang `YAML` parser"; "By default, all map keys are
processed as strings, as are all bareword or quoted values"; `atoms: true`
turns values that begin with `:` into atoms and "Atoms are not garbage
collected by `BEAM`, so be careful with this option, and don't use it with
user-supplied input"; "In case your YAML contains anchors, you can have these
resolved by passing `merge_anchors: true`". Its README example for
`read_from_string/1` gives `{:ok, %{"a" => "a", "b" => 1, "c" => true, "d" =>
nil, "e" => "nil"}}`. The source of `read_from_string/2` returns `{:ok,
term}` or `{:error, error}` and catches every throw, error and exit of the
parser. `yamerl_constr` documents the options that matter here:
`{node_mods, Mods_List}` "List of Erlang modules to extend support node
types. Default: `[]`", `{schema, failsafe | json | core | yaml11}` "Name of
the official schema to use. Default: `core`", `{keep_duplicate_keys,
boolean()}` "By default all duplicate keys in maps/proplists will be ignored
and the last occurence of a key will prevail", and `{ignore_unrecognized_tags,
boolean()}` "When `false` (the default), a node with an unrecognized tag can't
be constructed". `yaml_elixir` fixes `detailed_constr`, `str_node_as_binary`
and `keep_duplicate_keys` itself; `merge_anchors`, `atoms` and
`maps_as_keywords` are its own options.

**Test results** (literal documents; options `[]` unless stated; each line is
asserted by the root test):

- Plain frontmatter: `{:ok, map}` with string keys and string values. Plain,
  single-quoted and double-quoted scalars are strings; `|` gives
  `"one\ntwo\n"` and `>` gives `"three four\nfive\n"`; a nested map of string
  pairs is a nested map. String keys need no option.
- Typed scalars: plain `true` is `true`, `null` and `~` are `nil`, `12` is
  `12`, `1.5` is `1.5`, `0x10` is `16`; plain `no`, `on` and `2026-11-14` stay
  the strings `"no"`, `"on"` and `"2026-11-14"` (core schema, no YAML 1.1
  booleans, no timestamps). An empty value is `nil`. The same texts in single
  or double quotes are always the strings, and `''` is `""`. The reader keeps
  a string apart from a typed value only through the quotes, so RC-67 must
  compare the term type, not the text.
- Aliases and merges: a block-style alias is expanded to the anchored value
  (`use: *b` gives `%{"x" => 1}`); no marker, no error, and `merge_anchors:
  true` changes nothing for it. A merge key `<<: *b` without the option stays
  a key `"<<N"` (`N` from `System.unique_integer/1`, so it is not stable)
  holding the anchored map; with `merge_anchors: true` its pairs merge into
  the parent. An alias without an anchor is
  `{:error, %YamlElixir.ParsingError{type: :no_matching_anchor}}`. A depth-6
  block-style chain expands (128 leaves). A
  flow-style depth-6 chain (`a1: &a1 [*a0, *a0, *a0]` and so on) does not give
  the anchored value: `a1` is `["x", "x", "x"]` and `a2` to `a6` are three
  copies of their own key name (`["a2", "a2", "a2"]`); it is a wrong result,
  not an error and not a marker. **No option and no result form lets a caller
  refuse an alias or detect that one was used.** RC-67 therefore refuses a
  frontmatter that holds `&`, `*` or `<<` outside a quoted scalar before it
  calls the reader. A quoted `'&x'`, `'*x'` or `"<<"` stays the plain string.
- Not one plain map: a list gives `{:ok, ["a", "b"]}`; a scalar gives
  `{:ok, "just text"}`; the empty string and a blank line give `{:ok, %{}}`;
  two documents in one string give the last one (`{:ok, %{"b" => 2}}`), while
  `read_all_from_string/2` gives both; a duplicate key is no error and the
  first value wins (`{:ok, %{"a" => 1}}`, which differs from the yamerl text
  quoted above, because `yaml_elixir` aggregates with `Map.put_new/3`); a
  tab-indented line is no error (`"a:\n\tb: 1"` gives `%{"a" => nil, "b" =>
  1}`); invalid UTF-8 inside a plain scalar is `{:error,
  %YamlElixir.ParsingError{type: :invalid_unicode}}`, inside a quoted scalar
  `type: :unexpected_eos`; a document that starts with the bytes `FF FE` is
  read as UTF-16 (byte-order mark) and gives a scalar string, not an error;
  `!!binary` is decoded (`"hello"`); `!ruby/object:Foo` is `{:error,
  %YamlElixir.ParsingError{type: :unrecognized_node}}`; an unterminated flow
  collection is `{:error, %YamlElixir.ParsingError{message: "malformed yaml"}}`.
  No input raised or killed the caller. RC-67 must still check that the
  result is a map before it uses it.
- Atoms and code: 2,000 documents with 2,000 distinct new keys left
  `:erlang.system_info(:atom_count)` unchanged (after one warm-up parse).
  yamerl's Erlang node modules (`yamerl_node_erlang_atom`,
  `yamerl_node_erlang_fun`) are off (`node_mods` is `[]`), so the tags
  `!<tag:yamerl,2012:atom>` and `!<tag:yamerl,2012:fun>` are
  `{:error, ... type: :unrecognized_node}` and a document naming
  `persistent_term:put/2` does not run it. A control in the same test turns
  `node_mods` on (a global yamerl parameter) and the same document then does
  run the named call during the read (and still returns `{:error, "malformed
  yaml"}`): the reader is safe against that only while no caller sets
  `node_mods`. RC-67 must never set it.
- Bounded time: nested plain maps of exactly 16,384 and 1,048,576 bytes each
  parsed inside a `Task` with a 5 s limit and gave `{:ok, map}`. The measured
  times are in the pull request body; the 1 MiB parse used most of the limit
  on the development host, so RC-67 must bound the frontmatter size well below
  1 MiB itself.

**Start of `yamerl`.** `yaml_elixir` has no `application/0`, so Mix infers
`applications: [:kernel, :stdlib, :elixir, :yamerl]` and `yamerl` starts with
it in a release or under `mix`. `YamlElixir` also calls
`Application.start(:yamerl)` on every read, so a copied consumer that lists
`yaml_elixir` as a dependency does not need to start `yamerl` itself, and a
consumer that excludes it from `applications` still works through that call.
Hex access is needed to fetch both packages; `yamerl` builds with rebar3.

**Assumptions, not tested.** The behaviour of other versions, other input
sizes, `atoms: true`, `maps_as_keywords`, the file readers and the `~y` sigil.
`yamerl` source for `yamerl_node_erlang_fun` was read: it evaluates the text
with `erl_eval`.

**Limits.** This shows finite behaviour of two pinned versions on literal
documents. It is not a claim that the reader is safe for hostile input of any
size, and it adopts no YAML writer. Telemetry, Config and Control do not
apply: there is no Piece and no running Elzoo service.

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
| `:disk_log` | [Erlang disk_log docs](https://www.erlang.org/doc/apps/kernel/disk_log.html) | evaluated by ELZ-009, not adopted | Negative comparison on OTP 29.1.2: two writers on one log both appended sequence 1, duplicate identities persisted and a killed multi-call commit left a partial unit. Bare `disk_log` supplies no store CAS, uniqueness or atomic multi-record commit |
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
| [Ecto SQL](https://hexdocs.pm/ecto_sql/3.14.0/Ecto.Adapters.SQL.html) · [source](https://github.com/elixir-ecto/ecto_sql) | `Ecto.Adapters.SQL`, `Repo.transaction/2`, `Ecto.Migrator` (3.14.0, Ecto 3.14.3 transitive) | Transaction boundary for the `integration/sql` Store translation over a consumer-owned Repo | Adopted at 3.14.0 by ELZ-009: K1–K11 and D11/D15/D17/D19 pass on a disposable local PostgreSQL, including backend termination and unreachable server. Ecto does not make an Elzoo hop durable; consumer owns Repo, schema and server configuration |
| [Postgrex](https://hexdocs.pm/postgrex/0.22.4/Postgrex.html) · [source](https://github.com/elixir-ecto/postgrex) | PostgreSQL driver under Ecto SQL (0.22.4) | Wire protocol and error translation for the Store adapter | Adopted at 0.22.4 with Ecto SQL, not as a second direct abstraction. PostgreSQL atomicity, locking and durability remain upstream server contracts |
| [Oban](https://hexdocs.pm/oban/Oban.html) · [source](https://github.com/oban-bg/oban) | docs page showed `Oban.start_link/1`, `insert/1-3`, `insert_all/1-3` (v2.24.2 page) | PostgreSQL-backed jobs and retry/scheduling for `assembly/durable-job` | Adopted at 2.24.2 by ELZ-010 (`integration/jobs`, `adapt`): uniqueness (incl. the held-lock `id: nil` case), retry staging, snooze, cancellation, disjoint claim, Lifeline rescue after a real SIGKILL and stale-ack fencing exercised on a disposable PostgreSQL. Oban's retry is not the Elzoo outbox and its ownership contract is not a lease; pruning, queue backpressure and Pro features are not exercised |
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

## Ash foundation evaluation

[ELZ-015](../spikes/ash_foundation/README.md) pins Ash 3.37.3, AshAi 1.5.0,
AshStateMachine 0.3.0 and SimpleSat 0.1.4 in its own Mix project/lockfile.
Their exact versions and transitive checksums are in
`spikes/ash_foundation/mix.lock`, not the root provider registry: these are
experiment dependencies, not ready catalogue providers. The experiment tests
application actions, policy checks and tool dispatch with volatile ETS.
Production storage, concurrency, authentication and jobs remain unadopted.

Prefer upstream Ash extensions for corresponding resource capabilities before
writing equivalent mechanisms. Evaluate AshPostgres for transactional state,
AshOban for jobs, Reactor for dependency execution, and AshAuthentication for
identity. AshMoney, AshDoubleEntry and AshPaperTrail remain separate candidates;
this experiment does not certify them. Ash policies and Cedar have distinct
contracts; do not silently run competing authority definitions.

[Upstream/fork policy](development/08-upstream-and-forks.md): use upstream
releases by default. A needed MIT fork belongs under balungpisah with preserved
notices/provenance, exact consumed revisions and responsibility for our delta.
No fork is currently required by the Ash experiment.

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
| PostgreSQL append commits head, records and outbox in one transaction | `integration/sql` K1–K11 and D11/D15/D17/D19 on a disposable local cluster | Ecto SQL/Postgrex APIs; PostgreSQL transaction, READ COMMITTED and row-lock contracts | Network, server configuration (fsync/synchronous_commit), backups and operator durability |
| Durable job attempts, retry and recovery (ELZ-010) | `assembly/durable-job` DJ1–DJ20 incl. SIGKILL rescue; `workflow/state-machine` laws L1–L29 over the decision table | Oban 2.24.2 job/retry/rescue docs and source; PostgreSQL transactions | Database availability, scheduler timing, clock skew, exactly-once execution and external effects |

When a candidate is adopted, update this register and the relevant catalogue
row in the same change. Do not edit the architecture to turn a failed
integration test into an assumption.
