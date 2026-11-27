# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/conversation_test_helper.exs", __DIR__)

defmodule Elzoo.ConversationStoreTest do
  @moduledoc """
  Store scenarios, each on the volatile Memory Store and on the PostgreSQL Store
  (ELZOO_TEST_DATABASE_URL, fail closed): the owner, its writes and check,
  page and tail, a pruned prefix and the version 1 import.
  """
  use ExUnit.Case, async: false

  alias Elzoo.Conversation
  alias Elzoo.Conversation.{Record, V1}
  alias Elzoo.ConversationTest.Helper, as: H
  alias Elzoo.ConversationTest.ProbeStore

  setup_all do
    repo = H.start_repo!()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    :ok
  end

  @tag timeout: 600_000
  test "100,000 messages on the Memory Store: no refusal, a deep page, a tail window and a measured owner start" do
    hundred_thousand(:memory, H.memory())
  end

  @tag timeout: 600_000
  test "100,000 messages on PostgreSQL: no refusal, a deep page, a tail window and a measured owner start" do
    hundred_thousand(:postgres, H.postgres())
  end

  test "identical retries of an input, an association and an answer keep one record each" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)
      input = H.input("m1")
      association = H.association("m1", "run-1")
      answer = H.answer("a1", "m1", "run-1")

      assert {:ok, %{sequence: 1}} = Conversation.append_input(owner, input)
      assert {:ok, %{sequence: 2}} = Conversation.associate_run(owner, association)
      assert {:ok, %{sequence: 3}} = Conversation.append_answer(owner, answer)

      for owner <- [owner, owner, H.owner!(store)] do
        assert {:ok, :already_present} = Conversation.append_input(owner, input)
        assert {:ok, :already_present} = Conversation.associate_run(owner, association)
        assert {:ok, :already_present} = Conversation.append_answer(owner, answer)
      end

      assert H.head!(store).revision == 3
      assert length(H.rows!(store)) == 3
    end)
  end

  test "two independent owners race one message ID with other content: one record, one duplicate" do
    H.each_store(fn _kind, store ->
      for round <- 1..10 do
        id = "race-#{round}"
        first = H.owner!(store)
        second = H.owner!(store)

        results =
          [
            Task.async(fn -> Conversation.append_input(first, H.input(id, text: "first")) end),
            Task.async(fn -> Conversation.append_input(second, H.input(id, text: "second")) end)
          ]
          |> Task.await_many()

        assert [{:ok, %{sequence: ^round}}] = Enum.filter(results, &match?({:ok, _}, &1))
        assert Enum.count(results, &(&1 == {:refused, "duplicate_message_id"})) == 1
        GenServer.stop(first)
        GenServer.stop(second)
      end

      assert length(H.rows!(store)) == 10
    end)
  end

  test "a refusal is decided after reading the rows another owner appended" do
    H.each_store(fn _kind, store ->
      stale = H.owner!(store)
      writer = H.owner!(store)

      assert {:ok, %{sequence: 1}} = Conversation.append_input(writer, H.input("i1"))

      assert {:ok, %{sequence: 2}} =
               Conversation.associate_run(writer, H.association("i1", "run-1"))

      assert {:ok, %{sequence: 3}} =
               Conversation.append_answer(writer, H.answer("a1", "i1", "run-1"))

      # The stale owner has read none of rows 1..3. On its own model the answer
      # retried with completed: false would be run_not_completed; on the rows
      # after its head it is the identical record.
      assert {:ok, :already_present} =
               Conversation.append_answer(stale, H.answer("a1", "i1", "run-1", completed: false))

      # A refusal on a stale model that newer rows make admissible is admitted:
      # the input exists once the owner reads past its head.
      late = H.owner!(store)
      assert {:ok, %{sequence: 4}} = Conversation.append_input(writer, H.input("i2"))

      assert {:ok, %{sequence: 5}} =
               Conversation.associate_run(late, H.association("i2", "run-2"))

      # A refusal that the newer rows confirm stays a refusal.
      assert {:ok, %{sequence: 6}} = Conversation.append_input(writer, H.input("i3"))

      assert {:refused, "duplicate_message_id"} =
               Conversation.append_input(stale, H.input("i3", text: "other"))

      assert H.head!(store).revision == 6
      Enum.each([stale, writer, late], &GenServer.stop/1)
    end)
  end

  test "concurrent appends from independent owners keep contiguous sequences and lose no message" do
    H.each_store(fn _kind, store ->
      owners = for _ <- 1..4, do: H.owner!(store)

      results =
        owners
        |> Enum.with_index()
        |> Enum.map(fn {owner, writer} ->
          Task.async(fn ->
            for index <- 1..25 do
              id = "w#{writer}-#{index}"
              {id, settle(fn -> Conversation.append_input(owner, H.input(id)) end)}
            end
          end)
        end)
        |> Task.await_many(120_000)
        |> List.flatten()

      rows = H.rows!(store)
      assert Enum.map(rows, & &1.sequence) == Enum.to_list(1..100)
      ids = Enum.map(rows, &H.decode!(&1).message_id)
      assert Enum.sort(ids) == Enum.sort(Enum.map(results, &elem(&1, 0)))

      for {id, result} <- results do
        assert {:ok, %{sequence: sequence}} = result
        assert Enum.at(ids, sequence - 1) == id
      end
    end)
  end

  test "already_answered and missing_input refuse new answer IDs" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)
      assert {:ok, _} = Conversation.append_input(owner, H.input("m1"))
      assert {:ok, _} = Conversation.associate_run(owner, H.association("m1", "run-1"))
      assert {:ok, _} = Conversation.append_answer(owner, H.answer("a1", "m1", "run-1"))

      assert {:refused, "already_answered"} =
               Conversation.append_answer(owner, H.answer("a2", "m1", "run-1"))

      assert {:refused, "missing_input"} =
               Conversation.append_answer(owner, H.answer("a3", "m-missing", "run-1"))

      assert H.head!(store).revision == 3
    end)
  end

  test "a committed message append and association whose reply is lost resolve to ok" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)

      H.inject(store, :append, :reply_loss)
      assert {:ok, %{sequence: 1}} = Conversation.append_input(owner, H.input("m1"))
      assert {:ok, :already_present} = Conversation.append_input(owner, H.input("m1"))

      H.inject(store, :append, :reply_loss)
      assert {:ok, %{sequence: 2}} = Conversation.associate_run(owner, H.association("m1", "run-1"))

      assert {:ok, :already_present} =
               Conversation.associate_run(owner, H.association("m1", "run-1"))

      assert length(H.rows!(store)) == 2
    end)
  end

  test "an unresolved message append and association are safe to retry identically, committed or not" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)

      # Committed, but neither confirmation nor the read of the new rows answers.
      unresolvable(store)
      assert {:unknown, :unresolved} = Conversation.append_input(owner, H.input("m1"))
      assert H.head!(store).revision == 1
      assert {:ok, :already_present} = Conversation.append_input(owner, H.input("m1"))

      # Not committed: no row, which proves nothing; the retry commits once.
      H.inject(store, :append, :unavailable)
      assert {:unknown, :unresolved} = Conversation.append_input(owner, H.input("m2"))
      assert H.head!(store).revision == 1
      assert {:ok, %{sequence: 2}} = Conversation.append_input(owner, H.input("m2"))

      unresolvable(store)

      assert {:unknown, :unresolved} =
               Conversation.associate_run(owner, H.association("m1", "run-1"))

      assert H.head!(store).revision == 3

      assert {:ok, :already_present} =
               Conversation.associate_run(owner, H.association("m1", "run-1"))

      # The referenced input exists, yet an unconfirmed association stays unknown.
      H.inject(store, :append, :unavailable)

      assert {:unknown, :unresolved} =
               Conversation.associate_run(owner, H.association("m2", "run-2"))

      assert H.head!(store).revision == 3
      assert {:ok, %{sequence: 4}} = Conversation.associate_run(owner, H.association("m2", "run-2"))

      assert length(H.rows!(store)) == 4
    end)
  end

  test "check decides like the write for every result, without appending" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)

      steps = [
        {:input, H.input("i1"), :ok},
        {:input, H.input("i1"), {:ok, :already_present}},
        {:input, H.input("i1", text: "other"), {:refused, "duplicate_message_id"}},
        {:association, H.association("i9", "run-1"), {:refused, "missing_input"}},
        {:association, H.association("i1", "run-1"), :ok},
        {:association, H.association("i1", "run-1"), {:ok, :already_present}},
        {:association, H.association("i1", "run-2"), {:refused, "already_associated"}},
        {:answer, H.answer("a1", "i1", "run-1", completed: false), {:refused, "run_not_completed"}},
        {:answer, H.answer("a1", "i1", "run-2"), {:refused, "association_mismatch"}},
        {:answer, H.answer("a1", "i1", "run-1"), :ok},
        {:answer, H.answer("a1", "i1", "run-1", completed: false), {:ok, :already_present}},
        {:answer, H.answer("a2", "i1", "run-1"), {:refused, "already_answered"}},
        {:input, %{message_id: "i2"}, {:refused, "invalid_request"}}
      ]

      for {mode, dto, expected} <- steps do
        before = H.head!(store)
        assert {:ok, [^expected]} = Conversation.check(owner, [{mode, dto}]), inspect(dto)
        assert H.head!(store) == before

        case {expected, write(owner, mode, dto)} do
          {:ok, {:ok, %{sequence: sequence}}} -> assert sequence == before.revision + 1
          {same, same} -> :ok
          other -> flunk("check and write disagree: #{inspect(other)}")
        end
      end

      assert {:error, :invalid_request} = Conversation.check(owner, [])
      assert {:error, :invalid_request} = Conversation.check(owner, [{:other, H.input("x")}])
      assert {:error, :invalid_request} = Conversation.check(owner, :not_a_list)

      assert {:error, :invalid_request} =
               Conversation.check(owner, [{:input, H.input("x")} | :tail])

      # No intent count bound: a chain longer than any page is decided in full.
      before = H.head!(store)
      chain = for n <- 1..2_500, do: {:input, H.input("chain-#{n}")}
      assert {:ok, decisions} = Conversation.check(owner, chain ++ [{:input, H.input("chain-1")}])
      assert length(decisions) == 2_501
      assert Enum.take(decisions, 2_500) == List.duplicate(:ok, 2_500)
      assert List.last(decisions) == {:ok, :already_present}
      assert H.head!(store) == before
    end)
  end

  test "check refreshes after an independent append and admits a chain of undelivered intents" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)
      other = H.owner!(store)
      assert {:ok, %{sequence: 1}} = Conversation.append_input(other, H.input("i1"))

      assert {:ok, [{:refused, "duplicate_message_id"}]} =
               Conversation.check(owner, [{:input, H.input("i1", text: "claimed")}])

      assert {:ok, [{:ok, :already_present}]} = Conversation.check(owner, [{:input, H.input("i1")}])

      undelivered = [{:input, H.input("i2")}, {:association, H.association("i2", "run-2")}]

      assert {:ok, [:ok, :ok, :ok]} =
               Conversation.check(owner, undelivered ++ [{:answer, H.answer("a2", "i2", "run-2")}])

      assert {:ok, [:ok, :ok, {:refused, "association_mismatch"}]} =
               Conversation.check(owner, undelivered ++ [{:answer, H.answer("a2", "i2", "run-9")}])

      assert {:ok, [:ok, {:refused, "duplicate_message_id"}]} =
               Conversation.check(owner, [
                 {:input, H.input("i2")},
                 {:input, H.input("i2", text: "reused")}
               ])

      assert H.head!(store).revision == 1
      assert {:ok, %{sequence: 2}} = Conversation.append_input(owner, H.input("i2"))
    end)
  end

  test "a refresh that cannot read or finds damage fails the check and the append" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)
      assert {:ok, %{sequence: 1}} = Conversation.append_input(owner, H.input("i1"))

      H.inject(store, :head, :unavailable)
      assert {:error, :unavailable} = Conversation.check(owner, [{:input, H.input("i2")}])

      H.append_raw!(store, H.stream(), [H.entry!(:input, H.input("outside-1"))])
      H.inject(store, :head, :unavailable)
      assert {:error, :unavailable} = Conversation.append_input(owner, H.input("i2"))
      assert H.head!(store).revision == 2

      # An outside writer reuses an ID with other content: the stream is damaged.
      H.append_raw!(store, H.stream(), [H.entry!(:input, H.input("i1", text: "claimed"))])
      assert {:error, :damaged} = Conversation.check(owner, [{:input, H.input("i2")}])
      assert {:error, :damaged} = Conversation.append_input(owner, H.input("i2"))
      assert H.head!(store).revision == 3

      assert {:error, :damaged} =
               Conversation.start_link(
                 store: store,
                 target_tenant: H.tenant(),
                 conversation_id: H.conversation()
               )
    end)
  end

  test "a timed-out check is an error and a timed-out append is unknown, also when it commits later" do
    H.each_store(fn _kind, inner ->
      {store, probe} = ProbeStore.wrap(inner)
      owner = H.owner!(store)
      test = self()

      ProbeStore.hook(probe, :append, fn _operation, _args, run ->
        send(test, {:append_blocked, self()})

        receive do
          :release_append -> run.()
        end
      end)

      assert {:unknown, :unresolved} = Conversation.append_input(owner, H.input("m1"), 100)
      assert_receive {:append_blocked, ^owner}
      assert {:error, :timeout} = Conversation.check(owner, [{:input, H.input("m2")}], 100)
      assert H.head!(inner).revision == 0

      ProbeStore.unhook(probe, :append)
      send(owner, :release_append)
      assert {:ok, :already_present} = Conversation.append_input(owner, H.input("m1"))
      assert H.head!(inner).revision == 1
      assert {:ok, [:ok]} = Conversation.check(owner, [{:input, H.input("m2")}])
    end)
  end

  test "page and tail refuse another tenant, an ungranted conversation and a malformed scope with zero Store calls" do
    H.each_store(fn _kind, inner ->
      owner = H.owner!(inner)
      assert {:ok, _} = Conversation.append_input(owner, H.input("m1"))
      assert {:ok, _} = Conversation.append_input(owner, H.input("m2"))
      {store, probe} = ProbeStore.wrap(inner)
      reference = H.reference()

      cases = [
        {:not_found, %{H.scope() | tenant: "tenant-2"}, reference},
        {:not_found, H.scope(["conversation-2"]), reference},
        {:not_found, H.scope([]), reference},
        {{:error, :invalid_scope}, Map.put(H.scope(), :extra, true), reference},
        {{:error, :invalid_scope}, Map.delete(H.scope(), :actor), reference},
        {{:error, :invalid_scope}, Map.put(H.scope(), :__struct__, URI), reference},
        {{:error, :invalid_scope}, H.scope(Enum.map(1..65, &"conversation-#{&1}")), reference},
        {{:error, :invalid_scope}, %{H.scope() | tenant: "tenant\0"}, reference},
        {{:error, :invalid_scope}, %{H.scope() | actor: ""}, reference},
        {{:error, :invalid_scope}, %{H.scope() | resources: "conversation-1"}, reference},
        {{:error, :invalid_scope}, %{H.scope() | resources: ["conversation-1" | "x"]}, reference},
        {{:error, :invalid_scope}, :not_a_scope, reference},
        {{:error, :invalid_request}, H.scope(), Map.put(reference, :extra, true)}
      ]

      malformed_references =
        for segment <- H.refused_segments(),
            bad <- [%{reference | target_tenant: segment}, %{reference | conversation_id: segment}],
            do: {{:error, :invalid_request}, H.scope(), bad}

      cases = cases ++ malformed_references

      for {expected, scope, reference} <- cases do
        ProbeStore.reset(probe)
        assert Conversation.page(store, scope, reference, 1, 10) == expected, inspect(scope)
        assert Conversation.tail(store, scope, reference, 10) == expected, inspect(scope)
        assert ProbeStore.calls(probe) == []
      end

      for {from, limit} <- [{0, 10}, {1, 0}, {1, 1_001}, {:one, 10}, {1, 10.0}] do
        assert {:error, :invalid_request} =
                 Conversation.page(store, H.scope(), reference, from, limit)
      end

      for count <- [0, 1_001, :all] do
        assert {:error, :invalid_request} = Conversation.tail(store, H.scope(), reference, count)
      end

      assert ProbeStore.calls(probe) == []

      assert {:ok, %{revision: 2, entries: [%{sequence: 1, message_id: "m1"}, %{sequence: 2}]}} =
               Conversation.page(store, H.scope(), reference, 1, 10)

      assert [{:read, _}] = ProbeStore.calls(probe)
      ProbeStore.reset(probe)

      assert {:ok, %{revision: 2, entries: [%{sequence: 2, message_id: "m2", kind: :input}]}} =
               Conversation.tail(store, H.scope(), reference, 1)

      assert [{:head, _}, {:read, _}] = ProbeStore.calls(probe)
    end)
  end

  test "page and tail require every expected row and stop at the sampled head" do
    H.each_store(fn _kind, inner ->
      owner = H.owner!(inner)

      for index <- 1..5,
          do: assert({:ok, _} = Conversation.append_input(owner, H.input("m#{index}")))

      {store, probe} = ProbeStore.wrap(inner)
      read = fn -> Conversation.page(store, H.scope(), H.reference(), 1, 5) end
      tail = fn -> Conversation.tail(store, H.scope(), H.reference(), 5) end

      ProbeStore.hook(probe, :read, fn _, _, run ->
        {:ok, rows, head} = run.()
        {:ok, List.delete_at(rows, 1), head}
      end)

      assert {:error, :damaged} = read.()
      assert {:error, :damaged} = tail.()

      ProbeStore.hook(probe, :read, fn _, _, run ->
        {:ok, rows, head} = run.()
        {:ok, rows, %{head | low_water: 1}}
      end)

      assert {:error, :damaged} = read.()
      assert {:error, :damaged} = tail.()

      ProbeStore.hook(probe, :read, fn _, _, run ->
        H.append_raw!(inner, H.stream(), [
          H.entry!(:input, H.input("late-#{System.unique_integer([:positive])}"))
        ])

        run.()
      end)

      assert {:ok, %{revision: 5, entries: entries}} =
               Conversation.tail(store, H.scope(), H.reference(), 3)

      assert Enum.map(entries, & &1.sequence) == [3, 4, 5]
      ProbeStore.unhook(probe, :read)

      H.corrupt!(
        inner,
        H.stream(),
        2,
        Record.payload(H.entry!(:input, H.input("m2", text: "changed")))
      )

      assert {:error, :damaged} = read.()
      assert {:error, :damaged} = Conversation.tail(store, H.scope(), H.reference(), 10)

      assert {:ok, %{entries: [%{sequence: 3}, %{sequence: 4}]}} =
               Conversation.page(store, H.scope(), H.reference(), 3, 2)
    end)
  end

  test "a retained prefix stops the owner from starting and damages page, tail and check" do
    H.each_store(fn _kind, store ->
      owner = H.owner!(store)

      for index <- 1..5,
          do: assert({:ok, _} = Conversation.append_input(owner, H.input("m#{index}")))

      :ok = H.prune!(store, H.stream(), 3)
      assert H.head!(store).low_water == 3

      assert {:error, :damaged} =
               Conversation.start_link(
                 store: store,
                 target_tenant: H.tenant(),
                 conversation_id: H.conversation()
               )

      assert {:error, :damaged} = Conversation.page(store, H.scope(), H.reference(), 1, 10)
      assert {:error, :damaged} = Conversation.page(store, H.scope(), H.reference(), 4, 10)
      assert {:error, :damaged} = Conversation.tail(store, H.scope(), H.reference(), 2)
      assert {:error, :damaged} = Conversation.check(owner, [{:input, H.input("m6")}])
    end)
  end

  test "start refuses invalid options, unsupported Stores and damaged or unreadable streams" do
    valid = [store: H.memory(), target_tenant: H.tenant(), conversation_id: H.conversation()]
    assert {:ok, _owner} = Conversation.start_link(valid)

    seg64 = String.duplicate("s", 64)

    assert {:ok, _owner} =
             Conversation.start_link(
               Keyword.merge(valid, target_tenant: seg64, conversation_id: seg64)
             )

    bad_segments =
      for segment <- H.refused_segments(),
          position <- [:target_tenant, :conversation_id],
          do: Keyword.put(valid, position, segment)

    for options <-
          [
            [],
            Keyword.delete(valid, :store),
            Keyword.put(valid, :extra, true),
            Map.new(valid)
          ] ++ bad_segments do
      assert {:error, :invalid_options} = Conversation.start_link(options), inspect(options)
    end

    for store <- [
          H.memory(visibility: :staged_uncommitted_tail),
          H.memory(limits: H.limits(Record.max_payload_bytes() - 1)),
          H.memory(fold: H.fold(tl(Record.kinds()))),
          H.memory(fold: %{H.fold() | versions: [2]}),
          :not_a_store
        ] do
      assert {:error, :unsupported_store} =
               Conversation.start_link(Keyword.put(valid, :store, store))
    end

    H.each_store(fn _kind, store ->
      owner = H.owner!(store)
      assert {:ok, _} = Conversation.append_input(owner, H.input("m1"))
      assert {:ok, _} = Conversation.append_input(owner, H.input("m2"))

      H.corrupt!(
        store,
        H.stream(),
        2,
        Record.payload(H.entry!(:input, H.input("m2", text: "changed")))
      )

      assert {:error, :damaged} = start(store, H.conversation())

      H.append_raw!(store, H.stream("duplicate"), [
        H.entry!(:input, H.input("m1")),
        H.entry!(:input, H.input("m1", text: "again"))
      ])

      assert {:error, :damaged} = start(store, "duplicate")

      H.append_foreign!(store, H.stream("foreign"))
      assert {:error, :damaged} = start(store, "foreign")

      H.inject(store, :head, :unavailable)
      assert {:error, :unavailable} = start(store, "fresh")
      H.append_raw!(store, H.stream("fresh"), [H.entry!(:input, H.input("m1"))])
      H.inject(store, :read, :unavailable)
      assert {:error, :unavailable} = start(store, "fresh")
      assert {:ok, _owner} = start(store, "fresh")
    end)
  end

  test "a compare-and-set that keeps losing returns contended after nine attempts, reading only new rows" do
    H.each_store(fn _kind, inner ->
      {store, probe} = ProbeStore.wrap(inner)
      owner = H.owner!(store)
      assert {:ok, %{sequence: 1}} = Conversation.append_input(owner, H.input("m0"))

      ProbeStore.hook(probe, :append, fn _operation, _args, run ->
        H.append_raw!(inner, H.stream(), [
          H.entry!(:input, H.input("outside-#{System.unique_integer([:positive])}"))
        ])

        run.()
      end)

      ProbeStore.reset(probe)
      assert {:error, :contended} = Conversation.append_input(owner, H.input("m1"))
      ProbeStore.unhook(probe, :append)
      calls = ProbeStore.calls(probe)

      assert Enum.count(calls, &match?({:append, _}, &1)) == 9
      assert for({:read, [_stream, from, _limit]} <- calls, do: from) == Enum.to_list(2..9)
      assert H.head!(inner).revision == 10

      assert {:ok, %{sequence: 11}} = Conversation.append_input(owner, H.input("m1"))
    end)
  end

  test "import_v1 migrates 32 inputs, 32 answers and 32 associations, completes a cut import and refuses other content" do
    snapshot = H.v1_fixture()
    {:ok, v1} = V1.parse(snapshot)
    v1_runs = Map.new(v1.associations, &{&1.input_message_id, &1.run_id})

    H.each_store(fn _kind, store ->
      assert {:ok, %{sequence: 96}} = Conversation.import_v1(store, H.reference(), snapshot)
      assert_imported(store, H.reference(), v1, v1_runs)
      assert {:ok, :already_present} = Conversation.import_v1(store, H.reference(), snapshot)

      owner = H.owner!(store)

      assert {:refused, "already_answered"} =
               Conversation.append_answer(owner, H.answer("answer-new", "input-1", "run-1"))

      {cut_store, probe} = ProbeStore.wrap(store)
      appends = :counters.new(1, [])

      ProbeStore.hook(probe, :append, fn _operation, _args, run ->
        :counters.add(appends, 1, 1)
        if :counters.get(appends, 1) == 40, do: {:error, :unavailable}, else: run.()
      end)

      cut = H.reference("conversation-2")
      assert {:unknown, :unresolved} = Conversation.import_v1(cut_store, cut, snapshot)
      assert H.head!(store, H.stream("conversation-2")).revision == 39
      assert {:ok, %{sequence: 96}} = Conversation.import_v1(store, cut, snapshot)
      assert_imported(store, cut, v1, v1_runs)

      H.append_raw!(store, H.stream("conversation-2"), [H.entry!(:input, H.input("later"))])
      assert {:error, :not_empty} = Conversation.import_v1(store, cut, snapshot)

      H.append_raw!(store, H.stream("conversation-3"), [H.entry!(:input, H.input("foreign"))])

      assert {:error, :not_empty} =
               Conversation.import_v1(store, H.reference("conversation-3"), snapshot)

      empty = %{tenant: "t", resource: "r", revision: 0, fields: %{}}

      assert {:ok, :already_present} =
               Conversation.import_v1(store, H.reference("conversation-4"), empty)

      assert {:error, :not_empty} =
               Conversation.import_v1(store, H.reference("conversation-3"), empty)
    end)

    store = H.memory()

    assert {:error, :invalid_snapshot} =
             Conversation.import_v1(store, H.reference(), %{snapshot | revision: -1})

    for segment <- H.refused_segments(),
        bad <- [
          %{H.reference() | target_tenant: segment},
          %{H.reference() | conversation_id: segment}
        ] do
      assert {:error, :invalid_request} = Conversation.import_v1(store, bad, snapshot), inspect(bad)
    end

    assert {:error, :unsupported_store} =
             Conversation.import_v1(
               H.memory(visibility: :staged_uncommitted_tail),
               H.reference(),
               snapshot
             )
  end

  defp hundred_thousand(kind, store) do
    owner = H.owner!(store)

    {append_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..100_000, fn index ->
          assert {:ok, %{sequence: ^index}} =
                   Conversation.append_input(owner, H.input("m-#{index}", text: "message #{index}"))
        end)
      end)

    assert {:ok, %{revision: 100_000, entries: page}} =
             Conversation.page(store, H.scope(), H.reference(), 50_001, 1_000)

    assert Enum.map(page, & &1.sequence) == Enum.to_list(50_001..51_000)
    assert Enum.map(page, & &1.message_id) == Enum.map(50_001..51_000, &"m-#{&1}")

    assert {:ok, %{revision: 100_000, entries: tail}} =
             Conversation.tail(store, H.scope(), H.reference(), 100)

    assert Enum.map(tail, & &1.message_id) == Enum.map(99_901..100_000, &"m-#{&1}")

    GenServer.stop(owner)
    {start_us, {:ok, restarted}} = :timer.tc(fn -> start(store, H.conversation()) end)
    {:memory, owner_bytes} = :erlang.process_info(restarted, :memory)

    IO.puts(
      "#{kind}: 100,000 appends through one owner in #{div(append_us, 1_000)} ms; " <>
        "owner start over 100,000 rows in #{div(start_us, 1_000)} ms; owner memory #{owner_bytes} bytes"
    )

    assert {:ok, %{sequence: 100_001}} = Conversation.append_input(restarted, H.input("m-100001"))

    assert {:refused, "duplicate_message_id"} =
             Conversation.append_input(restarted, H.input("m-1", text: "other"))
  end

  defp assert_imported(store, reference, v1, v1_runs) do
    assert {:ok, %{revision: 96, entries: entries}} =
             Conversation.page(store, H.scope([reference.conversation_id]), reference, 1, 100)

    messages =
      for entry <- entries, entry.kind in [:input, :answer] do
        case entry do
          %{kind: :input} ->
            Map.take(entry, [:message_id, :role, :actor, :text])

          %{kind: :answer} ->
            entry
            |> Map.take([:message_id, :actor, :text, :run_id, :input_message_id])
            |> Map.put(:role, "assistant")
        end
      end

    assert messages == v1.messages

    associations =
      for %{kind: :association} = entry <- entries, do: {entry.input_message_id, entry.run_id}

    assert Map.new(associations) == v1_runs

    assert Enum.map(associations, &elem(&1, 0)) == Enum.map(1..32, &"input-#{&1}")
    refute Enum.map(associations, &elem(&1, 0)) == Enum.map(v1.associations, & &1.input_message_id)

    for {%{kind: :association} = entry, index} <- Enum.with_index(entries) do
      assert Enum.at(entries, index - 1).message_id == entry.input_message_id
    end
  end

  defp unresolvable(store) do
    H.inject(store, :append, :reply_loss)
    H.inject(store, :read_at, :unavailable)
    H.inject(store, :head, :unavailable)
  end

  defp start(store, id),
    do: Conversation.start_link(store: store, target_tenant: H.tenant(), conversation_id: id)

  defp write(owner, :input, dto), do: Conversation.append_input(owner, dto)
  defp write(owner, :association, dto), do: Conversation.associate_run(owner, dto)
  defp write(owner, :answer, dto), do: Conversation.append_answer(owner, dto)

  defp settle(append) do
    case append.() do
      {:error, :contended} -> settle(append)
      result -> result
    end
  end
end
