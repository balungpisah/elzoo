# ELZ-028 — Contract amendments for issue #45 (approved by main; not yet applied)

Written by the ELZ-028 worker. Status after the round-4 re-review
([ELZ-028-early-rereview4.md](ELZ-028-early-rereview4.md)) and the main
coordinator's decision relayed by the pieces coordinator: the **reviewer's
reworded texts** for B1, B3a, B3b and R3 replace the worker's originals, and
one more checkbox amendment (B3c) is added at main's request. A1, A3 and A6
stand as accepted. A2, A4 and A5 remain withdrawn. The worker applies nothing
live until the pieces coordinator confirms CLEAR; then all accepted texts are
applied to the live issue and the task copy in one commit by the usual
procedure (exact diff comment, `gh issue edit`, task copy bytewise,
release-plan hash, roadmap views).

Every "before" text is a byte-exact substring of the live body fetched on
2026-11-08 (`gh issue view 45 --json body`), including hard line wraps and
three-space continuation indents; a script checked that each occurs exactly
once. The "after" texts are given as the reviewer and main approved them; the
applying coordinator re-wraps them with the body's three-space continuation
and keeps the list delimiters (`;` inside the invariant list), without
changing any word.

## A-amendments (accepted)

### A1 — `claim_expired` candidates

- **Before:** `claim_expired{owner, ttl, limit}`, and the store clock.
- **After:** `claim_expired{owner, ttl, limit, candidates}` (the caller
  supplies the bounded candidate keys; key discovery is a caller Need), and
  the store clock.

### A3 — attributable release

Exact before:

```text
stale and
   ambiguous (`renew` timestamp in the future or
   unreadable) fail closed and their
   release is an explicit, attributable record
```

Exact after:

```text
stale and
   ambiguous (`renew` timestamp in the future or
   unreadable) fail closed and their
   release is an explicit, attributable record naming the releasing actor,
   the prior owner when knowable, and the reason; a replacement claim may
   record that release atomically in the same transaction
```

### A6 — `claim_expired` does not take free keys

Exact insertion anchor (single occurrence, replaced):

```text
   cross-store agreement, authorization.
```

Exact after:

```text
   cross-store agreement, authorization. `claim_expired` admits only keys
   whose lease is stale (expired); a key that is free (never held or
   explicitly released) is reported as refused `free` and is claimed with
   `claim`.
```

## B-amendments (reviewer's reworded texts, approved by main)

### B1 — sampled-time rule for "renew extends only a live lease"

Exact before:

```text
`renew` extends only a live lease, so a renewal
   issued before a handoff and applied after it cannot revive it;
```

