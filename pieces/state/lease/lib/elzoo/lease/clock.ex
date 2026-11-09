# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease.Clock do
  @moduledoc """
  Store clocks for `Elzoo.Lease`. Times are integer microseconds since the
  Unix epoch (UTC). The lease never reads a node wall clock.

  PostgreSQL: `Elzoo.Lease.Postgres` samples `clock_timestamp()` **inside its
  transaction after the head row lock** with `postgres_sql/0`, on the same Repo
  as the Store. Memory: the manual clock of this module, sampled inside the
  owner's serialized section; tests move it explicitly.
  """

  @doc "SQL that samples the PostgreSQL server clock in microseconds."
  def postgres_sql, do: "SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000000)::bigint"

  @doc "Start a manual clock at `start_us`; returns `{:ok, pid}`."
  def manual(start_us) when is_integer(start_us) and start_us >= 0,
    do: Agent.start_link(fn -> %{now: start_us, fail: false} end)

  @doc "Sample the manual clock: `{:ok, now_us}` or `{:error, :clock_unavailable}`."
  def sample(pid) do
    Agent.get(pid, fn
      %{fail: true} -> {:error, :clock_unavailable}
      %{now: now} -> {:ok, now}
    end)
  catch
    :exit, _ -> {:error, :clock_unavailable}
  end

  def advance(pid, delta_us) when is_integer(delta_us),
    do: Agent.update(pid, &%{&1 | now: &1.now + delta_us})

  def set(pid, now_us) when is_integer(now_us) and now_us >= 0,
    do: Agent.update(pid, &%{&1 | now: now_us})

  @doc "Make the manual clock fail (`fail?` true) or answer again."
  def fail(pid, fail?) when is_boolean(fail?), do: Agent.update(pid, &%{&1 | fail: fail?})
end
