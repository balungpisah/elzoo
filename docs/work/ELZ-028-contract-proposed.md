# ELZ-028 — proposed Contract clarifications for issue #45 (not applied)

Written by the ELZ-028 worker after the early review
([ELZ-028-early-review.md](ELZ-028-early-review.md)). The worker does **not**
edit the issue body or the task copy. Each amendment gives the exact current
text and the exact proposed text; the main coordinator decides, and an
authorized coordinator applies accepted amendments to the live issue, the
task copy and the roadmap hash. Where the reviewer proposed wording (R1, R2),
that wording is used unchanged. Every amendment is additive or a
clarification; no law is weakened.

## A1 — `claim_expired` candidates (reviewer R1 wording)

Section: Admission record 2, "Interface and invariant", inputs.

- **Before:** `claim_expired{owner, ttl, limit}`, and the store clock.
- **After:** `claim_expired{owner, ttl, limit, candidates}` (the caller
  supplies the bounded candidate keys; key discovery is a caller Need), and
  the store clock.

Reason: the ready Store has no cross-stream index; a WRAP cannot enumerate
keys. Discovery stays with the Assembly (ELZ-010's submission stream, a
product table).

## A2 — "claim-next-ready under one transaction" (reviewer R1 wording, appended)

Section: Admission record 5, "Failure and evidence", the sentence "Tests on
the double and the selected provider: concurrent `claim_expired`
disjointness, renewal after handoff, write with expired lease refused by
revision, claim-next-ready under one transaction."

- **Before:** (sentence kept unchanged).
- **After:** the same sentence, followed by: "For the selected caller, define
  the ready predicate and demonstrate that selecting a ready key and
  recording its claim share the required transaction; candidate enumeration
  and any partial batch outcomes are explicitly specified."

Worker's proposed specification under that sentence (for the coordinator to
accept, amend or reject; it is the design of
[ELZ-028.md §2.8](ELZ-028.md)):

- ready predicate: `ready(key) := status(key) = stale` (an expired lease);
  free (never held or released) keys are **not** ready for `claim_expired`
  (see A6);
- the transaction: for one key, readiness is evaluated on the committed
  records at head revision `r` and the claim is the Store CAS at `r`; the
  selection and the claim therefore share one atomic step per key;
- candidate enumeration: supplied by the caller (A1), evaluated in list
  order, at most 1_000 keys, stopping after `limit` claims;
- partial batch outcomes: the batch is **not** one transaction; keys claimed
  before a crash remain claimed and are reported `active` to later
  invocations; two invocations with overlapping candidates never hold the
  same key at the same revision; a key released and reclaimed while an
  invocation runs can appear in two invocations' results only with
  different fence revisions; the result lists the keys held, refused (with
  reason), errored and skipped (never evaluated because `limit` was reached).

## A3 — attributable release (reviewer R2 wording)

Section: Admission record 2, invariants.

- **Before:** "stale and ambiguous (`renew` timestamp in the future or
  unreadable) fail closed and their release is an explicit, attributable
  record".
- **After:** "stale and ambiguous (`renew` timestamp in the future or
  unreadable) fail closed and their release is an explicit, attributable
  record naming the releasing actor, the prior owner when knowable, and the
  reason; a replacement claim may record that release atomically in the
  same transaction".

Worker's note: the design records `lease_released{owner: prior-or-null, by,
at, reason}` with a closed set of reason codes (no free text, so the data
classification stays "owner identifiers only"), appended in the same CAS
batch as the replacement `lease_claimed` or `lease_seized`. Ambiguous keys
admit only `seize`; the holder's owner string grants nothing when the
record is unreadable, regressed, pruned or stamped in the future.

## A4 — expired-holder write versus "the lease never authorizes a write"

Section: Acceptance, first checkbox, and Admission record 2.

- **Before (kept pending the decision):** "A write from an expired lease
  holder is refused by revision (test)."
- **Proposed clarification (appended to the invariant list, the checkbox
  kept):** "A write from an expired lease holder is refused by revision as
  soon as a replacement (claim, seize or any other record) has moved the
  head; while no record has moved the head, the expired holder's fenced
  write still commits, because the lease never authorizes or refuses a write
  and the revision cannot observe elapsed time. The fence is a staleness
  detector, not an identity or authorization token."

Reason (reviewer R3): the two existing sentences can be read as
contradictory; the design implements the second reading and reports the
no-takeover case as a control, not as satisfying the checkbox.

## A5 — "one atomic step" in store time

Section: Admission record 2, invariants, "lease condition and record change
are checked in one atomic step".

- **Before:** "lease condition and record change are checked in one atomic
  step".
- **After:** "lease condition and record change are checked in one atomic
  step: the store-clock reading the condition used is recorded in the
  committed record, the record change is fenced by the head revision the
  condition was evaluated at, and readers re-derive liveness from the
  recorded stamps (a renewal stamped at or after the previous expiry never
  extends the lease). No SQL statement observes the commit instant
  (PostgreSQL `now()` is the transaction start time), so a renewal is
  admitted only with a grace margin that bounds the stamp's age at commit
  under the Store write timeout."

Reason (reviewer B1): makes the store-time semantics of the invariant
explicit instead of leaving "atomic step" open to a reading that no SQL
design can satisfy; the design in [ELZ-028.md §2.2–2.4](ELZ-028.md)
implements exactly this text. If the main coordinator prefers the row-lock
reading (clock evaluated under the Store's head lock), the WRAP over the
ready Store cannot provide it and a scope/ownership decision on a Store-level
operation is needed before implementation.

## A6 — `claim_expired` does not take free keys

Section: Admission record 2, outputs/inputs (clarification).

- **Before:** (no statement).
- **After (appended):** "`claim_expired` admits only keys whose lease is
  stale (expired); a key that is free (never held or explicitly released) is
  reported as refused `free` and is claimed with `claim`."

Reason (reviewer R1): the issue did not say whether never-held keys qualify;
the narrow reading keeps "expired" literal and keeps `claim` the only path
to a free key.

## Not proposed

- No change to the state owner, the non-goals, the renewal law, the
  disjointness law, the terminal-release law or the "never by timestamp
  comparison" sentence.
- No new library, fork or dependency.
