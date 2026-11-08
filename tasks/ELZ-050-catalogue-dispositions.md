# ELZ-050 — Record decision-ready dispositions for every planned and deferred catalogue entry

- Phase: demand-led catalogue admission (documentation)
- Catalogue IDs: every entry whose `status` is `planned` or `deferred` in
  `registry/catalogue.json` at the task base (14 planned and 39 deferred at
  main `ade0e45`; the task records the actual count at its base)
- Dependencies: ELZ-033

## Outcome

Give a builder one place to read, before claiming any planned or deferred
entry, the disposition that entry carries, the library or idea source it
rests on, the owner decision behind it, its dependencies, its caller and
invariant, and the questions that are still open. The owner requires that
these records be decision-ready before any new build task is published; the
catalogue's planned and deferred entries are part of the build plan, not a
parking lot. This task is documentation only. It promotes no entry to ready,
adds no dependency, source, manifest, ledger or registry status change, and
publishes no other task.

## Inputs

1. The research branch `research/ecosystem-survey` (last known tip
   `409d5430fa441148cbc996950bf97c0a9f564911`), merged normally into the task
   branch so its evidence travels with the PR. Its
   `docs/work/research/owner-decisions-2026-11-08.md` records the owner
   decisions; `ecosystem-ranking-2026-11-08.md` and the three source reports
   record the ranking and the Hex evidence checked on 2026-11-08. The afternoon
   "Product facts" table supersedes conflicting earlier answers in the same file.
2. `docs/capability-model.md` admission rules, `docs/capability-coverage.md`
   cases C1–C9, `docs/plans/roadmap.md` and `release-plan.json` jobs and
   dispositions, and `docs/development/08-upstream-and-forks.md`.
3. Hex metadata re-read at task time for every package a record relies on.

## Scope

- Add `docs/plans/catalogue-dispositions.md` with exactly one anchored record
  per planned or deferred ID, and link it prominently from `docs/catalogue.md`
  and `docs/plans/roadmap.md` where builders start reading. Record the owner's
  admission rule in both documents: every planned and deferred entry is part of
  the build plan; demand-led admission applies only to gaps outside the
  catalogue; adopt a maintained library by default and copy or clean-room only
  for a concrete recorded reason.
- Register ELZ-050 as a published job in `docs/plans/release-plan.json` with
  no outputs, and regenerate the views with `check-roadmap.py --write`.
- Each record carries: stable ID, current status and responsibility;
  disposition (ADOPT, WRAP, FORK, CLEAN-ROOM or REJECT as the ranking defines
  them) with reason and explicit conditions; the chosen library, exact version
  and license, or the named clean-room idea sources and their copying limits;
  a link to the exact owner decision it rests on, with owner decisions kept
  distinct from reviewer inference and open proposals; dependencies on other
  catalogue IDs, each marked ready, planned or deferred, in an acyclic order;
  the concrete caller and invariant, or the honest statement that no caller
  exists and the resulting conditional decision; Needs and boundary limits
  that a later Contract draft must respect; open questions with the named
  decision owner and the next action.
- Apply the recorded owner choices: ReqLLM calling Anthropic directly with the
  key as a Need and no gateway process (TensorZero excluded); metering from
  ReqLLM per-call usage through the ready Store; MinIO through the S3 API only
  with req_s3 first; AshAuthentication for identity; Claude Code CLI and Codex
  CLI as OS processes through the ELZ-029 boundary; Swoosh with plain SMTP
  first; carbonite compared with ash_paper_trail for the ELZ-023 decision
  record as the first audited mutation; Phoenix LiveView as UI host; payments
  provider and message broker left as explicit open questions; replication,
  CRDT, FHIR and media conditional with no caller. Jido is disposed module by
  module as the owner record states; a literal copy of a named Jido module
  needs the owner to name it.
- Re-verify every relied-on package against Hex (latest version, release date,
  license, retirement) with a small read-only script whose output is committed
  beside the records with its UTC time. A draft survey claim is not evidence.
- Run a coverage check that compares record IDs with the planned and deferred
  IDs in the actual registry: exactly one record each, all required fields
  present, dependency references resolve, no cycles. Commit the check output.
- Keep `python3 scripts/check-roadmap.py` plain and `--live` green. Where the
  ranking order and the actual dependencies or accepted decisions disagree,
  record the disagreement; do not invent readiness or silently reorder.

## Acceptance

- [ ] `docs/plans/catalogue-dispositions.md` exists with one anchored record
      per planned or deferred ID at the task base, and the coverage check
      output committed beside it reports no missing, duplicate or unresolved
      reference.
- [ ] Every record names disposition, reason, library/version/license or
      clean-room idea source, owner-decision link, dependencies with their
      statuses, caller and invariant or an explicit no-caller statement, Needs
      and limits, and open questions with owner and next action.
- [ ] The Hex re-verification output is committed with its UTC time, and every
      version and license named in a record matches it.
- [ ] `docs/catalogue.md` and `docs/plans/roadmap.md` link to the records.
- [ ] `python3 scripts/check-roadmap.py` and `--live` pass; `python3
      scripts/check-claims.py` passes; `git diff --check` is clean.
- [ ] No change under `registry/`, `pieces/`, `lib/`, `test/`, `LEDGER.md`,
      `mix.exs`, `mix.lock` or `.github/`; the research branch content arrives
      only through a normal merge.

## Evidence and limits

Documentation checks only: roadmap plain and live, claims, whitespace, local
links, the coverage check and the Hex re-read. No `mix check` claim is made
or required unless a non-documentation path changes. Research and Hex
metadata are inputs; they do not establish a tested provider boundary,
readiness or an adoption badge. A disposition is an admission decision that a
later published task must still carry through Contract review, evidence and
merge under AGENTS.md. Payments provider and message broker remain open owner
questions; "decision-ready" records that fact rather than hiding it.

## Out of scope

Implementation of any entry; readiness promotion; registry, manifest or
ledger edits; new Piece IDs; publication of ELZ-051 to ELZ-055 or any other
task. The research branch `research/ecosystem-survey` is deleted only after
this task's PR is merged, as part of acceptance cleanup.

## Reference

Owner decisions and ranking on `research/ecosystem-survey` at `409d543`;
capability model and coverage cases; roadmap policy on index-only
dispositions; AGENTS.md "Before expanding the catalogue".
