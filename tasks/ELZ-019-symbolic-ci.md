# ELZ-019 — Run CI only on machine A

- Phase: P0 development infrastructure
- Dependencies: ELZ-018

## Outcome

Move both workflows off GitHub-hosted machines to the user-owned machine A Linux machine. No hosted-runner fallback.

## Scope and acceptance

- [ ] Register and start a repository-scoped self-hosted runner on machine A using available SSH/admin access; do not expose registration credentials.
- [ ] Route Check and Gleam workflows exclusively to machine A with explicit self-hosted labels and a reproducible Linux job environment.
- [ ] Document runner ownership, service lifecycle, version/container assumptions and offline behavior; prohibit GitHub-hosted runners in project instructions.
- [ ] Keep old hosted workflows disabled until no hosted job can be triggered by re-enabling; run the proposed CI on machine A before merge.
- [ ] Obtain independent review and verify job runner identity plus real test results; merge, verify main on machine A and clean up.

No product/Piece behavior changes. GitHub remains the source/PR/check orchestration service, while execution is on machine A. This prevents hosted compute-minute use, not a claim about all GitHub storage or account charges.
