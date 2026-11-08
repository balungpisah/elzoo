# ELZ-023 final review follow-up

ELZ-023: F1 and approved F2 fixes applied; fresh validation and incremental review pending.
Branch/PR: `task/ELZ-023`; issue #37; no PR; independent reviewed head `196d0881cd80a878029ff582e87c786732c2cbbf`.
Checks: full setup/check at production `fed4026` previously exit 0 (32 + 608 passed); F1 targeted suite exit 0 (`Result: 47 passed`, 41.6 seconds); F1+F2 targeted suite exit 0 (`Result: 49 passed`, 41.9 seconds); full check after all review fixes and incremental review remain pending.
Grounding: [verbatim independent review](ELZ-023-final-review.md), including its 160,000 finite oracle sequences and limits; new actual-owner F1 saturation and 4090-poll regressions; prior assertions preserved.
Limits: no review clearance/PR/merge claimed; the old full check does not accept this delta.
Open work: fresh full setup/check and independent incremental review, then PR.

Prepared 2026-11-08 11:07 WIB. Independent reviewer session
`orca_session_id:0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch
`ctx_ba3927238e5e`, verdict CONDITIONAL (F1 major, F2 medium); no Contract
amendment needed per that review. The reviewer found no bypass of the durable
failed_definite law, but did find liveness starvation and a source-attribution gap.

## F1 implemented within the existing budget

ProviderUnknown and actual recovery-deadline stranding consume the reserved
first-settlement slot, alongside the existing decisive categories. Strand writes
carry bounded evidence; grounding and strand failures halt. Routine observations
share a persisted 1024-write allowance and then return not-retained/routine_budget;
no-op expiry and repeated schema-disarm append nothing. This preserves headroom
for resolution and future reservations. No model field, numeric ingress ceiling,
Cure source/law or existing test/assertion changed. Maximum codec sizes remain
706230 / 870232 / reserved870758 / delta66376 in the existing size test.

Three appended tests reproduce the review's cases: 1022 attributable refusals then
replay/no-replay grounding; saturated expiry plus unavailable grounding; and 4090
pending polls followed by successful replay grounding, rearm, a second reservation,
expiry and read-only recovery. All old tests plus these give 47 passed. F3's
self-declared Store-limits assumption is now explicit in the README.

Exact green command, exit 0:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test mix test pieces/delivery/effect-intent/test/elzoo/
```

Log: `/tmp/elz023-a1/review-f1-tests.log`. No full check is claimed for F1 yet.

## F2 approved correction: source attribution

Original brief hard rule 7 says: “never edit, weaken or delete an existing test
or assertion” and “If a task seems to need it, ask.” The reviewed existing tests
explicitly assert the now-disallowed public no-send behavior. Correcting it while
leaving those assertions unchanged cannot yield an honest green run.

The [exact approved patch](ELZ-023-F2-proposed.patch) is now applied. It:

1. Refuses `not_dispatched` at the raw Envelope observation path (public calls
   and raw callback Envelopes); only a declared, attested typed send failure can
   establish adapter_no_send. Correlated refused input still gets bounded refusal
   evidence; it never settles or rearms. Poll-provided final no-effect is unchanged.
2. Corrects `all eight Envelope pairs take the intended path…`: its two no-send
   fixtures return the declared `:permanent` / `:no_send` send failures; await the
   same expected definite phase; public copies are now asserted refused/retained.
   All eight phase/disarm assertions remain, with the other six public paths intact.
3. Corrects `known-attempt refusals fill only optional capacity…`: establishes its
   reserved settlement through authenticated `poll -> no_effect`, replacing the
   public no-send injection; asserts evidence 1023 and the ProviderNoEffect phase.
   Every final contradiction/quarantine/evidence1024/recovery/no-rearm assertion
   remains. The separate pure NoSend reservation tests remain unchanged.

Requested approval is limited to these two existing test fixture/expectation
corrections; it does not authorize deleting tests, weakening a law, accepting F2
as a limit, changing the live Contract or touching any protected file. After
approval, add the independent review's exact in-flight/no-replay attack as a new
regression: public no-send cannot settle/rearm or cause a second physical send,
while a genuine attested send-return no-send can still establish its ground.
Then run fresh setup/full check and independent incremental review.


### Approval and retained regression coverage

The root coordinator approved question `msg_db1a9f1bb028` on 2026-11-08 about
11:40 WIB, in dispatch `ctx_ada55dc734ce`: the two named tests were introduced
in this unmerged branch at `dae4acf`; no merged existing test or assertion is
changed. The independent CONDITIONAL verdict at `196d088` required F2's
source-attribution correction. The exact two corrections listed above preserve
the tests, their phase/disarm and capacity/contradiction assertions, and turn
the formerly accepted public no-send case into an explicit refusal assertion.
The preceding request text is historical; approval is granted and applied.

Two appended tests add the reviewer's in-flight attack under a no-replay binding
and raw send/poll Envelope controls. The first holds the send callback alive,
asserts public no-send is retained only as refusal, leaves the phase dispatched,
and rejects rearm and another dispatch with no second callback invocation;
then a genuine declared/attested typed send return establishes AdapterNoSend,
permits rearm and a second attempt with the same key/digest. The second rejects
raw no-send Envelopes from both Adapter callback paths. Callback invocation is
finite instrumentation, not a proof of bytes reaching transport.
No test is deleted, no Cure source/law weakened, and no Contract or protected
file changed. Fresh setup and full check results will be recorded below.


### F1+F2 targeted validation

At 2026-11-08 11:16:01 WIB (local command clock), the exact targeted command
above exited 0 with `Result: 49 passed`, 41.9 seconds; log:
`/tmp/elz023-a1/review-fixes-tests.log`. The approval time above is the
coordinator's stated approximate time, preserved as supplied.
`git fetch origin --prune` exited 0; `git merge --no-ff origin/main` exited 0
(already up to date at `0a423705784f2c0223ed67d6f75bfdb5412845ce`).
`python3 scripts/check-roadmap.py` and `python3 scripts/check-claims.py` each
exited 0 (137 links, no tracked claims); protected-file diff is empty.
