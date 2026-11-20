# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/retention_erasure_test_helper.exs", __DIR__)

defmodule Elzoo.RetentionErasureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL
  alias Elzoo.Encryption
  alias Elzoo.RetentionErasure, as: RE
  alias Elzoo.RetentionErasure.Migration
  alias Elzoo.Secrets.Credential

  alias Elzoo.RetentionErasure.{
    AdminRepo,
    DownRepo,
    Harness,
    IdleRepo,
    LogRepo,
    TestKek,
    TestRepo
  }

  @message "invalid retention erasure prefix or options"
  @ref ~r/\Av1_[A-Za-z0-9_-]{22}\z/

  setup_all do
    Harness.start!(AdminRepo, pool_size: 3)
    [[version]] = Harness.query!(AdminRepo, "SELECT current_setting('server_version_num')").rows
    assert String.to_integer(version) in 160_000..169_999
    Harness.start!(TestRepo, pool_size: 4)
    :ok
  end

  setup do
    prefix = Harness.install!(AdminRepo)
    on_exit(fn -> Harness.drop!(AdminRepo, prefix) end)
    kek = TestKek.start!()
    {:ok, p: prefix, kek: kek, v: vault(prefix, TestKek.need(kek))}
  end

  defp vault(p, need, repo \\ TestRepo), do: RE.vault(repo: repo, prefix: p, kek: need)

  defp admin!(sql, params \\ []), do: Harness.query!(AdminRepo, sql, params).rows

  defp count(p, table, subject),
    do: admin!(~s|SELECT count(*) FROM "#{p}".#{table} WHERE subject = $1|, [subject]) |> one()

  defp one([[value]]), do: value

  defp wrapped(p, subject, version \\ 1),
    do:
      admin!(~s|SELECT wrapped FROM "#{p}".elzoo_vault_keys WHERE subject = $1 AND version = $2|, [
        subject,
        version
      ])
      |> one()

  defp envelope(p, ref),
    do: admin!(~s|SELECT envelope FROM "#{p}".elzoo_vault_entries WHERE ref = $1|, [ref]) |> one()

  defp put!(v, subject, plaintext) do
    assert {:ok, ref} = RE.put(v, subject, plaintext)
    ref
  end

  # The test's own unwrap of a stored subject key, by the documented storage format.
  defp unwrap(wrapped, subject, version, kek),
    do: Encryption.open(wrapped, <<version::64, subject::binary>>, kek_keys(kek))

  defp kek_keys(kek), do: fn "elzoo-vault-kek", version -> TestKek.answer(kek, version) end

  # A keys Need over the vault's current key rows only: a missing (subject, version) is
  # {:error, :not_found}, as a host Need over a store that destroyed the key answers.
  defp vault_rows_keys(p, kek) do
    fn subject, version ->
      case admin!(
             ~s|SELECT wrapped FROM "#{p}".elzoo_vault_keys WHERE subject = $1 AND version = $2|,
             [subject, version]
           ) do
        [] ->
          {:error, :not_found}

        [[w]] ->
          {:ok, key} = unwrap(w, subject, version, kek)
          {:ok, TestKek.credential(key, version)}
      end
    end
  end

  defp marker(n), do: "pii-marker-#{n}-" <> Base.encode16(:crypto.strong_rand_bytes(8))

  defp waiters(p),
    do:
      admin!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND strpos(query, $1) > 0",
        [p]
      )
      |> one()

  # Waits until `n` statements of this test's schema wait on a lock, or one of `tasks` has ended.
  defp await_blocked(p, n, tasks, deadline \\ 500) do
    cond do
      waiters(p) >= n -> :blocked
      Enum.any?(tasks, &(not Process.alive?(&1.pid))) -> :ended
      deadline == 0 -> flunk("no lock wait observed")
      true -> Process.sleep(10) && await_blocked(p, n, tasks, deadline - 1)
    end
  end

  defp receive_kek_call(arg) do
    receive do
      {:kek_called, pid, ^arg} -> pid
    after
      5_000 -> flunk("the KEK Need was not called with #{inspect(arg)}")
    end
  end

  defp faults,
    do: [
      raise: fn _ -> raise "kek fault" end,
      throw: fn _ -> throw(:kek_fault) end,
      exit: fn _ -> exit(:kek_fault) end,
      not_found: fn _ -> {:error, :not_found} end,
      raw: fn _ -> {:ok, :binary.copy(<<7>>, 32)} end,
      short: fn _ ->
        {:ok, %Credential{value: :binary.copy(<<7>>, 31), version: 1, expires_at_unix_ms: 0}}
      end
    ]

  describe "1. round trip" do
    test "0-, 1- and 65,536-byte plaintexts for 1- and 128-byte subjects and two subjects",
         %{p: p, v: v, kek: kek} do
      long = String.duplicate("é", 64)
      assert byte_size(long) == 128
      m0 = marker(0)
      big = binary_part(:binary.copy(m0, div(65_536, byte_size(m0)) + 1), 0, 65_536)

      cases =
        for subject <- ["a", long], plaintext <- ["", "x", big, marker(1)] do
          ref = put!(v, subject, plaintext)
          assert ref =~ @ref
          {subject, ref, plaintext}
        end

      assert length(Enum.uniq_by(cases, &elem(&1, 1))) == length(cases)

      for {subject, ref, plaintext} <- cases do
        assert RE.fetch(v, ref) == {:ok, plaintext}
        # The stored format: key ID = subject, version 1, aad = ref, under the stored key.
        env = envelope(p, ref)
        assert Encryption.key_ref(env) == {:ok, %{key_id: subject, version: 1}}
        assert Encryption.open(env, ref, vault_rows_keys(p, kek)) == {:ok, plaintext}

        assert Encryption.open(env, "v1_" <> String.duplicate("A", 22), vault_rows_keys(p, kek)) ==
                 {:error, :invalid}
      end

      assert RE.status(v, "a") == {:ok, :active}
      assert RE.status(v, long) == {:ok, :active}
      assert RE.status(v, "nobody") == {:ok, :absent}
    end

    test "many entries of one subject share key version 1; raw rows hold no plaintext or key",
         %{p: p, v: v, kek: kek} do
      markers = for n <- 1..20, do: marker(n)
      refs = for m <- markers, do: put!(v, "principal:alice", m)
      other = put!(v, "principal:bob", marker(99))

      assert admin!(~s|SELECT subject, version FROM "#{p}".elzoo_vault_keys ORDER BY subject|) ==
               [["principal:alice", 1], ["principal:bob", 1]]

      assert admin!(~s|SELECT DISTINCT key_version FROM "#{p}".elzoo_vault_entries|) == [[1]]
      for {ref, m} <- Enum.zip(refs, markers), do: assert(RE.fetch(v, ref) == {:ok, m})
      assert {:ok, _} = RE.fetch(v, other)

      wa = wrapped(p, "principal:alice")
      wb = wrapped(p, "principal:bob")
      assert Encryption.key_ref(wa) == {:ok, %{key_id: "elzoo-vault-kek", version: 1}}
      {:ok, key_a} = unwrap(wa, "principal:alice", 1, kek)
      {:ok, key_b} = unwrap(wb, "principal:bob", 1, kek)
      assert byte_size(key_a) == 32 and key_a != key_b

      raw =
        admin!(~s|SELECT envelope FROM "#{p}".elzoo_vault_entries|) ++
          admin!(~s|SELECT wrapped FROM "#{p}".elzoo_vault_keys|)

      needles = [key_a, key_b, TestKek.bytes(kek, 1) | markers]

      for [bytes] <- raw, needle <- needles, do: assert(:binary.match(bytes, needle) == :nomatch)
    end
  end

  describe "2. erasure" do
    test "erase(A) leaves B, makes A :not_found and :erased, and blocks a later put", %{
      p: p,
      v: v,
      kek: kek
    } do
      a = for n <- 1..3, do: put!(v, "A", marker(n))
      b = put!(v, "B", "b-plaintext")
      copied = envelope(p, hd(a))
      [[now]] = admin!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      assert RE.erase(v, "A") == :ok
      for ref <- a, do: assert(RE.fetch(v, ref) == {:error, :not_found})
      assert RE.fetch(v, b) == {:ok, "b-plaintext"}
      assert RE.status(v, "A") == {:ok, :erased}
      assert RE.status(v, "B") == {:ok, :active}
      assert count(p, "elzoo_vault_keys", "A") == 0
      assert count(p, "elzoo_vault_entries", "A") == 0

      [[erased_at]] =
        admin!(~s|SELECT erased_at FROM "#{p}".elzoo_vault_subjects WHERE subject = 'A'|)

      assert erased_at in now..(now + 60)

      calls = length(TestKek.calls(kek))
      assert RE.put(v, "A", "again") == {:error, :erased}
      assert count(p, "elzoo_vault_keys", "A") == 0
      assert count(p, "elzoo_vault_entries", "A") == 0
      assert length(TestKek.calls(kek)) == calls

      # Crypto-shredding: the envelope copied before the erase has no key in the vault.
      assert Encryption.open(copied, hd(a), vault_rows_keys(p, kek)) == {:error, :no_key}

      # Erasing again is :ok and keeps the first erasure time.
      assert RE.erase(v, "A") == :ok

      assert admin!(~s|SELECT erased_at FROM "#{p}".elzoo_vault_subjects WHERE subject = 'A'|) ==
               [[erased_at]]
    end

    test "limit: a wrapped key copied before the erase unwraps until its KEK version is destroyed",
         %{p: p, v: v, kek: kek} do
      ref = put!(v, "A", "kept-by-backup")
      copied_env = envelope(p, ref)
      copied_key = wrapped(p, "A")
      assert RE.erase(v, "A") == :ok

      # The wrapped key's key ID is the KEK's, not the subject: the subject key outlives erase in
      # a copy while KEK version 1 exists.
      assert Encryption.key_ref(copied_key) == {:ok, %{key_id: "elzoo-vault-kek", version: 1}}
      assert {:ok, key} = unwrap(copied_key, "A", 1, kek)

      assert Encryption.open(copied_env, ref, fn "A", 1 -> {:ok, TestKek.credential(key, 1)} end) ==
               {:ok, "kept-by-backup"}

      TestKek.destroy(kek, 1)
      assert unwrap(copied_key, "A", 1, kek) == {:error, :no_key}
    end

    test "erase of an absent subject is :ok and blocks a later put", %{p: p, v: v, kek: kek} do
      assert RE.status(v, "ghost") == {:ok, :absent}
      assert RE.erase(v, "ghost") == :ok
      assert RE.status(v, "ghost") == {:ok, :erased}
      assert RE.put(v, "ghost", "x") == {:error, :erased}
      assert count(p, "elzoo_vault_keys", "ghost") == 0
      assert count(p, "elzoo_vault_entries", "ghost") == 0
      assert TestKek.calls(kek) == []
    end
  end

  describe "3. swaps" do
    setup %{p: p, v: v} do
      a1 = put!(v, "A", "a1-plaintext")
      a2 = put!(v, "A", "a2-plaintext")
      b1 = put!(v, "B", "b1-plaintext")
      {:ok, a1: a1, a2: a2, b1: b1, env_a1: envelope(p, a1)}
    end

    test "an entry envelope moved to another ref is :invalid", %{p: p, v: v} = ctx do
      admin!(~s|UPDATE "#{p}".elzoo_vault_entries SET envelope = $1 WHERE ref = $2|, [
        ctx.env_a1,
        ctx.a2
      ])

      assert RE.fetch(v, ctx.a2) == {:error, :invalid}

      new = "v1_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      admin!(
        ~s|INSERT INTO "#{p}".elzoo_vault_entries (ref, subject, key_version, envelope) VALUES ($1, 'A', 1, $2)|,
        [new, ctx.env_a1]
      )

      assert RE.fetch(v, new) == {:error, :invalid}
      assert RE.fetch(v, ctx.a1) == {:ok, "a1-plaintext"}
    end

    test "an entry moved to another subject, or B's ref holding A's envelope, never opens",
         %{p: p, v: v} = ctx do
      admin!(~s|UPDATE "#{p}".elzoo_vault_entries SET envelope = $1 WHERE ref = $2|, [
        ctx.env_a1,
        ctx.b1
      ])

      assert RE.fetch(v, ctx.b1) == {:error, :unavailable}
      admin!(~s|UPDATE "#{p}".elzoo_vault_entries SET subject = 'B' WHERE ref = $1|, [ctx.a1])
      assert RE.fetch(v, ctx.a1) == {:error, :unavailable}
    end

    test "a wrapped key moved to another subject is :unavailable for fetch and put",
         %{p: p, v: v} = ctx do
      admin!(~s|UPDATE "#{p}".elzoo_vault_keys SET wrapped = $1 WHERE subject = 'B'|, [
        wrapped(p, "A")
      ])

      assert RE.fetch(v, ctx.b1) == {:error, :unavailable}
      assert RE.put(v, "B", "b2") == {:error, :unavailable}
      assert count(p, "elzoo_vault_entries", "B") == 1
      assert RE.fetch(v, ctx.a1) == {:ok, "a1-plaintext"}
    end

    test "a wrapped key moved to another version is :unavailable for fetch and put",
         %{p: p, v: v} = ctx do
      admin!(
        ~s|INSERT INTO "#{p}".elzoo_vault_keys (subject, version, wrapped) SELECT subject, 2, wrapped FROM "#{p}".elzoo_vault_keys WHERE subject = 'A'|
      )

      # put/3 takes the newest version, 2, whose wrapped key is bound to version 1.
      assert RE.put(v, "A", "a3") == {:error, :unavailable}
      admin!(~s|DELETE FROM "#{p}".elzoo_vault_keys WHERE subject = 'A' AND version = 1|)
      admin!(~s|UPDATE "#{p}".elzoo_vault_entries SET key_version = 2 WHERE subject = 'A'|)
      assert RE.fetch(v, ctx.a1) == {:error, :unavailable}
      assert RE.fetch(v, ctx.a2) == {:error, :unavailable}
      assert RE.fetch(v, ctx.b1) == {:ok, "b1-plaintext"}
    end
  end

  describe "4. concurrency on PostgreSQL" do
    test "two first puts of one new subject store exactly one key row", %{p: p, kek: kek} do
      test = self()
      gated = vault(p, TestKek.gated(kek, test))
      plain = vault(p, TestKek.need(kek))

      first = Task.async(fn -> RE.put(gated, "S", "first") end)
      holder = receive_kek_call(:current)
      # The first put holds the uncommitted subject row; the second waits on it.
      second = Task.async(fn -> RE.put(plain, "S", "second") end)
      assert await_blocked(p, 1, [second]) == :blocked
      send(holder, :release)
      assert {:ok, r1} = Task.await(first)
      assert {:ok, r2} = Task.await(second)

      assert admin!(~s|SELECT version FROM "#{p}".elzoo_vault_keys WHERE subject = 'S'|) == [[1]]
      assert RE.fetch(plain, r1) == {:ok, "first"}
      assert RE.fetch(plain, r2) == {:ok, "second"}
    end

    test "two first puts that both pass the lock store one version 1 (ON CONFLICT, re-read)",
         %{p: p, kek: kek} do
      # A subject row with no key yet; both puts take FOR SHARE and both generate a key.
      admin!(~s|INSERT INTO "#{p}".elzoo_vault_subjects (subject, state) VALUES ('S', 'active')|)
      gated = vault(p, TestKek.gated(kek, self()))
      tasks = for label <- ["one", "two"], do: Task.async(fn -> RE.put(gated, "S", label) end)
      h1 = receive_kek_call(:current)
      h2 = receive_kek_call(:current)
      [t1] = Enum.filter(tasks, &(&1.pid == h1))
      [t2] = Enum.filter(tasks, &(&1.pid == h2))
      send(h1, :release)
      assert {:ok, r1} = Task.await(t1)
      send(h2, :release)
      # The second put's insert does nothing; it re-reads and unwraps the stored version 1.
      assert receive_kek_call(1) == h2
      send(h2, :release)
      assert {:ok, r2} = Task.await(t2)

      assert admin!(~s|SELECT version FROM "#{p}".elzoo_vault_keys WHERE subject = 'S'|) == [[1]]
      plain = vault(p, TestKek.need(kek))
      opened = for r <- [r1, r2], do: elem(RE.fetch(plain, r), 1)
      assert Enum.sort(opened) == ["one", "two"]
    end

    test "put holding its lock, then erase: the put commits first and its entry is gone",
         %{p: p, v: v, kek: kek} do
      for {subject, existing?} <- [{"old", true}, {"new", false}] do
        before = if existing?, do: put!(v, subject, "earlier")
        gated = vault(p, TestKek.gated(kek, self()))
        put = Task.async(fn -> RE.put(gated, subject, "racing") end)
        holder = receive_kek_call(if existing?, do: 1, else: :current)
        erase = Task.async(fn -> RE.erase(v, subject) end)
        # With FOR SHARE the erase waits for the put; without it the erase commits now.
        assert await_blocked(p, 1, [erase]) == :blocked
        send(holder, :release)
        assert {:ok, ref} = Task.await(put)
        assert Task.await(erase) == :ok

        assert RE.fetch(v, ref) == {:error, :not_found}
        if before, do: assert(RE.fetch(v, before) == {:error, :not_found})
        assert RE.status(v, subject) == {:ok, :erased}
        assert count(p, "elzoo_vault_keys", subject) == 0
        assert count(p, "elzoo_vault_entries", subject) == 0
      end
    end

    test "erase holding its lock, then put: the put is :erased, for an existing and an absent subject",
         %{p: p, v: v, kek: kek} do
      for {subject, existing?} <- [{"A", true}, {"ghost", false}] do
        if existing?, do: put!(v, subject, "earlier")
        calls = length(TestKek.calls(kek))
        test = self()

        # The test holds the entries table in SHARE mode so that the erase stops inside its
        # transaction, after its subject upsert (uncommitted for an absent subject) and before
        # its entry delete.
        locker =
          Task.async(fn ->
            AdminRepo.transact(fn ->
              Harness.query!(AdminRepo, ~s|LOCK TABLE "#{p}".elzoo_vault_entries IN SHARE MODE|)
              send(test, :locked)

              receive do
                :release -> {:ok, :ok}
              end
            end)
          end)

        assert_receive :locked, 5_000
        erase = Task.async(fn -> RE.erase(v, subject) end)
        assert await_blocked(p, 1, [erase]) == :blocked
        put = Task.async(fn -> RE.put(v, subject, "racing") end)
        assert await_blocked(p, 2, [put]) == :blocked
        send(locker.pid, :release)
        assert Task.await(locker) == {:ok, :ok}
        assert Task.await(erase) == :ok
        assert Task.await(put) == {:error, :erased}
        assert RE.status(v, subject) == {:ok, :erased}
        assert count(p, "elzoo_vault_keys", subject) == 0
        assert count(p, "elzoo_vault_entries", subject) == 0
        assert length(TestKek.calls(kek)) == calls
      end
    end

    test "free races of put and erase leave no key or entry of the subject", %{p: p, v: v} do
      for n <- 1..30 do
        subject = "race:#{n}"
        put!(v, subject, "seed")
        put = Task.async(fn -> RE.put(v, subject, "racing") end)
        erase = Task.async(fn -> RE.erase(v, subject) end)
        assert Task.await(erase) == :ok

        case Task.await(put) do
          {:ok, ref} -> assert RE.fetch(v, ref) == {:error, :not_found}
          other -> assert other == {:error, :erased}
        end

        assert count(p, "elzoo_vault_keys", subject) == 0
        assert count(p, "elzoo_vault_entries", subject) == 0
      end
    end
  end

  describe "5. KEK Need" do
    test "a first put whose Need fails is :unavailable and writes no row", %{p: p} do
      for {name, need} <- faults() do
        assert {name, RE.put(vault(p, need), "S", "x")} == {name, {:error, :unavailable}}

        for table <- ~w(elzoo_vault_subjects elzoo_vault_keys elzoo_vault_entries),
            do: assert(admin!(~s|SELECT count(*) FROM "#{p}".#{table}|) == [[0]])
      end
    end

    test "an unwrap whose Need fails or answers a wrong version is :unavailable, no row written",
         %{p: p, v: v, kek: kek} do
      ref = put!(v, "S", "x")
      bytes = TestKek.bytes(kek, 1)
      wrong = fn version -> {:ok, TestKek.credential(bytes, version + 1)} end

      for {name, need} <- [{:wrong_version, wrong} | faults()] do
        faulty = vault(p, need)
        assert {name, RE.put(faulty, "S", "y")} == {name, {:error, :unavailable}}
        assert {name, RE.fetch(faulty, ref)} == {name, {:error, :unavailable}}
        assert count(p, "elzoo_vault_entries", "S") == 1
        assert count(p, "elzoo_vault_keys", "S") == 1
      end

      assert RE.fetch(v, ref) == {:ok, "x"}
    end

    test "the Need is called once per seal or unwrap and never for :malformed or :in_transaction",
         %{v: v, kek: kek} do
      ref = put!(v, "S", "x")
      assert TestKek.calls(kek) == [:current]
      assert RE.fetch(v, ref) == {:ok, "x"}
      assert put!(v, "S", "y") =~ @ref
      assert TestKek.calls(kek) == [:current, 1, 1]

      assert RE.put(v, "", "x") == {:error, :malformed}
      assert RE.put(v, "S", :binary.copy("x", 65_537)) == {:error, :malformed}
      assert RE.fetch(v, "v1_short") == {:error, :malformed}

      assert {:ok, results} =
               TestRepo.transact(fn ->
                 {:ok, [RE.put(v, "T", "x"), RE.fetch(v, ref), RE.erase(v, "S"), RE.status(v, "S")]}
               end)

      assert results == List.duplicate({:error, :in_transaction}, 4)
      assert TestKek.calls(kek) == [:current, 1, 1]
    end
  end

  describe "6. shape and bounds" do
    @bad_subjects [
      "",
      String.duplicate("a", 129),
      <<0xFF>>,
      "a\0b",
      "a\x7Fb",
      "a\u0085b",
      "a\u001Fb",
      :subject,
      1,
      nil
    ]
    @bad_refs [
      "",
      "v1_",
      "v1_" <> String.duplicate("A", 21),
      "v1_" <> String.duplicate("A", 23),
      "v2_" <> String.duplicate("A", 22),
      "V1_" <> String.duplicate("A", 22),
      "v1_" <> String.duplicate("A", 21) <> "=",
      "v1_" <> String.duplicate("A", 21) <> "+",
      "v1_" <> String.duplicate("A", 21) <> "/",
      "v1_" <> String.duplicate("A", 21) <> "\0",
      :ref,
      nil
    ]

    test "bad subjects, plaintexts and refs are :malformed before any query", %{p: p, kek: kek} do
      # IdleRepo is not started: any query would be :unavailable.
      v = vault(p, TestKek.need(kek), IdleRepo)
      assert RE.status(v, "ok") == {:error, :unavailable}

      for s <- @bad_subjects do
        assert {s, RE.put(v, s, "x")} == {s, {:error, :malformed}}
        assert {s, RE.erase(v, s)} == {s, {:error, :malformed}}
        assert {s, RE.status(v, s)} == {s, {:error, :malformed}}
      end

      for pt <- [:binary.copy("x", 65_537), :text, ~c"chars", <<1::7>>],
          do: assert(RE.put(v, "S", pt) == {:error, :malformed})

      for r <- @bad_refs, do: assert({r, RE.fetch(v, r)} == {r, {:error, :malformed}})

      for bad_vault <- [nil, %{repo: TestRepo}, :vault] do
        assert RE.put(bad_vault, "S", "x") == {:error, :malformed}
        assert RE.fetch(bad_vault, "v1_" <> String.duplicate("A", 22)) == {:error, :malformed}
        assert RE.erase(bad_vault, "S") == {:error, :malformed}
        assert RE.status(bad_vault, "S") == {:error, :malformed}
      end

      assert TestKek.calls(kek) == []
    end

    test "boundary subjects and plaintexts that pass", %{v: v} do
      for s <- ["a", String.duplicate("a", 128), "a\u00A0b", "tenant:ü"] do
        ref = put!(v, s, :binary.copy("p", 65_536))
        assert RE.fetch(v, ref) == {:ok, :binary.copy("p", 65_536)}
      end

      # A well-formed ref that names no entry.
      assert RE.fetch(v, "v1_" <> String.duplicate("A", 22)) == {:error, :not_found}
      assert RE.fetch(v, "v1_" <> String.duplicate("-_", 11)) == {:error, :not_found}
    end

    test "every call inside an open repo.transact/2 is :in_transaction and runs nothing",
         %{p: p, v: v} do
      ref = put!(v, "S", "x")

      assert {:ok, results} =
               TestRepo.transact(fn ->
                 {:ok, [RE.put(v, "N", "y"), RE.fetch(v, ref), RE.erase(v, "S"), RE.status(v, "S")]}
               end)

      assert results == List.duplicate({:error, :in_transaction}, 4)
      assert RE.status(v, "S") == {:ok, :active}
      assert RE.status(v, "N") == {:ok, :absent}
      assert count(p, "elzoo_vault_entries", "S") == 1
    end

    test "an unreachable or unstarted Repo is :unavailable", %{p: p, kek: kek} do
      ref = "v1_" <> String.duplicate("A", 22)

      capture_log(fn ->
        {:ok, pid} =
          DownRepo.start_link(
            hostname: "127.0.0.1",
            port: 1,
            database: "elz279_unreachable",
            username: "nobody",
            pool_size: 1,
            queue_target: 20,
            queue_interval: 100,
            connect_timeout: 200,
            log: false
          )

        Process.unlink(pid)

        for repo <- [DownRepo, IdleRepo] do
          v = vault(p, TestKek.need(kek), repo)
          assert RE.put(v, "S", "x") == {:error, :unavailable}
          assert RE.fetch(v, ref) == {:error, :unavailable}
          assert RE.erase(v, "S") == {:error, :unavailable}
          assert RE.status(v, "S") == {:error, :unavailable}
        end

        Supervisor.stop(pid)
      end)

      assert TestKek.calls(kek) == []
    end

    test "a bad prefix or bad options raise the fixed ArgumentError", %{p: p} do
      need = fn _ -> {:error, :none} end

      for bad <- [
            "",
            "A",
            "1a",
            "a-b",
            "a;b",
            ~s(a"b),
            "public.x",
            String.duplicate("a", 64),
            :p,
            nil
          ] do
        assert_raise ArgumentError, @message, fn -> Migration.install(bad) end
        assert_raise ArgumentError, @message, fn -> vault(bad, need) end
      end

      assert %RE{} = vault(String.duplicate("a", 63), need)

      for opts <- [
            [repo: TestRepo, prefix: p],
            [repo: TestRepo, prefix: p, kek: need, extra: 1],
            [repo: TestRepo, prefix: p, kek: need, kek: need],
            [repo: "TestRepo", prefix: p, kek: need],
            [repo: TestRepo, prefix: p, kek: fn _, _ -> :ok end],
            %{repo: TestRepo, prefix: p, kek: need},
            nil
          ] do
        assert_raise ArgumentError, @message, fn -> RE.vault(opts) end
      end
    end
  end

  describe "7. secrecy" do
    test "no plaintext, key or KEK byte in results, raised messages, Inspect or logs",
         %{p: p, kek: kek} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      Harness.start!(LogRepo, pool_size: 1, log: :debug)
      v = vault(p, TestKek.need(kek), LogRepo)
      secret = marker(7)
      subject = "principal:" <> marker(8)

      {results, log} =
        with_log(fn ->
          ref = put!(v, subject, secret)
          {:ok, ^secret} = RE.fetch(v, ref)

          results = [
            ref,
            RE.put(v, subject, :binary.copy(secret, 10_000)),
            RE.put(vault(p, fn _ -> raise secret end, LogRepo), "other", secret),
            RE.fetch(vault(p, fn _ -> exit(secret) end, LogRepo), ref),
            RE.status(v, subject),
            RE.erase(v, subject),
            RE.fetch(v, ref),
            RE.put(v, subject, secret),
            inspect(v),
            Exception.message(catch_error(RE.vault(repo: LogRepo, prefix: secret, kek: & &1)))
          ]

          {:ok, _} = SQL.query(LogRepo, "SELECT $1::text", ["control-log-probe"])
          results
        end)

      assert Enum.at(results, -2) == "#Elzoo.RetentionErasure<redacted>"
      assert Enum.at(results, -1) == @message
      assert log =~ "control-log-probe"

      blob = :erlang.term_to_binary(results)
      needles = [secret, subject, TestKek.bytes(kek, 1), Base.encode16(TestKek.bytes(kek, 1))]

      for needle <- needles do
        assert :binary.match(blob, needle) == :nomatch
        refute log =~ needle
      end

      refute log =~ "elzoo_vault"
      # Transactions too: no BEGIN, COMMIT or ROLLBACK of the Piece reaches the Logger.
      refute log =~ ~r/\b(begin|commit|rollback)\b/i
    end

    test "subject keys never leave the vault in a result", %{p: p, v: v, kek: kek} do
      ref = put!(v, "S", "x")
      {:ok, key} = unwrap(wrapped(p, "S"), "S", 1, kek)

      results = [
        ref,
        RE.fetch(v, ref),
        RE.put(v, "S", "y"),
        RE.status(v, "S"),
        RE.erase(v, "S"),
        RE.fetch(v, ref)
      ]

      blob = :erlang.term_to_binary(results)
      assert :binary.match(blob, key) == :nomatch
      assert :binary.match(blob, TestKek.bytes(kek, 1)) == :nomatch
    end
  end
end
