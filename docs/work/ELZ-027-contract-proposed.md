# ELZ-027 proposed Contract amendments (issue #44)

Prepared by worker session `ba44606d-07d3-4747-b49a-3d8f4f770de1` after the
independent early review ([exact report](ELZ-027-early-review.md), finding
BLOCKING 1 and gate G1) and the focused re-review
([exact report](ELZ-027-early-rereview.md)). A1 was approved and applied at
`c2c47af` (issue comment 6723353344). A1-rev2 and A2 wait for the main
coordinator. The worker does not edit the issue body or the task
copy; the main coordinator decides and names who applies the text and the
roadmap hash. Until the pending decisions the branch holds no implementation.

## A1 — offline versus live classification (APPLIED at c2c47af)

Status: approved by the main coordinator and applied to issue #44 and the task
copy in commit `c2c47af`. Kept here as the record of the first wording; the
re-review asks for the tighter text in A1-rev2 below.

Location: issue body, section "Admission record", item 2 "Interface and
invariant", inside the Invariants sentence.

Before (the text before `c2c47af`; the issue source wrapped it over three
lines, with a line break after "those"):

> due slots that passed while offline (those between the last recorded instant and now) become occurrences only under `queue`

After (the reviewer's proposed wording, adopted without change):

> The caller identifies each due slot passed while the scheduler was offline as an offline catch-up slot, using its retained last recorded instant and availability boundary; an offline catch-up slot becomes an occurrence only under `queue`, subject to its bound. Slots identified as live use the declared overlap policy. The caller supplies the availability boundary; elapsed time or a grace period alone does not establish whether a slot was offline.

Reason: the current text has no discriminator between a slot that passed
while the scheduler was unavailable and an ordinary already-due live slot. The
early proposal's grace setting inferred that distinction from elapsed time,
which the review rejected. The amendment makes the availability boundary a
caller-supplied input. The piece fails closed: without a valid boundary
(`available_since_unix_ms` with `available_since_unix_ms <= now_unix_ms`) no
slot is classified and the call returns an error. No grace policy is proposed.

The inputs sentence "the current instant from a clock port" was not changed by
A1; A2 below corrects the clock-port description in item 6.

## A1-rev2 — single-boundary precondition and fail-closed refusal (re-review, REWORD)

Location: issue body, Admission record item 2, the sentences inserted by A1.
The exact raw text now live (three lines of the wrapped source are quoted as
one paragraph; the live body wraps at the same indent):

Before (exact, the text now live):

> The caller identifies each due slot passed while the scheduler was offline as an offline catch-up slot, using its retained last recorded instant and availability boundary; an offline catch-up slot becomes an occurrence only under `queue`, subject to its bound. Slots identified as live use the declared overlap policy. The caller supplies the availability boundary; elapsed time or a grace period alone does not establish whether a slot was offline.

After (the re-reviewer's proposed exact text, adopted without change):

> The caller supplies an availability boundary for each admission call and is responsible for establishing that every unrecorded due slot before that boundary passed while the scheduler was offline and that the scheduler was continuously available from the boundary through the current instant. A due slot before the boundary is an offline catch-up slot and becomes an occurrence only under `queue`, subject to its bound; a due slot at or after the boundary follows the declared overlap policy. If the caller cannot establish this classification or supply a valid boundary no later than the current instant, the call is refused without classifying slots or changing state. Elapsed time or a grace period alone does not establish whether a slot was offline.

The surrounding sentences ("match an unsettled occurrence." before and "The
overlap decision is recorded, never silent." after) stay as they are now.

Reason: one boundary classifies an interval correctly only when the caller
can establish uninterrupted availability from the boundary through now and
that every earlier unrecorded slot was offline. The text makes that caller
obligation and the fail-closed refusal explicit. The piece can validate the
number, not the truth; the caller declares it.

## A2 — composition record (re-review BLOCKING 2)

Location: issue body, Admission record item 6.

Before (exact raw text, including line breaks):

```text
6. **Composition record.** Depends on the ready delivery/time recipe (clock port; no open task
   owns it), core/envelope
   result schema and delivery/idempotency on the consumer side; durable
   occurrences compose with ELZ-009 once available (volatile until then).
   Data classification: schedule metadata only.
```

After (proposed exact text):

```text
6. **Composition record.** The current instant and the availability boundary
   are caller-supplied Needs of each admission call; the ready delivery/time
   recipe is an OTP timer recipe that can drive admission ticks and is not a
   clock port or a dependency of this slice. Depends on core/envelope for the
   result schema that settles an occurrence (`completed` acknowledges,
   `rejected` and `failed` release, `timed_out` and `unknown` settle nothing)
   and on delivery/idempotency on the consumer side for suppressing repeated
   admitted deliveries of one occurrence; both are exercised by executable
   translation tests at those boundaries. Durable occurrences compose with
   ELZ-009 once available (volatile until then). Data classification:
   schedule metadata only.
```

Reason: `delivery/time` is a timer recipe (Process.send_after and
cancellation references), not a wall-clock port; the slice takes the instant
and the boundary as inputs. The two consumer-side compositions stay and become
executable: the piece ships translation functions and tests against the real
`Elzoo.Envelope.validate_result/1` result schema and the real
`Cure.Elzoo.Idempotency.receiver/2`, and declares both Pieces as
dependencies. The amendment removes only the unsupported clock-port and
dependency claim and keeps the consumer-side responsibility.

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
- "Misfire" in the dispatch wording is the offline catch-up slot of A1; no
  separate misfire threshold exists.
- The C1 caller of the issue is the invitation expiry sweep (a one-shot
  schedule); the C1 acceptance webhook of the wider disposition is not part of
  this slice.
