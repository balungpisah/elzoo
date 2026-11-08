# ELZ-028 — proposed Contract clarifications for issue #45 (not applied)

Written by the ELZ-028 worker; revised after the focused re-review
([ELZ-028-early-rereview.md](ELZ-028-early-rereview.md)). The worker does
**not** edit the issue body or the task copy. The main coordinator decides;
an authorized coordinator applies accepted amendments to the live issue, the
task copy and the roadmap hash. "Before" texts are byte-exact substrings of
the live body as the re-review quoted them (literal line breaks and
three-space continuation indents).

## Kept

### A1 — `claim_expired` candidates (reviewer R1 wording; re-review: ACCEPTABLE)

Section: Admission record 2, inputs. The before text occurs once in the
live body.

- **Before:** `claim_expired{owner, ttl, limit}`, and the store clock.
- **After:** `claim_expired{owner, ttl, limit, candidates}` (the caller
  supplies the bounded candidate keys; key discovery is a caller Need), and
  the store clock.

Reason: the Store has no cross-stream index; discovery stays with the
caller. Under the revision-3 design the sweep over the candidates is one
transaction (ready selection and claim together), so this amendment adds the
input without touching the "claim-next-ready under one transaction" law.

### A3 — attributable release (re-review: REWORD; reviewer's byte-exact text)

Section: Admission record 2, invariants.

Exact before (literal line breaks and spaces):

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

Reason: the design records `lease_released{owner: prior-or-null, by, at,
reason}` with a closed set of reason codes in the same transaction as the
replacement `lease_claimed` or `lease_seized`; the original law is preserved
and made explicit.

### A6 — `claim_expired` does not take free keys (re-review: REWORD; reviewer's byte-exact anchor)

Section: Admission record 2, non-goals sentence. Replace the single
occurrence of the anchor below.

Exact insertion anchor:

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

Reason: the issue did not say whether never-held keys qualify; the narrow
reading keeps "expired" literal. This does not decide disjointness or the
transaction law, which the revision-3 design satisfies directly.

## Withdrawn (re-review: REJECT)

- **A2** ("claim-next-ready under one transaction"): withdrawn. The
  revision-3 design performs ready selection and claim inside one
  transaction on both stores (ELZ-028.md §2.4), so the existing evidence
  sentence stands as written and needs no substitute. The overlapping-result
  semantics described in revision 2 are withdrawn; one invocation is one
  transaction and concurrent invocations are disjoint.
- **A4** (expired-holder write): withdrawn. The acceptance checkbox "A write
  from an expired lease holder is refused by revision (test)" is kept
  unchanged and is satisfied by scenario LS4 (expired holder, replacement
  claimed, holder's write refused by revision). The no-takeover behaviour is
  recorded as a Piece limit, not as a Contract change.
- **A5** ("one atomic step" in store time): withdrawn. The revision-3 design
  checks the store-clock condition and changes the record inside one
  transaction under the head row lock (PostgreSQL) and inside one serialized
  step (Memory), so the invariant is met as written.

## Not a Contract amendment: ownership decision OD-1

The design needs an ownership decision, not an issue edit: may `state/lease`
own Adapters that act on the `integration/sql` tables (`elzoo_log_heads`,
`elzoo_log_records`, migration version 1, under the Store's prefix) for lease
operations, while the holder's state writes keep using the ready Store's
public `append`? Options and consequences are in ELZ-028.md §1.2 (Option L
recommended; Option S changes the ready Store's Contract under a separate
task). The worker implements nothing before this decision.

## Not proposed

- No change to the state owner, the renewal law, the disjointness law, the
  terminal-release law, the "one atomic step" law or the "never by timestamp
  comparison" sentence.
- No new library, fork or dependency.
