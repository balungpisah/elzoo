# ELZ-011 amended-proposal feasibility evidence

Root decision: msg_18881a0d44c3, 2026-11-08. D1/D2/D3 option A/D4/D5
accepted, with real PostgreSQL composition and pinned-source retry_job state
coverage. No production files or existing merged tests changed. This is
feasibility evidence for focused review, not implementation acceptance.

## Amendment and dependencies

Exact approved before/after posted before body edit:
https://github.com/balungpisah/elzoo/issues/11#issuecomment-6718026190.
Issue/task now byte-equal at 4359 bytes, SHA256
4d811943c4d3ce87289f6dd24619b9862174876490d40d165b7f70a23c105183.
The manifest's only authored job-row changes are ELZ-011 dependencies/hash;
views were regenerated. ELZ-013 PR14 merge
9999a3cfb99be9ea7566f299d3ab2f3332f25a49 and ELZ-023 PR91 merge
a5f0e630f61e93893f1a2c706268226681ca593a are ancestors of origin/main.

## Probe scope and results

`composition.exs`: 8 passed. Uses the ready real PostgreSQL Store and StoreHost,
real EffectIntent/Cure policy and Oban 2.24.2, in a fresh random schema on the
assigned database; drops that schema on completion. No Memory store. Covers:

- All nine proposed failure triples pass the actual Binding compiler.
- Intended after deadline refuses dispatch; permanent no-send disarms/rearm refuses.
- Poll during a held send at max_children 1 returns task_start, advances evidence,
  and leaves the reservation Dispatched without a no-send ground.
- Typed preflight permits a recorded rearm; a subsequent unknown send and 404
  unavailable observation remain Dispatched until explicit recovery expiry strands.
- Checkpoint at sequence 2 exists when the Adapter is entered; restart is read-only,
  the bound host callback can reactivate, and recovered Dispatched cannot send.
- Real Basic-engine retry_job matrix over all seven states confirms the pinned
  source: scheduled/retryable/completed/discarded/cancelled become available;
  available/executing are ignored; ID and uniqueness persist. max_attempts grows
  to attempt+1 where needed. Absent ID also returns :ok, with no new job.
- A real registered Jobs worker exhausts a read-only job to discarded; duplicate
  enqueue gives its original ID, host activation plus retry_job re-wakes it,
  no second Adapter entry occurs, and explicit host expiry later strands it.
- A bounded control caller times out while the owner is suspended, yet the
  queued dispatch executes after resume. Timeout is therefore unknown and never
  authority to resend. A dead owner call becomes a fixed error.

The worker in the re-wake test is deliberately a small inspection/cancel stub,
not the future HTTP runner. The fixture clock is controlled, not wall time.
The probe demonstrates real persistence/provider seams; it does not establish
all scheduling races, request authentication, complete runner semantics or a
combined HTTP/PostgreSQL/Oban production pipeline.

`timing-json.exs`: 21 passed (14 original transport/map tests plus 7 new tests).
Uses real Req/Jason: duplicate raw JSON keys (including escaped/nested ones)
are visible through ordered_objects and rejected before map conversion;
strict numeric/ack types, bytes/depth/node limits and string-key atom stability
are checked. Isolated copies of the actual reduced normalize function are
mutated to retain fields, upgrade trust, guess ack and atomize keys; each
violates its named property. The historical hand-made-map controls remain
historical finite examples and are not relabelled as function mutations.

The slow-drip server keeps per-read receives below 200 ms while the complete
request takes >=800 ms. The outer 250 ms timer returns total_timeout before
800 ms; removing it fails that elapsed bound. Child lifetime is linked to its
caller, and killing that caller also kills the inner child. Throwing, raising
and hanging callbacks return unknown/timeout; their errors cannot become
no-send. These are broad finite timing tolerances on local loopback, not
hard real-time or physical cancellation guarantees. Production must apply
the timer to the whole named preparation/request/authentication work and
exercise the actual callback wiring.

