# ELZ-023 final review follow-up

ELZ-023: F1 fixed locally; F2 requires approval to correct two existing tests.
Branch/PR: `task/ELZ-023`; issue #37; no PR; independent reviewed head `196d0881cd80a878029ff582e87c786732c2cbbf`.
Checks: full setup/check at production `fed4026` previously exit 0 (32 + 608 passed); F1 targeted suite exit 0 (`Result: 47 passed`, 41.6 seconds); full check after all review fixes and incremental review remain pending.
Grounding: [verbatim independent review](ELZ-023-final-review.md), including its 160,000 finite oracle sequences and limits; new actual-owner F1 saturation and 4090-poll regressions; prior assertions preserved.
Limits: F2 remains unfixed; no review clearance/PR/merge claimed; the old full check does not accept this delta.
Open work: coordinator approval for the concrete F2 test corrections below; F2 regression, fresh full setup/check and independent incremental review.

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

## F2 approval request: source attribution, not accepting a limit

Original brief hard rule 7 says: “never edit, weaken or delete an existing test
or assertion” and “If a task seems to need it, ask.” The reviewed existing tests
explicitly assert the now-disallowed public no-send behavior. Correcting it while
leaving those assertions unchanged cannot yield an honest green run.

The [exact proposed patch](ELZ-023-F2-proposed.patch) is **not applied**. It:

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
