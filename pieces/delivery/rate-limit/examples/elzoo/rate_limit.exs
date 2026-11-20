# SPDX-License-Identifier: Apache-2.0
{:ok, limiter} =
  Elzoo.RateLimit.new(
    tenant_rate: %{capacity: 3, refill: 1, interval_ms: 1_000},
    principal_rate: %{capacity: 2, refill: 1, interval_ms: 500},
    max_in_flight: 4,
    tenant_in_flight: 2,
    max_keys: 1_024
  )

# The host holds the state and passes its own clock reading as now_ms.
key = %{tenant: "acme", principal: "user-1"}
{:ok, first, limiter} = Elzoo.RateLimit.admit(limiter, key, 1, 0)
{:ok, limiter} = Elzoo.RateLimit.release(limiter, first)
{:ok, second, limiter} = Elzoo.RateLimit.admit(limiter, key, 1, 0)

# The principal bucket is empty: refused with the exact wait; the state is unchanged.
{:refused, :principal_rate, 500, ^limiter} = Elzoo.RateLimit.admit(limiter, key, 1, 0)

# A second principal of the tenant takes its last fair-share slot; a third is refused.
{:ok, _third, limiter} = Elzoo.RateLimit.admit(limiter, %{key | principal: "user-2"}, 1, 0)
IO.inspect(Elzoo.RateLimit.admit(limiter, %{key | principal: "user-3"}, 1, 0) |> Tuple.delete_at(3))

# A release frees exactly the slots of its own admission, once.
{:ok, limiter} = Elzoo.RateLimit.release(limiter, second)
IO.inspect(Elzoo.RateLimit.release(limiter, second))

# The three tenant tokens are spent until the next whole interval.
user3 = %{key | principal: "user-3"}
IO.inspect(Elzoo.RateLimit.admit(limiter, user3, 1, 999) |> Tuple.delete_at(3))
IO.inspect(Elzoo.RateLimit.admit(limiter, user3, 1, 1_000) |> elem(0))
