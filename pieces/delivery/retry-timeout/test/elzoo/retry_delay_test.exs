# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryDelayTest do
  use ExUnit.Case, async: false
  alias Elzoo.RetryTimeout, as: R
  alias Elzoo.RetryTimeout.Runner

  @policies [
    defaults: [],
    base_zero: [base_backoff_ms: 0],
    base_eq_cap: [base_backoff_ms: 250, max_backoff_ms: 250],
    base_7_cap_1000: [max_attempts: 5, base_backoff_ms: 7, max_backoff_ms: 1000]
  ]
  @classes [:completed, :permanent, :retryable, :dispatched]
  @modes [:redispatch_forbidden, :redispatch_idempotent]

  # Recorded twice on the base commit 2c277b64, before lib/ or cure/ changed; both runs equal.
  @golden [
    {:defaults,
     [
       redispatch_forbidden: [10, 20, 40, 80, 160, 320, 640, 1000, 1000, 1000, 1000, 1000],
       redispatch_idempotent: [10, 20, 40, 80, 160, 320, 640, 1000, 1000, 1000, 1000, 1000]
     ],
     [
       {:redispatch_forbidden, :completed, [:settle, :settle, :settle]},
       {:redispatch_forbidden, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_forbidden, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_forbidden, :dispatched, [:unresolved, :unresolved, :unresolved]},
       {:redispatch_idempotent, :completed, [:settle, :settle, :settle]},
       {:redispatch_idempotent, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_idempotent, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_idempotent, :dispatched, [:retry, :retry, :exhausted]}
     ]},
    {:base_zero,
     [
       redispatch_forbidden: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
       redispatch_idempotent: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
     ],
     [
       {:redispatch_forbidden, :completed, [:settle, :settle, :settle]},
       {:redispatch_forbidden, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_forbidden, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_forbidden, :dispatched, [:unresolved, :unresolved, :unresolved]},
       {:redispatch_idempotent, :completed, [:settle, :settle, :settle]},
       {:redispatch_idempotent, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_idempotent, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_idempotent, :dispatched, [:retry, :retry, :exhausted]}
     ]},
    {:base_eq_cap,
     [
       redispatch_forbidden: [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250],
       redispatch_idempotent: [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250]
     ],
     [
       {:redispatch_forbidden, :completed, [:settle, :settle, :settle]},
       {:redispatch_forbidden, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_forbidden, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_forbidden, :dispatched, [:unresolved, :unresolved, :unresolved]},
       {:redispatch_idempotent, :completed, [:settle, :settle, :settle]},
       {:redispatch_idempotent, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_idempotent, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_idempotent, :dispatched, [:retry, :retry, :exhausted]}
     ]},
    {:base_7_cap_1000,
     [
       redispatch_forbidden: [7, 14, 28, 56, 112, 224, 448, 896, 1000, 1000, 1000, 1000],
       redispatch_idempotent: [7, 14, 28, 56, 112, 224, 448, 896, 1000, 1000, 1000, 1000]
     ],
     [
       {:redispatch_forbidden, :completed, [:settle, :settle, :settle]},
       {:redispatch_forbidden, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_forbidden, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_forbidden, :dispatched, [:unresolved, :unresolved, :unresolved]},
       {:redispatch_idempotent, :completed, [:settle, :settle, :settle]},
       {:redispatch_idempotent, :permanent, [:permanent, :permanent, :permanent]},
       {:redispatch_idempotent, :retryable, [:retry, :retry, :exhausted]},
       {:redispatch_idempotent, :dispatched, [:retry, :retry, :exhausted]}
     ]}
  ]

  defp table(extra) do
    for {label, opts} <- @policies do
      max = Keyword.get(opts, :max_attempts, 3)

      backoff =
        for mode <- @modes do
          {:ok, policy} = R.policy(opts ++ [mode: mode] ++ extra)
          {mode, for(n <- 1..12, do: elem(R.backoff(policy, n), 1))}
        end

      decide =
        for mode <- @modes, class <- @classes do
          {:ok, policy} = R.policy(opts ++ [mode: mode] ++ extra)
          {mode, class, for(n <- [1, max - 1, max], do: elem(R.decide(policy, n, class), 1))}
        end

      {label, backoff, decide}
    end
  end

  test "default_policy_unchanged: golden backoff/2 and decide/3 table" do
    assert table([]) == @golden
  end

  @u32 4_294_967_295
  @two32 4_294_967_296

  defp policy!(opts) do
    {:ok, policy} = R.policy(opts)
    policy
  end

  defp delay(policy, n, class, fd, r),
    do: R.delay(policy, n, class, %{failure_delay_ms: fd, random: r})

  # Independent integer formula of the Contract text.
  defp spread(r, b), do: div(r * (b + 1), @two32)

  test "default_policy_unchanged: new keys default, change no backoff/2 or decide/3, refuse bad values" do
    for {_, opts} <-
          @policies ++ [idempotent: [mode: :redispatch_idempotent], max: [max_attempts: 7]] do
      assert {:ok, {:RetryPolicy, _, _, _, _, :JitterNone, 3_600_000}} = R.policy(opts)
    end

    assert table(jitter: :full, max_failure_delay_ms: 0) == @golden

    assert {:ok, {:RetryPolicy, 3, 10, 1000, :RedispatchForbidden, :JitterFull, 0}} =
             R.policy(jitter: :full, max_failure_delay_ms: 0)

    assert R.policy(jitter: :equal) == {:error, :invalid_jitter}
    assert R.policy(jitter: nil) == {:error, :invalid_jitter}
    assert R.policy(max_failure_delay_ms: -1) == {:error, :invalid_max_failure_delay}
    assert R.policy(max_failure_delay_ms: @two32) == {:error, :invalid_max_failure_delay}
    assert R.policy(max_failure_delay_ms: 1.0) == {:error, :invalid_max_failure_delay}
    assert {:ok, _} = R.policy(max_failure_delay_ms: @u32)
    assert R.policy(max_attempts: 0, jitter: :equal) == {:error, :invalid_max_attempts}
    assert R.policy(mode: :blind, jitter: :equal) == {:error, :invalid_mode}
    assert R.policy(jitter: :equal, max_failure_delay_ms: -1) == {:error, :invalid_jitter}
    refute R.valid_policy?({:RetryPolicy, 3, 10, 1000, :RedispatchForbidden})
    assert R.valid_policy?(policy!([]))
  end

  test "not_dispatched_failure_delay: the named wait, clamped, never shortens backoff" do
    p = policy!(base_backoff_ms: 100, max_backoff_ms: 1000, max_failure_delay_ms: 5000)

    # The random value changes no result under :none.
    for n <- [1, 4, 5], fd <- [nil, 40, 101, 900, 5001] do
      assert delay(p, n, :retryable, fd, 0) == delay(p, n, :retryable, fd, @u32)
    end

    for {fd, expected} <- [
          {nil, 100},
          {40, 100},
          {100, 100},
          {101, 101},
          {4999, 4999},
          {5000, 5000},
          {5001, 5000},
          {1_000_000_000_000, 5000}
        ],
        do: assert(delay(p, 1, :retryable, fd, 0) == {:ok, expected}, inspect(fd))

    assert delay(p, 4, :retryable, 500, 0) == {:ok, 800}
    assert delay(p, 4, :retryable, 900, 0) == {:ok, 900}
    assert delay(p, 5, :retryable, 999, 0) == {:ok, 1000}

    zero = policy!(base_backoff_ms: 100, max_backoff_ms: 1000, max_failure_delay_ms: 0)
    assert delay(zero, 1, :retryable, 50, 0) == {:ok, 100}
    assert delay(zero, 3, :retryable, 50, 0) == {:ok, 400}
  end

  test "full_jitter: spread in 0..b, added to the clamped wait; sweep against the formula" do
    p =
      policy!(base_backoff_ms: 100, max_backoff_ms: 1000, jitter: :full, max_failure_delay_ms: 5000)

    assert delay(p, 1, :retryable, nil, 0) == {:ok, 0}
    assert delay(p, 1, :retryable, nil, @u32) == {:ok, 100}
    assert delay(p, 1, :retryable, nil, 2_147_483_648) == {:ok, 50}
    assert delay(p, 1, :retryable, 300, 0) == {:ok, 300}
    assert delay(p, 1, :retryable, 300, @u32) == {:ok, 400}

    zero = policy!(base_backoff_ms: 0, jitter: :full)
    for r <- [0, 1, 2_147_483_648, @u32], do: assert(delay(zero, 1, :retryable, nil, r) == {:ok, 0})

    big = policy!(base_backoff_ms: @two32, max_backoff_ms: @two32, jitter: :full)
    assert delay(big, 1, :retryable, nil, @u32) == {:ok, @two32 - 1}

    :rand.seed(:exsss, {357, 357, 357})
    randoms = [0, @u32 | for(_ <- 1..1000, do: :rand.uniform(@two32) - 1)]
    mfd = 3_600_000

    for b <- [0, 1, 2, 7, 1000, @u32] do
      q = policy!(base_backoff_ms: b, max_backoff_ms: b, jitter: :full)
      assert R.backoff(q, 1) == {:ok, b}

      for r <- randoms, fd <- [nil, 0, b, b + 1, 10_000_000] do
        j = spread(r, b)
        assert j >= 0 and j <= b
        {:ok, d} = delay(q, 1, :retryable, fd, r)

        if is_nil(fd) do
          assert d == j
          assert d >= 0 and d <= b
        else
          floor = max(min(fd, mfd), b)
          assert d == floor + j
          assert d >= floor and d <= floor + b
        end
      end

      assert spread(@u32, b) == b
    end
  end

  test "dispatched_keeps_backoff: completed, permanent and dispatched ignore fd, random and jitter" do
    for class <- [:dispatched, :completed, :permanent],
        jitter <- [:none, :full],
        mode <- @modes,
        n <- [1, 3, 12] do
      p = policy!(base_backoff_ms: 7, max_backoff_ms: 1000, jitter: jitter, mode: mode)
      {:ok, b} = R.backoff(p, n)
      assert b == %{1 => 7, 3 => 28, 12 => 1000}[n]
      assert delay(p, n, class, 1_000_000, @u32) == {:ok, b}
    end
  end

  test "delay_input_boundary: fixed reasons in order" do
    p = policy!([])
    ok = %{failure_delay_ms: nil, random: 0}
    assert R.delay(p, 1, :retryable, ok) == {:ok, 10}

    for input <- [
          Map.put(ok, :extra, 1),
          %{failure_delay_ms: nil},
          %{random: 0},
          %{ok | random: -1},
          %{ok | random: @two32},
          %{ok | random: 1.5},
          %{ok | failure_delay_ms: -1},
          %{ok | failure_delay_ms: 1.5},
          [failure_delay_ms: nil, random: 0]
        ],
        do:
          assert(R.delay(p, 1, :retryable, input) == {:error, :invalid_delay_input}, inspect(input))

    assert R.delay({:RetryPolicy, 3, 10, 1000, :RedispatchForbidden}, 1, :retryable, ok) ==
             {:error, :invalid_policy}

    assert R.delay(
             {:RetryPolicy, 3, 10, 1000, :RedispatchForbidden, :JitterEqual, 3_600_000},
             1,
             :retryable,
             ok
           ) ==
             {:error, :invalid_policy}

    assert R.backoff({:RetryPolicy, 3, 10, 1000, :RedispatchForbidden}, 1) ==
             {:error, :invalid_policy}

    assert R.decide({:RetryPolicy, 3, 10, 1000, :RedispatchForbidden}, 1, :retryable) ==
             {:error, :invalid_policy}

    assert R.delay(p, 0, :retryable, ok) == {:error, :invalid_attempt}
    assert R.delay(p, 1, :unknown, ok) == {:error, :invalid_class}
    assert R.delay(nil, 1, :retryable, %{random: -1}) == {:error, :invalid_policy}
    assert R.delay(p, 0, :unknown, %{random: -1}) == {:error, :invalid_attempt}
    assert R.delay(p, 1, :unknown, %{random: -1}) == {:error, :invalid_class}
  end

  defp request(id) do
    %{
      "version" => 1,
      "message_id" => id,
      "schema_id" => "v",
      "schema_version" => 1,
      "kind" => "command",
      "producer" => %{"unit_id" => "u", "port_id" => "p"},
      "payload" => "p",
      "idempotency_key" => id
    }
  end

  defp result(req, outcome, dispatch, error) do
    common =
      Map.take(req, ~w(message_id attempt_id))
      |> Map.merge(%{
        "version" => 1,
        "correlation_id" => req["message_id"],
        "outcome" => outcome,
        "dispatch" => dispatch
      })

    if error,
      do: Map.put(common, "error_class", error),
      else:
        Map.merge(common, %{"value" => nil, "value_schema_id" => "v", "value_schema_version" => 1})
  end

  defp runner(attempt, policy_opts) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    start_supervised!(
      {Runner,
       capacity: 1,
       policy: policy!(policy_opts),
       attempt_timeout_ms: 1000,
       attempt: attempt,
       dead_letter: fn _ -> :ok end,
       task_supervisor: supervisor},
      id: make_ref()
    )
  end

  # Captures the first armed retry timer inside the runner (an OTP sys debug hook on each
  # {:noreply, state}), so a short jitter cannot let the timer fire before the test reads it.
  defp retry_window(outcome, dispatch, policy_opts) do
    parent = self()
    pid = runner(fn req -> result(req, outcome, dispatch, "retryable") end, policy_opts)

    hook = fn hook_state, event, _ ->
      with {:noreply, %{ops: ops}} <- event,
           [{_, _, target}] <- for({_, %{timers: %{retry: timer}}} <- ops, do: timer) do
        send(parent, {:first_retry, target})
        :done
      else
        _ -> hook_state
      end
    end

    :ok = :sys.install(pid, {hook, nil})
    t0 = System.monotonic_time(:millisecond)
    {:ok, _ref} = Runner.submit(pid, request("j"))
    assert_receive {:first_retry, target}, 2000
    {t0, target, System.monotonic_time(:millisecond)}
  end

  test "runner_jitter: the Runner passes the result class and its own random value to delay/4" do
    pid =
      runner(
        fn req ->
          if String.ends_with?(req["attempt_id"], "/attempt/1"),
            do: result(req, "rejected", "not_dispatched", "retryable"),
            else: result(req, "completed", "dispatched", nil)
        end,
        jitter: :full,
        base_backoff_ms: 5
      )

    # The Runner refuses today's 5-tuple policy at start.
    opts = [
      capacity: 1,
      attempt_timeout_ms: 1000,
      attempt: fn _ -> nil end,
      dead_letter: fn _ -> :ok end,
      task_supervisor: start_supervised!({Task.Supervisor, []}, id: make_ref())
    ]

    assert {:error, {:invalid_options, _}} =
             start_supervised(
               {Runner, [policy: {:RetryPolicy, 3, 10, 1000, :RedispatchForbidden}] ++ opts},
               id: make_ref()
             )

    assert {:ok, _} = start_supervised({Runner, [policy: policy!([])] ++ opts}, id: make_ref())

    {:ok, ref} = Runner.submit(pid, request("full"))
    assert_receive {R, ^ref, {:completed, done}}, 2000
    assert done["attempt_id"] == "full/attempt/2"

    b = 3_600_000

    # A possibly dispatched retry (idempotent mode) waits exactly b: never jittered.
    {t0, target, t1} =
      retry_window("failed", "dispatched",
        mode: :redispatch_idempotent,
        jitter: :full,
        base_backoff_ms: b,
        max_backoff_ms: b
      )

    assert t0 + b <= target and target <= t1 + b

    # A not-dispatched retry waits j in 0..b. This fails by chance only when the drawn
    # j lies within t1 - t0 of b, probability about (t1 - t0 + 1) / 3_600_001.
    {t0, target, t1} =
      retry_window("rejected", "not_dispatched",
        jitter: :full,
        base_backoff_ms: b,
        max_backoff_ms: b
      )

    assert t0 <= target and target <= t1 + b
    assert target < t0 + b
  end
end
