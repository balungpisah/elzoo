# ELZ-437 — wave 4 channel: an unknown dispatch stays fenced until its own evidence, and a foreign command does not make a restored wait ambiguous

- Dependencies: ELZ-418, ELZ-419

## Outcome and scope

This task fixes three defects of the wave 4 channel example
(`examples/support/wave4_channel.ex`). They were on `main` before ELZ-419, and
ELZ-419 and ELZ-418 keep them. The channel's tenant command stream keeps
every row (under ELZ-418 the channel never calls `maintain/3`), so its whole
history stays readable.

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
     ended), recovery decides from the durable facts as today. The new host
     dispatches the exact request again, with the same identity and bytes.
     That dispatch returns the first write's result, or commits once.
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
   - For each row, the scan reads that row's outbox item by its key. A row
     concerns this wait only when it is a reply of the wait's own ticket:
     - A row with no item does not concern this wait. Neither does an item
       of another destination, or a reply item whose notice names another
       actor or conversation.
     - For a reply item of this actor and conversation, `result/3` of the
       command that the notice names gives the reply's ticket. A reply of
       another ticket does not concern this wait.
   - A reply of the wait's own ticket is a committed reply that recovery did
     not restore. The wait stays ambiguous and fenced, as today, and the
     module documentation states this limit. The same holds for a row or
     item that does not validate: another stream or sequence, a malformed
     notice, or a named command whose result is not a completed reply input.
   - Otherwise the wait is not ambiguous: a fresh reply is admitted, the Run
     can expire at its deadline, and eligibility is `:none`.
   - A read that fails gives `{:error, :unavailable}`, and the next call
     reads again. It never sets a permanent fence.
   - The scan decides wherever the ambiguity is read: fresh reply admission,
     the expiry, and acknowledgement eligibility. This includes a reopen on
     the terminal path, where the Run ended while the wait was ambiguous.
   - **Limit: a pending reply ASK.** A pending reply ASK writes no item, and
     the checked-command surface lists no ASKs, so the scan does not see one.
     The module documentation states this limit. The host handles such an
     ASK as follows:
     - An exact signed replay of its reply restores its custody while the Run
       waits and the host holds no reply of the round. This holds also after
       the scan has cleared the ambiguity. Fresh replies are then not
       admitted, as for any restored ASK.
     - Before that replay, a fresh reply can be admitted. Both commands
       expect the same conversation revision, so its compare-and-set lets at
       most one of the two commit. A later release of the ASK is refused.
     - At the Run's expiry the ASK is excluded from acknowledgements, as a
       known pending reply ASK is.

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
  - Separately: roll the writer back, join it, fence and reopen. The new
    host's exact dispatch commits once, and the round completes.
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
- Restored wait: a reopen restores a wait with no reply, and a command of
  another conversation moves the head. Then, run separately:
  - A fresh reply is admitted, and the round completes.
  - The Run expires once at its deadline, eligibility is `:none`, and the
    round's acknowledgements complete. The same holds when the host is
    fenced and reopened after the expiry, before the acknowledgements.
  - A pending reply ASK of this wait lies in the range. Its exact signed
    replay restores its custody, and a fresh reply is then not admitted.
    Separately, a fresh reply admitted first commits, and the ASK's release
    is refused.
  - A committed reply of the wait's ticket that recovery did not restore lies
    in the range. The wait stays ambiguous and fenced (the stated limit).
  - A read failure during the scan gives `{:error, :unavailable}`, and the
    next call proceeds. A head that moves during the scan restarts it.
- Existing tests that assert today's fences change to the new rules, for
  example a restored Run's expiry that ends in the reply ambiguity fence. The
  pull request names each changed test.
- Negative controls, each recorded and reverted:
  - the reply-association fence clears on `{:unknown, :not_observed}`;
  - `{:refused, :contended}` fences the round;
  - the release fence clears on `{:approval_pending, _}`;
  - every moved head is ambiguous;
  - the scan ignores the ticket of a reply of this conversation;
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
