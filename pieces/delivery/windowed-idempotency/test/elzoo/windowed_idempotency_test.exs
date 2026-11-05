# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WindowedIdempotencyTest do
  use ExUnit.Case, async: false
  alias Elzoo.WindowedIdempotency, as: Window
  @receiver :"Cure.Elzoo.WindowedIdempotency"
  @source File.read!(Path.expand("../../cure/elzoo/windowed_idempotency.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)

  defp call(name, args), do: apply(@receiver, name, args)
  defp message(q, s \\ 1, i \\ 1, v \\ 10), do: {:Message, s, i, q, v}

  defp receive_as(state, input, expected) do
    assert {:ok, ^expected} = Window.classify(state, input)
    assert {:ok, {next, output}, ^expected} = Window.receive(state, input)
    decision = call(:classify, [state, input])
    assert {:Transition, ^next, ^output} = call(:step, [state, input, decision])
    assert {:Transition, ^next, ^output} = call(:receiver, [state, input])

    if expected in [:fresh, :advance, :reorder, :new_incarnation] do
      assert output == {:some, input}
    else
      assert output == :none
      assert next == state
    end

    assert_bounds(next)
    next
  end

  defp assert_bounds({:WindowedState, w, n, senders}) do
    assert length(senders) <= n

    for {:SenderWindow, _, _, high, accepted} <- senders do
      assert length(accepted) <= w
      assert length(Enum.uniq(accepted)) == length(accepted)
      assert high in accepted
      assert Enum.all?(accepted, &(&1 > high - w and &1 <= high))
    end
  end

  test "first, duplicate values, boundary reorder/stale, incarnations and full capacity" do
    {:ok, state} = Window.new(4, 1)
    state = receive_as(state, message(10), :fresh)
    state = receive_as(state, message(10), :duplicate)
    state = receive_as(state, message(10, 1, 1, 999), :duplicate)
    state = receive_as(state, message(6), :stale)
    state = receive_as(state, message(7), :reorder)
    state = receive_as(state, message(7), :duplicate)
    state = receive_as(state, message(9), :reorder)
    state = receive_as(state, message(8), :reorder)
    state = receive_as(state, message(0, 2), :full)
    state = receive_as(state, message(11), :advance)
    state = receive_as(state, message(100), :advance)
    state = receive_as(state, message(101, 1, 0), :superseded)
    state = receive_as(state, message(-10, 1, 2), :new_incarnation)
    state = receive_as(state, message(-11, 1, 2), :reorder)
    receive_as(state, message(-9, 1, 2), :advance)
  end

  test "step stores the production helper for singleton and wider full windows" do
    for w <- [1, 4] do
      {:ok, initial} = Window.new(w, 2)
      state = receive_as(initial, message(-5, 2), :fresh)
      state = receive_as(state, message(0), :fresh)

      state =
        Enum.reduce(1..8, state, fn sequence, state ->
          {:WindowedState, ^w, 2, entries} = state
          {:SenderWindow, 1, 1, _, previous} = Enum.find(entries, &(elem(&1, 1) == 1))
          expected = call(:advance_accepted, [w == 1, w, sequence, previous])
          next = receive_as(state, message(sequence), :advance)
          {:WindowedState, ^w, 2, updated} = next

          assert {:SenderWindow, 1, 1, ^sequence, ^expected} =
                   Enum.find(updated, &(elem(&1, 1) == 1))

          assert {:SenderWindow, 2, 1, -5, [-5]} in updated
          if w == 1, do: assert(expected == [sequence])
          next
        end)

      state = receive_as(state, message(8), :duplicate)
      receive_as(state, message(8 - w), :stale)
    end

    assert call(:advance_accepted, [true, 1, -8, [-9, -10]]) == [-8]
    assert call(:prune_after, [5, []]) == []
  end

  test "direct invalid initial configurations suppress without mutation" do
    for {w, n} <- [{0, 1}, {-1, 1}, {1, 0}, {1, -1}, {0, 0}] do
      state = call(:initial, [w, n])
      assert call(:classify, [state, message(1)]) == :WindowInvalid
      assert call(:receiver, [state, message(1)]) == {:Transition, state, :none}
    end
  end

  test "construction and all foreign validation errors have fixed atoms and precedence" do
    for bad <- [0, -1, 1.0, nil, "1", [], [1 | 2]] do
      assert Window.new(bad, bad) == {:error, :invalid_window}
      assert Window.new(1, bad) == {:error, :invalid_max_senders}
    end

    {:ok, state} = Window.new(3, 1)
    entry = {:SenderWindow, 1, 1, 3, [3, 2]}

    invalid_states = [
      nil,
      {},
      {:WindowedState, 1, 1},
      {:WindowedState, 0, 1, []},
      {:WindowedState, 1, 0, []},
      {:WindowedState, 1.0, 1, []},
      {:WindowedState, 1, nil, []},
      {:WindowedState, 3, 1, [entry | :improper]},
      {:WindowedState, 3, 1, :not_a_list},
      {:WindowedState, 3, 1, [entry, {:SenderWindow, 2, 1, 3, [3]}]},
      {:WindowedState, 3, 2, [entry, entry]}
    ]

    invalid_entries = [
      nil,
      {:SenderWindow, 1, 1, 3},
      {:SenderWindow, nil, 1, 3, [3]},
      {:SenderWindow, 1, nil, 3, [3]},
      {:SenderWindow, 1, 1, 3.0, [3]},
      {:SenderWindow, 1, 1, 3, []},
      {:SenderWindow, 1, 1, 3, [3 | :improper]},
      {:SenderWindow, 1, 1, 3, :not_a_list},
      {:SenderWindow, 1, 1, 3, [3, nil]},
      {:SenderWindow, 1, 1, 3, [2]},
      {:SenderWindow, 1, 1, 3, [3, 3]},
      {:SenderWindow, 1, 1, 3, [3, 0]},
      {:SenderWindow, 1, 1, 3, [3, 4]}
    ]

    invalid_states = invalid_states ++ Enum.map(invalid_entries, &{:WindowedState, 3, 1, [&1]})

    for invalid <- invalid_states do
      for input <- [message(1), :invalid] do
        assert Window.receive(invalid, input) == {:error, :invalid_state}
        assert Window.classify(invalid, input) == {:error, :invalid_state}
      end
    end

    invalid_messages =
      [nil, [], {:Message, 1, 1, 1}, {:Other, 1, 1, 1, 1}] ++
        for(index <- 1..4, do: put_elem(message(1), index, 1.0))

    for input <- invalid_messages do
      assert Window.receive(state, input) == {:error, :invalid_message}
      assert Window.classify(state, input) == {:error, :invalid_message}
    end

    receive_as(state, message(-100, -2, -3, -4), :fresh)
  end

  test "seeded traces agree with independent map/set reference model" do
    :rand.seed(:exsss, {505, 17, 29})

    for w <- [1, 2, 5], n <- [1, 3] do
      {:ok, initial} = Window.new(w, n)

      Enum.reduce(1..400, {initial, %{}}, fn _, {state, model} ->
        input =
          message(
            :rand.uniform(20) - 11,
            :rand.uniform(5),
            :rand.uniform(4) - 2,
            :rand.uniform(100)
          )

        {expected, next_model} = reference(model, input, w, n)
        next = receive_as(state, input, expected)
        assert normalize(next) == next_model
        {next, next_model}
      end)
    end
  end

  defp reference(model, {:Message, sender, incarnation, sequence, _}, w, n) do
    old = Map.get(model, sender)

    decision =
      case old do
        nil -> if map_size(model) == n, do: :full, else: :fresh
        {i, _, _} when incarnation < i -> :superseded
        {i, _, _} when incarnation > i -> :new_incarnation
        {_, high, _} when sequence > high -> :advance
        {_, high, _} when sequence <= high - w -> :stale
        {_, _, seen} -> if MapSet.member?(seen, sequence), do: :duplicate, else: :reorder
      end

    next =
      case decision do
        d when d in [:fresh, :new_incarnation] ->
          {incarnation, sequence, MapSet.new([sequence])}

        :advance ->
          {_, _, seen} = old

          {incarnation, sequence,
           MapSet.new(sequence..(sequence - w + 1)//-1)
           |> MapSet.intersection(MapSet.put(seen, sequence))}

        :reorder ->
          {_, high, seen} = old
          {incarnation, high, MapSet.put(seen, sequence)}

        _ ->
          old
      end

    {decision, if(next == nil, do: model, else: Map.put(model, sender, next))}
  end

  defp normalize({:WindowedState, _, _, senders}) do
    Map.new(senders, fn {:SenderWindow, s, i, h, accepted} -> {s, {i, h, MapSet.new(accepted)}} end)
  end

  test "receiver composes as a typed first operator and suppresses downstream work" do
    source = """
    mod Elzoo.WindowConsumer
      use Std.Option
      use Elzoo.Composition
      use Elzoo.WindowedIdempotency
      fn accumulate(state: Int, input: Elzoo.Idempotency.Message) -> Transition(Int, Int) =
        Transition{state: state + input.value, output: Some(state + input.value)}
      fn run(state: Joined(WindowedState, Int), input: Elzoo.Idempotency.Message) -> Transition(Joined(WindowedState, Int), Int) =
        compose(receiver, accumulate, state, input)
    end
    """

    assert {:ok, module} = Cure.Compiler.compile_and_load(source, source_roots: @roots)
    {:ok, initial} = Window.new(3, 1)
    input = message(1)
    assert {:Transition, next, {:some, 10}} = apply(module, :run, [{:Joined, initial, 0}, input])
    assert {:Transition, ^next, :none} = apply(module, :run, [next, input])
  end

  test "production audit is clean including opacity and totality" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total] do
      assert Map.fetch!(report, key) == []
    end

    assert report.absurd == 0
  end

  test "production false duplicate law, retained singleton mutation and hole are rejected" do
    for {name, from, to} <- [
          {"WindowWrongDuplicate", "WindowDuplicate() -> Transition{state: state, output: None()}",
           "WindowDuplicate() -> Transition{state: state, output: Some(input)}"},
          {"WindowWrongRetention", "True() -> [sequence]", "True() -> [sequence | previous]"}
        ] do
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.WindowedIdempotency", "mod Elzoo." <> name)
        |> String.replace(from, to)

      refute wrong == @source

      assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)
    end

    unfinished =
      @source
      |> String.replace("mod Elzoo.WindowedIdempotency", "mod Elzoo.WindowUnfinished")
      |> String.replace("reflexive(singleton(sequence))", "?unfinished")

    assert {:error, {:codegen_error, {:unfilled_hole, info}}} =
             Cure.Compiler.compile_and_load(unfinished, source_roots: @roots)

    assert info.definition == :"Elzoo.WindowUnfinished#singleton_advance_window"
  end
end
