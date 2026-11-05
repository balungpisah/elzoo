# Elzoo bootstrap

This is a one-time bootstrap plan, not a mandatory development lifecycle.

## Contract

- The repository root is `/Users/laptopdp/Developer/sabrang/elzoo`.
- This is a new project. Zoo's Bend toolchain, decisions and gates do not govern
  elzoo. Preserve the composable architecture, not its development bureaucracy.
- Cure owns new pure decision logic when suitable. Elixir/OTP and maintained
  libraries own existing runtime/integration implementations. Do not rebuild OTP.
- Use the vocabulary in CONTEXT.md. Claims carry appropriate grounding; proofs
  are optional per claim, and external implementations remain upstream's work.
- Toolchain: Cure v0.35.0 exact commit
  `a004c335cc4e9f2203ba6f51fc31e8540b66378d`, Elixir 1.20.4, OTP 29.1.2.
  Cure has a same-named branch and tag: use the SHA, not a bare version ref.
- One Mix application initially. `mix setup` and `mix check` are the public
  development commands. `mix check` must compile real Cure, check selected proofs
  and execute meaningful runtime and negative-control tests, not merely lint docs.
- Bootstrap exemplar: a pure composable operator/assembly with proof and OTP
  execution, plus an external-library boundary. Label its limits; don't pretend
  a simplified deduplicator implements the complete old receiver contract.
- Retain external assumptions explicitly. No whole-repository lowest badge,
  mandatory proof for every operation, custom task engine or elaborate gate loop.
- Private remote, if created: `balungpisah/elzoo`. No deployment or paid services.

## Ownership and leaves

1. `runtime`: Mix project, configuration, Cure sources, Elixir runtime, tests,
   toolchain setup scripts. Owns mix.exs, mix.lock, .formatter.exs, .tool-versions,
   .gitignore, config/, lib/, cure/, test/, scripts/setup* and scripts/check*.
   Gates: gates/runtime.md.
2. `architecture`: docs/architecture.md, docs/catalogue.md, docs/dependencies.md,
   docs/adr/ and docs/cure-notes.md. Research reuse candidates and explain delivery
   semantics and trust boundaries. Gates: gates/architecture.md.
3. `workflow`: AGENTS.md, GOAL.md, docs/development/, tasks/ and gates/workflow.md.
   Prepare concrete dependency-ordered tasks and a lean autonomous workflow.
   No custom task CLI; use Git, Mix and GitHub issues. No secrets or live publishing.
4. Coordinator: README.md, root GATES.md/PLAN.md/CONTEXT.md, .github/, integration,
   clean-checkout verification, remote and task publication, final evidence.

Each worker reads its gates before coding, works only its paths, runs its checks,
and reports defects and limitations. Do not spawn additional workers. No worker
commits or pushes; the coordinator integrates and commits the initial repository.

## Status

- Scope and file ownership recorded before implementation.

- Architecture and workflow leaves integrated; parent corrected phase wording,
  merge-history settings, cleanup commands and an omitted DAG edge.
- ELZ-007 separated from retry/window implementation so independent workers
  can run it after shared contracts, with ELZ-008 owning integration.

- Runtime leaf delivered four compiled Cure modules, OTP/Jason boundaries,
  model checks and negative controls. Parent mix check passed eight tests.
- Parent isolated source-root slowdown and failure-marker timing; both fixed.

- Independent fresh remote clone passed setup, eight tests, deliberate-failure
  and filtered-check rejection, and source addition/removal artifact cleanup.
- Independent release evaluation loaded all four Cure modules and executed
  duplicate suppression. Git claim/handoff/delete-race probes passed.
- Linux CI run 42013712025 passed; all twelve issues are published. ELZ-001
  accepted, ELZ-002 next. Setup/check now share the test build environment.
- Bootstrap delivered; the catalogue and later assemblies remain scoped tasks.
