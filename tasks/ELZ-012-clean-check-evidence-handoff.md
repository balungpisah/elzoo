# ELZ-012 — Reproduce the clean check and hand off evidence

- Phase: P3 handoff
- Catalogue IDs: core/grounding and verification/clean-check
- Dependencies: ELZ-011

## Outcome

Make the current exemplar and selected P1/P2/P3 assembly behavior reproducible
from a clean clone and leave a scope-accurate evidence handoff.

## Scope

- run mix setup and mix check from a clean clone/worktree under pinned Cure,
  Elixir and OTP;
- verify Cure is compiled at the exact SHA rather than a moving ref;
- record selected proofs, runtime tests, negative controls, upstream contracts,
  monitored observations and deferred capabilities;
- update only relevant handoff/development/catalogue docs;
- leave a future worker able to pick the next issue without oral context.

## Acceptance

- [ ] Clean clone succeeds with documented mix setup and mix check.
- [ ] Output includes ELZOO CHECK PASSED and meaningful proof, runtime and
      negative-control results.
- [ ] Evidence names grounding and scope; no test is worded as an unbounded
      proof and no upstream contract is claimed as local ownership.
- [ ] Remaining work has concrete/new task IDs rather than a broad done claim.
- [ ] Coordinator can inspect a clean Git status after merge and cleanup.

## Evidence and limits

This grounds reproducibility of the selected exemplar only. It does not
certify future assemblies, deployments or all Cure, Elixir, OTP or library
behavior.

## Out of scope

No new runtime feature, automatic issue publication or custom task engine.