`mutate-composition.py`: exits 0 only when the isolated mutant's ExUnit run
exits 2 with 6/8 passed. Changing the actual reduced poll's 404 result to
unknown_to_provider AND accepting that authentication breaks the authentication
assertion and the persisted Dispatched-state scenario (it becomes Stranded).
This is a runtime negative control, not Cure proof rejection. Production still
requires the full accepted mutation list on its actual source, including
redirect/retry; the original PUT finite probe alone cannot detect removing
retry:false because Req's default PUT retry differs from GET polling.

## Exact commands

All Mix commands use this prefix and own database:

```sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
export MIX_ENV=test
export ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test
mix run docs/work/ELZ-011-probes/composition.exs
mix run docs/work/ELZ-011-probes/timing-json.exs
python3 docs/work/ELZ-011-probes/mutate-composition.py
python3 scripts/check-roadmap.py
python3 scripts/check-roadmap.py --live
git diff --check
```

Fresh setup at the claimed base was previously green; no dependency/pin change
since it. Cure 208248063d64e621782cd26dd30698ee42850a89, Elixir 1.20.4,
OTP 29.1.2. No full mix check for this proposal-only delta; fresh setup and full
check are required for production and final review.

## Failed experiments and limits

The first two composition invocations failed at Ecto query compilation (prefix
must immediately follow from). The next run had 2/8 pass: the fixture supplied
identity fields in the wrong order, so the real owner refused admission and
remained read-only. Correct binding identity is tenant, provider_account,
binding.id, operation, host reference. The fourth had 6/8 pass: the fixture
expected a three-field Stranded tuple rather than the actual two-field tuple,
and shared matrix jobs interfered with a later real queue test. Corrected the
new fixture tuple and separated matrix versus worker queues; configured the
same short Oban stager interval as the established provider probe. No production
change, merged assertion edit or weakened acceptance was used to get green.
Initial 20-test timing run passed; caller-death coverage was then added and
callback exceptions caught, producing the final 21-test suite.

Outstanding production gates remain all D4 clarifications and D5 acceptance:
full HTTP/intent/job composition, admission declaration/schema and identity,
actual Cure job policy, durable outage/recovery/duplicates/rescue, whole table
coverage, retry/redirect and all real-source mutants, resource saturation,
redaction, exports/copy consumer, full setup/check and independent actual-diff
review. No quantified no-rearm claim is made by these probes. Explicit Needs
include external truth, stable origin/provider identity, clock/scheduling,
host reconciliation and expiry after job termination. Grace/poll-delay <=512
alone does not bound concurrent/rescued wakes or pre-deadline polling.

Pinned Oban source evidence was posted before reliance:
https://github.com/balungpisah/elzoo/issues/11#issuecomment-6718031813.

## SHA256 evidence

- `docs/work/ELZ-011-probes/composition.exs`: `060bc0218a866bcb3fdf491ba13ed25d9cf1c8d61808a4ad8b167a30f6e28dbe`
- `docs/work/ELZ-011-probes/timing-json.exs`: `4ba1a67f7888008f76750199e96964b011523a9befa376564f884cf8d9b35598`
- `docs/work/ELZ-011-probes/mutate-composition.py`: `fd095f89b4aa4b70d545bebe06814ee880b4bb151bdf4757790768c438c841d8`
- `deps/oban/lib/oban.ex`: `9115b5be8e25d4ae8875562f328ac79f6af9d11fffa1fdb22d414be748b6d794`
- `deps/oban/lib/oban/engines/basic.ex`: `e119228a19b21c93d394d2731df811f83d830be168a9143dd4efe04962a6f8a6`
- `/tmp/elz011-proposal/composition-final.log`: `bb394792d583d5f9491119dd195ac05e232dec6e37ec6685f1b6ccfb61b450ef`
- `/tmp/elz011-proposal/timing-json-final.log`: `070784077ec18e0a104fa3efc4e506a9f3444767b398a0cbf586678b09cd5234`
- `/tmp/elz011-proposal/composition-mutant-final.log`: `b67b40c64ff83b56fd60fd6e9b09400d4c8a03459bd37ba557573f46cb931af3`
