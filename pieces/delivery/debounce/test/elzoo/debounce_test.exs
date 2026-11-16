# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DebounceTest do
  use ExUnit.Case, async: false

  alias Elzoo.Debounce

  @source File.read!(Path.expand("../../cure/elzoo/debounce.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @maximum 9_223_372_036_854_775_807
  @max_value_bytes 65_536
  @laws ~w(regression_rejection_keeps_state stale_timeout_has_no_emission latest_pending_value_is_emitted emitted_generation_cannot_emit_twice)

  defp fields({:DebounceState, epoch, quiet_ms, generation, pending, last_observed_now}),
    do: {epoch, quiet_ms, generation, pending, last_observed_now}

  defp assert_refusal(state, command, reason) do
    assert {:error, ^reason, ^state} = Debounce.transition(state, command)
  end

  test "new state is empty; early timeout reschedules the original deadline and due timeout emits latest value once" do
    assert {:ok, empty} = Debounce.new("partition-a", 10)
    assert fields(empty) == {~c"partition-a", 10, 0, :none, :none}

    assert {:ok, first, {:schedule, {"partition-a", 1}, 20}} =
             Debounce.transition(empty, {:put, 10, "first"})

    assert {:ok, early, {:schedule, {"partition-a", 1}, 20}} =
             Debounce.transition(first, {:timeout, 15, {"partition-a", 1}})

    assert fields(early) ==
             {~c"partition-a", 10, 1, {:some, {:DebouncePending, ~c"first", 1, 20}}, {:some, 15}}

    assert {:ok, latest, {:schedule, {"partition-a", 2}, 28}} =
             Debounce.transition(early, {:put, 18, "latest"})

    assert {:ok, emitted, {:emit, "latest"}} =
             Debounce.transition(latest, {:timeout, 28, {"partition-a", 2}})

    assert fields(emitted) == {~c"partition-a", 10, 2, :none, {:some, 28}}

    assert {:ok, duplicate, :ignored} =
             Debounce.transition(emitted, {:timeout, 29, {"partition-a", 2}})

    assert fields(duplicate) == {~c"partition-a", 10, 2, :none, {:some, 29}}
  end

  test "empty-state and well-formed nonmatching timeouts are ignored but record their samples" do
    {:ok, state} = Debounce.new("partition-a", 10)
    assert {:ok, observed, :ignored} = Debounce.transition(state, {:timeout, 7, {"other", 1}})
    assert fields(observed) == {~c"partition-a", 10, 0, :none, {:some, 7}}

    assert {:ok, later, :ignored} = Debounce.transition(observed, {:timeout, 8, {"partition-a", 1}})
    assert fields(later) == {~c"partition-a", 10, 0, :none, {:some, 8}}
    assert_refusal(later, {:put, 7, "regression"}, :time_regression)
  end

  test "latest puts replace values and stale or wrong-epoch tokens never emit" do
    {:ok, state} = Debounce.new("partition-a", 5)
    {:ok, first, {:schedule, {"partition-a", 1}, 6}} = Debounce.transition(state, {:put, 1, "old"})

    {:ok, replaced, {:schedule, {"partition-a", 2}, 8}} =
      Debounce.transition(first, {:put, 3, "new"})

    assert {:ok, wrong_epoch, :ignored} =
             Debounce.transition(replaced, {:timeout, 8, {"partition-b", 2}})

    assert fields(wrong_epoch) ==
             {~c"partition-a", 5, 2, {:some, {:DebouncePending, ~c"new", 2, 8}}, {:some, 8}}

    assert {:ok, stale, :ignored} =
             Debounce.transition(wrong_epoch, {:timeout, 8, {"partition-a", 1}})

    assert fields(stale) ==
             {~c"partition-a", 5, 2, {:some, {:DebouncePending, ~c"new", 2, 8}}, {:some, 8}}

    assert {:ok, due, {:emit, "new"}} =
             Debounce.transition(stale, {:timeout, 8, {"partition-a", 2}})

    assert fields(due) == {~c"partition-a", 5, 2, :none, {:some, 8}}
  end

  test "clear cancels pending tokens, preserves time and generation, and invalidates old generations" do
    {:ok, state} = Debounce.new("partition-a", 5)

    {:ok, pending, {:schedule, {"partition-a", 1}, 6}} =
      Debounce.transition(state, {:put, 1, "value"})

    assert {:ok, cleared, {:cancel, {"partition-a", 1}}} = Debounce.transition(pending, :clear)
    assert fields(cleared) == {~c"partition-a", 5, 1, :none, {:some, 1}}

    assert {:ok, unchanged, :unchanged} = Debounce.transition(cleared, :clear)
    assert unchanged == cleared

    assert {:ok, next, {:schedule, {"partition-a", 2}, 11}} =
             Debounce.transition(unchanged, {:put, 6, "next"})

    assert {:ok, stale, :ignored} = Debounce.transition(next, {:timeout, 11, {"partition-a", 1}})

    assert fields(stale) ==
             {~c"partition-a", 5, 2, {:some, {:DebouncePending, ~c"next", 2, 11}}, {:some, 11}}
  end

  test "serialized put-first postpones while timeout-first emits the old value before a later put" do
    {:ok, empty} = Debounce.new("partition-a", 5)

    {:ok, initial, {:schedule, {"partition-a", 1}, 6}} =
      Debounce.transition(empty, {:put, 1, "old"})

    assert {:ok, put_first, {:schedule, {"partition-a", 2}, 11}} =
             Debounce.transition(initial, {:put, 6, "new"})

    assert {:ok, after_stale, :ignored} =
             Debounce.transition(put_first, {:timeout, 6, {"partition-a", 1}})

    assert fields(after_stale) ==
             {~c"partition-a", 5, 2, {:some, {:DebouncePending, ~c"new", 2, 11}}, {:some, 6}}

    assert {:ok, timeout_first, {:emit, "old"}} =
             Debounce.transition(initial, {:timeout, 6, {"partition-a", 1}})

    assert {:ok, after_put, {:schedule, {"partition-a", 2}, 11}} =
             Debounce.transition(timeout_first, {:put, 6, "new"})

    assert fields(after_put) ==
             {~c"partition-a", 5, 2, {:some, {:DebouncePending, ~c"new", 2, 11}}, {:some, 6}}
  end

  test "epoch and quiet interval accept both endpoints and reject values outside their bounds" do
    for epoch <- ["e", String.duplicate("e", 160)], quiet_ms <- [1, 86_400_000] do
      assert {:ok, _state} = Debounce.new(epoch, quiet_ms)
    end

    for epoch <- ["", String.duplicate("e", 161), <<0>>, <<255>>, nil, ~c"epoch"] do
      assert Debounce.new(epoch, 1) == {:error, :invalid_epoch}
    end

    for quiet_ms <- [0, -1, 86_400_001, 1.0, nil, "1"] do
      assert Debounce.new("e", quiet_ms) == {:error, :invalid_quiet_ms}
    end
  end

  test "time endpoints, deadline arithmetic overflow and nondecreasing samples are enforced" do
    {:ok, empty} = Debounce.new("epoch", 10)

    assert {:ok, _at_zero, {:schedule, {"epoch", 1}, 10}} =
             Debounce.transition(empty, {:put, 0, "zero"})

    assert {:ok, at_max_sample, :ignored} =
             Debounce.transition(empty, {:timeout, @maximum, {"other", 1}})

    assert fields(at_max_sample) == {~c"epoch", 10, 0, :none, {:some, @maximum}}

    for now <- [-1, @maximum + 1, 1.0] do
      assert_refusal(empty, {:put, now, "value"}, :invalid_now)
      assert_refusal(empty, {:timeout, now, {"epoch", 1}}, :invalid_now)
    end

    {:ok, near_deadline} = Debounce.new("epoch", 10)

    assert {:ok, boundary, {:schedule, {"epoch", 1}, @maximum}} =
             Debounce.transition(near_deadline, {:put, @maximum - 10, "boundary"})

    assert_refusal(boundary, {:put, @maximum - 9, "overflow"}, :deadline_overflow)
    {:ok, at_one, _} = Debounce.transition(empty, {:put, 1, "one"})
    assert_refusal(at_one, {:put, 0, "regression"}, :time_regression)
    assert_refusal(at_max_sample, {:timeout, @maximum - 1, {"epoch", 1}}, :time_regression)
  end

  test "value byte limits include empty and arbitrary binary values" do
    {:ok, empty} = Debounce.new("epoch", 1)

    assert {:ok, empty_pending, {:schedule, {"epoch", 1}, 1}} =
             Debounce.transition(empty, {:put, 0, <<>>})

    assert {:ok, empty_emitted, {:emit, <<>>}} =
             Debounce.transition(empty_pending, {:timeout, 1, {"epoch", 1}})

    assert fields(empty_emitted) == {~c"epoch", 1, 1, :none, {:some, 1}}

    {:ok, empty} = Debounce.new("epoch", 1)
    binary = <<255, 0>>

    assert {:ok, pending, {:schedule, {"epoch", 1}, 1}} =
             Debounce.transition(empty, {:put, 0, binary})

    assert {:ok, emitted, {:emit, ^binary}} =
             Debounce.transition(pending, {:timeout, 1, {"epoch", 1}})

    assert fields(emitted) == {~c"epoch", 1, 1, :none, {:some, 1}}

    {:ok, empty_again} = Debounce.new("epoch", 1)

    assert {:ok, max_value, {:schedule, {"epoch", 1}, 1}} =
             Debounce.transition(empty_again, {:put, 0, :binary.copy(<<1>>, @max_value_bytes)})

    assert_refusal(
      empty_again,
      {:put, 0, :binary.copy(<<1>>, @max_value_bytes + 1)},
      :invalid_value
    )

    assert_refusal(empty_again, {:put, 0, :not_binary}, :invalid_value)
    assert {:DebounceState, _, _, _, {:some, {:DebouncePending, value, _, _}}, _} = max_value
    assert length(value) == @max_value_bytes
  end

  test "malformed state, command, time and token rejections return the exact original state" do
    {:ok, state} = Debounce.new("epoch", 5)
    valid_pending = {:DebouncePending, ~c"v", 1, 6}

    invalid_states = [
      nil,
      {},
      {:DebounceState, [], 5, 0, :none, :none},
      {:DebounceState, [101 | :improper], 5, 0, :none, :none},
      {:DebounceState, [256], 5, 0, :none, :none},
      {:DebounceState, [255], 5, 0, :none, :none},
      {:DebounceState, ~c"e" ++ [0], 5, 0, :none, :none},
      {:DebounceState, ~c"e", 0, 0, :none, :none},
      {:DebounceState, ~c"e", 5, -1, :none, :none},
      {:DebounceState, ~c"e", 5, @maximum + 1, :none, :none},
      {:DebounceState, ~c"e", 5, 1, {:some, valid_pending}, :none},
      {:DebounceState, ~c"e", 5, 2, {:some, valid_pending}, {:some, 1}},
      {:DebounceState, ~c"e", 5, 1, {:some, {:DebouncePending, [118 | :bad], 1, 6}}, {:some, 1}},
      {:DebounceState, ~c"e", 5, 1, {:some, {:DebouncePending, [], 1, @maximum + 1}}, {:some, 1}},
      {:DebounceState, ~c"e", 5, 1, :bad, {:some, 1}},
      {:DebounceState, ~c"e", 5, 0, :none, {:some, -1}},
      {:DebounceState, ~c"e", 5, 0, :none, :bad}
    ]

    for invalid <- invalid_states do
      assert {:error, :invalid_state, ^invalid} = Debounce.transition(invalid, :clear)
    end

    for command <- [:unknown, {:put, 0}, {:timeout, 0}, {:put, 0, "v", :extra}] do
      assert_refusal(state, command, :invalid_command)
    end

    for token <- [
          :bad,
          {"epoch"},
          {"", 1},
          {<<0>>, 1},
          {<<255>>, 1},
          {String.duplicate("e", 161), 1},
          {"epoch", 0},
          {"epoch", @maximum + 1}
        ] do
      assert_refusal(state, {:timeout, 0, token}, :invalid_token)
    end

    assert_refusal(state, {:put, 0, :bad}, :invalid_value)
  end

  test "generation maximum is reachable, clear works at maximum, and only an increment beyond it refuses" do
    {:ok, initial} = Debounce.new("epoch", 1)
    {:DebounceState, epoch, quiet_ms, 0, :none, :none} = initial
    seeded = {:DebounceState, epoch, quiet_ms, @maximum - 1, :none, {:some, 4}}

    assert {:ok, at_max, {:schedule, {"epoch", @maximum}, 5}} =
             Debounce.transition(seeded, {:put, 4, "last generation"})

    assert fields(at_max) ==
             {~c"epoch", 1, @maximum, {:some, {:DebouncePending, ~c"last generation", @maximum, 5}},
              {:some, 4}}

    assert {:ok, emitted, {:emit, "last generation"}} =
             Debounce.transition(at_max, {:timeout, 5, {"epoch", @maximum}})

    assert fields(emitted) == {~c"epoch", 1, @maximum, :none, {:some, 5}}

    assert {:ok, cleared, {:cancel, {"epoch", @maximum}}} = Debounce.transition(at_max, :clear)
    assert fields(cleared) == {~c"epoch", 1, @maximum, :none, {:some, 4}}
    assert_refusal(cleared, {:put, 4, "exhausted"}, :generation_exhausted)
  end

  test "selected Cure laws compile with a clean audit" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
    for law <- @laws, do: assert(@source =~ "fn #{law}(")
    IO.puts("selected debounce Cure laws compiled: #{length(@laws)}")
  end
end
