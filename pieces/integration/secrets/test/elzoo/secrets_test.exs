# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SecretsTest.Trap do
  defstruct [:observer, :secret]

  # Test-time implementations cannot extend a consolidated protocol. The
  # standalone consumer disables consolidation to exercise this adversarial
  # Inspect; the root suite still checks that secret-bearing terms never escape.
  unless Protocol.consolidated?(Inspect) do
    defimpl Inspect do
      def inspect(trap, _) do
        send(trap.observer, :inspected_secret)
        raise "secret Inspect must not run"
      end
    end
  end
end

defmodule Elzoo.SecretsTest.SecretError do
  defexception [:observer, :secret]

  def message(error) do
    send(error.observer, :formatted_secret)
    error.secret
  end
end

defmodule Elzoo.SecretsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Elzoo.Secrets
  alias Elzoo.SecretsTest.{SecretError, Trap}

  @max 9_007_199_254_740_991
  @request %{ref: "anthropic-key", scope: "tenant-a/anthropic/text"}
  @secret "sk-synthetic-SECRET-105"

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      Map.merge(@request, %{value: @secret, version: 7, expires_at_unix_ms: 200}),
      overrides
    )
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{grant: @request, resolver: fn _, _ -> {:ok, snapshot()} end, clock: fn -> 100 end},
      overrides
    )
  end

  test "success reveals unchanged binary, metadata and constant redacted Inspect" do
    {:ok, credential} = Secrets.resolve(@request, context())
    assert Secrets.reveal(credential) == @secret

    assert Map.from_struct(credential) ==
             Map.take(snapshot(), [:value, :version, :expires_at_unix_ms])

    assert inspect(credential) == "#Elzoo.Secrets.Credential<redacted>"

    for value <- [<<0>>, :binary.copy(<<255>>, 16_384)] do
      {:ok, other} =
        Secrets.resolve(
          @request,
          context(%{resolver: fn _, _ -> {:ok, snapshot(%{value: value})} end})
        )

      assert Secrets.reveal(other) == value
      assert inspect(other) == inspect(credential)
    end
  end

  test "request validation precedes context; identifiers are bounded opaque bytes" do
    invalid = [
      nil,
      [],
      %Trap{observer: self()},
      Map.put(@request, :extra, 1),
      Map.delete(@request, :ref)
    ]

    for key <- [:ref, :scope], value <- ["", :binary.copy("x", 129), :key, nil, 1] do
      assert Secrets.resolve(Map.put(@request, key, value), nil) == {:error, :malformed}
    end

    for request <- invalid, do: assert(Secrets.resolve(request, nil) == {:error, :malformed})

    for ref <- [<<0>>, :binary.copy(<<255>>, 128)] do
      request = %{ref: ref, scope: ref}

      ctx =
        context(%{grant: request, resolver: fn r, s -> {:ok, snapshot(%{ref: r, scope: s})} end})

      assert {:ok, _} = Secrets.resolve(request, ctx)
    end
  end

  test "invalid context is unavailable before denial; denied scope or ref never invokes callbacks" do
    observer = self()
    resolver = fn _, _ -> send(observer, :resolved) end
    clock = fn -> send(observer, :clocked) end
    ctx = context(%{resolver: resolver, clock: clock})

    invalid = [
      nil,
      [],
      %Trap{observer: observer},
      Map.delete(ctx, :grant),
      Map.delete(ctx, :resolver),
      Map.put(ctx, :extra, 1),
      %{ctx | resolver: fn -> :ok end},
      %{ctx | clock: nil},
      %{ctx | grant: %{ref: "x"}},
      %{ctx | grant: Map.put(@request, :extra, 1)},
      %{ctx | grant: Map.put(@request, :ref, "")},
      %{ctx | grant: Map.put(@request, :scope, :binary.copy("x", 129))}
    ]

    for bad <- invalid, do: assert(Secrets.resolve(@request, bad) == {:error, :unavailable})
    assert Secrets.resolve(@request, %{ctx | grant: :deny, clock: nil}) == {:error, :unavailable}

    for grant <- [
          :deny,
          %{@request | ref: "other"},
          %{@request | scope: "tenant-b/anthropic/text"},
          %{@request | scope: "tenant-a/openai/text"},
          %{@request | scope: "tenant-a/anthropic"}
        ] do
      assert Secrets.resolve(@request, %{ctx | grant: grant}) == {:error, :denied}
    end

    refute_received :resolved
    refute_received :clocked
  end

  test "finite resolver failures, unknown terms and malformed success remain distinct" do
    observer = self()
    clock = fn -> send(observer, :clocked) end

    for reason <- [:denied, :missing, :unavailable] do
      assert Secrets.resolve(
               @request,
               context(%{resolver: fn _, _ -> {:error, reason} end, clock: clock})
             ) == {:error, reason}
    end

    for result <- [
          :missing,
          {:error, @secret},
          {:ok, snapshot(), @secret},
          %Trap{observer: observer}
        ] do
      assert Secrets.resolve(@request, context(%{resolver: fn _, _ -> result end, clock: clock})) ==
               {:error, :unavailable}
    end

    malformed = [
      nil,
      [],
      %Trap{observer: observer},
      Map.put(snapshot(), :extra, 1),
      Map.delete(snapshot(), :version),
      snapshot(%{ref: "other"}),
      snapshot(%{scope: "other"})
    ]

    for field <- [:value, :version, :expires_at_unix_ms],
        value <- [nil, 1.0, %Trap{observer: observer}] do
      assert Secrets.resolve(
               @request,
               context(%{resolver: fn _, _ -> {:ok, snapshot(%{field => value})} end, clock: clock})
             ) == {:error, :malformed}
    end

    for bad <- malformed do
      assert Secrets.resolve(
               @request,
               context(%{resolver: fn _, _ -> {:ok, bad} end, clock: clock})
             ) == {:error, :malformed}
    end

    refute_received :clocked
    refute_received :inspected_secret
  end

  test "value, version, expiry and clock boundaries do not truncate or coerce" do
    for {field, values} <- [
          value: ["", :binary.copy("x", 16_385)],
          version: [0, -1, @max + 1],
          expires_at_unix_ms: [-1, @max + 1]
        ] do
      for value <- values do
        assert Secrets.resolve(
                 @request,
                 context(%{resolver: fn _, _ -> {:ok, snapshot(%{field => value})} end})
               ) == {:error, :malformed}
      end
    end

    for version <- [1, @max] do
      assert {:ok, credential} =
               Secrets.resolve(
                 @request,
                 context(%{
                   resolver: fn _, _ ->
                     {:ok, snapshot(%{version: version, expires_at_unix_ms: @max})}
                   end,
                   clock: fn -> @max - 1 end
                 })
               )

      assert credential.version == version
      assert credential.expires_at_unix_ms == @max
    end

    for now <- [0, 199, 200, 201, @max] do
      result = Secrets.resolve(@request, context(%{clock: fn -> now end}))
      if now < 200, do: assert(match?({:ok, _}, result)), else: assert(result == {:error, :expired})
    end

    assert Secrets.resolve(
             @request,
             context(%{
               resolver: fn _, _ -> {:ok, snapshot(%{expires_at_unix_ms: 0})} end,
               clock: fn -> 0 end
             })
           ) == {:error, :expired}

    for now <- [-1, @max + 1, 100.0, nil, @secret] do
      assert Secrets.resolve(@request, context(%{clock: fn -> now end})) == {:error, :unavailable}
    end

    assert {:ok, _} =
             Secrets.resolve(
               @request,
               Map.delete(
                 context(%{resolver: fn _, _ -> {:ok, snapshot(%{expires_at_unix_ms: @max})} end}),
                 :clock
               )
             )

    assert Secrets.resolve(
             @request,
             Map.delete(
               context(%{resolver: fn _, _ -> {:ok, snapshot(%{expires_at_unix_ms: 0})} end}),
               :clock
             )
           ) == {:error, :expired}
  end

  test "secret-bearing raise, throw, exit and malformed values are not formatted, logged or returned" do
    observer = self()
    trap = %Trap{observer: observer, secret: @secret}
    error = %SecretError{observer: observer, secret: @secret}

    faults = [
      fn -> raise error end,
      fn -> throw({@secret, trap}) end,
      fn -> exit({@secret, trap}) end
    ]

    log =
      capture_log(fn ->
        for fault <- faults do
          assert Secrets.resolve(@request, context(%{resolver: fn _, _ -> fault.() end})) ==
                   {:error, :unavailable}

          assert Secrets.resolve(@request, context(%{clock: fault})) == {:error, :unavailable}
        end

        assert Secrets.resolve(
                 @request,
                 context(%{resolver: fn _, _ -> {:ok, snapshot(%{value: trap})} end})
               ) == {:error, :malformed}

        assert inspect(elem(Secrets.resolve(@request, context()), 1)) ==
                 "#Elzoo.Secrets.Credential<redacted>"
      end)

    assert log == ""
    refute_received :inspected_secret
    refute_received :formatted_secret
  end

  test "expiry is sampled after a blocked lookup, once, not at call admission" do
    observer = self()

    resolver = fn _, _ ->
      send(observer, {:snapshot, self()})

      receive do
        :release -> {:ok, snapshot()}
      end
    end

    clock = fn ->
      send(observer, {:clock, self()})

      receive do
        {:now, now} -> now
      end
    end

    task =
      Task.async(fn -> Secrets.resolve(@request, context(%{resolver: resolver, clock: clock})) end)

    assert_receive {:snapshot, pid}
    refute_received {:clock, _}
    send(pid, :release)
    assert_receive {:clock, ^pid}
    send(pid, {:now, 200})
    assert Task.await(task) == {:error, :expired}
    refute_received {:snapshot, _}
    refute_received {:clock, _}
  end

  test "coherent concurrent snapshots straddle rotation; revocation cannot recall a held result" do
    observer = self()
    backend = start_supervised!({Agent, fn -> {:ok, snapshot()} end})

    resolver = fn _, _ ->
      result = Agent.get(backend, & &1)
      send(observer, {:snapshot, self()})

      receive do
        :release -> result
      end
    end

    resolve = fn -> Secrets.resolve(@request, context(%{resolver: resolver})) end

    old = Task.async(resolve)
    assert_receive {:snapshot, old_pid}

    Agent.update(backend, fn _ ->
      {:ok, snapshot(%{value: "rotated", version: 8, expires_at_unix_ms: 300})}
    end)

    new = Task.async(resolve)
    assert_receive {:snapshot, new_pid}
    Agent.update(backend, fn _ -> {:error, :denied} end)
    send(new_pid, :release)
    send(old_pid, :release)
    assert {:ok, previous} = Task.await(old)
    assert {:ok, current} = Task.await(new)

    assert {Secrets.reveal(previous), previous.version, previous.expires_at_unix_ms} ==
             {@secret, 7, 200}

    assert {Secrets.reveal(current), current.version, current.expires_at_unix_ms} ==
             {"rotated", 8, 300}

    revoked = Task.async(resolve)
    assert_receive {:snapshot, revoked_pid}
    send(revoked_pid, :release)
    assert Task.await(revoked) == {:error, :denied}
    assert Secrets.reveal(previous) == @secret
    assert Secrets.reveal(current) == "rotated"
  end
end
