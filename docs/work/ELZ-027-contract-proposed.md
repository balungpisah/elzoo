# ELZ-027 proposed Contract amendments (issue #44)

Prepared by worker session `ba44606d-07d3-4747-b49a-3d8f4f770de1` after the
independent early review ([exact report](ELZ-027-early-review.md), finding
BLOCKING 1 and gate G1). The worker does not edit the issue body or the task
copy; the main coordinator decides and names who applies the text and the
roadmap hash. Until approval the branch holds no implementation.

## A1 — offline versus live classification (required by BLOCKING 1 / G1)

Location: issue body, section "Admission record", item 2 "Interface and
invariant", inside the Invariants sentence.

Before (exact current text):

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

Matching inputs sentence (no text change needed): "the current instant from a
clock port" stays; the boundary is passed with it in the same arrival input.

## Clarifications that need no wording change

These stay within Scope item 1 ("define the pure occurrence transition and
result schema") and are recorded here so the coordinator can object:

- The result schema refines the listed outputs with explicit recorded
  decisions: `already_recorded{occurrence id}` for a slot at or below the
  watermark (the second activation of one slot), `skipped{slot, offline_catch_up
  | overlap | queue_full}`, `occurrence{id, live | offline_catch_up}`,
  `replaced{old id, new id}`, `rejected{stale_generation | unknown_occurrence |
  payload_mismatch | schedule_mismatch | invalid_schedule}`, and a batch-level
  refusal `not_due` for a slot after `now`. Every listed output of the issue
  keeps its meaning; nothing is silent.
- "Misfire" in the dispatch wording is the offline catch-up slot of A1; no
  separate misfire threshold exists.
- The C1 caller of the issue is the invitation expiry sweep (a one-shot
  schedule); the C1 acceptance webhook of the wider disposition is not part of
  this slice.
