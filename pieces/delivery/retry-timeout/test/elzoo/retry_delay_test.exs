# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryDelayTest do
  use ExUnit.Case, async: false
  alias Elzoo.RetryTimeout, as: R

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
end
