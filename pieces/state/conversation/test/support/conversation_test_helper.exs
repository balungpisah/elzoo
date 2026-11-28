# SPDX-License-Identifier: Apache-2.0
sql_helper =
  Enum.find(
    [
      Path.expand("durable_log_postgres_test_helper.exs", __DIR__),
      Path.expand(
        "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
        __DIR__
      )
    ],
    &File.regular?/1
  ) || raise "Conversation PostgreSQL test support is unavailable"

Code.require_file(sql_helper)

defmodule Elzoo.ConversationTest.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.ConversationTest.ProbeStore do
  @moduledoc """
  A Store that records each call by operation and delegates to an inner Store.
  A hook `fun.(operation, args, run)` replaces one operation; `run.()` performs
  the inner call. Hooks run in the calling process.
  """
  @behaviour Elzoo.DurableLog.Store

  def wrap({_module, opts} = inner) do
    {:ok, probe} = Agent.start_link(fn -> %{calls: [], hooks: %{}} end)
    {{__MODULE__, %{inner: inner, probe: probe, fold: opts.fold, limits: opts.limits}}, probe}
  end

  def calls(probe), do: Agent.get(probe, &Enum.reverse(&1.calls))
  def reset(probe), do: Agent.update(probe, &%{&1 | calls: []})
  def hook(probe, operation, fun), do: Agent.update(probe, &put_in(&1.hooks[operation], fun))

  def unhook(probe, operation),
    do: Agent.update(probe, &%{&1 | hooks: Map.delete(&1.hooks, operation)})

  @impl true
  def capabilities(store), do: intercept(store, :capabilities, [])
  @impl true
  def head(store, stream), do: intercept(store, :head, [stream])
  @impl true
  def read(store, stream, from, limit), do: intercept(store, :read, [stream, from, limit])
  @impl true
  def read_at(store, stream, sequence), do: intercept(store, :read_at, [stream, sequence])
  @impl true
  def append(store, stream, expected, records, items),
    do: intercept(store, :append, [stream, expected, records, items])

  @impl true
  def put_checkpoint(store, checkpoint), do: intercept(store, :put_checkpoint, [checkpoint])
  @impl true
  def latest_checkpoint(store, stream, version),
    do: intercept(store, :latest_checkpoint, [stream, version])

  @impl true
  def retain(store, stream, expected, through, nonce),
    do: intercept(store, :retain, [stream, expected, through, nonce])

  @impl true
  def pending(store, stream, limit), do: intercept(store, :pending, [stream, limit])
  @impl true
  def ack(store, id, nonce), do: intercept(store, :ack, [id, nonce])
  @impl true
  def read_ack(store, id), do: intercept(store, :read_ack, [id])
  @impl true
  def read_checkpoint(store, stream, sequence, version),
    do: intercept(store, :read_checkpoint, [stream, sequence, version])

  @impl true
  def read_maintenance(store, stream, operation),
    do: intercept(store, :read_maintenance, [stream, operation])

  @impl true
  def repair_torn_tail(store, stream, expected, staged, nonce),
    do: intercept(store, :repair_torn_tail, [stream, expected, staged, nonce])

  defp intercept({__MODULE__, state}, operation, args) do
    hook =
      Agent.get_and_update(state.probe, fn probe ->
        {Map.get(probe.hooks, operation), %{probe | calls: [{operation, args} | probe.calls]}}
      end)

    {module, _} = state.inner
    run = fn -> apply(module, operation, [state.inner | args]) end
    if hook, do: hook.(operation, args, run), else: run.()
  end
end

