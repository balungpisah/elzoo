# ELZ-023 final review follow-up

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

ELZ-023: F1 and approved F2 fixes applied; fresh full check passed; incremental review pending.
Branch/PR: `task/ELZ-023`; issue #37; no PR; independent reviewed head `196d0881cd80a878029ff582e87c786732c2cbbf`.
Checks: full setup/check at production `fed4026` previously exit 0 (32 + 608 passed); F1 targeted suite exit 0 (`Result: 47 passed`, 41.6 seconds); F1+F2 targeted suite exit 0 (`Result: 49 passed`, 41.9 seconds); fresh setup and full check at `7fcc308` exit 0 (`Result: 32 passed`, `Result: 613 passed`, `ELZOO CHECK PASSED`); incremental review remains pending.
Grounding: [verbatim independent review](ELZ-023-final-review.md), including its 160,000 finite oracle sequences and limits; new actual-owner F1 saturation/4090-poll and F2 authority regressions; two explicitly approved in-progress test corrections, merged tests untouched.
Limits: no review clearance/PR/merge claimed; the old full check does not accept this delta.
Open work: independent incremental review of the actual F1+F2 diff, then PR/authorized queue/main acceptance/cleanup.

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
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test mix test pieces/delivery/effect-intent/test/elzoo/
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


## Fresh validation of both fixes (11:31 WIB)

Production commit `7fcc308049703060678bf4fda7d939d15c4f4273` was pushed and the
worktree stayed clean throughout fresh setup and the uninterrupted full check.
Cure is `208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4, OTP 29.1.2.
Only the assigned `elzoo_pieces_test` database was used. Exact commands:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test mix setup
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test mix check
```

Both exited **0**. Setup fetched the locked dependencies and completed; full
check ended 2026-11-08 **11:31:26 WIB**, elapsed 874.0 seconds:

```text
Result: 32 passed
Finished in 858.7 seconds (48.6s async, 810.1s sync)
Result: 613 passed
ELZOO STAGE root_suite end utc=2026-11-08T04:31:26.073298Z elapsed=874.0
ELZOO CHECK PASSED
```

All 26 fixed consumers, the OTP-only consumer and aggregate(42) ran. Aggregate
consumer tests took 232.1 seconds, separate runtime VM 0.6 seconds, total 233.0
seconds. The actual exported receipt identifies `7fcc308` and
`uncommitted_changes: false`; all 238 receipt hashes matched exported bytes,
all 13 effect-intent source/test/example files matched the frozen originals,
and the root Application was absent. Receipt captured from the running consumer:
`/tmp/elz023-a1/fixes-aggregate-receipt.json`.

`python3 scripts/check-roadmap.py --live` exited 0 (137 links; live Contracts
match). Live issue/task equality remains 16,468 bytes, SHA-256
`b3fae2e02e9ee8789320e76491568759f9e9f28693b8cf5561bb086ccffeee58`.
A test-name/body audit against `196d088` finds 26 old owner tests preserved,
31 now present, exactly the two approved old test blocks changed. Cure source,
template and generator are byte-identical to the prior reviewed head.

The full-range `git diff --check origin/main HEAD` first flagged four blank
unified-diff context lines in the saved approval patch. Those four context-line
spaces are now normalized in the documentation artifact only: applying the
original and normalized patches to separate copies of `0c71170` with
`patch -p1 --batch` both exited 0 and produced byte-identical source and test
files. Original patch SHA-256 is
`5a1f2cdeb4d1e33517a04c31b8fd11cee70dda8589790b5ee76e5158a579851a`,
retained in commit `0c71170`; this does not change the approved edit.

Subsequent handoff changes are documentation only. The prior independent
CONDITIONAL findings remain open until the separate reviewer clears this
actual delta; no PR/merge acceptance is claimed here.

### Log integrity

- `/tmp/elz023-a1/setup-fixes.log`: SHA-256 `5097600b4764ef5b526ac44e8120693670ac61a2c4d20dab809c740230e715e8`.
- `/tmp/elz023-a1/check-fixes.log`: SHA-256 `1c59b870cbfad9756838915a64839d7741faa81c42262f660a3923f78f9554d8`.
- `/tmp/elz023-a1/review-fixes-tests.log`: SHA-256 `f25c4a6cd5673665d5f15ba1c2fe9f487200e4fd23805fe84cbcb070d1aa96fd`.
- `/tmp/elz023-a1/fixes-aggregate-receipt.json`: SHA-256 `f1ab7100bd1d9e3f1b0ca8d7ecd22593389cba88fef5d82ee9c980331ce03d69`.

Final handoff metadata checks: fetch and `git merge --no-ff origin/main` each exited 0 (already current at `0a42370`); `python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py` and `git diff --check origin/main` each exited 0 after the documentation normalization; no tracked claim metadata and no protected-file diff.
