# Pinned development commands

The project runtime/tooling path owns the Mix project, setup scripts, Cure
source and tests.
Workflow depends on these public commands:

    mix setup
    mix check

The bootstrap uses:

- Cure v0.35.0 at exact commit
  a004c335cc4e9f2203ba6f51fc31e8540b66378d, not a moving same-named ref;
- Elixir 1.20.4;
- OTP 29.1.2.

mix setup must be reproducible without a Zoo checkout. mix check must compile
real Cure, run selected proof checks, meaningful ExUnit/OTP and boundary tests,
and execute negative controls. A formatter-only check is not acceptable. The
runtime gate records ELZOO CHECK PASSED.

Use targeted mix test while iterating, but report full mix check before review.
If the local runtime differs from the pin, report the environment instead of
presenting a partial result as a pass. External libraries are tested at their
integration boundary and remain grounded by an upstream contract; they do not
need a local Cure proof by default.

Both public commands prefer `MIX_ENV=test` so the first setup does not build
the compiler twice across dev and test. Leave `MIX_ENV` unset for these
commands. Use ordinary Mix commands for dev/prod builds when needed.

ELZ-015 adds an isolated Ash experiment under `spikes/ash_foundation`. Root
`mix setup` fetches its separately locked dependencies and root `mix check`
runs its formatter and ExUnit checks in a separate BEAM process. Targeted
`mix elzoo.ash_spike` runs only that experiment. The root dependency graph
contains no Ash package and source-consumer requirements are unchanged by the
spike; Ash is not part of the Cure compiler trust claim. ELZ-010 adds Oban
2.24.2 to the root graph (test-only for its pre-implementation probes, then a
normal provider of `integration/jobs`). See its README for versions and limits.

Linux CI runs on symbolic through a repository-scoped self-hosted runner and
pinned Ubuntu job containers. See [runner operations](10-symbolic-ci.md);
GitHub-hosted compute and hosted fallback are prohibited.
