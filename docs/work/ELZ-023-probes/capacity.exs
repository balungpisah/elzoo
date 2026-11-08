# SPDX-License-Identifier: Apache-2.0
# Candidate domain encoding/reservation experiment; not a production codec/fold.
ExUnit.start(autorun: false)

defmodule Elzoo.IntentCapacityProbe do
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec
  @max 9_223_372_036_854_775_807
  def limits, do: %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  def stream, do: "intent/" <> String.duplicate("f", 64)

  def fold,
    do: %{
      initial: "",
      kinds: %{"intent" => :state_bearing},
      versions: [1],
      reduce: fn _, _, _, b -> b end
    }

  def field(b), do: Codec.field(b)
  def hash(b), do: Codec.hash(b)

  def text(b),
    do:
      is_binary(b) and String.valid?(b) and not String.contains?(b, <<0>>) and
        byte_size(b) in 1..256

  def identity(fields) when length(fields) == 8 do
    if Enum.all?(fields, &text/1),
      do: {:ok, IO.iodata_to_binary(Enum.map(fields, &field/1))},
      else: {:error, :identity_limit}
  end

  def identity(_), do: {:error, :identity_limit}
  # Five logical identity fields plus schema reference, replay capability reference,
  # and clock name. Full compiled binding is pinned by digest; not copied per entry.
  def identities,
    do: Enum.map(1..8, fn i -> String.pad_trailing(Integer.to_string(i), 256, "x") end)

  def attempt(i, opts \\ []) do
    %{
      index: i,
      revision: i,
      kind: 1,
      phase: 3,
      ground: 3,
      flags: 0,
      created: @max,
      sent: @max,
      settled: @max,
      key: hash("key"),
      arguments: hash("arguments/#{i}"),
      binding: hash("binding"),
      schema: String.duplicate("s", 256),
      nonce: <<i::128>>,
      slots: {3 * i - 2, 3 * i - 1, 3 * i},
      pending: @max,
      unavailable: @max
    }
    |> Map.merge(Map.new(opts))
  end

  def encode_attempt(a) do
    {d, c, r} = a.slots

    IO.iodata_to_binary([
      <<a.index::16, a.revision::16, a.kind, a.phase, a.ground, a.flags, a.created::64, a.sent::64,
        a.settled::64>>,
      a.key,
      a.arguments,
      a.binding,
      field(a.schema),
      a.nonce,
      <<d::16, c::16, r::16, a.pending::64, a.unavailable::64>>
    ])
  end

  def evidence(i, opts \\ []) do
    %{
      attempt: rem(i - 1, 256) + 1,
      kind: rem(i - 1, 4) + 1,
      observed: @max,
      digest: hash("authenticated redacted evidence/#{i}"),
      reference: String.duplicate("r", 256),
      note: String.duplicate("n", 209)
    }
    |> Map.merge(Map.new(opts))
  end

  def encode_evidence(e) do
    b =
      IO.iodata_to_binary([
        <<e.attempt::16, e.kind, e.observed::64>>,
        e.digest,
        <<byte_size(e.reference)::16>>,
        e.reference,
        <<byte_size(e.note)::16>>,
        e.note
      ])

    if byte_size(b) <= 512, do: {:ok, b}, else: {:error, :evidence_limit}
  end

  def model(opts \\ []) do
    %{
      ids: identities(),
      arguments: String.duplicate("a", 65_536),
      events: 4096,
      entries: Enum.map(1..256, &attempt/1),
      evidence: Enum.map(1..1024, &evidence/1)
    }
    |> Map.merge(Map.new(opts))
  end

  def encode(m) do
    with {:ok, ids} <- identity(m.ids),
         true <- is_binary(m.arguments) and byte_size(m.arguments) <= 65_536,
         true <- length(m.entries) <= 256 and length(m.evidence) <= 1024 and m.events in 0..4096,
         true <- Enum.all?(m.entries, fn a -> text(a.schema) end),
         ev when is_list(ev) <- Enum.map(m.evidence, &encode_evidence/1),
         true <- Enum.all?(ev, &match?({:ok, _}, &1)) do
      # Header carries phase/disarm/quarantine, stable key/binding/argument digest,
      # admission/recovery/anchor/horizon, current entry and event count.
      b =
        IO.iodata_to_binary([
          <<1, 3, 0, 0>>,
          ids,
          hash(ids),
          hash("binding"),
          hash(m.arguments),
          <<@max::64, @max::64, @max::64, @max::64, 256::16, m.events::16>>,
          field(m.arguments),
          <<length(m.entries)::16>>,
          Enum.map(m.entries, &field(encode_attempt(&1))),
          <<length(ev)::16>>,
          Enum.map(ev, fn {:ok, b} -> field(b) end)
        ])

      {:ok, b}
    else
      _ -> {:error, :model_limit}
    end
  end

  def checkpoint(model, events) do
    seen = if events == 0, do: %{}, else: Map.new(1..events, fn i -> {i, hash(<<i::64>>)} end)

    c = %Elzoo.Checkpoint{
      stream: stream(),
      sequence: events,
      fold_version: 1,
      model: model,
      cursor: {events, false, []},
      seen: seen,
      nonce: <<1::128>>
    }

    %{c | digest: hash(Codec.checkpoint_bytes(c))}
  end

  def encoded_checkpoint_size(model, events),
    do: byte_size(Codec.checkpoint_bytes(checkpoint(model, events))) + 32

  # Budget includes reserved *unused* priority records; routine records cannot borrow.
  # Attempts/revisions consume one shared entry; reserve before the intended barrier:
  # two immediate barrier events (intended + dispatched) and three future priority events.
  def admit_budget(entries, used_evidence, held_slots, events, held_events) do
    if entries < 256 and used_evidence + held_slots + 3 <= 1024 and events + held_events + 5 <= 4096,
      do: {:ok, {entries + 1, used_evidence, held_slots + 3, events + 2, held_events + 3}},
      else: {:refused, :capacity}
  end

  def routine_budget(used, held, events, held_events) do
    if used + held < 1024 and events + held_events < 4096,
      do: {:ok, {used + 1, held, events + 1, held_events}},
      else: {:not_retained, :capacity}
  end

  def priority_budget(used, held, events, held_events) when held > 0 and held_events > 0,
    do: {:ok, {used + 1, held - 1, events + 1, held_events - 1}}

  def startup(l) do
    if Enum.all?(limits(), fn {k, v} -> Map.get(l, k, 0) >= v end),
      do: :ok,
      else: {:error, :store_limits}
  end

  # Candidate delta: header + current arguments + single entry/evidence, not full model.
  def largest_delta do
    {:ok, ids} = identity(identities())
    {:ok, e} = encode_evidence(evidence(1))

    IO.iodata_to_binary([
      <<1, 1>>,
      ids,
      field(String.duplicate("a", 65_536)),
      field(encode_attempt(attempt(1))),
      field(e)
    ])
  end

  def preflight(payload, projected_model, events, l) do
    request = %{
      stream: stream(),
      expected: events - 1,
      records: [{"intent", 1, payload}],
      outbox: []
    }

    cond do
      events not in 1..4096 ->
        {:rejected, :event_limit}

      encoded_checkpoint_size(projected_model, events) > l.max_checkpoint_bytes ->
        {:rejected, :checkpoint_too_large}

      true ->
        Log.preflight(request, fold(), l)
    end
  end
