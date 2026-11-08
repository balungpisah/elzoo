# ELZ-028 — proposed Contract clarifications for issue #45 (not applied)

Written by the ELZ-028 worker; revised after the round-3 re-review
([ELZ-028-early-rereview3.md](ELZ-028-early-rereview3.md)). The worker does
**not** edit the issue body or the task copy. The main coordinator decides;
an authorized coordinator applies accepted amendments to the live issue, the
task copy and the roadmap hash. Every "before" text below is a byte-exact
substring of the live body fetched on 2026-11-08 (`gh issue view 45 --json
body`), including hard line wraps and three-space continuation indents; a
script checked that each occurs exactly once.

## A-amendments (round 3: ACCEPTABLE)

### A1 — `claim_expired` candidates (reviewer R1 wording)

- **Before:** `claim_expired{owner, ttl, limit}`, and the store clock.
- **After:** `claim_expired{owner, ttl, limit, candidates}` (the caller
  supplies the bounded candidate keys; key discovery is a caller Need), and
  the store clock.

### A3 — attributable release (reviewer's byte-exact text)

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

### A6 — `claim_expired` does not take free keys (reviewer's byte-exact anchor)

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

## B-amendments (Contract interpretations requested from the main coordinator)

These three points cannot be closed by design alone (round-3 findings B1, B3,
R3). Each gives the exact replacement and a consistency argument. They
qualify how an existing law is evaluated or evidenced; none removes a law.

### B1 — the linearization point of "renew extends only a live lease"

Exact before:

```text
`renew` extends only a live lease, so a renewal
   issued before a handoff and applied after it cannot revive it;
```

Exact after:

```text
`renew` extends only a live lease, so a renewal
   issued before a handoff and applied after it cannot revive it; liveness for
   `renew`, and for a holder's re-`claim`, is evaluated at the store-clock
   sample taken under the key's head lock inside the transaction that records
   the change (the linearization point), so a renewal whose sample preceded
   the expiry extends the lease even if its commit is later in wall time, and a
   renewal whose sample followed the expiry is refused and records nothing; a
   reader without the lock compares its own later store-clock sample with the
   recorded stamps and treats a stamp later than its sample as ambiguous;
```

Consistency argument. No database primitive evaluates a wall-clock condition
at the commit instant: PostgreSQL `now()` is the transaction start time and
`clock_timestamp()` is the time of its own statement, so every SQL design
evaluates liveness at a sample taken before the commit. The design takes
that sample under the key's head row lock, inside the transaction that
inserts the record and advances the revision. Because every writer of the
key samples under the same lock, the samples of admitted transitions are
totally ordered in the same order as the revisions they produce (a sample
earlier than the latest recorded stamp is a clock regression and is refused),
so the recorded history is a linearizable sequence in store-sample time in
which every admitted renewal satisfied `sample < until` at its linearization
point. A renewal cannot revive a lease after a handoff because the handoff
holds the lock first and changes the head, which the renewal's transaction
then observes (refused). What readers see: a holder learns its `until` from
the committed record; a `status`/`hold` reader without the lock takes its
own sample later than the write's and may observe (a) an active lease whose
previous lease had expired in wall time before the renewal committed, which
is the admitted semantics, or (b) a stamp later than its own sample, which
it reports as ambiguous (fail closed). The deterministic control on both
stores (ELZ-028.md LS8c) shows the admitted case explicitly: the clock is
sampled live under the lock, the transaction is held past the expiry, and
the commit is accepted with the earlier stamp; the mirror control (LS8b)
shows a sample after expiry refusing and writing nothing.

### B3 — qualification of the disjointness law and the sweep transaction

Exact before (invariant):

```text
`claim_expired` results are disjoint across concurrent claimers;
```

Exact after:

```text
`claim_expired` results are disjoint across concurrent claimers: no key is
   held by two owners at once, and a key whose lease expired and was re-claimed
   between two overlapping sweeps may appear in both results only with
   different fence revisions;
```

Exact before (evidence sentence):

```text
Tests on the double and the selected provider: concurrent
   `claim_expired` disjointness, renewal after handoff, write with expired
   lease refused by revision, claim-next-ready under one transaction.
```

Exact after:

```text
Tests on the double and the selected provider: concurrent
   `claim_expired` disjointness, renewal after handoff, write with expired
   lease refused by revision, claim-next-ready under one transaction (on the
   selected provider the sweep is one database transaction; on the volatile
   double it is one serialized owner without batch rollback, a finite
   approximation, so the one-transaction law is established on the provider
   and the double exercises the same scenarios).
```

Consistency argument. On PostgreSQL a sweep is one transaction: each
candidate's head row is locked (`FOR UPDATE SKIP LOCKED`), the clock is
sampled under that lock, readiness (`stale`) is evaluated on the committed
records, and the release and claim records are inserted and the revision
advanced in the same transaction; two concurrent sweeps therefore cannot
both claim one key (one skips the locked row or sees the other's committed
claim as active), which is the checkbox "never hands one key to two
owners". What the unqualified sentence cannot promise is that two
*overlapping invocations* never both list a key: if sweep A claims key k
with a short TTL and the lease expires before A returns, sweep B may
legitimately claim k again; both results list k, with different fence
revisions, and at no instant were two owners held. The qualification states
exactly this. The Memory double has no transaction over several keys: a
single serialized owner performs all of the sweep's Store calls (so sweeps
and lease steps through that owner do not interleave), but an error on a
later candidate cannot roll back an earlier committed claim; the double is
therefore a finite approximation of the one-transaction law, which the
evidence sentence now says explicitly instead of implying equal strength on
both stores.

### R3 — the acceptance checkbox on expired-holder writes

Exact before:

```text
- [ ] A write from an expired lease holder is refused by revision (test).
```

Exact after:

```text
- [ ] A write from an expired lease holder is refused by revision once any
  replacement record has moved the head (test); while no record has moved the
  head, the revision cannot observe elapsed time and the lease never refuses a
  write (documented limit with a control test).
```

Consistency argument. The same Contract states that the lease never
authorizes a write and that the record revision is the fence. A revision is
a counter of committed records; it cannot observe elapsed time, so an
expired holder whose key nobody has written since still presents the current
revision and the Store accepts its write (the Store accepts any caller with
the current revision; owner strings are not identity). The guarantee that
can be given and tested is therefore: as soon as any replacement record
(claim, seize, release or any other record) has moved the head, the expired
holder's write is refused by revision (LS4). The no-takeover case is a
documented limit with a control test, consistent with "the lease never
authorizes a write" and with "completion from a non-holder is rejected by
the record revision (the fencing value), never by timestamp comparison".

## Withdrawn (rounds 2–3: REJECT)

- **A2** (claim-next-ready sentence): withdrawn; superseded by B3's exact
  evidence-sentence amendment above.
- **A4** (expired-holder write): withdrawn; superseded by R3 above.
- **A5** ("one atomic step" in store time): withdrawn; superseded by B1
  above, which keeps the law and names its evaluation point.

## Not a Contract amendment: ownership decision OD-1

May `state/lease` own Adapters that act on the `integration/sql` tables
(`elzoo_log_heads`, `elzoo_log_records`, migration version 1, under the
Store's prefix) for lease operations, while the holder's state writes keep
using the ready Store's public `append`? Options and consequences are in
ELZ-028.md §1.2 (Option L recommended; Option S changes the ready Store's
Contract under a separate task). The worker implements nothing before this
decision.

## Not proposed

- No change to the state owner, the terminal-release law, the "one atomic
  step" law, the "never by timestamp comparison" sentence or the non-goals.
- No new library, fork or dependency.