defmodule Elzoo.ConversationTest.Helper do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL
  alias Elzoo.Conversation.Record
  alias Elzoo.ConversationTest.Repo
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Postgres, PostgresHarness, Store}

  @tenant "tenant-1"
  @conversation "conversation-1"

  def tenant, do: @tenant
  def conversation, do: @conversation
  def reference(id \\ @conversation), do: %{target_tenant: @tenant, conversation_id: id}
  def stream(id \\ @conversation), do: Record.stream(@tenant, id)

  @doc """
  Values that are not stream-name segments: empty, 65 bytes, a `/`, `.`, `..`,
  a non-ASCII character, an invalid byte, a space and a NUL.
  """
  def refused_segments,
    do: ["", String.duplicate("s", 65), "a/b", "/", ".", "..", "é", <<0xFF>>, "a b", "a\0"]

  def scope(resources \\ [@conversation]),
    do: %{tenant: @tenant, actor: "reader", resources: resources}

  def fold(kinds \\ Record.kinds()) do
    %{
      kinds: Map.new(kinds ++ ["foreign"], &{&1, :non_state_bearing}),
      versions: [1],
      destinations: []
    }
  end

  def limits(max_record_bytes \\ Record.max_payload_bytes()),
    do: %{max_record_bytes: max_record_bytes, max_batch_size: 1_000, max_checkpoint_bytes: 65_536}

  def memory(opts \\ []) do
    {:ok, pid} =
      Memory.start_link(
        fold: Keyword.get(opts, :fold, fold()),
        limits: Keyword.get(opts, :limits, limits()),
        append_visibility: Keyword.get(opts, :visibility, :atomic)
      )

    Memory.store(pid)
  end

  def start_repo! do
    {:ok, repo} = Repo.start_link(url: PostgresHarness.database_url!(), pool_size: 12, log: false)
    Process.unlink(repo)
    :ok = PostgresHarness.reachable!(Repo)
    repo
  end

  def postgres(opts \\ []) do
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    prefix = "conv_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(Repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(Repo, 1, Elzoo.DurableLog.TestMigration, prefix: prefix, log: false)

    on_exit(fn ->
      PostgresHarness.cleanup(controller)
      SQL.query!(Repo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)
      Agent.stop(controller)
    end)

    PostgresHarness.attach(
      Repo,
      prefix,
      Keyword.get(opts, :fold, fold()),
      Keyword.get(opts, :limits, limits()),
      controller
    )
  end

  @doc "Run `fun.(kind, store)` once on a fresh Memory Store and once on a fresh PostgreSQL Store."
  def each_store(opts \\ [], fun) do
    for kind <- [:memory, :postgres] do
      store = if kind == :memory, do: memory(opts), else: postgres(opts)
      fun.(kind, store)
    end
  end

  def owner!(store, id \\ @conversation) do
    {:ok, owner} =
      Elzoo.Conversation.start_link(store: store, target_tenant: @tenant, conversation_id: id)

    owner
  end

  def inject({Memory, _} = store, operation, mode), do: Memory.fault(store, operation, mode)

  def inject({Postgres, _} = store, operation, mode),
    do: PostgresHarness.hook(store, :inject, [operation, mode])

  def head!(store, stream \\ stream()) do
    {:ok, head} = Store.read(store, :head, [stream])
    head
  end

  def rows!(store, stream \\ stream()) do
    head = head!(store, stream)

    if head.revision == 0 do
      []
    else
      {:ok, rows, _} = Store.read(store, :read, [stream, 1, head.revision])
      rows
    end
  end

  @doc "Append entries as one batch, as a writer outside the owner would."
  def append_raw!(store, stream, entries) do
    head = head!(store, stream)
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      entries
      |> Enum.with_index(head.revision + 1)
      |> Enum.map(fn {entry, sequence} -> Record.row(stream, sequence, entry, nonce) end)

    request = %{
      operation: :append,
      stream: stream,
      expected: head.revision,
      target: head.revision + length(rows),
      nonce: nonce,
      digest: Codec.hash(Enum.map(rows, &Log.canonical_bytes/1))
    }

    assert {:committed, _} =
             Store.write(store, :append, [stream, head.revision, rows, []], request)

    rows
  end

  def entry!(mode, dto) do
    {:ok, entry, _completed} = Record.intent(mode, dto)
    entry
  end

  def decode!(row) do
    {:ok, entry} = Record.decode(row, row.stream, row.sequence, fold(), limits())
    entry
  end

  @doc "Append one row of a kind this Piece does not own (the Store fold declares it)."
  def append_foreign!(store, stream) do
    head = head!(store, stream)

    row = %Log.Record{
      stream: stream,
      sequence: head.revision + 1,
      kind: "foreign",
      schema_version: 1,
      payload: "{}",
      nonce: :crypto.strong_rand_bytes(16)
    }

    row = %{row | digest: Log.digest(row)}

    assert {:committed, _} =
             Store.write(
               store,
               :append,
               [stream, head.revision, [row], []],
               Record.request(row)
             )

    row
  end

  @doc """
  A version 1 conversation of 32 inputs, 32 answers and 32 associations: each
  answer follows the next input, two inputs share each Run, and the
  associations were admitted in reverse input order.
  """
  def v1_fixture do
    inputs =
      for k <- 1..32,
          do: v1_input("input-#{k}", "question #{k}", Enum.at(["user", "source"], rem(k, 2)))

    run = fn k -> "run-#{div(k - 1, 2) + 1}" end
    answers = for k <- 1..32, do: v1_answer("answer-#{k}", "input-#{k}", run.(k), "answer #{k}\0")

    messages =
      [hd(inputs) | Enum.flat_map(1..31, &[Enum.at(inputs, &1), Enum.at(answers, &1 - 1)])] ++
        [List.last(answers)]

    associations = for k <- 32..1//-1, do: v1_association("input-#{k}", run.(k))
    v1_snapshot(messages, associations, 96)
  end

  def input(id, opts \\ []),
    do: %{
      message_id: id,
      role: Keyword.get(opts, :role, "user"),
      actor: Keyword.get(opts, :actor, "host"),
      text: Keyword.get(opts, :text, "text of " <> id)
    }

  def association(input_id, run_id), do: %{input_message_id: input_id, run_id: run_id}

  def answer(id, input_id, run_id, opts \\ []),
    do: %{
      message_id: id,
      actor: Keyword.get(opts, :actor, "host"),
      text: Keyword.get(opts, :text, "answer of " <> input_id),
      run_id: run_id,
      input_message_id: input_id,
      completed: Keyword.get(opts, :completed, true)
    }

  @doc "Replace the payload of a stored row, keeping its digest (persisted damage)."
  def corrupt!({Memory, _} = store, stream, sequence, payload),
    do: Memory.corrupt(store, :records, {stream, sequence}, %{payload: payload})

  def corrupt!({Postgres, opts}, stream, sequence, payload) do
    SQL.query!(
      opts.repo,
      "UPDATE #{Postgres.identifier(opts.prefix)}.elzoo_log_records SET payload = $1 WHERE stream = $2 AND sequence = $3",
      [payload, stream, sequence],
      log: false
    )

    :ok
  end

  @doc "Install a valid checkpoint at `through` and retain the prefix through it."
  def prune!({module, _} = store, stream, through) do
    {:ok, [row], _} = Store.read(store, :read, [stream, through, 1])

    checkpoint = %{
      stream: stream,
      sequence: through,
      fold_version: 1,
      model: "conversation",
      cursor: {through, false, []},
      seen: %{through => row.digest},
      nonce: :crypto.strong_rand_bytes(16)
    }

    checkpoint = Map.put(checkpoint, :digest, Codec.hash(Codec.checkpoint_bytes(checkpoint)))
    assert {:committed, ^through} = module.put_checkpoint(store, checkpoint)

    assert {:committed, ^through} =
             module.retain(store, stream, 0, through, :crypto.strong_rand_bytes(16))

    :ok
  end

  # Version 1 field state, as the version 1 Piece stored it.

  def v1_snapshot(messages, associations, revision \\ 1),
    do: %{
      tenant: "v1-tenant",
      resource: "v1-conversation",
      revision: revision,
      fields: %{"conversation" => v1_state(messages, associations)}
    }

  def v1_state(messages, associations),
    do:
      v1_record([
        {"associations", {:list, associations}},
        {"messages", {:list, messages}},
        {"version", 1}
      ])

  def v1_input(id, text, role \\ "user", actor \\ "host"),
    do:
      v1_record([
        {"actor", {:text, actor}},
        {"message_id", {:text, id}},
        {"role", {:text, role}},
        {"text", {:text, text}}
      ])

  def v1_answer(id, input_id, run_id, text, actor \\ "host"),
    do:
      v1_record([
        {"actor", {:text, actor}},
        {"input_message_id", {:text, input_id}},
        {"message_id", {:text, id}},
        {"role", {:text, "assistant"}},
        {"run_id", {:text, run_id}},
        {"text", {:text, text}}
      ])

  def v1_association(input_id, run_id),
    do: v1_record([{"input_message_id", {:text, input_id}}, {"run_id", {:text, run_id}}])

  def v1_record(pairs), do: {:record, Enum.sort_by(pairs, &elem(&1, 0))}
end