end

defmodule Elzoo.IntentCapacityProbeTest do
  use ExUnit.Case, async: false
  alias Elzoo.IntentCapacityProbe, as: P
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Codec, Record}

  test "actual worst-case encoding fits every checkpoint with framing/digest/witnesses" do
    m = P.model()
    assert {:ok, b} = P.encode(m)
    assert byte_size(P.encode_attempt(P.attempt(256))) == 426
    assert {:ok, e} = P.encode_evidence(P.evidence(1024))
    assert byte_size(e) == 512
    # Exact formula: header+8 length-framed IDs+3 digests+4 times+2 indices,
    # args framing, both table counts, per-entry framing, every evidence frame.
    assert byte_size(b) == 4 + 8 * 260 + 96 + 36 + 65_540 + 4 + 256 * 430 + 1024 * 516
    c = P.checkpoint(b, 4096)
    assert Codec.checkpoint_valid?(c)
    assert P.encoded_checkpoint_size(b, 4096) <= 1_048_576
    assert byte_size(Codec.seen_bytes(c.seen)) == 5 + 4096 * 40
    for n <- [0, 1, 4095, 4096], do: assert(P.encoded_checkpoint_size(b, n) <= 1_048_576)

    IO.puts(
      "Capacity: entry=426 evidence=512 model=#{byte_size(b)} checkpoint=#{P.encoded_checkpoint_size(b, 4096)} delta=#{byte_size(P.largest_delta())}"
    )
  end

  test "identity/arguments/entries/evidence/events boundaries and limit+1" do
    m = P.model()
    assert {:ok, _} = P.encode(m)

    for bad <- [
          %{m | ids: [String.duplicate("x", 257) | tl(m.ids)]},
          %{m | arguments: String.duplicate("a", 65_537)},
          %{m | entries: m.entries ++ [P.attempt(257)]},
          %{m | evidence: m.evidence ++ [P.evidence(1025)]},
          %{m | events: 4097}
        ] do
      assert {:error, _} = P.encode(bad)
    end

    assert {:error, :evidence_limit} =
             P.encode_evidence(P.evidence(1, note: String.duplicate("n", 210)))

    assert {:ok, _} = P.identity([String.duplicate("é", 128) | tl(m.ids)])
    assert {:error, _} = P.identity([String.duplicate("é", 129) | tl(m.ids)])
  end

  test "priority reserves survive routine saturation and admission at event boundary" do
    # 256 attempts: 512 barrier events + 768 reserved priority events, 768 slots.
    b =
      Enum.reduce(1..256, {0, 0, 0, 0, 0}, fn _, {a, u, h, e, r} ->
        {:ok, b} = P.admit_budget(a, u, h, e, r)
        b
      end)

    assert b == {256, 0, 768, 512, 768}
    assert P.admit_budget(256, 0, 768, 512, 768) == {:refused, :capacity}

    {u, h, e, r} =
      Enum.reduce(1..256, {0, 768, 512, 768}, fn _, {u, h, e, r} ->
        {:ok, b} = P.routine_budget(u, h, e, r)
        b
      end)

    assert P.routine_budget(u, h, e, r) == {:not_retained, :capacity}

    assert {1024, 0, 1536, 0} ==
             Enum.reduce(1..768, {u, h, e, r}, fn _, {u, h, e, r} ->
               {:ok, b} = P.priority_budget(u, h, e, r)
               b
             end)

    assert {:ok, _} = P.admit_budget(0, 0, 0, 4091, 0)
    assert {:refused, :capacity} = P.admit_budget(0, 0, 0, 4092, 0)
    # Existing reserves still work when all unreserved event capacity is consumed.
    assert P.routine_budget(10, 3, 4093, 3) == {:not_retained, :capacity}
    assert {:ok, {11, 2, 4094, 2}} = P.priority_budget(10, 3, 4093, 3)
  end

  test "Store startup requirements and actual append payload limit" do
    assert :ok = P.startup(P.limits())

    for key <- Map.keys(P.limits()) do
      assert {:error, :store_limits} = P.startup(Map.update!(P.limits(), key, &(&1 - 1)))
    end

    {:ok, m} = P.encode(P.model())
    assert :ok = P.preflight(P.largest_delta(), m, 4096, P.limits())
    assert :ok = P.preflight(String.duplicate("x", 131_072), m, 4096, P.limits())

    assert {:rejected, :record_too_large} =
             P.preflight(String.duplicate("x", 131_073), m, 4096, P.limits())

    assert {:rejected, :event_limit} = P.preflight(P.largest_delta(), m, 4097, P.limits())
    # Store's max_record_bytes is payload bytes, not canonical framing; record both.
    row = %Record{
      stream: P.stream(),
      sequence: 4096,
      kind: "intent",
      schema_version: 1,
      payload: P.largest_delta(),
      nonce: <<1::128>>
    }

    assert byte_size(Log.canonical_bytes(row)) + 32 < 131_072
  end

  test "checkpoint exact byte limit and preflight refusal before append leave head unchanged" do
    {:ok, b} = P.encode(P.model())
    size = P.encoded_checkpoint_size(b, 4096)
    c = P.checkpoint(b, 4096)
    replay = %{model: b, cursor: c.cursor, seen: c.seen}
    # take rejects by size before it even calls Store; nil is deliberately not a Store.
    assert {:rejected, :checkpoint_too_large} =
             Elzoo.Checkpoint.take(
               {nil, replay, %{P.limits() | max_checkpoint_bytes: size - 1}},
               P.stream(),
               1,
               &Function.identity/1
             )

    pid = start_supervised!({Memory, fold: P.fold(), limits: P.limits()})
    s = Memory.store(pid, %{fold: P.fold()})
    assert {:ok, head} = Memory.head(s, P.stream())
    assert head.revision == 0

    assert {:rejected, :checkpoint_too_large} =
             P.preflight(P.largest_delta(), b, 4096, %{P.limits() | max_checkpoint_bytes: size - 1})

    assert {:ok, ^head} = Memory.head(s, P.stream())
    assert :ok = P.preflight(P.largest_delta(), b, 4096, %{P.limits() | max_checkpoint_bytes: size})
  end

  test "existing Store accepts exact one-MiB snapshot and refuses byte/batch limit plus one" do
    pid = start_supervised!({Memory, fold: P.fold(), limits: P.limits()})
    s = Memory.store(pid, %{fold: P.fold()})

    row = %Record{
      stream: P.stream(),
      sequence: 1,
      kind: "intent",
      schema_version: 1,
      payload: "seed",
      nonce: <<1::128>>
    }

    row = %{row | digest: Log.digest(row)}
    assert {:committed, 1} = Memory.append(s, P.stream(), 0, [row], [])
    state = Log.replay([row], 1, P.fold())

    empty = %Elzoo.Checkpoint{
      stream: P.stream(),
      sequence: 1,
      fold_version: 1,
      model: "",
      cursor: state.cursor,
      seen: state.seen,
      nonce: <<1::128>>
    }

    overhead = byte_size(Codec.checkpoint_bytes(empty)) + 32
    # This is the opaque Store model byte boundary, not an admitted domain model.
    exact = String.duplicate("x", 1_048_576 - overhead)

    assert {:committed, 1} =
             Elzoo.Checkpoint.take(
               {s, %{state | model: exact}, P.limits()},
               P.stream(),
               1,
               &Function.identity/1
             )

    assert {:rejected, :checkpoint_too_large} =
             Elzoo.Checkpoint.take(
               {s, %{state | model: exact <> "x"}, P.limits()},
               P.stream(),
               1,
               &Function.identity/1
             )

    request = %{
      stream: P.stream(),
      expected: 1,
      records: [{"intent", 1, "a"}, {"intent", 1, "b"}],
      outbox: []
    }

    assert {:rejected, :batch_too_large} = Log.preflight(request, P.fold(), P.limits())
  end

  test "cumulative storage is bounded per stream but is not a one-MiB total promise" do
    {:ok, b} = P.encode(P.model())
    # Monotone exact worst-model upper bound, one immutable checkpoint per event.
    cumulative = Enum.reduce(1..4096, 0, fn n, sum -> sum + P.encoded_checkpoint_size(b, n) end)
    assert cumulative > 1_048_576
    assert cumulative <= 4096 * 1_048_576

    IO.puts(
      "Capacity: cumulative checkpoint byte upper bound=#{cumulative}; excludes DB indexes/rows, replicas and append log"
    )
  end
end

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
IO.puts("Result: #{result.total} passed (capacity amendment probe)")
