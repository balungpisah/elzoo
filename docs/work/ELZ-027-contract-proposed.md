# ELZ-027 Contract amendments record (issue #44)

Prepared by the implementation worker. Reviews:
[early review](ELZ-027-early-review.md), [re-review](ELZ-027-early-rereview.md),
[round 3](ELZ-027-early-rereview3.md). The worker edited the issue body only
on the main coordinator's explicit approval and in the order the pieces
coordinator prescribed; every edit has an issue comment with the exact
before/after text, and the task copy and the ELZ-027 `issue_body_sha256` were
synced in the same commit. Quotations below are raw issue source with the
issue's own line wraps and three-space indentation, so a literal substring
comparison against the historical and live bodies is true.

| Amendment | Status | Issue comment | Commit |
| --- | --- | --- | --- |
| A1 | applied, later superseded by A1-rev2 | 6723353344 | `c2c47af` |
| A1-rev2 | applied and live | 6723459763 | `bbc0eff` |
| A2 | withdrawn, never applied | none | none |

## A1 — offline versus live classification (applied `c2c47af`, superseded)

Location: Admission record item 2, Invariants. The replaced clause sat inside
a semicolon list; the two separators around it became sentence boundaries, as
recorded in the issue comment.

Before (raw issue source as published, body SHA-256
`48a50ec8c43d81a3adcb797b6e82ca5971e1c38893f8258303cfd12f158331da`):

```text
   match an unsettled occurrence; due slots that passed while offline (those
   between the last recorded instant and now) become occurrences only under
   `queue`; the overlap decision is recorded, never silent.
```

After (raw issue source as applied by A1, body SHA-256
`d6333de4e63831e35cd36aa2b2abfbf42912840191751b256db105ef7b90f4c6`):

```text
   match an unsettled occurrence. The caller identifies each due slot passed
   while the scheduler was offline as an offline catch-up slot, using its
   retained last recorded instant and availability boundary; an offline
   catch-up slot becomes an occurrence only under `queue`, subject to its
   bound. Slots identified as live use the declared overlap policy. The caller
   supplies the availability boundary; elapsed time or a grace period alone
   does not establish whether a slot was offline. The overlap decision is
   recorded, never silent.
```

Reason: the published text had no discriminator between a slot that passed
while the scheduler was unavailable and an ordinary already-due live slot. The
revision 1 grace setting inferred that distinction from elapsed time, which the
early review rejected. A1 made the availability boundary a caller-supplied
input and the piece fail closed without it.

## A1-rev2 — single-boundary precondition and fail-closed refusal (applied `bbc0eff`, live)

Location: the same region. The re-review asked for text that makes the
single-boundary availability precondition and the fail-closed refusal
explicit; the main coordinator approved it.

Before (raw issue source, identical to the A1 after block above):

```text
   match an unsettled occurrence. The caller identifies each due slot passed
   while the scheduler was offline as an offline catch-up slot, using its
   retained last recorded instant and availability boundary; an offline
   catch-up slot becomes an occurrence only under `queue`, subject to its
   bound. Slots identified as live use the declared overlap policy. The caller
   supplies the availability boundary; elapsed time or a grace period alone
   does not establish whether a slot was offline. The overlap decision is
   recorded, never silent.
```

After (raw issue source now live, body SHA-256
`1d1ea7504ebc53d39bb525906103771433a485d32b8e7a50eb132e8914393c22`):

```text
   match an unsettled occurrence. The caller supplies an availability boundary
   for each admission call and is responsible for establishing that every
   unrecorded due slot before that boundary passed while the scheduler was
   offline and that the scheduler was continuously available from the boundary
   through the current instant. A due slot before the boundary is an offline
   catch-up slot and becomes an occurrence only under `queue`, subject to its
   bound; a due slot at or after the boundary follows the declared overlap
   policy. If the caller cannot establish this classification or supply a
   valid boundary no later than the current instant, the call is refused
   without classifying slots or changing state. Elapsed time or a grace period
   alone does not establish whether a slot was offline. The overlap decision
   is recorded, never silent.
```

Reason: one boundary classifies an interval correctly only when the caller can
establish uninterrupted availability from the boundary through now and that
every earlier unrecorded slot was offline. The text makes that caller
obligation and the fail-closed refusal explicit. The piece validates the
number, not the truth; the caller declares it and refrains from admission (or
is refused) when it cannot.

## A2 — composition record (withdrawn, not proposed)

The main coordinator decided that the live composition statement of Admission
record item 6 stands and must be tested as written: the `core/envelope` result
schema, consumer-side `delivery/idempotency`, and the `delivery/time` recipe
as the clock port. No wording change is proposed. The earlier draft that
described `delivery/time` differently is withdrawn; the executable composition
is specified in `ELZ-027.md`. If a statement proves untestable as written
during implementation, an exact before/after is sent as a separate item.

## Clarifications that need no wording change

Recorded so the coordinator can object; accepted by the main coordinator with
A1 except where the re-review corrected them:

- The result schema refines the listed outputs with explicit recorded
  decisions: `already_recorded{slot}` for a slot at or below the watermark
  (no occurrence id is asserted, because the slot may have been skipped or
  decided under an older generation), `skipped{slot, offline_catch_up |
  overlap | queue_full}`, `occurrence{id, live | offline_catch_up}`,
  `replaced{old id, new id}`, `rejected{stale_generation | unknown_occurrence |
  payload_mismatch | schedule_mismatch | invalid_schedule}`, and a batch-level
  refusal `not_due` for a slot after `now`. Every listed output of the issue
  keeps its meaning; nothing is silent.
- "Misfire" in the dispatch wording is the offline catch-up slot of A1-rev2; no
  separate misfire threshold exists.
- The C1 caller of the issue is the invitation expiry sweep (a one-shot
  schedule); the C1 acceptance webhook of the wider disposition is not part of
  this slice.
