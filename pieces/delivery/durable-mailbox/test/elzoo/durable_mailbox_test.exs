# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/durable_mailbox_test_helper.exs", __DIR__)

defmodule Elzoo.DurableMailboxTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableMailbox, as: MB
  alias Elzoo.DurableMailbox.{AdminRepo, AppRepo, CrashRepo, Harness, Migration, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @chains "elzoo_mailbox_chains"
  @links "elzoo_mailbox_links"
  @messages "elzoo_mailbox_messages"

  @post %{
    "type" => "object",
    "required" => ["text"],
    "properties" => %{"text" => %{"type" => "string"}}
  }

  @decl %{
    id: "room.mail",
    version: 1,
    max_pending: 64,
    messages: %{
      "chat.post" => %{schema_version: 1, schema: @post},
      "chat.react" => %{schema_version: 2, schema: %{"type" => "object"}},
      "blob" => %{schema_version: 1, schema: %{"type" => "string"}}
    }
  }

  setup_all do
    role = Harness.app_role!()
    Harness.start!(AdminRepo, pool_size: 3)
    [[version]] = Harness.query!(AdminRepo, "SELECT current_setting('server_version_num')").rows
    assert String.to_integer(version) in 160_000..169_999
    Harness.start!(AppRepo, pool_size: 6, after_connect: {Harness, :connect, [role, []]})

    Harness.start!(RepeatableRepo,
      pool_size: 1,
      after_connect:
        {Harness, :connect, [role, ["SET default_transaction_isolation = 'repeatable read'"]]}
    )

    # Every application connection is the non-owner role that does not bypass row security.
    assert [[^role, false, false]] =
             Harness.query!(
               AppRepo,
               "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             ).rows

    {:ok, role: role}
  end

  setup %{role: role} do
    p = install(role)
    {:ok, p: p, mb: mailbox(p)}
  end

  defp install(role) do
    p = Harness.install!(AdminRepo, role)
    on_exit(fn -> Harness.drop!(AdminRepo, p) end)
    p
  end

  defp mailbox(p, decl \\ @decl, repo \\ AppRepo) do
    {:ok, mb} = MB.new([repo: repo, prefix: p], decl)
    mb
  end

  defp opening(chain_id, changes \\ %{}) do
    Map.merge(
      %{
        chain_id: chain_id,
        run_id: "#{chain_id}/run-1",
        unit_identity: "#{chain_id}/unit-1",
        pin: "pin-a",
        carry: %{"start" => 1}
      },
      changes
    )
  end

  defp mail(id, changes \\ %{}) do
    {address, changes} = Map.pop(changes, :address, {:chain, "c1"})
    {sender, changes} = Map.pop(changes, :sender, %{kind: :human, id: "user-1"})

    message =
      Map.merge(
        %{message_id: id, name: "chat.post", schema_version: 1, payload: %{"text" => "hi #{id}"}},
        changes
      )

    %{sender: sender, address: address, message: message}
  end

  defp successor(chain_id, n, changes \\ %{}) do
    Map.merge(
      %{
        run_id: "#{chain_id}/run-#{n}",
        unit_identity: "#{chain_id}/unit-#{n}",
        carry: %{"start" => n},
        carry_kind: :finished
      },
      changes
    )
  end

  defp rolling(chain_id, seq, changes \\ %{}) do
    Map.merge(
      %{
        chain_id: chain_id,
        link_seq: seq,
        outcome: "completed",
        successor: successor(chain_id, seq + 1),
        change: nil
      },
      changes
    )
  end

  # Plan with change nil, then roll over: the successor keeps the pin.
  defp roll!(mb, tenant, chain_id, seq, changes \\ %{}) do
    r = rolling(chain_id, seq, changes)
    {:ok, _} = MB.plan_rollover(mb, tenant, %{chain_id: chain_id, link_seq: seq, change: r.change})
    next = seq + 1
    {:ok, %{seq: ^next}} = MB.rollover(mb, tenant, r)
    r
  end

  defp claim!(mb, tenant, chain_id) do
    {:ok, %{message: m} = claimed} = MB.claim(mb, tenant, %{chain_id: chain_id})
    Map.put(claimed, :message_id, m.message_id)
  end

  defp settle(mb, tenant, chain_id, message_id, link_seq, result),
    do:
      MB.settle(mb, tenant, %{
        chain_id: chain_id,
        message_id: message_id,
        link_seq: link_seq,
        result: result
      })

  defp status(mb, tenant, chain_id, message_id),
    do: MB.status(mb, tenant, %{chain_id: chain_id, message_id: message_id})

  defp tip(mb, tenant, chain_id) do
    {:ok, %{tip: tip}} = MB.chain(mb, tenant, %{chain_id: chain_id, after_seq: nil, limit: 1})
    tip
  end

  defp q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows

  # Every row of the three tables that the tenant's scope shows, read directly as the
  # application role inside Elzoo.TenantIsolation.transact/3 (the tables force row security,
  # so a read outside a scope shows nothing).
  defp rows(p, tenant) do
    {:ok, rows} =
      TI.transact(AppRepo, %{tenant: tenant}, fn ->
        {:ok,
         for t <- [@chains, @links, @messages] do
           q!(AppRepo, "SELECT * FROM #{p}.#{t} ORDER BY 1, 2, 3")
         end}
      end)

    rows
  end

  defp messages(p, tenant) do
    [_, _, messages] = rows(p, tenant)
    messages
  end

  defp owner(p, tenant, sql, params \\ []) do
    TI.transact(AdminRepo, %{tenant: tenant}, fn ->
      SQL.query(AdminRepo, String.replace(sql, "$P", p), params, log: false)
    end)
  end

  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code(other), do: other

  defp wait_until(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the barrier condition never held")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  # Backends of this database that wait on an ungranted lock (pg_locks), other than the
  # caller's own. pg_stat_activity keeps one snapshot per transaction unless it is cleared.
  defp waiting(repo) do
    q!(repo, "SELECT pg_stat_clear_snapshot()")

    [[n]] =
      q!(repo, """
      SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE NOT l.granted AND a.datname = current_database() AND l.pid <> pg_backend_pid()
      """)

    n
  end

  # Run `calls` one after the other while the owner holds `lock_sql` (FOR UPDATE) in an open
  # transaction, each seen waiting in pg_locks before the next starts; then release the lock
  # (rollback) and return the results in queue order.
  defp behind(p, lock_sql, calls) do
    {:error, {:held, tasks}} =
      TI.transact(AdminRepo, %{tenant: "T1"}, fn ->
        [_] = q!(AdminRepo, String.replace(lock_sql, "$P", p))

        tasks =
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {call, n} ->
            task = Task.async(call)
            wait_until(fn -> waiting(AdminRepo) == n end)
            task
          end)

        {:error, {:held, tasks}}
      end)

    Task.await_many(tasks, 10_000)
  end

  @chain_lock "SELECT chain_id FROM $P.elzoo_mailbox_chains WHERE chain_id = 'c1' FOR UPDATE"

  describe "1 the closed surface" do
    test "each refusal of put/3 steps 1-4 and 6-9 writes nothing", %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m0"))

      other = mailbox(p, %{@decl | version: 2})
      {:ok, :applied} = MB.open(other, "T1", opening("c-other"))
      {:ok, small} = MB.new([repo: AppRepo, prefix: p], %{@decl | max_pending: 1})
      {:ok, :applied} = MB.open(small, "T1", opening("c-small"))
      {:ok, :applied} = MB.put(small, "T1", mail("s0", %{address: {:chain, "c-small"}}))
      before = rows(p, "T1")

      refusals = [
        # 1 shape and bounds
        {mb, mail("m1", %{sender: %{kind: :bot, id: "x"}}), :invalid},
        {mb, mail("m1", %{address: {:room, "c1"}}), :invalid},
        {mb, mail(String.duplicate("m", 156)), :invalid},
        {mb, mail("m1", %{payload: %{"text" => {:tuple}}}), :invalid},
        # 2 undeclared name
        {mb, mail("m1", %{name: "chat.delete"}), :undeclared_name},
        {mb, mail("m1", %{name: "Chat.Post"}), :undeclared_name},
        # 3 schema version
        {mb, mail("m1", %{schema_version: 2}), :schema_version},
        # 4 payload against the declared schema
        {mb, mail("m1", %{payload: %{"text" => 5}}), :invalid_payload},
        {mb, mail("m1", %{payload: %{}}), :invalid_payload},
        {mb, mail("m1", %{name: "blob", payload: 7}), :invalid_payload},
        # 6 the address names no chain of the tenant
        {mb, mail("m1", %{address: {:chain, "absent"}}), :unknown_chain},
        {mb, mail("m1", %{address: {:run, "absent"}}), :unknown_chain},
        # 7 a binding with another declaration
        {other, mail("m1"), :declaration_mismatch},
        {mb, mail("m1", %{address: {:chain, "c-other"}}), :declaration_mismatch},
        # 8 a stored message_id with other bytes
        {mb, mail("m0", %{payload: %{"text" => "edited"}}), :conflict},
        # 9 the chain holds max_pending open messages
        {small, mail("s1", %{address: {:chain, "c-small"}}), :mailbox_full}
      ]

      for {binding, request, reason} <- refusals do
        assert MB.put(binding, "T1", request) == {:error, reason}, inspect({request, reason})
        assert rows(p, "T1") == before
      end

      # The undeclared name and the failing payload left no row of their message ID.
      assert Enum.sort(for row <- messages(p, "T1"), do: Enum.at(row, 2)) == ["m0", "s0"]
    end

    test "new/2 refuses a declaration that does not build or breaks a bound", %{p: p} do
      opts = [repo: AppRepo, prefix: p]
      spec = %{schema_version: 1, schema: %{"type" => "object"}}
      names = fn n -> Map.new(1..n, &{"n#{&1}", spec}) end

      assert {:ok, _} = MB.new(opts, %{@decl | messages: names.(64)})
      assert {:ok, _} = MB.new(opts, %{@decl | messages: names.(1)})

      bad = [
        %{@decl | messages: %{"a" => %{schema_version: 1, schema: %{"$ref" => "https://x/s"}}}},
        %{@decl | messages: %{"a" => %{schema_version: 1, schema: %{"type" => 7}}}},
        %{@decl | messages: %{"a" => %{schema_version: 1, schema: [1]}}},
        %{@decl | messages: %{}},
        %{@decl | messages: names.(65)},
        %{@decl | messages: %{"Chat" => spec}},
        %{@decl | messages: %{"a b" => spec}},
        %{@decl | messages: %{String.duplicate("a", 129) => spec}},
        %{@decl | messages: %{"a" => %{spec | schema_version: 0}}},
        %{@decl | messages: %{"a" => Map.put(spec, :extra, 1)}},
        %{@decl | id: "Room"},
        %{@decl | id: ""},
        %{@decl | id: String.duplicate("a", 129)},
        %{@decl | version: 0},
        %{@decl | version: 2_147_483_648},
        Map.delete(@decl, :max_pending),
        Map.put(@decl, :extra, 1)
      ]

      for d <- bad, do: assert(MB.new(opts, d) == {:error, :invalid_declaration}, inspect(d))

      assert {:ok, _} = MB.new(opts, %{@decl | id: String.duplicate("a", 128)})
      assert {:ok, _} = MB.new(opts, %{@decl | version: 2_147_483_647})

      for o <- [[repo: AppRepo], [repo: AppRepo, prefix: "Bad"], [repo: nil, prefix: p], %{}],
          do: assert(MB.new(o, @decl) == {:error, :invalid_declaration})
    end

    test "the declaration identity is SHA-256 of the README canonical encoding", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))

      {:ok, %{declaration: identity}} =
        MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 1})

      # Written out by hand: keys sorted by their bytes at every level, compact.
      text =
        ~s({"id":"room.mail","max_pending":64,"messages":{"blob":{"schema":{"type":"string"},"schema_version":1},) <>
          ~s("chat.post":{"schema":{"properties":{"text":{"type":"string"}},"required":["text"],"type":"object"},"schema_version":1},) <>
          ~s("chat.react":{"schema":{"type":"object"},"schema_version":2}},"version":1})

      assert identity ==
               {"room.mail", 1, Base.encode16(:crypto.hash(:sha256, text), case: :lower)}
    end
  end

  describe "1b canonical JSON" do
    test "payload and carry are stored as the README canonical JSON", %{mb: mb, p: p} do
      carry = %{"b" => [1, 1.0, 1.5e20, nil, true], "a" => %{"z" => "", "Z" => "q"}}
      {:ok, :applied} = MB.open(mb, "T1", opening("c1", %{carry: carry}))

      payload = %{
        "text" => "\"\\/\u0001\n\té\u2028",
        "aa" => -0.0,
        "a" => 12_345_678_901_234_567_890
      }

      {:ok, :applied} = MB.put(mb, "T1", mail("m1", %{payload: payload}))
      [_, [link], [message]] = rows(p, "T1")

      assert Enum.at(link, 8) ==
               ~s({"a":{"Z":"q","z":""},"b":[1,1.0,1.5e20,null,true]})

      assert Enum.at(message, 8) ==
               ~s({"a":12345678901234567890,"aa":-0.0,"text":"\\"\\\\/\\u0001\\n\\t) <>
                 "é\u2028\"}"

      assert %{message: %{payload: ^payload}} = claim!(mb, "T1", "c1")
      assert %{carry: ^carry} = tip(mb, "T1", "c1")
    end
  end

  describe "2 bounds" do
    test "message_id, payload and carry at the bound and one past it", %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))

      # A JSON string of n characters is n + 2 bytes.
      at = String.duplicate("a", 65_534)
      past = String.duplicate("a", 65_535)
      assert MB.put(mb, "T1", mail(String.duplicate("m", 155))) == {:ok, :applied}
      assert MB.put(mb, "T1", mail("é" <> String.duplicate("m", 153))) == {:ok, :applied}
      assert MB.put(mb, "T1", mail("é" <> String.duplicate("m", 154))) == {:error, :invalid}
      assert MB.put(mb, "T1", mail("big", %{name: "blob", payload: at})) == {:ok, :applied}
      assert MB.put(mb, "T1", mail("big2", %{name: "blob", payload: past})) == {:error, :invalid}

      # Sorted keys and no whitespace: 65,536 canonical bytes.
      object = %{"text" => String.duplicate("b", 65_536 - 11)}
      assert byte_size(Jason.encode!(object)) == 65_536
      assert MB.put(mb, "T1", mail("obj", %{payload: object})) == {:ok, :applied}

      assert MB.put(
               mb,
               "T1",
               mail("obj2", %{payload: Map.put(object, "text", "b" <> object["text"])})
             ) ==
               {:error, :invalid}

      assert MB.open(mb, "T1", opening("c2", %{carry: at})) == {:ok, :applied}
      assert MB.open(mb, "T1", opening("c3", %{carry: past})) == {:error, :invalid}
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c2", link_seq: 1, change: nil})

      assert MB.rollover(
               mb,
               "T1",
               rolling("c2", 1, %{successor: successor("c2", 2, %{carry: past})})
             ) ==
               {:error, :invalid}

      assert MB.rollover(mb, "T1", rolling("c2", 1, %{successor: successor("c2", 2, %{carry: at})})) ==
               {:ok, %{seq: 2}}

      assert tip(mb, "T1", "c2").carry == at

      # Depth: 32 nested containers pass, 33 do not.
      nest = fn n -> Enum.reduce(1..n, "x", fn _, acc -> [acc] end) end

      assert MB.put(
               mb,
               "T1",
               mail("d32", %{name: "chat.react", schema_version: 2, payload: %{"a" => nest.(31)}})
             ) == {:ok, :applied}

      assert MB.put(
               mb,
               "T1",
               mail("d33", %{name: "chat.react", schema_version: 2, payload: %{"a" => nest.(32)}})
             ) == {:error, :invalid}

      {:ok, %{message: %{payload: ^at}}} =
        with {:ok, %{message: %{message_id: id}}} <- MB.claim(mb, "T1", %{chain_id: "c1"}),
             {:ok, :applied} <- settle(mb, "T1", "c1", id, 1, :applied),
             {:ok, %{message: %{message_id: id}}} <- MB.claim(mb, "T1", %{chain_id: "c1"}),
             {:ok, :applied} <- settle(mb, "T1", "c1", id, 1, :applied),
             do: MB.claim(mb, "T1", %{chain_id: "c1"})

      assert length(messages(p, "T1")) == 5
    end

    test "max_pending 0 and 65,537 are refused; 1 and 65,536 are accepted", %{p: p} do
      opts = [repo: AppRepo, prefix: p]

      for n <- [0, 65_537, -1, 1.0],
          do: assert(MB.new(opts, %{@decl | max_pending: n}) == {:error, :invalid_declaration})

      for n <- [1, 65_536], do: assert({:ok, _} = MB.new(opts, %{@decl | max_pending: n}))
    end

    test "text fields at 0, 1, the bound and one past it; control characters", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      t128 = String.duplicate("t", 128)
      t129 = String.duplicate("t", 129)
      u160 = String.duplicate("u", 160)
      u161 = String.duplicate("u", 161)

      for {field, value, result} <- [
            {:chain_id, t128, {:ok, :applied}},
            {:chain_id, t129, {:error, :invalid}},
            {:chain_id, "", {:error, :invalid}},
            {:chain_id, "c\u0085", {:error, :invalid}},
            {:chain_id, "c\n", {:error, :invalid}},
            {:chain_id, <<0xFF>>, {:error, :invalid}},
            {:run_id, t129, {:error, :invalid}},
            {:pin, t129, {:error, :invalid}},
            {:unit_identity, u161, {:error, :invalid}},
            {:unit_identity, "u\0", {:error, :invalid}}
          ] do
        request = Map.put(opening("bound-#{field}-#{byte_size(value)}"), field, value)
        assert MB.open(mb, "T1", request) == result, inspect({field, value})
      end

      # A unit identity may hold control characters other than NUL.
      assert MB.open(mb, "T1", opening("u1", %{unit_identity: u160})) == {:ok, :applied}
      assert MB.open(mb, "T1", opening("u2", %{unit_identity: "u\n2"})) == {:ok, :applied}
      assert MB.open(mb, "T1", opening("c1", %{}) |> Map.put(:extra, 1)) == {:error, :invalid}
      assert MB.open(mb, t129, opening("t")) == {:error, :invalid}
      assert MB.put(mb, "T1", mail("m", %{sender: %{kind: :human, id: t129}})) == {:error, :invalid}

      for outcome <- ["", "Done", String.duplicate("o", 65)],
          do:
            assert(
              MB.rollover(mb, "T1", rolling("c1", 1, %{outcome: outcome})) == {:error, :invalid}
            )

      assert MB.plan_rollover(mb, "T1", %{
               chain_id: "c1",
               link_seq: 1,
               change: %{pin: "p", ref: String.duplicate("r", 257)}
             }) ==
               {:error, :invalid}

      assert {:ok, _} =
               MB.plan_rollover(mb, "T1", %{
                 chain_id: "c1",
                 link_seq: 1,
                 change: %{pin: "p", ref: String.duplicate("r", 256)}
               })

      assert MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 0}) == {:error, :invalid}
      assert MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 257}) == {:error, :invalid}

      assert MB.settle(mb, "T1", %{
               chain_id: "c1",
               message_id: "m",
               link_seq: 1,
               result: {:refused, :other}
             }) == {:error, :invalid}
    end
  end

  describe "3 duplicate and conflict" do
    test "open/3: an equal request is :duplicate, a changed field or declaration :conflict",
         %{mb: mb, p: p} do
      o = opening("c1")
      assert MB.open(mb, "T1", o) == {:ok, :applied}
      assert MB.open(mb, "T1", o) == {:ok, :duplicate}

      for {field, value} <- [
            run_id: "r2",
            unit_identity: "u2",
            pin: "pin-b",
            carry: %{"start" => 2},
            carry: %{"start" => 1.0}
          ],
          do: assert(MB.open(mb, "T1", Map.put(o, field, value)) == {:error, :conflict})

      # Key order is not part of the bytes: the canonical encoding sorts keys.
      assert MB.open(mb, "T1", %{o | carry: Map.new([{"start", 1}])}) == {:ok, :duplicate}
      assert MB.open(mailbox(p, %{@decl | max_pending: 9}), "T1", o) == {:error, :conflict}
      # Still a duplicate after the chain rolled over.
      roll!(mb, "T1", "c1", 1)
      assert MB.open(mb, "T1", o) == {:ok, :duplicate}
      assert [[_ | _]] = Enum.at(rows(p, "T1"), 0)
    end

    test "put/3: equal bytes are :duplicate wherever addressed, other bytes :conflict",
         %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      m = mail("m1")
      assert MB.put(mb, "T1", m) == {:ok, :applied}
      assert MB.put(mb, "T1", m) == {:ok, :duplicate}
      assert MB.put(mb, "T1", %{m | address: {:run, "c1/run-1"}}) == {:ok, :duplicate}

      for changed <- [
            mail("m1", %{sender: %{kind: :agent, id: "user-1"}}),
            mail("m1", %{sender: %{kind: :human, id: "user-2"}}),
            mail("m1", %{name: "chat.react", schema_version: 2, payload: %{"text" => "hi m1"}}),
            mail("m1", %{payload: %{"text" => "hi m2"}}),
            mail("m1", %{payload: %{"text" => "hi m1", "x" => nil}})
          ],
          do: assert(MB.put(mb, "T1", changed) == {:error, :conflict})

      roll!(mb, "T1", "c1", 1)
      # The same mail put to the chain and to a closed link's run_id is one message.
      m2 = mail("m2")
      assert MB.put(mb, "T1", %{m2 | address: {:run, "c1/run-1"}}) == {:ok, :applied}
      assert MB.put(mb, "T1", m2) == {:ok, :duplicate}
      assert MB.put(mb, "T1", %{m2 | address: {:run, "c1/run-2"}}) == {:ok, :duplicate}
      assert MB.put(mb, "T1", %{m | address: {:run, "c1/run-2"}}) == {:ok, :duplicate}
      assert length(messages(p, "T1")) == 2
    end

    test "two concurrent open/3 calls of one chain_id give one chain", %{mb: mb, p: p} do
      table = "#{p}.#{@chains}"

      held = fn calls ->
        {:ok, tasks} =
          AdminRepo.transact(fn ->
            q!(AdminRepo, "LOCK TABLE #{table} IN SHARE MODE")
            tasks = for call <- calls, do: Task.async(call)

            wait_until(fn ->
              q!(
                AdminRepo,
                "SELECT count(*) FROM pg_locks WHERE relation = to_regclass($1) AND mode = 'RowExclusiveLock' AND NOT granted",
                [table]
              ) == [[length(calls)]]
            end)

            {:ok, tasks}
          end)

        Task.await_many(tasks, 10_000)
      end

      o = opening("c1")
      results = held.([fn -> MB.open(mb, "T1", o) end, fn -> MB.open(mb, "T1", o) end])
      assert Enum.sort(results) == [{:ok, :applied}, {:ok, :duplicate}]

      o2 = opening("c2")
      other = %{o2 | carry: %{"start" => 2}}
      results = held.([fn -> MB.open(mb, "T1", o2) end, fn -> MB.open(mb, "T1", other) end])
      assert Enum.sort(results) == [{:error, :conflict}, {:ok, :applied}]

      [chains, links, _] = rows(p, "T1")
      assert Enum.map(chains, &Enum.at(&1, 1)) == ["c1", "c2"]
      assert Enum.map(links, &Enum.take(&1, 3)) == [["T1", "c1", 1], ["T1", "c2", 1]]
    end
  end

  describe "4 FIFO" do
    test "messages are claimed in their order; :not_applied makes one the next claim again",
         %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      for id <- ["m-c", "m-a", "m-b"], do: {:ok, :applied} = MB.put(mb, "T1", mail(id))

      first = claim!(mb, "T1", "c1")

      assert %{message_id: "m-c", link_seq: 1, run_id: "c1/run-1", unit_identity: "c1/unit-1"} =
               first

      assert first.message == %{
               message_id: "m-c",
               sender: %{kind: :human, id: "user-1"},
               name: "chat.post",
               schema_version: 1,
               payload: %{"text" => "hi m-c"},
               seq: 1
             }

      # A second claim before the settle gives the delivering message again.
      assert claim!(mb, "T1", "c1") == first
      {:ok, :applied} = settle(mb, "T1", "c1", "m-c", 1, :applied)
      assert %{message_id: "m-a", message: %{seq: 2}} = claim!(mb, "T1", "c1")
      {:ok, :applied} = settle(mb, "T1", "c1", "m-a", 1, :not_applied)
      assert status(mb, "T1", "c1", "m-a") == {:ok, %{state: :pending, link_seq: nil, reason: nil}}
      assert %{message_id: "m-a", message: %{seq: 2}} = claim!(mb, "T1", "c1")
      {:ok, :applied} = settle(mb, "T1", "c1", "m-a", 1, :applied)
      assert %{message_id: "m-b", message: %{seq: 3}} = claim!(mb, "T1", "c1")
      {:ok, :applied} = settle(mb, "T1", "c1", "m-b", 1, :applied)
      assert MB.claim(mb, "T1", %{chain_id: "c1"}) == {:ok, :empty}
      assert MB.claim(mb, "T1", %{chain_id: "absent"}) == {:error, :unknown_chain}
    end
  end

  describe "5 mailbox_full" do
    test "at max_pending 1 and 2; a duplicate at the bound is :duplicate", %{p: p} do
      for n <- [1, 2] do
        mb = mailbox(p, %{@decl | max_pending: n})
        chain = "c#{n}"
        at = fn id -> mail(id, %{address: {:chain, chain}}) end
        {:ok, :applied} = MB.open(mb, "T1", opening(chain))
        for i <- 1..n, do: assert(MB.put(mb, "T1", at.("m#{i}")) == {:ok, :applied})
        assert MB.put(mb, "T1", at.("over")) == {:error, :mailbox_full}
        assert MB.put(mb, "T1", at.("m#{n}")) == {:ok, :duplicate}
        assert MB.put(mb, "T1", at.("m1")) == {:ok, :duplicate}

        # A delivering message is still open; a consumed one is not.
        %{message_id: "m1"} = claim!(mb, "T1", chain)
        assert MB.put(mb, "T1", at.("over")) == {:error, :mailbox_full}
        {:ok, :applied} = settle(mb, "T1", chain, "m1", 1, :applied)
        assert MB.put(mb, "T1", at.("over")) == {:ok, :applied}
        assert MB.put(mb, "T1", at.("over2")) == {:error, :mailbox_full}
      end
    end
  end

  describe "6 mail to a superseded identity" do
    test "mail addressed to a closed link's run_id is claimed for the tip", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      roll!(mb, "T1", "c1", 1)
      roll!(mb, "T1", "c1", 2)
      assert MB.put(mb, "T1", mail("m1", %{address: {:run, "c1/run-1"}})) == {:ok, :applied}

      assert %{message_id: "m1", link_seq: 3, run_id: "c1/run-3", unit_identity: "c1/unit-3"} =
               claim!(mb, "T1", "c1")

      assert status(mb, "T1", "c1", "m1") ==
               {:ok, %{state: :delivering, link_seq: 3, reason: nil}}
    end
  end

  describe "7 claim against rollover" do
    test "claim first: the rollover is :delivery_unsettled; rollover first: the claim names the successor",
         %{mb: mb, role: role} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m1"))
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 1, change: nil})

      assert [{:ok, claimed}, {:error, :delivery_unsettled}] =
               behind(mb.prefix, @chain_lock, [
                 fn -> MB.claim(mb, "T1", %{chain_id: "c1"}) end,
                 fn -> MB.rollover(mb, "T1", rolling("c1", 1)) end
               ])

      assert %{link_seq: 1, message: %{message_id: "m1"}} = claimed

      assert status(mb, "T1", "c1", "m1") ==
               {:ok, %{state: :delivering, link_seq: 1, reason: nil}}

      assert %{seq: 1, state: :live} = tip(mb, "T1", "c1")

      # In a fresh schema, the rollover queued first.
      p2 = install(role)
      mb2 = mailbox(p2)
      {:ok, :applied} = MB.open(mb2, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb2, "T1", mail("m1"))
      {:ok, _} = MB.plan_rollover(mb2, "T1", %{chain_id: "c1", link_seq: 1, change: nil})

      assert [{:ok, %{seq: 2}}, {:ok, claimed}] =
               behind(p2, @chain_lock, [
                 fn -> MB.rollover(mb2, "T1", rolling("c1", 1)) end,
                 fn -> MB.claim(mb2, "T1", %{chain_id: "c1"}) end
               ])

      assert %{link_seq: 2, run_id: "c1/run-2", unit_identity: "c1/unit-2"} = claimed
      assert claimed.message.message_id == "m1"
    end
  end

  describe "8 concurrent rollovers" do
    test "two rollovers of one link commit one successor", %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 1, change: nil})
      r = rolling("c1", 1)

      # Equal bytes: both answer the one successor.
      assert behind(p, @chain_lock, [
               fn -> MB.rollover(mb, "T1", r) end,
               fn -> MB.rollover(mb, "T1", r) end
             ]) ==
               [{:ok, %{seq: 2}}, {:ok, %{seq: 2}}]

      # Other bytes against a recorded successor: :already_rolled_over.
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 2, change: nil})
      r2 = rolling("c1", 2)

      for other <- [
            %{r2 | outcome: "failed"},
            %{r2 | successor: successor("c1", 3, %{carry_kind: :restarted})},
            %{r2 | successor: successor("c1", 3, %{carry: %{"start" => 4}})},
            %{r2 | successor: successor("c1", 3, %{run_id: "c1/run-x"})}
          ] do
        assert behind(p, @chain_lock, [
                 fn -> MB.rollover(mb, "T1", r2) end,
                 fn -> MB.rollover(mb, "T1", other) end
               ]) ==
                 [{:ok, %{seq: 3}}, {:error, :already_rolled_over}]
      end

      # A change on a recorded successor without one is other bytes too.
      changed = %{r | change: %{pin: "pin-a", ref: "ref-1"}}
      assert MB.rollover(mb, "T1", changed) == {:error, :already_rolled_over}
      assert MB.rollover(mb, "T1", r) == {:ok, %{seq: 2}}

      [_, links, _] = rows(p, "T1")

      assert Enum.map(links, &Enum.slice(&1, 2..5)) == [
               [1, "c1/run-1", "c1/unit-1", nil],
               [2, "c1/run-2", "c1/unit-2", 1],
               [3, "c1/run-3", "c1/unit-3", 2]
             ]

      insert = """
      INSERT INTO $P.elzoo_mailbox_links (tenant, chain_id, seq, run_id, unit_identity,
        predecessor_seq, pin, carry, carry_kind, state, stopped)
      VALUES ('T1', 'c1', $1, $2, $3, $4, 'pin-a', '{}', 'finished', 'live', false)
      """

      # The unique index on the predecessor and the primary key refuse a second successor.
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: c1}}} =
               owner(p, "T1", insert, [99, "x-run", "x-unit", 1])

      assert c1 =~ "predecessor_seq"

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: c2}}} =
               owner(p, "T1", insert, [2, "y-run", "y-unit", nil])

      assert c2 == "elzoo_mailbox_links_pkey"
    end
  end

  describe "9 crash after claim" do
    test "a dropped connection gives the same message to the same link at the next claim",
         %{mb: mb, p: p, role: role} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m2"))

      pid = Harness.start!(CrashRepo, pool_size: 1, after_connect: {Harness, :connect, [role, []]})
      [[backend]] = q!(CrashRepo, "SELECT pg_backend_pid()")
      crashed = claim!(mailbox(p, @decl, CrashRepo), "T1", "c1")
      assert %{message_id: "m1", link_seq: 1} = crashed

      # The host dies before any settle: its connection is dropped.
      assert [[true]] = q!(AdminRepo, "SELECT pg_terminate_backend($1)", [backend])
      Supervisor.stop(pid)

      assert claim!(mb, "T1", "c1") == crashed
      assert status(mb, "T1", "c1", "m2") == {:ok, %{state: :pending, link_seq: nil, reason: nil}}
    end
  end

  describe "10 settle" do
    test "each result and each refusal reason", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      ids = ["applied", "not-applied", "unacknowledged", "invalid-input", "input-id-conflict"]
      for id <- ids, do: {:ok, :applied} = MB.put(mb, "T1", mail(id))
      deliver = fn id -> %{message_id: ^id, link_seq: 1} = claim!(mb, "T1", "c1") end

      deliver.("applied")
      # A settle for another link, or of another message, is :not_delivering.
      assert settle(mb, "T1", "c1", "applied", 2, :applied) == {:error, :not_delivering}
      assert settle(mb, "T1", "c1", "not-applied", 1, :applied) == {:error, :not_delivering}
      assert settle(mb, "T1", "c1", "absent", 1, :applied) == {:error, :not_delivering}
      assert settle(mb, "T1", "c1", "applied", 1, :applied) == {:ok, :applied}
      assert settle(mb, "T1", "c1", "applied", 1, :applied) == {:ok, :duplicate}
      assert settle(mb, "T1", "c1", "applied", 2, :applied) == {:error, :not_delivering}
      assert settle(mb, "T1", "c1", "applied", 1, :not_applied) == {:error, :not_delivering}

      assert settle(mb, "T1", "c1", "applied", 1, {:refused, :unacknowledged}) ==
               {:error, :not_delivering}

      assert status(mb, "T1", "c1", "applied") ==
               {:ok, %{state: :consumed, link_seq: 1, reason: nil}}

      deliver.("not-applied")
      assert settle(mb, "T1", "c1", "not-applied", 1, :not_applied) == {:ok, :applied}
      assert settle(mb, "T1", "c1", "not-applied", 1, :not_applied) == {:error, :not_delivering}
      deliver.("not-applied")
      {:ok, :applied} = settle(mb, "T1", "c1", "not-applied", 1, :applied)

      for {id, reason} <- [
            {"unacknowledged", :unacknowledged},
            {"invalid-input", :invalid_input},
            {"input-id-conflict", :input_id_conflict}
          ] do
        deliver.(id)
        assert settle(mb, "T1", "c1", id, 1, {:refused, reason}) == {:ok, :applied}
        assert settle(mb, "T1", "c1", id, 1, {:refused, reason}) == {:ok, :duplicate}
        assert settle(mb, "T1", "c1", id, 1, {:refused, :record_size}) == {:error, :not_delivering}
        assert settle(mb, "T1", "c1", id, 1, :applied) == {:error, :not_delivering}
        assert status(mb, "T1", "c1", id) == {:ok, %{state: :refused, link_seq: 1, reason: reason}}
      end

      assert MB.claim(mb, "T1", %{chain_id: "c1"}) == {:ok, :empty}
      refute tip(mb, "T1", "c1").stopped

      # Refused messages do not block a rollover.
      roll!(mb, "T1", "c1", 1)
      {:ok, :applied} = MB.put(mb, "T1", mail("too-big"))
      {:ok, :applied} = MB.put(mb, "T1", mail("after"))
      %{message_id: "too-big", link_seq: 2} = claim!(mb, "T1", "c1")
      assert settle(mb, "T1", "c1", "too-big", 2, {:refused, :record_size}) == {:ok, :applied}
      assert settle(mb, "T1", "c1", "too-big", 2, {:refused, :record_size}) == {:ok, :duplicate}

      assert status(mb, "T1", "c1", "too-big") ==
               {:ok, %{state: :refused, link_seq: 2, reason: :record_size}}

      assert {:ok,
              %{
                links: [%{seq: 1, stopped: false}, %{seq: 2, stopped: true}],
                tip: %{seq: 2, stopped: true}
              }} =
               MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 10})

      assert MB.claim(mb, "T1", %{chain_id: "c1"}) == {:ok, :stopped}

      assert status(mb, "T1", "c1", "after") ==
               {:ok, %{state: :pending, link_seq: nil, reason: nil}}

      # The host restarts the room: the successor is not stopped and receives the mail.
      roll!(mb, "T1", "c1", 2, %{successor: successor("c1", 3, %{carry_kind: :restarted})})
      assert %{seq: 3, stopped: false, carry_kind: :restarted} = tip(mb, "T1", "c1")
      assert %{message_id: "after", link_seq: 3} = claim!(mb, "T1", "c1")
    end
  end

  describe "11 the pin" do
    test "kept with change nil, changed only with change, and the plan checked", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))

      plan = fn seq, change ->
        MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: seq, change: change})
      end

      change = %{pin: "pin-b", ref: "change-1"}

      assert MB.rollover(mb, "T1", rolling("c1", 1)) == {:error, :plan_mismatch}
      assert plan.(1, nil) == {:ok, %{planned_pin: "pin-a", previous: nil}}
      assert %{planned_pin: "pin-a"} = tip(mb, "T1", "c1")
      assert MB.rollover(mb, "T1", rolling("c1", 1, %{change: change})) == {:error, :plan_mismatch}
      assert MB.rollover(mb, "T1", rolling("c1", 1)) == {:ok, %{seq: 2}}
      assert %{seq: 2, pin: "pin-a", change_ref: nil, planned_pin: nil} = tip(mb, "T1", "c1")

      assert plan.(2, change) == {:ok, %{planned_pin: "pin-b", previous: nil}}
      assert plan.(2, nil) == {:ok, %{planned_pin: "pin-a", previous: "pin-b"}}
      assert MB.rollover(mb, "T1", rolling("c1", 2, %{change: change})) == {:error, :plan_mismatch}
      assert plan.(2, change) == {:ok, %{planned_pin: "pin-b", previous: "pin-a"}}
      assert MB.rollover(mb, "T1", rolling("c1", 2)) == {:error, :plan_mismatch}
      assert MB.rollover(mb, "T1", rolling("c1", 2, %{change: change})) == {:ok, %{seq: 3}}

      assert %{seq: 3, pin: "pin-b", change_ref: "change-1", planned_pin: nil, predecessor_seq: 2} =
               tip(mb, "T1", "c1")

      assert MB.rollover(mb, "T1", rolling("c1", 3)) == {:error, :plan_mismatch}
      assert plan.(1, nil) == {:error, :not_tip}
      assert plan.(9, nil) == {:error, :unknown_link}
      assert MB.rollover(mb, "T1", rolling("c1", 9)) == {:error, :unknown_link}

      # The successor of a kept pin keeps the changed pin.
      assert plan.(3, nil) == {:ok, %{planned_pin: "pin-b", previous: nil}}
      assert MB.rollover(mb, "T1", rolling("c1", 3)) == {:ok, %{seq: 4}}
      assert %{pin: "pin-b", change_ref: nil} = tip(mb, "T1", "c1")

      {:ok, %{links: links}} = MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 10})

      assert Enum.map(links, &{&1.seq, &1.pin, &1.planned_pin, &1.state, &1.outcome}) == [
               {1, "pin-a", "pin-a", :closed, "completed"},
               {2, "pin-a", "pin-b", :closed, "completed"},
               {3, "pin-b", "pin-b", :closed, "completed"},
               {4, "pin-b", nil, :live, nil}
             ]
    end
  end

  describe "12 identity in use" do
    test "a successor or an open that reuses a run_id or unit_identity of the tenant",
         %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      roll!(mb, "T1", "c1", 1)
      {:ok, :applied} = MB.open(mb, "T1", opening("c2"))
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 2, change: nil})
      before = rows(p, "T1")

      for s <- [
            successor("c1", 3, %{run_id: "c1/run-1"}),
            successor("c1", 3, %{unit_identity: "c1/unit-1"}),
            successor("c1", 3, %{run_id: "c1/run-2"}),
            successor("c1", 3, %{unit_identity: "c2/unit-1"})
          ] do
        assert MB.rollover(mb, "T1", rolling("c1", 2, %{successor: s})) ==
                 {:error, :identity_in_use}
      end

      for o <- [
            opening("c3", %{run_id: "c1/run-2"}),
            opening("c3", %{unit_identity: "c1/unit-1"}),
            opening("c3", %{run_id: "c2/run-1"})
          ] do
        assert MB.open(mb, "T1", o) == {:error, :identity_in_use}
      end

      assert rows(p, "T1") == before

      # The same IDs in another tenant.
      {:ok, :applied} = MB.open(mb, "T2", opening("c1"))

      assert MB.open(mb, "T2", opening("c9", %{run_id: "c1/run-2", unit_identity: "c1/unit-2"})) ==
               {:ok, :applied}

      {:ok, _} = MB.plan_rollover(mb, "T2", %{chain_id: "c1", link_seq: 1, change: nil})

      assert MB.rollover(mb, "T2", rolling("c1", 1, %{successor: successor("c2", 1)})) ==
               {:ok, %{seq: 2}}
    end
  end

  describe "13 chain/3 and status/3" do
    test "paging at limit 1 and 256 with more; the tip with its carry", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      for seq <- 1..257, do: roll!(mb, "T1", "c1", seq)

      page = fn after_seq, limit ->
        MB.chain(mb, "T1", %{chain_id: "c1", after_seq: after_seq, limit: limit})
      end

      {:ok, %{links: links, more: true, tip: tip, declaration: {"room.mail", 1, _}}} =
        page.(nil, 256)

      assert Enum.map(links, & &1.seq) == Enum.to_list(1..256)
      refute Enum.any?(links, &Map.has_key?(&1, :carry))

      assert tip == %{
               seq: 258,
               run_id: "c1/run-258",
               unit_identity: "c1/unit-258",
               predecessor_seq: 257,
               pin: "pin-a",
               planned_pin: nil,
               carry: %{"start" => 258},
               carry_kind: :finished,
               state: :live,
               outcome: nil,
               change_ref: nil,
               stopped: false
             }

      assert %{
               seq: 1,
               predecessor_seq: nil,
               carry_kind: :opened,
               state: :closed,
               outcome: "completed"
             } = hd(links)

      assert {:ok, %{links: [%{seq: 257}, %{seq: 258}], more: false, tip: ^tip}} = page.(256, 256)
      assert {:ok, %{links: [%{seq: 1}], more: true, tip: ^tip}} = page.(nil, 1)
      assert {:ok, %{links: [%{seq: 257}], more: true}} = page.(256, 1)
      assert {:ok, %{links: [%{seq: 258} = last], more: false}} = page.(257, 1)
      refute Map.has_key?(last, :carry)
      assert {:ok, %{links: [], more: false, tip: ^tip}} = page.(258, 1)
      assert {:ok, %{links: [], more: false}} = page.(1000, 256)

      assert MB.chain(mb, "T1", %{chain_id: "absent", after_seq: nil, limit: 1}) ==
               {:error, :unknown_chain}
    end

    test "status/3 of each state and :unknown_message", %{mb: mb} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      for id <- ["a", "b", "c", "d"], do: {:ok, :applied} = MB.put(mb, "T1", mail(id))
      %{message_id: "a"} = claim!(mb, "T1", "c1")
      {:ok, :applied} = settle(mb, "T1", "c1", "a", 1, :applied)
      %{message_id: "b"} = claim!(mb, "T1", "c1")
      {:ok, :applied} = settle(mb, "T1", "c1", "b", 1, {:refused, :invalid_input})
      %{message_id: "c"} = claim!(mb, "T1", "c1")

      assert status(mb, "T1", "c1", "a") == {:ok, %{state: :consumed, link_seq: 1, reason: nil}}

      assert status(mb, "T1", "c1", "b") ==
               {:ok, %{state: :refused, link_seq: 1, reason: :invalid_input}}

      assert status(mb, "T1", "c1", "c") == {:ok, %{state: :delivering, link_seq: 1, reason: nil}}
      assert status(mb, "T1", "c1", "d") == {:ok, %{state: :pending, link_seq: nil, reason: nil}}
      assert status(mb, "T1", "c1", "e") == {:error, :unknown_message}
      assert status(mb, "T1", "c2", "a") == {:error, :unknown_message}
      assert status(mb, "T2", "c1", "a") == {:error, :unknown_message}
    end
  end

  describe "14 row security as the application role" do
    test "verify/1 passes; T1 cannot see or write T2 rows; DELETE fails 42501",
         %{mb: mb, p: p, role: role} do
      assert q!(AppRepo, "SELECT current_user") == [[role]]
      assert MB.verify(mb) == :ok

      {:ok, :applied} = MB.open(mb, "T2", opening("c2"))
      {:ok, :applied} = MB.put(mb, "T2", mail("m2", %{address: {:chain, "c2"}}))
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m1"))

      assert MB.put(mb, "T1", mail("x", %{address: {:chain, "c2"}})) == {:error, :unknown_chain}
      assert MB.put(mb, "T1", mail("x", %{address: {:run, "c2/run-1"}})) == {:error, :unknown_chain}
      assert MB.claim(mb, "T1", %{chain_id: "c2"}) == {:error, :unknown_chain}

      assert MB.chain(mb, "T1", %{chain_id: "c2", after_seq: nil, limit: 1}) ==
               {:error, :unknown_chain}

      assert status(mb, "T1", "c2", "m2") == {:error, :unknown_message}
      assert settle(mb, "T1", "c2", "m2", 1, :applied) == {:error, :unknown_chain}

      assert MB.plan_rollover(mb, "T1", %{chain_id: "c2", link_seq: 1, change: nil}) ==
               {:error, :unknown_chain}

      assert MB.rollover(mb, "T1", rolling("c2", 1)) == {:error, :unknown_chain}

      # Outside a scope no row is visible: fail closed.
      for t <- [@chains, @links, @messages],
          do: assert(q!(AppRepo, "SELECT count(*) FROM #{p}.#{t}") == [[0]])

      inserts = [
        "INSERT INTO #{p}.#{@chains} VALUES ('T2', 'c9', 'room.mail', 1, 'x', 1, 1)",
        "INSERT INTO #{p}.#{@links} VALUES ('T2', 'c9', 1, 'r9', 'u9', NULL, 'p', NULL, '{}', 'opened', 'live', NULL, NULL, false)",
        "INSERT INTO #{p}.#{@messages} VALUES ('T2', 'c2', 'm9', 9, 'human', 'u', 'chat.post', 1, '{}', 'pending', NULL, NULL)",
        "DELETE FROM #{p}.#{@messages} WHERE message_id = 'm1'",
        "DELETE FROM #{p}.#{@links}",
        "DELETE FROM #{p}.#{@chains}"
      ]

      for sql <- inserts do
        result =
          TI.transact(AppRepo, %{tenant: "T1"}, fn -> SQL.query(AppRepo, sql, [], log: false) end)

        assert code(result) == :insufficient_privilege, sql
      end

      assert length(messages(p, "T1")) == 1
      assert length(messages(p, "T2")) == 1

      # verify/1 names the first failing table.
      {:ok, _} = owner(p, "T1", "ALTER TABLE $P.#{@links} NO FORCE ROW LEVEL SECURITY")
      assert MB.verify(mb) == {:error, {:links, :not_forced}}
    end

    test "every function succeeds with only the README grants", %{mb: mb, p: p, role: role} do
      assert [[grants]] =
               q!(
                 AdminRepo,
                 """
                 SELECT string_agg(table_name || ':' || privilege_type, ',' ORDER BY table_name, privilege_type)
                 FROM information_schema.role_table_grants WHERE grantee = $1 AND table_schema = $2
                 """,
                 [role, p]
               )

      assert grants ==
               Enum.map_join([@chains, @links, @messages], ",", fn t ->
                 Enum.map_join(["INSERT", "SELECT", "UPDATE"], ",", &"#{t}:#{&1}")
               end)

      assert MB.verify(mb) == :ok
      assert MB.open(mb, "T1", opening("c1")) == {:ok, :applied}
      assert MB.put(mb, "T1", mail("m1")) == {:ok, :applied}
      assert {:ok, %{message: _}} = MB.claim(mb, "T1", %{chain_id: "c1"})
      assert settle(mb, "T1", "c1", "m1", 1, :applied) == {:ok, :applied}
      assert {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 1, change: nil})
      assert MB.rollover(mb, "T1", rolling("c1", 1)) == {:ok, %{seq: 2}}

      assert {:ok, %{tip: %{seq: 2}}} =
               MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 5})

      assert {:ok, %{state: :consumed}} = status(mb, "T1", "c1", "m1")
    end
  end

  describe "15 caller transaction, isolation and failures" do
    def forward_query(_event, _measurements, meta, parent), do: send(parent, {:query, meta.query})

    test "a caller's open transaction gives :in_transaction before any query", %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      before = rows(p, "T1")
      outside = MB.verify(mb)
      id = {__MODULE__, make_ref()}
      event = [:elzoo, :durable_mailbox, :app_repo, :query]

      {:ok, {results, inside}} =
        AppRepo.transact(fn ->
          :telemetry.attach(id, event, &__MODULE__.forward_query/4, self())

          try do
            results = [
              MB.open(mb, "T1", opening("c2")),
              MB.put(mb, "T1", mail("m1")),
              MB.claim(mb, "T1", %{chain_id: "c1"}),
              settle(mb, "T1", "c1", "m1", 1, :applied),
              MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 1, change: nil}),
              MB.rollover(mb, "T1", rolling("c1", 1)),
              MB.chain(mb, "T1", %{chain_id: "c1", after_seq: nil, limit: 1}),
              status(mb, "T1", "c1", "m1")
            ]

            SQL.query!(AppRepo, "SELECT 'probe'", [], log: false)
            assert_received {:query, "SELECT 'probe'"}
            refute_received {:query, _}
            {:ok, {results, MB.verify(mb)}}
          after
            :telemetry.detach(id)
          end
        end)

      assert results == List.duplicate({:error, :in_transaction}, 8)
      assert outside == :ok
      assert inside == outside
      assert rows(p, "T1") == before
    end

    test "a Repo that defaults to repeatable read gets :isolation from every write",
         %{mb: mb, p: p} do
      {:ok, :applied} = MB.open(mb, "T1", opening("c1"))
      {:ok, :applied} = MB.put(mb, "T1", mail("m0"))
      {:ok, _} = MB.plan_rollover(mb, "T1", %{chain_id: "c1", link_seq: 1, change: nil})
      before = rows(p, "T1")
      rr = mailbox(p, @decl, RepeatableRepo)

      for result <- [
            MB.open(rr, "T1", opening("c2")),
            MB.put(rr, "T1", mail("m1")),
            MB.claim(rr, "T1", %{chain_id: "c1"}),
            settle(rr, "T1", "c1", "m0", 1, :applied),
            MB.plan_rollover(rr, "T1", %{chain_id: "c1", link_seq: 1, change: nil}),
            MB.rollover(rr, "T1", rolling("c1", 1))
          ],
          do: assert(result == {:error, :isolation})

      assert rows(p, "T1") == before
      # Reads do not check the isolation level.
      assert {:ok, %{state: :pending}} = status(rr, "T1", "c1", "m0")
    end

    test "a database failure is :unavailable", %{p: p} do
      missing = mailbox(p <> "_absent")

      for result <- [
            MB.open(missing, "T1", opening("c1")),
            MB.put(missing, "T1", mail("m1")),
            MB.claim(missing, "T1", %{chain_id: "c1"}),
            settle(missing, "T1", "c1", "m1", 1, :applied),
            MB.plan_rollover(missing, "T1", %{chain_id: "c1", link_seq: 1, change: nil}),
            MB.rollover(missing, "T1", rolling("c1", 1)),
            MB.chain(missing, "T1", %{chain_id: "c1", after_seq: nil, limit: 1}),
            status(missing, "T1", "c1", "m1")
          ],
          do: assert(result == {:error, :unavailable})

      assert MB.verify(missing) == {:error, {:chains, :not_enabled}}
    end

    test "install/1 refuses a bad prefix with one fixed message before any DDL" do
      for prefix <- ["Bad", "", "a-b", String.duplicate("a", 64), nil, :atom],
          do:
            assert_raise(ArgumentError, "invalid durable mailbox prefix", fn ->
              Migration.install(prefix)
            end)
    end
  end
end
