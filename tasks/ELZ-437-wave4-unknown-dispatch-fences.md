# ELZ-437 — wave 4 channel: an unknown dispatch stays fenced until its own evidence, and a foreign command does not make a restored wait ambiguous

- Dependencies: ELZ-418, ELZ-419

## Outcome and scope

This task fixes three defects of the wave 4 channel example
(`examples/support/wave4_channel.ex`). They were on `main` before ELZ-419, and
ELZ-419 and ELZ-418 keep them. The channel's tenant command stream keeps
every row: under ELZ-418, no participant retains that stream (a Need), so
its whole history stays readable.

1. **The reply association after an unknown outcome.** Today
   `reconcile_reply_association` clears the fence on
   `{:unknown, :not_observed}`, and the next `advance` dispatches the same
   request again. On PostgreSQL, an append paused after its stream-head
   compare-and-set is not visible while its writer is alive. The second
   dispatch can then wait in the host process behind the first writer's row.
   A `{:refused, :contended}` result falls into the catch-all of
   `classify_reply_association`, which fences the round for good
   (`{:reply_association, :conflict}`).
   - After an unknown outcome, the host dispatches nothing more for that
     command until `result/3` gives its terminal outcome.
     `{:unknown, :not_observed}` keeps the fence. While the fence holds:
     - `advance` returns `{:unknown, :reply_association}` and dispatches
       nothing;
     - intake and release return `{:error, :unavailable}`, as for any fence.
   - After a fenced reopen (every writer that the old host started has
     ended), recovery first reconciles a verified retained result
     read-only, as today. If it observes none, the new host may dispatch the
     exact request again, with the same identity and bytes, subject to the
     normal preflight and refusals: the dispatch returns the first write's
     result, commits once, or is refused. This permission covers only this
     command; it is never permission to append an acknowledged Conversation
     delivery whose row is missing (ELZ-419's Wave 4 Need).
   - `{:refused, :contended}` wrote nothing. The host keeps the same request
     and dispatches it again at a later `advance`; it never fences the round.
     Other refusals and conflicts keep today's fences.
2. **An ASK release after an unknown outcome.** Today `reconcile_v2_release`
   clears the fence when the original ASK reads `{:approval_pending, pending}`
   with the same key and requirement. That shows that the ASK committed. It
   does not show whether its release did, and the release append may still
   commit. A later `release` or `release_reply` call then dispatches a second
   release, with new evidence, while the first can still commit. The two
   appends race at one head, and the host process can wait behind the first
   writer. The reply reports whichever release won.
   - After an unknown release outcome, the host keeps the fence until
     `result/3` gives the ASK's terminal outcome. `{:approval_pending, _}`
     keeps the fence. While it holds, `release` and `release_reply` return
     `{:error, :unavailable}` and dispatch nothing.
   - After a fenced reopen the host may hold the ASK again, by recovery or by
     an exact signed replay as on `main`. Then a new call with valid evidence
     and current authority can release it. That release can be refused;
     nothing promises that it commits.
   - The command that opened the ASK is unchanged: a matching
     `{:approval_pending, _}` is still the evidence that it committed.
3. **A restored wait whose cursor moved.** Today, a reopen can restore a wait
   with no recovered reply. Then `recover_ambiguous_reply_cursor` marks the
   wait ambiguous when the head moved past the wait's cursor at all, for
   example by a command of another conversation. As a result:
   - every fresh reply is refused;
   - the Run's expiry is fenced for good (`{:reply_ambiguity, :expiry}`);
   - acknowledgement eligibility is `:unknown`, which fences the end of the
     round (`{:terminal_reply_state, :unknown}`).

   The fix:
   - The host decides the ambiguity by scanning the rows after the wait's
     cursor up to the head.
     - The scan reads these rows as one contiguous range of the tenant's
       command stream, within the module's existing read bounds (4,096 rows
       and its byte bound).
     - The scan runs between two head reads, which must be equal. A moved
       head restarts the scan, at most a number of times that the module
       documentation states; after that the call gives
       `{:error, :unavailable}`.
   - The scan clears the ambiguity only when it shows every row in the
     range unrelated to this wait. For each row it reads that row's outbox
     item by its key and validates it: the requested key, stream, sequence
     and position, the item's digest, and the notice shape (integer version
     `1`, not `1.0`). A validated item shows its row unrelated when:
     - it has another destination, which the channel's Store view reads;
     - it is a reply item whose notice names another actor or conversation;
     - it is a reply item of this actor and conversation, and `result/3` of
       the command that the notice names gives a completed reply input of
       another ticket.
   - Every other row keeps the wait ambiguous and fenced, as today. The
     module documentation states each case as a limit:
     - a reply of the wait's own ticket: a committed reply that recovery
       did not restore;
     - a row with no item. A pending ASK writes no item, and the
       checked-command surface lists no ASKs, so such a row can be a pending
       reply ASK of this wait (or a command of another conversation that
       wrote no item). An exact signed replay of such an ASK restores its
       custody while the Run waits, as on `main`;
     - an item that does not validate, or that the channel's Store view
       cannot read (`{:error, :malformed}`, which both a damaged item and an
       item of a destination outside the view's fold give). Need (module
       documentation): the channel's Store view reads every destination
       that the tenant's supported participants write;
     - a named command whose result is absent (`{:unknown, :not_observed}`
       from a successful lookup) or is not a completed reply input.
   - A read that fails gives `{:error, :unavailable}`, and the next call
     reads again: a failed item read, and a `result/3` that gives
     `{:unknown, :storage}` or `{:unknown, :unresolved}`. It never clears
     custody, acknowledges, or sets a permanent fence.
   - The scan decides wherever the ambiguity is read: fresh reply admission,
     the expiry, and acknowledgement eligibility. This includes a reopen on
     the terminal path, where the Run ended after the scan had cleared the
     ambiguity and before the acknowledgements.

