# ELZ-357 — delivery/retry-timeout takes a retry delay from a not-dispatched failure, with optional full jitter

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 1; settled owner decision 2 of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#settled-owner-decisions))
- Dependencies: ELZ-003, ELZ-006
- Release: V1B
- Output: none. A change in place of the ready Piece `delivery/retry-timeout` (ELZ-006), before the first release, with the same Piece ID (`AGENTS.md` section 4). The Contract gains two optional policy keys and one pure function; a policy made without the new keys gives today's results from `classify/1`, `decide/3` and `backoff/2`, and today's Runner timers.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and the generated files)
- Owned paths: `pieces/delivery/retry-timeout/**`; the `manifest_sha256` and `note` of the `delivery/retry-timeout` row of `entries` in `docs/plans/release-plan.json`, and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece, no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

The owner decided on 2026-11-21: "`delivery/retry-timeout` gains, in place, a retry delay taken from the failure, such as a Retry-After value or a rate-limit wait, plus optional jitter, for results that were not dispatched only; a possibly dispatched result keeps today's rule. First caller: Wave 9 `delivery/model-routing`. A published task changes the ready Contract."

This task adds that delay. A caller that knows the wait a not-dispatched refusal named (for example a `delivery/rate-limit` refusal's `retry_after_ms`) gets a delay that is never shorter than that wait or than today's backoff. A caller may also spread retries with full jitter. For every other result class the delay is exactly today's `backoff/2`, so a possibly dispatched result is never retried sooner because of a failure's delay or jitter. The function is pure: the caller passes the failure delay and the random value, so the result is testable.

This task does not read a delay from the DeliveryResult envelope: `core/envelope`'s DeliveryResult has no delay member, and this task does not add one (see "Kept open"). Nothing here changes `integration/ai-text`, `integration/ai-embedding` or any other caller. Under the plan's reading of decision 2 ("A reading of decision 2" in the plan), a provider's `throttled` or `overloaded` result is possibly dispatched. So this delay does not apply to it, and the provider's `retry_after` becomes a cool-down in `delivery/model-routing`, which is a separate task.

The Piece decides whether a possibly dispatched result may be sent again, and a wrong delay rule there would weaken it. So this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"). The hosted `check-piece` run does not replace the local run (`AGENTS.md` sections 5 and 6).

## Facts on `main` that this task builds on

Checked at `f40ba178`. Confirm each before you start; if one differs, stop and comment on the issue.

- `Elzoo.RetryTimeout.policy/1` (`lib/elzoo/retry_timeout.ex`) takes a proper keyword list. The defaults are `max_attempts` 3, `base_backoff_ms` 10, `max_backoff_ms` 1,000 and `mode` `:redispatch_forbidden`. It checks in this order: `{:error, :invalid_options}` (not a proper keyword list), `:invalid_max_attempts` (not an integer ≥ 1), `:invalid_backoff` (not integers with `0 <= base <= cap`) and `:invalid_mode`. It ignores keys it does not know. It returns `{:ok, {:RetryPolicy, max, base, cap, :RedispatchForbidden | :RedispatchIdempotent}}`, the erasure of the Cure record `RetryPolicy` (`cure/elzoo/retry_policy.cure`), which the README states.
- `valid_policy?/1` matches exactly that 5-tuple. `decide/3` and `backoff/2` refuse another term with `{:error, :invalid_policy}`, and an attempt that is not an integer ≥ 1 with `{:error, :invalid_attempt}`. `decide/3` refuses a class outside `:completed | :retryable | :permanent | :dispatched` with `{:error, :invalid_class}`. The Runner's `init/1` refuses a policy that fails `valid_policy?/1` (`:invalid_options`).
- The Cure `classify` reads a DeliveryResult in this order: `completed`, `error_class` `permanent`, `dispatch` `not_dispatched` (retryable), else dispatched. `backoff(policy, attempt)` is `base * 2^(attempt−1)` capped at `max_backoff_ms`, with `0` staying `0` and attempts below 1 giving `base`. The Cure file has three selected laws: `permanent_never_retried`, `completed_never_retried` and `dispatched_not_retried_when_forbidden`. `test/elzoo/retry_policy_test.exs` audits them (no axioms, holes, unresolved, unaudited, opaque or `not_proven_total`, `absurd` 0), and checks that a false law, a production mutation and a hole are each rejected by compilation.
- The Runner (`lib/elzoo/retry_timeout/runner.ex`, `observed/3`, about line 248) calls `RetryTimeout.backoff(state.policy, op.n)` for a `:retry` decision and arms the retry timer with that delay. Delays over 4,294,967,295 ms are re-armed in chunks.
- `piece.json` limits: "Helper laws do not prove the runner, integer comparisons, classification or conservation; those have finite test/model evidence."
- In-repo callers use `policy/1`, `classify/1`, `decide/3` and `backoff/2` only, and none builds or matches the policy tuple: `integration/ai-text` and `integration/ai-embedding` (`Retry.next/4`), `integration/ai-batch` and `integration/ai-embedding-openai` (tests), `assembly/durable-job` (it rebuilds the policy from its stored fields through `policy/1`), `assembly/http-job`, `workflow/state-machine` (`decide/3`; its Cure file uses only `RetryDecision`), `assembly/request-route-retry`, and the root tests: `test/support/cure_consumer_case_test_helper.exs` (`{:ok, 40} = backoff(policy([]), 3)`, and a Runner start at about line 316), `test/retry_timeout_adapter_test.exs` (`policy/1` and the Runner) and `test/elz010_cure_probe_test.exs` with its fixture (Cure `RetryDecision` only). `pieces/workflow/state-machine/piece.json` says "unchanged Elzoo.RetryPolicy types"; that Piece is not changed here, and its claim stays true of the types it uses. Re-run `rg -n "RetryPolicy|RetryTimeout\." pieces lib test` and confirm it.
- The pinned Cure (`208248063d64…`) checks a law that is an equality by reduction over a record built by a constructor function, for example `delay(mk(max, base, cap, mode, JitterNone(), mfd), attempt, ClassRetryable(), None(), random)` equal to `backoff(…)`, and a law for the dispatched class over any policy. It rejects a mutation of the dispatched branch that uses the failure delay. It rejects, by compilation, a law that states an integer inequality, such as `max(fd, b) <= delay(…)` under full jitter. Integer `/` on `Int` truncates toward zero (`-7 / 2` is −3), which equals floor division for the non-negative operands that the boundary admits: `(4294967295 * 11) / 4294967296` is 10. An infix `+` inside an argument of `Equivalent(...)` does not parse; the same sum through a named helper function (`add(a, b)`) checks and audits clean. The pinned Cure erases `None()` to `:none` and `Some(n)` to `{:some, n}`. The coordinator checked this with a probe module at publication; the probe is not part of this task.

## The Contract change

### Policy keys

`policy/1` takes two more optional keys:

- `jitter`: `:none` (the default) or `:full`. Any other value is `{:error, :invalid_jitter}`.
- `max_failure_delay_ms`: an integer in 0..4,294,967,295. The default is 3,600,000, the clamp of ELZ-340. Any other value is `{:error, :invalid_max_failure_delay}`.

The existing checks keep their order and come first; then `jitter`, then `max_failure_delay_ms`. A call without the two keys returns a policy whose `classify/1`, `decide/3` and `backoff/2` results equal today's for every input.

The Cure record `RetryPolicy` gains two fields after `mode`: `jitter: RetryJitter`, with the new type `RetryJitter = JitterNone | JitterFull`, and `max_failure_delay_ms: Int`. Its erasure becomes `{:RetryPolicy, max, base, cap, mode, :JitterNone | :JitterFull, max_failure_delay_ms}`, and the README states it. `valid_policy?/1` accepts exactly that 7-tuple with the ranges of `policy/1`. Today's 5-tuple is refused `{:error, :invalid_policy}` by `decide/3`, `backoff/2` and `delay/4`, and `:invalid_options` by the Runner. No in-repo caller builds one (see the facts above). The bodies of the Cure functions `classify`, `retry_permitted`, `decide` and `backoff`, and the three existing laws, do not change.

### `delay/4`

`Elzoo.RetryTimeout.delay(policy, attempts_made, class, %{failure_delay_ms: fd, random: r})` returns `{:ok, ms}`:

- The input is a map with exactly the two keys `failure_delay_ms` and `random`. `fd` is `nil` or a non-negative integer of any size. `r` is an integer in 0..4,294,967,295. Any other input is `{:error, :invalid_delay_input}`.
- Errors are checked in this order: `{:error, :invalid_policy}`, `{:error, :invalid_attempt}` (as `backoff/2`), `{:error, :invalid_class}` (as `decide/3`), then `{:error, :invalid_delay_input}`.
- Let `b` be `backoff(policy, attempts_made)`, and `j` the jitter: `(r * (b + 1)) div 4,294,967,296` under `:full` (so `0 <= j <= b`; at `r` = 4,294,967,295, `j = b` when `b <= 4,294,967,295`, and `j < b` above that, for example `b` = 2^32 gives 2^32 − 1), and 0 under `:none`.
- For `:retryable` (a valid result that was not dispatched and is not permanent):
  - with `fd` = `nil`, the delay is `b` under `:none` and `j` under `:full` (full jitter);
  - with an integer `fd`, let `c = min(fd, max_failure_delay_ms)`. The delay is `max(c, b)` under `:none` and `max(c, b) + j` under `:full`. So the wait that the failure named, up to the clamp, is never cut short, repeated refusals with a short wait still back off, and callers given the same wait spread out under `:full`.
- For `:completed`, `:permanent` and `:dispatched`, the delay is exactly `b`. It ignores `fd`, `r` and `jitter`, so a possibly dispatched result keeps today's rule.
- The decision is a pure Cure function in `cure/elzoo/retry_policy.cure`. Its failure delay is `Option(Int)`, and the Elixir boundary maps `nil` to `None()` and an integer to `Some(fd)` after validation. The Elixir function adds no rule of its own.

`delay/4` does not decide whether to retry; that is still `decide/3`. Its result may pass the operation's deadline. A caller that has a deadline still checks it, and the Runner's deadline still wins, as today.

### The Runner

For a `:retry` decision, the Runner calls `delay/4` with `failure_delay_ms: nil` and a `random` value that it draws in its own process with `:rand.uniform(4_294_967_296) - 1`, instead of `backoff/2`. Under `jitter: :none` every timer is exactly today's. Under `:full`, a not-dispatched retry waits `j` in 0..`b`, and a dispatched retry in `:redispatch_idempotent` mode waits exactly `b`. The Runner takes no failure delay: the DeliveryResult it sees has no delay member. Its start options, admission, settlement and every other behaviour do not change.

### Laws

Selected laws in `cure/elzoo/retry_policy.cure`, checked and audited by the pinned Cure like the existing three. A law about a jitter kind takes the policy fields and builds the record through a constructor function, as the probe in the facts did:

1. `delay_completed_is_backoff`, `delay_permanent_is_backoff` and `delay_dispatched_is_backoff`: for every policy, attempt, failure delay option and random value, the delay of that class equals `backoff(policy, attempt)`.
2. `delay_retryable_none_without_failure_is_backoff`: under `JitterNone()` with `None()`, the delay equals `backoff`.
3. `delay_retryable_none_with_failure_is_max`: under `JitterNone()` with `Some(fd)`, the delay equals `max(min(fd, max_failure_delay_ms), backoff)`, through the Cure helpers that the production function uses.
4. `delay_retryable_full_without_failure_is_spread`: under `JitterFull()` with `None()`, the delay equals the spread `j` of `random` and `backoff`.
5. `delay_retryable_full_with_failure_is_max_plus_spread`: under `JitterFull()` with `Some(fd)`, the delay equals `max(min(fd, max_failure_delay_ms), backoff)` plus `j`. The law states the sum through a named helper function (for example `add/2`), because an infix `+` inside an `Equivalent(...)` argument does not parse (facts above); production may use infix `+`.

The range statements (`0 <= j <= b`, and `max(c, b) <= delay <= max(c, b) + b` under `:full`) are integer comparisons, which the pinned Cure does not check (facts above) and which this Piece already grounds in tests (its limits). They are test claims here, not proof claims. If a law in the list above cannot be checked by the pinned Cure as written, stop and comment on the issue with the compiler's output; do not weaken the law or move it to a test silently.

## Kept open (owner's "no corner" rule)

Each of these is addable in place before the first release without breaking a caller of this Contract:

- a failure delay read from the DeliveryResult envelope (a new optional member of `core/envelope`), and a Runner that passes it;
- jitter kinds `:equal` and `:decorrelated` (the `jitter` set can gain members);
- `Elzoo.AiText.Retry.next/4` and `Elzoo.AiEmbedding.Retry.next/4` using `delay/4` (their `credentials_unavailable` retry would then take jitter);
- an injectable random source for the Runner.

## Acceptance

New groups go in a new test file, for example `test/elzoo/retry_delay_test.exs`, listed in `piece.json`. Every existing test of the Piece passes unchanged, except the one change of the audit test named in group 6. Expected values come from the rules above, computed by hand or by an independent integer formula in the test, never from the function under test.

1. **`default_policy_unchanged`**:
   - `policy([])` and each existing option set without the new keys give `jitter` `:JitterNone` and `max_failure_delay_ms` 3,600,000 in the erasure.
   - A golden table of `backoff/2` for attempts 1 to 12 under the defaults, under `base` 0, under `base == cap` and under `base` 7 with `cap` 1,000, and of `decide/3` for every class under both modes at attempts 1, `max − 1` and `max`. Record the table on the base commit, before you change `lib/` or `cure/`, from the new test with the values unset (it prints them). Run it twice there, confirm equal values, then commit the values. If two runs on the base differ, stop and comment on the issue.
   - The same table passes with a policy that sets `jitter: :full` and `max_failure_delay_ms: 0`: the new keys change no `decide/3` or `backoff/2` result.
   - `policy/1` refuses `jitter: :equal`, `jitter: nil`, `max_failure_delay_ms: -1`, `4_294_967_296` and `1.0`, each with its fixed reason. `max_attempts: 0` together with `jitter: :equal` gives `:invalid_max_attempts` (the order). A `valid_policy?/1` call on today's 5-tuple is false.
2. **`not_dispatched_failure_delay`** (`jitter: :none`; `base` 100, `cap` 1,000, `max_failure_delay_ms` 5,000):
   - At attempt 1 (`b` 100): `nil` gives 100; `fd` 40 gives 100 (under `b`); `fd` 100 gives 100 (equal); `fd` 101 gives 101; `fd` 4,999, 5,000 and 5,001 give 4,999, 5,000 and 5,000; `fd` 10^12 gives 5,000.
   - At attempt 4 (`b` 800) `fd` 500 gives 800 and `fd` 900 gives 900; at attempt 5 (`b` 1,000, the cap) `fd` 999 gives 1,000.
   - With `max_failure_delay_ms` 0, `fd` 50 gives `b`.
   - The `random` value changes no result under `:none` (0 and 4,294,967,295 give equal results).
3. **`full_jitter`** (`jitter: :full`):
   - With `b` 100: `random` 0 gives 0; 4,294,967,295 gives 100; 2,147,483,648 gives 50. With `b` 0 every `random` gives 0. With `fd` 300 and `max_failure_delay_ms` 5,000, `random` 0 gives 300 and 4,294,967,295 gives 400.
   - A sweep: for each `b` in {0, 1, 2, 7, 1,000, 4,294,967,295} and 1,000 `random` values (from `:rand` seeded in the test, plus both ends), and `fd` in {`nil`, 0, `b`, `b` + 1, 10^7}, the result equals the independent formula and lies in its stated range.
4. **`dispatched_keeps_backoff`**: for `:dispatched`, `:completed` and `:permanent`, under both jitter kinds and both modes, with `fd` 10^6 and `random` 4,294,967,295, the delay equals `backoff/2` at attempts 1, 3 and 12.
5. **`delay_input_boundary`**: the input refused `:invalid_delay_input` when it has an extra key, lacks `random`, lacks `failure_delay_ms`, or has `random` −1, 4,294,967,296 or 1.5, or `failure_delay_ms` −1 or 1.5, and when it is a keyword list. Today's 5-tuple, and a 7-tuple with an unknown jitter atom, give `:invalid_policy`; attempt 0 gives `:invalid_attempt`; class `:unknown` gives `:invalid_class`. The order: a bad policy together with a bad input gives `:invalid_policy`, and a bad class together with a bad input gives `:invalid_class`.
6. **Laws and controls**: the audit test of `test/elzoo/retry_policy_test.exs` asserts that each new law is an export of the loaded module (as `test/elz010_cure_probe_test.exs` does for its laws), and its loop of rejected mutations gains two entries: (a) the dispatched branch of the delay uses the retryable rule with the failure delay, and (b) the clamp `min(fd, max_failure_delay_ms)` is dropped. Compilation rejects each.
7. **`runner_jitter`**:
   - A Runner with `jitter: :full` and `base_backoff_ms` 5, given a not-dispatched result and then a completed one, settles `{:completed, _}` after two attempts.
   - A Runner with `mode: :redispatch_idempotent`, `jitter: :full` and `base_backoff_ms` = `max_backoff_ms` = 3,600,000, given a failed, dispatched, retryable result: its retry timer (`:sys.get_state(pid).ops[ref].timers.retry`, whose third element is the monotonic target, as the existing runner tests read the deadline timer) is armed for `b` = 3,600,000 ms: with `t0` = `System.monotonic_time(:millisecond)` taken before the submit and `t1` after the state read, `t0 + b <= target <= t1 + b`. So the Runner passes the class of the result, and a possibly dispatched retry is not jittered.
   - A Runner with the default policy keeps every existing timer test unchanged.

**Negative controls**, each by a temporary edit of the production Cure function in the worktree, run, recorded and reverted (`AGENTS.md` section 4). With the laws in place each edit fails compilation; record that, then remove for the same run only the laws that the edit breaks, and record the ExUnit failure:

1. Apply the failure delay to `ClassDispatched`: group 4 fails.
2. Drop the `max_failure_delay_ms` clamp: the `fd` 5,001 and 10^12 cases of group 2 fail.
3. Give `:none` the jitter (use `j` under both kinds): group 2's `random` case fails.
4. In the Runner (an Elixir edit; no law breaks), pass `:retryable` to `delay/4` for every `:retry` decision: group 7's dispatched case fails (except when the jitter falls within the elapsed time `t1 − t0` of `b`).

Groups 2 to 4 carry the delay rule; group 7 carries the Runner's use of it.

## Documents

- `README.md`, "Pure policy": the sentence "no jitter" of `backoff/2` (it stays true of `backoff/2`; say that jitter is `delay/4`'s), the two keys, their defaults and errors, `delay/4` with its rule and error order, the new erasure, and the sentence that a possibly dispatched result's delay is exactly `backoff/2`. "Runner": the Runner draws its own random value and passes no failure delay. "Grounding and limits": "three here" and the list of laws gain the new laws.
- `piece.json`: `contract` gains `delay/4` ("a retry delay from a not-dispatched failure, clamped, with optional full jitter; every other class keeps backoff"); `grounding` gains one `proof` entry per new law and a `test` entry for the new test file; `files` lists it; `limits` gain "The jittered range bounds are finite test evidence, not laws. The random value is the caller's; the Runner uses `:rand` in its process, not a cryptographic source."
- The index row (`AGENTS.md` section 3) in the last commit: `manifest_sha256`, and `note` equal to the new `contract`.

## Gate, review and build

Run `mix test pieces/delivery/retry-timeout/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which runs the tests of every ready Piece that depends on this one (among them `integration/ai-text`, `integration/ai-embedding`, `integration/ai-batch`, `assembly/durable-job`, `assembly/http-job`, `workflow/state-machine`, `assembly/request-route-retry` and `delivery/circuit-breaker`) and the per-ID consumers, and `git diff --check`. The pull request body names the golden values and the negative-control results.

The full independent review of the coordinator guide ("Reviewer by risk") finds the code and a test for each rule of this text. Then the exact-head hosted `check-piece` and the merge queue.

## Limits to state

- The delay is a number; this Piece sleeps only in its Runner. A caller that waits elsewhere owns its timer.
- A failure delay is the caller's reading of the failure (for example `retry_after_ms` of a `delivery/rate-limit` refusal); this Piece does not check that the failure named it.
- The clamp bounds the wait that a failure can ask for; a delay above the operation's deadline is still returned, and the deadline check is the caller's (the Runner's deadline wins, as today).
- Full jitter can give a delay of 0 for a retryable result without a failure delay. When `b` is above 4,294,967,295 (`max_backoff_ms` has no upper bound), the jitter never quite reaches `b`.
- Selected laws cover the delay's equalities by class and jitter kind, not the ranges, the Runner or the boundary validation; those have finite test evidence.
