# Take pieces into your own project

Elzoo is a source catalogue. Your application owns the copied files and its
wiring. You do not install the whole catalogue as a runtime dependency or
start Elzoo.Application. Keep ordinary library calls ordinary: a recipe can
contain examples/tests and dependency instructions without a wrapper module.

## Find and inspect

Start with [LEDGER.md](https://github.com/balungpisah/elzoo/blob/main/LEDGER.md).
Each ready row links to a README with its contract, limits, dependency IDs
and grounding. The adjacent piece.json lists source files and exact claim
references; registry/providers.json records provider pins. `owned` means handwritten Elzoo code;
`adapter` means local translation around an upstream implementation; `recipe`
means direct upstream usage. Proof is a separate property of a particular
claim, not an implementation category or a badge for an entire piece.

Take Pieces from the latest commit of `main` whose push run of the backend
workflow (`symbolic-check.yml`) is green; there is no separate marker branch.
A push run that logs `ELZOO PUSH CHECK SKIPPED` counts: it names the green
exact-head run of the merged pull request.

Planned and deferred entries are inventory, not installable stubs. Ready
means the named subset is usable. For example, the hashing recipe does not
implement the whole crypto family, and the HTTP client recipe is not a durable
HTTP-to-job assembly. Those broader contracts remain explicit tasks.

## Who provides what

The catalogue and the consuming application divide responsibility as follows.
This table summarizes the sections below; it adds no Contract or claim.

| The Elzoo catalogue provides | The consuming application provides |
| --- | --- |
| Ready Piece bundles with the applicable source, tests, examples, README Contract and limits, `piece.json` claims, and Apache-2.0 license and NOTICE | Its own Mix project, `mix.exs`, `mix.lock` and dependency resolution, including transitive packages |
| A receipt per selection under `.elzoo/receipts/`: origin revision when available, dirty-source indicator, original file hashes, selected claims and the provider versions tested in Elzoo | Pinning recorded versions for exact reproduction and rerunning boundary tests after any update |
| Install snippets under `.elzoo/install/*.md`: dependency and configuration text to merge by hand | Its Application, supervisor tree, test helper and configuration; the copier rewrites none of them |
| For Cure Pieces: the small Mix compiler source and instructions to register it before `:app`; Cure stays a pinned build/test dependency | The recorded Elixir 1.20.4 / OTP 29.1.2 baseline for the recorded proof results |
| Claim-level grounding and limits, including selected laws, tests, upstream contracts or assumptions where recorded in the README and `piece.json` | Evidence for its own edits and composition; copied evidence does not survive edits automatically |
| Explicit Needs where declared by a Piece | Supplying the external capabilities a selected Piece declares it needs |
| Pure Operators and explicit Effect and Adapter boundaries where provided | Its effects, delivery policy and persistence, and an OTP shell where a lifecycle needs a process |
| The default `Elzoo.*` / `Cure.Elzoo.*` namespace for application-owned copies and documented public record tags | Before redistributing copied source as a library, renaming modules, Cure imports, Elixir MFA/atom references and tests; explicitly renaming public record tags or translating them at an Adapter and testing the boundary |
| Known conflicts detected before writing, identical files left intact and no force replacement; copying is not a multi-file transaction | No concurrent writers against a destination, and deliberate merging of updates through a scratch project |
| A new Piece ID for a changed ready Contract, with migration notes | Opting in to a new ID by changing its dependency IDs, and resolving any module or data-tag overlap |

## Copy

Install the pinned Elixir/OTP versions and run `mix setup` in Elzoo once.
Create your application normally, then run these commands from Elzoo:

```sh
mix new ../my_app
mix elzoo.take integration/json integration/http --to ../my_app --dry-run
mix elzoo.take integration/json integration/http --to ../my_app
```

For pure Cure composition and the working OTP example:

```sh
mix elzoo.take assembly/ingest-dedup-accumulate --to ../my_app
```

The command resolves transitive piece dependencies and copies their source,
tests, examples, contracts and Apache-2.0 license/notice. It writes a receipt
under `.elzoo/receipts/` containing the origin commit, dirty-source indicator,
original file hashes, selected claims and provider versions. Read the printed
`.elzoo/install/*.md` path and merge its dependency/configuration snippets into
your existing Mix project. The copier deliberately does not rewrite mix.exs,
mix.lock, your Application, your test helper, or existing configuration.

Some pieces need a configuration line in every consumer (for example
`integration/ai-text-anthropic` needs `config :req_llm, load_dotenv: false` so
that `req_llm` never loads a `.env` file). A piece declares such lines in its
manifest field `install_configuration`, each with a one-line reason; the
registry accepts only a single literal `config :app, key: value` call for an
application the piece itself brings. The install file lists the selection's
lines once each under "Configuration", with every declaring piece and reason.
Merge them into your configuration (for example `config/config.exs`) before
those applications start. The lines are copied as data and never evaluated by
the copier; a selection without such lines gets no Configuration section.
Elzoo's copied-consumer harness writes these lines and checks they are set
before the application starts; a consumer that drops a line is not checked.

JSON/HTTP/library recipes do not pull in Cure. Selecting a Cure piece adds
the small Mix compiler source and instructions to register it before `:app`.
Cure itself is a pinned build/test dependency (`runtime: false`); its implementation is not vendored. Your
project resolves its own lockfile, including transitive packages such as
Finch under Req. The receipt records the upstream versions tested in Elzoo. Generated Hex
constraints allow patch updates for consumer resolution; that range is not a
claim of tested compatibility. Pin the recorded versions for exact reproduction
and rerun boundary tests after any update.

The default `Elzoo.*` / `Cure.Elzoo.*` namespace is for **application-owned
copies**, with one coordinated revision of each module per BEAM release.
Two libraries cannot safely embed different copies under those same names.
A library redistributing copied source must rename all modules, Cure imports,
Elixir MFA/atom references and tests into its own namespace before shipping.
Cure records also erase to bare tags such as `:Transition` and `:Joined`;
Envelope/Edge add `:EnvelopeMessage`, `:ReplyEndpoint`, `:DeliveryResult`,
`:RouteReference`, `:PortBinding` and `:EdgeDeclaration`. These are distinct
from the existing Operator/Port/Assembly tags, not namespaced at runtime;
module renaming alone does not distinguish these data shapes. Explicitly rename
public record tags or translate them at an Adapter and test the boundary.
The copier does not perform or certify this renaming. Loading two different
revisions with unchanged names is unsupported; the second module can replace
the first in the VM. Applications also must not mix conflicting copies.
This first copier does not merge concurrent edits. The Cure compiler requires the recorded
Elixir 1.20.4 / OTP 29.1.2 baseline for the recorded proof results.

## Weave

An Operator remains `state + input -> Transition(next_state, Option(output))`.
A composition can be used as another Operator. Wrap only the lifecycle that
needs a process in `Elzoo.Unit` or your own OTP shell. Your application chooses
its Supervisor tree, effects, delivery policy and persistence. Named/versioned descriptor validation is available through `core/port` and
`core/assembly`; select `core/assembly` for a reusable outer interface. Cure
function types and declared schema compatibility are separate checks, neither
validates arbitrary foreign runtime payloads. Select `core/envelope` for the
shared message/result/deadline data, `core/edge` for fused/volatile binding
checks, or `core/wiring` for local named declarations and explicit route
matching. None executes delivery, selects a route, validates payloads or
certifies a full graph. Source dependency closure is not semantic compatibility
checking.

Use `Jason`, `Req`, `Enum`, `Stream`, `Supervisor`, `Registry`, timers and
`:crypto` directly where their contracts fit. Select the optional
`integration/cure-json` bridge only when a Cure caller actually needs it.
Req's API uses Finch transitively; it does not introduce a second Elzoo HTTP
abstraction. HTTP status failures and transport failures are different
outcomes; the recipe makes retries, redirects and timeout choices explicit.

## Verify and customize

After merging dependency/configuration instructions, run `mix deps.get` and
`mix test` in your application. Copying source does not automatically preserve
its evidence after edits. Selected Cure laws must compile, translated
boundaries need their tests, and upstream assumptions stay visible. A
successful source installation is not proof of the consuming application's
behavior. The receipt records original bytes, not a continuing certification.

Known conflicting files are detected before any write. Identical files are
left intact; symlink targets and conflicting files are refused. Do not run
concurrent writers against a destination. Filesystem failures during copying
are not an atomic multi-file transaction. No existing code is force-replaced.

A ready behavioral Contract change gets a new Piece ID, with explicit migration
notes, while fixes restoring the existing Contract retain the ID. An ID change
does not itself rename BEAM modules. Compare both Contract and source/provenance;
opt in to new dependencies deliberately and resolve any module/data-tag overlap.

For updates, export the new selection into a scratch Mix project, compare it
with your copies/receipt, and merge deliberately. There is no silent upgrade,
rollback engine or remote registry service. Per-selection receipts may
conflict when their provenance changes even if some source bytes are equal;
review that change instead of overwriting a receipt automatically.

## Ownership and licensing

Elzoo-owned code is Apache-2.0, as requested by the project owner. Copied files
retain SPDX identifiers and carry `licenses/elzoo/LICENSE` and NOTICE. This
does not change the license of your whole project. Upstream libraries retain
their own licenses; provider metadata identifies them, and Mix fetches their
original packages. The repository is private; source licensing does not
change GitHub access permissions.
