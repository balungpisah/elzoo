# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/effect_intent_test_helper.exs", __DIR__)

defmodule Elzoo.EffectIntent.StorageTest do
  use ExUnit.Case, async: false
  alias Elzoo.EffectIntent.{Binding, Model, Policy, TestBinding}
  alias Elzoo.DurableLog.Codec

  defp descriptor do
    {:ok, b} = Binding.load(TestBinding)
    b
  end

  defp admission(b, args \\ "args") do
    identity = ["tenant", b.provider_account, b.id, b.operation, "request"]
    delta = Model.admission(identity, args, "v1", 5000, 100)
    {:ok, m, :Stop} = Model.apply_delta(nil, delta, b)
    m
  end

  defp event(m, e, b, opts \\ %{}) do
    {:ok, next, _} = Model.apply_delta(m, Model.transition(e, Policy.count(m.policy), 100, opts), b)
    next
  end

  defp checkpoint(m) do
    seen = Map.new(1..m.events, fn n -> {n, Model.hash(<<n::64>>)} end)

    c = %Elzoo.Checkpoint{
      stream: Model.stream(m.key),
      sequence: m.events,
      fold_version: 1,
      model: Model.encode(m),
      cursor: {m.events, false, []},
      seen: seen,
      nonce: <<1::128>>
    }

    %{c | digest: Codec.hash(Codec.checkpoint_bytes(c))}
  end

  test "canonical model and delta roundtrips preserve actual policy/history" do
    b = descriptor()

    m =
      admission(b)
      |> event(:Arm, b)
      |> event(:ProviderUnknown, b)
      |> event(:Rearm, b)
      |> event(:Arm, b)
      |> event(:NoSend, b)

    bytes = Model.encode(m)
    assert {:ok, ^m} = Model.decode(bytes, b)
    assert Policy.flags(m.policy).replay_dependent
    fold = Model.fold(b)
    delta = Model.admission(m.identity, "args", "v1", 5000, 100)
    first = fold.reduce.(nil, "intent", 1, Model.binary(delta))
    assert first == admission(b)
    next = fold.reduce.(first, "intent", 1, Model.binary(Model.transition(:Arm, 0, 100)))
    assert Policy.count(next.policy) == 1
    assert_raise ArgumentError, fn -> fold.reduce.(first, "intent", 1, <<131, 100, 0>>) end
  end

  test "priority reservations survive complete optional evidence saturation" do
    b = descriptor()
    m = admission(b) |> event(:Arm, b)

    m =
      Enum.reduce(1..1021, m, fn _, m ->
        event(m, :Refused, b, %{evidence: <<1>>})
      end)

    # The first refused result used its priority slot; the other 1020 are
    # optional, leaving exactly the other two reserved priority slots.
    assert map_size(m.evidence) == 1021
    assert Model.held(m) == 2
    m = event(m, :Refused, b, %{evidence: <<1>>})
    assert map_size(m.evidence) + Model.held(m) == 1024

    assert {:error, :capacity} =
             Model.apply_delta(m, Model.transition(:Refused, 1, 100, %{evidence: <<1>>}), b)

    m = event(m, :NoSend, b, %{evidence: <<2>>})
    assert Model.held(m) == 1
    m = event(m, :Completed, b, %{evidence: <<3>>})
    assert Policy.flags(m.policy).quarantined
    assert Model.held(m) == 0
    assert map_size(m.evidence) == 1024
    assert Model.valid?(m)
    assert {:ok, ^m} = Model.decode(Model.encode(m), b)
  end

  test "event budget cannot borrow reserved decisive/contradictory/refused writes" do
    b = descriptor()
    m = admission(b) |> event(:Arm, b)
    saturated = %{m | events: 4093}
    assert Model.capacity?(saturated)
    assert {:error, :capacity} = Model.apply_delta(saturated, Model.transition(:Pending, 1, 100), b)
    m = event(saturated, :NoSend, b, %{evidence: <<1>>})
    m = event(m, :Refused, b, %{evidence: <<2>>})
    m = event(m, :Completed, b, %{evidence: <<3>>})
    assert m.events == 4096
    assert Policy.flags(m.policy).quarantined
    assert {:error, :capacity} = Model.apply_delta(m, Model.transition(:Pending, 1, 100), b)
  end

  test "maximum production layout and complete witness index fit; reported sizes are actual ETF bytes" do
    base = descriptor() |> Map.delete(:digest)

    b =
      Binding.compile!(
        Map.merge(base, %{
          id: String.duplicate("i", 256),
          provider_account: String.duplicate("a", 256),
          operation: String.duplicate("o", 256),
          clock: String.duplicate("c", 256)
        })
      )

    identity = [
      String.duplicate("t", 256),
      b.provider_account,
      b.id,
      b.operation,
      String.duplicate("r", 256)
    ]

    {:ok, m, :Stop} =
      Model.apply_delta(
        nil,
        Model.admission(
          identity,
          String.duplicate("x", 65_536),
          String.duplicate("s", 256),
          9_223_372_036_854_775_000,
          100
        ),
        b
      )

    attempts =
      for n <- 1..256,
          do:
            {n, String.duplicate("s", 256), Model.hash(m.arguments), b.digest,
             9_223_372_036_854_774_807}

    priority =
      for n <- 1..256,
          k <- [:settlement, :contradiction, :refused],
          into: %{},
          do: {{n, k}, :binary.copy(<<1>>, 512)}

    optional = Map.new(1..256, fn n -> {{:optional, n}, :binary.copy(<<2>>, 512)} end)

    policy =
      {:State, {:Definite, :ProviderReplaySafe, 256}, false, false, true, true, 0,
       List.duplicate(:ReplayCovered, 256)}

    m = %{
      m
      | attempts: attempts,
        policy: policy,
        evidence: Map.merge(priority, optional),
        events: 4096,
        anchor: 9_223_372_036_854_774_807,
        pending: 9_223_372_036_854_775_807,
        unavailable: 9_223_372_036_854_775_807
    }

    assert Model.valid?(m)
    c = checkpoint(m)
    assert Codec.checkpoint_valid?(c)
    size = byte_size(Codec.checkpoint_bytes(c)) + 32
    assert size <= 1_048_576
    assert Model.reserved_checkpoint_size(m) >= size
    assert Model.reserved_checkpoint_size(m) <= 1_048_576
    assert {:ok, ^m} = Model.decode(Model.encode(m), b)

    delta =
      Model.transition(:Revise, 1, 100, %{
        arguments: m.arguments,
        schema: m.schema,
        evidence: :binary.copy(<<1>>, 512)
      })

    assert byte_size(Model.binary(delta)) < 131_072

    IO.puts(
      "Effect-intent production capacity: model=#{byte_size(Model.encode(m))} checkpoint=#{size} reserved=#{Model.reserved_checkpoint_size(m)} delta=#{byte_size(Model.binary(delta))}"
    )

    # Cumulative snapshots are an upper bound, not a one-MiB total promise.
    overhead = size - byte_size(Model.encode(m)) - 4096 * 40
    cumulative = 4096 * (byte_size(Model.encode(m)) + overhead) + 40 * div(4096 * 4097, 2)
    assert cumulative > 1_048_576

    IO.puts(
      "Effect-intent production cumulative checkpoint bound: #{cumulative} bytes, plus SQL/index/append/replica overhead"
    )
  end

  test "arguments, identity, evidence and entry bounds reject limit plus one" do
    b = descriptor()
    assert Model.valid?(admission(b, :binary.copy(<<1>>, 65_536)))

    assert {:error, :admission} =
             Model.apply_delta(
               nil,
               Model.admission(
                 ["t", "account", "test", "refund", "r"],
                 :binary.copy(<<1>>, 65_537),
                 "v1",
                 5000,
                 100
               ),
               b
             )

    assert {:error, :admission} =
             Model.apply_delta(
               nil,
               Model.admission(
                 [String.duplicate("é", 129), "account", "test", "refund", "r"],
                 "a",
                 "v1",
                 5000,
                 100
               ),
               b
             )

    m = admission(b) |> event(:Arm, b)

    assert {:ok, _, _} =
             Model.apply_delta(
               m,
               Model.transition(:Refused, 1, 100, %{evidence: :binary.copy(<<1>>, 512)}),
               b
             )

    assert {:error, :evidence_limit} =
             Model.apply_delta(
               m,
               Model.transition(:Refused, 1, 100, %{evidence: :binary.copy(<<1>>, 513)}),
               b
             )

    for bad <- [
          %{m | events: 4097},
          %{m | arguments: :binary.copy(<<1>>, 65_537)},
          %{m | pending: -1},
          %{m | anchor: 99},
          Map.put(m, :extra, :field)
        ] do
      assert {:error, :invalid_snapshot} = Model.decode(Model.binary(bad), b)
    end

    assert {:error, :encoding} = Model.decode_term(<<131, 80, 0, 0, 255, 255, 1>>, 1_048_576)
    assert {:error, :encoding} = Model.decode_term(:binary.copy(<<0>>, 1_048_577), 1_048_576)
  end

  test "binding refuses partial/extra mappings, unsupported pairs, undeclared no-send and replay overflow" do
    opts = descriptor() |> Map.delete(:digest)

    for invalid <- [
          Map.update!(opts, :failures, &Map.delete(&1, :timeout)),
          Map.update!(opts, :failures, &Map.put(&1, :extra, {"failed", "dispatched", "retryable"})),
          Map.update!(
            opts,
            :failures,
            &Map.put(&1, :timeout, {"unknown", "not_dispatched", "retryable"})
          ),
          %{opts | no_send_attestations: []},
          %{
            opts
            | replay: %{
                window_ms: 1,
                max_flight_ms: 2,
                clock_allowance_ms: 0,
                semantics: :same_key_same_arguments
              }
          }
        ] do
      assert_raise ArgumentError, fn -> Binding.compile!(invalid) end
    end

    for {_tag, {outcome, dispatch, error}} <- opts.failures do
      assert {:ok, _} =
               Elzoo.Envelope.validate_result(%{
                 "version" => 1,
                 "message_id" => "m",
                 "correlation_id" => "m",
                 "attempt_id" => "m/1",
                 "outcome" => outcome,
                 "dispatch" => dispatch,
                 "error_class" => error
               })
    end

    module = Module.concat(__MODULE__, MissingFailure)
    bad = opts |> Map.update!(:failures, &Map.delete(&1, :timeout))

    assert_raise ArgumentError, fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Elzoo.EffectIntent.Binding, unquote(Macro.escape(Map.to_list(bad)))
          end
        end
      )
    end
  end
end
