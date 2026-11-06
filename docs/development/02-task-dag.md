# Task DAG and publication index

The canonical planning task/status/dependency source is
[docs/plans/release-plan.json](../plans/release-plan.json). Its
[generated job table and published issue links](../plans/views.md#jobs-and-published-issues)
and [dependency graph](../plans/dependencies.mmd) replace the manually edited
copies formerly held here. Regenerate with `python3 scripts/check-roadmap.py
--write`; check with `python3 scripts/check-roadmap.py --live`. Published issue
bodies remain the complete task Contracts and override any stale snapshot;
remote `task/ELZ-###` branches remain claim locks. Catalogue readiness stays in
the Piece Ledger and ready manifests.

ELZ IDs are permanent identities. The files in `tasks/` are publication copies,
not a second live issue service. The coordinator can publish an admitted body:

```sh
gh issue create -R balungpisah/elzoo \
  --title "ELZ-002 — Define contracts and the typed composition boundary" \
  --body-file tasks/ELZ-002-contracts-and-typed-composition.md \
  --label task --label ready --label P0
```

This example describes the mechanics, not an instruction to republish an
existing issue. Use the selected task's actual ID/phase and dependency evidence.
Labels are advisory; a prerequisite in a PR is not merged acceptance.

ELZ-033 — [issue #55](https://github.com/balungpisah/elzoo/issues/55),
[task body](../../tasks/ELZ-033-product-led-roadmap.md) — adopts product-led
selection and gates only the bounded ELZ-022/024/026 wave. A published admitted
Piece may serve a concrete product aim before a new Assembly example exists.
It changes no published implementation dependency or acceptance. RC-00 maps
to ELZ-033; all other RC IDs are unpublished proposals. Do not mechanically
publish inventory or treat planning counts as implementation progress.

## Retained foundation boundaries

The P0–P3 foundation sequence remains in the generated graph with its original
published prerequisites. ELZ-001 was accepted during bootstrap after independent
clean-checkout and Linux CI validation; see [bootstrap validation](07-bootstrap-validation.md).
The source-delivery, capability, Ash, operational and independent Gleam studies
remain bounded evidence, not new requirements for every pure Piece. Later work
must not rebuild the harness just because it uses it; report a concrete new
defect as scoped work while retaining prior evidence and limits.

ELZ-003 owns the accepted shared delivery-result/error/deadline declarations.
ELZ-007 selection/routing and ELZ-006 execution consume those unchanged.
This separation still governs later parallel policy work: a shared schema
change needs a separately reviewed prerequisite and the ready-Contract/new-ID
rule. Source dependency closure alone never proves semantic compatibility.
Registry rows remain task-scoped; the coordinator serializes metadata integration
and regenerates `LEDGER.md` with `mix elzoo.ledger` after source merges, never
hand-merges generated rows.

P0's exact-key idempotency is volatile and unbounded; ELZ-005's separate
`delivery/windowed-idempotency` ID is bounded and volatile. Neither is durable
or exactly once. Likewise the durable state Store does not alone supply a
business lease, general scheduler, authenticated approval or external-effect
reconciliation. See the roadmap's conditional provider and gap dispositions.

ELZ-010 remains exclusively with its existing coordinator. ELZ-011/012 retain
their foundation continuation. The roadmap [first-wave preflights](../plans/preflight.md)
record direct dependency merge evidence for ELZ-022/024/026, frozen shared
interfaces and decision blockers. New workers recheck live locks and readiness
at dispatch. At most three implementation workers total include active
ELZ-010; at most two new Piece workers while it is active, with independent
review and coordinator capacity. No recursive delegation, extra runner, hosted
fallback or provider/lockfile change is implied by the new selection policy.
