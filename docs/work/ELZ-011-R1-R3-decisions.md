# ELZ-011 focused-review owner decisions R1–R3

Status: proposed decisions, not applied. Independent focused review at
`7766446c40a88ad2be60ee51aaef59deb8e76c06` is **NOT YET CLEAR**.
Reviewer session `0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch
`ctx_4b5c11a942ed`. [Full report](ELZ-011-focused-review.md).
D1/D2/D5, H1/H4 and medium findings are closed or tracked as production gates.
The reviewer states implementation may start once root accepts R1–R3; this is
not acceptance of unimplemented production or permission to skip G1–G9.

## R1 — recommend option B, explicit wording amendment

Use the wrapper proposed and reviewed, with exact language instead of an
interpretation note that reverses "carried in". No duplicate Envelope fields,
no executor, and assembly must consume it at admission.

Before:
`- core/effect is a data-only declaration (capability_id, operation, classification) carried in an Envelope command.`

After:
`- core/effect is a data-only declaration (capability_id, operation, classification) that wraps an unchanged, separately validated Envelope command.`

The remainder of the existing bullet is unchanged. Exact diff:
[patch](ELZ-011-R1-contract-proposed.patch); full proposed after body:
[body](ELZ-011-R1-contract-proposed.md). If approved, post the diff on #11
before editing its body, then synchronize task and scoped roadmap body hash.

## R2 — accept priority quarantine row

A late authenticated completion contradicting no-send can leave an intent
quarantined while Dispatched. Its pure policy preserves that phase even on
expiry; polling and snoozing would otherwise continue without termination.

Before: no Intended/Dispatched quarantine row in the frozen job table;
clarification 2 says `check quarantined before any dispatch/rearm`.

After: insert this exact priority row before every Intended/Dispatched row:

`| Phase Intended or Dispatched, flags.quarantined | none (no dispatch, no poll) | {:cancel, :operator_required} |`

Clarification 2 becomes `check quarantined before any dispatch/rearm/poll;
quarantined Intended or Dispatched cancels with operator_required`.
The existing Definite quarantine/disarm rule remains. Test the real late
contradictory completion sequence, cancellation and no additional Adapter/poll
entry on PostgreSQL. The ready EffectIntent Contract/source stays unchanged.

## R3 — accept minimum delay for every scheduled poll

Before (clarification 3):
`First scheduled poll delay is at least ceil(total_ms/1000)+1 seconds;`

After:
`Every scheduled poll delay, first and later, is at least ceil(total_ms/1000)+1 seconds;`

Before (proposal range): `polling delay 1..30 s`

After: `polling delay ceil(total_ms/1000)+1 .. 30 s`

Apply this consistently to the proposal and frozen table explanation, including
polling and task_start snoozes. Keep finite grace, the <=512 arithmetic and its
explicit limitation for concurrent/rescued wakes and pre-deadline polls.
The optional admission-window cap is not added by this recommendation.

## Binding production gates G1–G9

Adopt the review's gates without weakening them:

1. Exact preflight chronology; any combined timer expiry is unknown; separate
   bounded supervisor for the inner request, not the owner's one-slot supervisor.
2. Context origin must match binding provider_account at construction and every
   send; mismatch typed pre-Req failure, with changed-origin negative control.
3. Freeze Envelope admission mapping: kind command, host tenant, logical-reference
   field, deadline source, payload binary equal to PUT bytes, exact capability
   and operation match, trusted classification refused or downgraded.
4. Same raw-byte/duplicate/depth/node validation for request body; control
   characters rejected in receipt identity/kind or opaque kinds never logged.
5. Real authenticated completion to Confirmed on PostgreSQL; forged key/digest/MAC
   refusal retention, duplicate/late completions; no validation stub.
6. Host Lifeline/orphan executing recovery, live rescue and duplicate wakes.
7. Bounded runner caller tasks; timed-out dispatch then retry yields one send.
8. Full actual-source mutations, including a PUT retry mode that actually retries,
   redirect, atomization, trust, retention, ack, identity, bypassing intent.
9. Fresh pinned setup/full check, copy and aggregate exports, independent diff review.

These summaries do not replace the exact G1–G9 text in the linked report.
No new task/Contract/proposal behavior has been applied by this decision packet.

## Evidence and limits

Reviewer independently reproduced PostgreSQL 8 passed, timing/JSON 21 passed,
and expected-mutant wrapper exit 0; source hashes, dependency ancestry and
roadmap plain/live pass. New quarantine counterexample used Memory; production
regression must use PostgreSQL. No full mix check or whole HTTP/Oban production
pipeline is claimed. The historical unified patch contains intentional context
lines with a trailing space, so git diff --check across the full base-to-head
range flags that patch text; ordinary working-tree diff checks are clean.