**Fenced reopen in tests.** A test that pauses a writer must end it before it
fences and reopens: it rolls the writer back or releases it through the
harness, and joins it. A reopen alone does not end a checked-out transaction,
because the pool disconnects a connection only when it is checked in.

Paths:
- `examples/support/wave4_channel.ex`, including its module documentation;
- `examples/wave4_channel.exs`;
- `test/wave4_channel_test.exs`;
- `test/support/wave4_channel_helper.exs`.

No Piece changes, so no index rows. New external dependencies: none.

## Acceptance

On PostgreSQL:

- Reply association: pause its append after the compare-and-set, with its
  writer alive.
  - Two `advance` calls dispatch nothing more: the Store sees one append for
    that command. Intake returns `{:error, :unavailable}`.
  - Release the writer. The next `advance` reads the committed result, and
    the round completes with one association row.
  - Separately: roll the writer back, join it, fence and reopen. Recovery
    observes no result; the new host's exact dispatch commits once, and the
    round completes.
  - Separately: a `{:refused, :contended}` result, produced through the test
    Store, leaves the round retryable, and a later `advance` completes it.
- The primary ASK release and the reply ASK release, each: pause the release
  append, with its writer alive.
  - While the ASK reads pending, `advance` keeps the fence. A second
    `release` or `release_reply` call with fresh valid evidence dispatches
    nothing.
  - Release the writer. The host reports the terminal outcome, with one
    release row in total.
  - Separately: roll back, join, fence and reopen. Once the host holds the
    ASK again, a release with valid evidence commits once. A release with
    revoked evidence is refused, and the ASK stays pending.
- The command that opened an ASK, with a lost response, still reconciles from
  `{:approval_pending, _}`.
- Restored wait: a reopen restores a wait with no reply, and commands of
  another conversation, each with its item, move the head. Then, run
  separately:
  - A fresh reply is admitted, and the round completes.
  - The Run expires once at its deadline, eligibility is `:none`, and the
    round's acknowledgements complete. The same holds when the host is
    fenced and reopened after the expiry, before the acknowledgements.
  - A validated reply of another ticket in this conversation lies in the
    range: the ambiguity clears. A committed reply of the wait's own ticket
    that recovery did not restore lies in the range: the wait stays
    ambiguous and fenced.
  - A pending reply ASK of this wait lies in the range: the wait stays
    ambiguous and fenced, and a fresh reply, also one that needs approval,
    is refused; the ASK's exact signed replay then restores its custody. A
    pending ASK of another conversation lies in the range: the wait stays
    fenced (the stated limit).
  - An item written through a second Store view, with a destination outside
    the channel's view, lies in the range: the wait stays fenced.
  - A read failure at an item read and, separately, at the named command's
    `result/3` gives `{:error, :unavailable}`, at fresh admission and on
    the terminal acknowledgement path; the next call proceeds. A head that
    moves during the scan restarts it.
- Existing tests that assert today's fences change to the new rules, for
  example a restored Run's expiry that ends in the reply ambiguity fence. The
  pull request names each changed test.
- Negative controls, each recorded and reverted:
  - the reply-association fence clears on `{:unknown, :not_observed}`;
  - `{:refused, :contended}` fences the round;
  - the release fence clears on `{:approval_pending, _}`;
  - every moved head is ambiguous;
  - the scan ignores the ticket of a reply of this conversation (the
    other-ticket and own-ticket cases tell the two apart);
  - a row with no item counts as unrelated;
  - a failed `result/3` counts as a nonmatching result;
  - the terminal path skips the scan.
- Every wave 4 test passes with two seeds.
- `mix check --affected origin/main` and `git diff --check` exit 0, or the
  pull request records the exact reason a command cannot run on the host.
  The full hosted check is green on the exact head.
- Review: one independent review by the strongest available reviewer of
  another model family, because the channel decides retries and holds durable
  custody. Also the exact-head automated review, with its threads answered
  and resolved, or the authorized replacement review under `AGENTS.md`
  section 6.