Exact after (reviewer's text, verbatim):

```text
`renew` extends only a lease that is live at the store-clock sample taken under the key's head lock within the transaction recording the change; a renewal issued before a handoff and evaluated after the handoff cannot revive the prior lease. A renewal sampled before expiry may commit after expiry; an unlocked status or hold may report the prior lease stale before that commit and report the renewed lease active afterwards. A renewal sampled at or after expiry is refused and records nothing. The same sampled-time rule applies to the active holder's re-claim; a reader reports a recorded stamp later than its own sample as ambiguous.
```

Accepted qualification (main): a renewal sampled before expiry may commit
after expiry, and unlocked readers may see the prior lease stale before that
commit; the sample is **not** called the linearization point of the combined
object. Design: ELZ-028.md §2.2, §2.4, tests LS8, LS8b, LS8c, LS26.

### B3a — exclusive live ownership instead of disjoint result sets

Exact before:

```text
`claim_expired` results are disjoint across concurrent claimers;
```

Exact after (reviewer's text, verbatim):

```text
`claim_expired` never grants the same key to two concurrently live lease owners. Overlapping invocations may both return the same key only when the earlier grant has ceased to be live before the later grant, and then the grants carry different record-revision fences; their result sets are not necessarily disjoint.
```

### B3b — the sweep transaction law is established on the provider

Exact before:

```text
Tests on the double and the selected provider: concurrent
   `claim_expired` disjointness, renewal after handoff, write with expired
   lease refused by revision, claim-next-ready under one transaction.
```

Exact after (reviewer's text, verbatim):

```text
Tests on the double and the selected provider: concurrent `claim_expired` ownership and repeated-key fence revisions, renewal after handoff, write with expired lease refused by the old revision after a replacement, and claim-next-ready under one database transaction on the selected provider. The volatile double serializes its sweep through one shared owner but does not roll back prior per-key commits after a later failure; it exercises the same scenarios and separately tests and reports this partial-commit limit.
```

### B3c — acceptance checkbox aligned with B3a (added at main's request)

Exact before:

```text
- [ ] Concurrent `claim_expired` never hands one key to two owners (test).
```

Exact after:

```text
- [ ] Concurrent `claim_expired` never hands one key to two concurrently live owners (test).
```

### R3 — the expired-holder checkbox, narrowed

Exact before:

```text
- [ ] A write from an expired lease holder is refused by revision (test).
```

Exact after (reviewer's text, verbatim):

```text
- [ ] A write using an expired holder's old fence is refused by revision after a replacement or other record has moved the head (test); if the head has not moved, expiry alone is not detected by the revision and does not by itself refuse that write (documented limit with a control test).
```

### B4 — non-holder completion (new; requested by confirmation point 1)

Exact before:

```text
completion from a non-holder is rejected by the record
   revision (the fencing value), never by timestamp comparison.
```

Exact after:

```text
completion from a non-holder presenting the fence of its superseded lease is rejected by the record revision (the fencing value), never by timestamp comparison; the revision cannot distinguish a writer that obtained the current revision outside the lease interface, which is a consumer bypass outside this Contract.
```

Why an amendment and not only a design restriction: the lease interface
hands the fence only to the holder, so every non-holder that uses the
interface is refused by revision after a takeover (LS4, LS20); but a writer
that reads the head directly and presents the current revision is accepted
by the ready Store, which cannot know who holds the lease and compares no
owner string. Restricting "non-holder" only inside the design would leave the
Contract promising a rejection the Piece cannot deliver against that bypass;
the R3 checkbox was narrowed for the same reason. The design records the
limit (ELZ-028.md §2.5, §2.8) until main decides.

## Reconciliations required by the decision

**G1/G2 wording.** The gates in ELZ-028.md §9 are kept verbatim as adopted
text. Under the approved amendments their terms are read as follows, and
this reading is recorded next to the gates in §9: "live-only renewal" means
live at the store-clock sample taken under the key's head lock within the
transaction recording the change (B1); "atomic condition/change" and "the
actual atomic point" mean that sample, the decision and the record change
are in one database transaction under the head lock on the provider, and in
one serialized owner section on the double; "disjoint claims" means no key
granted to two concurrently live owners, with repeated keys across
overlapping invocations carrying different fence revisions (B3a, B3c);
"claim-next-ready transaction" means one database transaction on the
selected provider, with the double exercising the scenarios and reporting
its partial-commit limit (B3b). A decision accepting these qualifications is
not evidence that the older, stronger reading held.

**Non-holder completion sentence.** With amendment B4 the sentence states
what the design delivers: `complete/4` is admitted by the fence alone (an
old fence is refused once any record moved the head; no owner string is
compared; a bypass presenting the current revision is outside the Contract);
the regression gate on the terminal
path refuses when the store-clock sample is earlier than the latest recorded
stamp, which is a fail-closed guard against a regressed store clock applied
to every operation except `seize` and to holders and non-holders alike, not
a holder/non-holder decision by timestamp and not an expiry check on the
completing writer. The narrowed R3 checkbox states what the revision can and
cannot detect.

## Withdrawn

- **A2**, **A4**, **A5**: withdrawn in rounds 2–3; superseded by B3b, R3 and
  B1 respectively.

## Not a Contract amendment: ownership decision OD-1

Decided by main: **Option L** with two conditions, recorded as gates OD-1a and
OD-1b in ELZ-028.md §7. Option S rejected.

## Not proposed

- No change to the state owner, the terminal-release law, the "one atomic
  step" law, the "never by timestamp comparison" sentence or the non-goals.
- No new library, fork or dependency.
