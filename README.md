# elzoo

Composable building blocks for reliable systems, using Cure and the Elixir
ecosystem. Pieces form assemblies; assemblies can be composed again into products.

Cure provides typed pure decision logic and selected proofs. Elixir/OTP supplies
the runtime, supervision and integration with existing libraries. A claim can be
grounded by a proof, a type check, executable tests, monitoring or an explicit
upstream contract. We do not require a proof of every implementation.

## Take pieces into your project

Browse [the checked piece ledger](LEDGER.md) for ready bundles, libraries,
selected proofs/tests, assumptions and remaining gaps. Each piece keeps its
source, contract and evidence together under `pieces/<family>/<name>/`.

```sh
# From an Elzoo checkout after mix setup:
mix new ../my_app
mix elzoo.take integration/json integration/http --to ../my_app --dry-run
mix elzoo.take integration/json integration/http --to ../my_app
```

Read the printed install instructions to merge dependencies into your Mix
project, then run its tests. The copier brings source, tests, examples,
Apache-2.0 license/notice and a provenance receipt. It does not overwrite your
edits or require Elzoo.Application. Library-only recipes need no Cure compiler.
For a Cure/OTP example, select `assembly/ingest-dedup-accumulate` instead.
See [consuming pieces](docs/consuming.md) for composition, updates and limits.

## Start developing

Install Elixir **1.20.4**, Erlang/OTP **29.1.2** (also pinned in
`.tool-versions`) and Git. To join from another machine, install GitHub CLI
and authenticate an account with access to the private repository:

```sh
gh repo clone balungpisah/elzoo
cd elzoo
```

Then build from the checkout:

```sh
mix local.hex --force
mix local.rebar --force
mix setup
mix check
```

Cure is pinned to an exact source commit, and dependencies are recorded in
`mix.lock`. No Bend installation or original Zoo checkout is needed.
Both commands use Mix’s test environment, so setup and check share one
compiler build. The first setup takes several minutes; subsequent checks
reuse those dependencies. Ordinary `mix run` and production builds use their
own standard Mix environments.
Network access to GitHub and Hex is required for dependency installation.
On a machine with limited resources, set
`ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1"` to limit BEAM scheduler threads.

Mix is Elixir’s standard project, dependency, build and test tool. These two
commands are the development harness; they are not a separate runtime engine.

## Start an autonomous agent

Read [AGENTS.md](AGENTS.md), then [GOAL.md](GOAL.md). They describe how to pick a
task, claim it, work in isolation, choose evidence, verify and integrate.

```sh
gh issue list --repo balungpisah/elzoo --state open
```

Agents push progress on their claimed task branches; reviewed merges update
`main` for everyone. Each machine keeps its own checkout and build artifacts.
GitHub issues and remote branches hold the shared coordination state.
CI runs on pushes and PRs. The current GitHub plan does not support protected
branches for this private repository, so agents must observe the documented
review/check requirements before merging.

The bootstrap harness (ELZ-001) is accepted. The first open task is
[ELZ-002: contracts and typed composition](https://github.com/balungpisah/elzoo/issues/2).

Work follows the task dependencies and working-assembly milestones. The old
Zoo's custom task engine and proof-first gate cycle are not prerequisites here.
The bootstrap's [GATES.md](GATES.md) and [PLAN.md](PLAN.md) record this initial
setup only; they are not a new process that every piece must reproduce.

## Design and scope

- [CONTEXT.md](CONTEXT.md): the shared vocabulary.
- [Architecture](docs/architecture.md): composition, placement, effects and guarantees.
- [Catalogue](docs/catalogue.md): what we own, reuse, adapt and defer.
- [Dependencies](docs/dependencies.md): upstream contracts and adoption status.
- [Cure notes](docs/cure-notes.md): tested compiler behavior and authoring guidance.
- [Decisions](docs/adr/): the few architectural choices worth preserving.
- [Bootstrap validation](docs/development/07-bootstrap-validation.md): actual checks and limits.

The checked-in bootstrap demonstrates the development path. It does not claim
that the planned catalogue, durable delivery, multi-host transport or arbitrary
runtime wiring are already implemented. A working example and its stated limits
are the starting point for the next agent.

External libraries remain upstream implementations. Elzoo owns the correctness
of its wrappers, declared assumptions and composition. Use a library directly
when its existing contract is enough; add an adapter only for a real boundary.

Private development repository: <https://github.com/balungpisah/elzoo>.

Elzoo-owned code is [Apache-2.0](LICENSE). Upstream libraries retain their own
licenses. The private repository’s access permissions are unchanged.
