# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RuntimeTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @cure_roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @core_source File.read!(Path.join(@root, "cure/elzoo/core.cure"))
  @composition_source Enum.find_value(@cure_roots, fn root ->
                        file = Path.join(root, "elzoo/composition.cure")
                        if File.regular?(file), do: File.read!(file)
                      end)
  @receiver_source Enum.find_value(@cure_roots, fn root ->
                     file = Path.join(root, "elzoo/idempotency.cure")
                     if File.regular?(file), do: File.read!(file)
                   end)

  test "the production Cure source is compiled to the app ebin" do
    beam = Path.join(Mix.Project.compile_path(), "Cure.Elzoo.Core.beam")
    assert File.regular?(beam), "missing production Cure artifact #{beam}"
    assert {:module, :"Cure.Elzoo.Core"} = Code.ensure_loaded(:"Cure.Elzoo.Core")
  end

  test "the same pure transition works fused and behind OTP" do
    messages = [
      Elzoo.Runtime.message(1, 1, 4, 10),
      Elzoo.Runtime.message(1, 1, 4, 999),
      Elzoo.Runtime.message(1, 1, 2, 3),
      Elzoo.Runtime.message(2, 1, 4, 7),
      Elzoo.Runtime.message(1, 2, 4, 5),
      Elzoo.Runtime.message(1, 1, 4, 10)
    ]

    {fused_outputs, fused_state} = Elzoo.Runtime.fused(messages)
    {hopped_outputs, {history, total}} = Elzoo.Runtime.hopped(messages)

    assert fused_outputs == [{:some, 10}, :none, {:some, 13}, {:some, 20}, {:some, 25}, :none]
    assert hopped_outputs == fused_outputs
    assert Elzoo.Runtime.joined(fused_state) |> elem(1) == total
    assert length(history) == 4
  end

  test "fused and hopped traces agree with an independent set-and-sum model" do
    :rand.seed(:exsss, {17, 29, 43})

    traces =
      for _ <- 1..20 do
        for _ <- 1..30 do
          Elzoo.Runtime.message(
            :rand.uniform(3),
            :rand.uniform(2),
            :rand.uniform(8),
            :rand.uniform(101) - 51
          )
        end
      end

    for messages <- [[] | traces] do
      {expected, {keys, total}} = reference(messages)
      {fused, fused_state} = Elzoo.Runtime.fused(messages)
      {hopped, {history, hopped_total}} = Elzoo.Runtime.hopped(messages)

      assert fused == expected
      assert hopped == expected
      assert hopped_total == total
      assert Elzoo.Runtime.joined(fused_state) |> elem(1) == total
      assert length(history) == MapSet.size(keys)

      assert history
             |> Enum.map(&Elzoo.Runtime.message_fields/1)
             |> Enum.map(&key/1)
             |> MapSet.new() == keys
    end
  end

  test "nested composition and a separately compiled consumer share the interface" do
    messages = [
      Elzoo.Runtime.message(1, 1, 0, 4),
      Elzoo.Runtime.message(1, 1, 0, 999),
      Elzoo.Runtime.message(1, 1, 1, 6),
      Elzoo.Runtime.message(1, 1, 2, -3)
    ]

    {nested_outputs, nested_state} = Elzoo.Runtime.nested(messages, 10)
    {consumer_outputs, consumer_state} = Elzoo.Runtime.consumer_nested(messages, 10)

    assert nested_outputs == [{:some, false}, :none, {:some, true}, {:some, false}]
    assert consumer_outputs == nested_outputs
    assert consumer_state == nested_state

    assert Elzoo.Runtime.message_fields(apply(:"Cure.Elzoo.Consumer", :demo_seed, [])) ==
             {0, 0, 0, 0}
  end

  test "OTP supervision makes volatile restart behavior explicit" do
    core = :"Cure.Elzoo.Core"

    child = %{
      id: :unit,
      start: {Elzoo.Unit, :start_link, [{core, :assembly, apply(core, :empty, [])}]}
    }

    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)

    try do
      [{:unit, pid, _, _}] = Supervisor.which_children(supervisor)
      message = Elzoo.Runtime.message(1, 1, 1, 10)
      assert Elzoo.Unit.step(pid, message) == {:some, 10}
      assert Elzoo.Unit.step(pid, message) == :none
      :ok = Supervisor.terminate_child(supervisor, :unit)
      {:ok, replacement} = Supervisor.restart_child(supervisor, :unit)
      assert replacement != pid
      assert Elzoo.Unit.step(replacement, message) == {:some, 10}
    after
      Supervisor.stop(supervisor)
    end
  end

  test "selected pure modules audit without hidden assumptions" do
    for source <- [
          @core_source,
          @composition_source,
          @receiver_source
        ] do
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: @cure_roots)
      report = Cure.Audit.Ledger.audit_env(env)
      assert report.unaudited == []
      assert report.unresolved == []
      assert report.holes == []
      assert report.axioms == []
      assert report.not_proven_total == []
      assert report.absurd == 0
    end
  end

  test "false proof, incompatible typed connection, and unfinished proof are rejected" do
    wrong_proof =
      @receiver_source
      |> String.replace("mod Elzoo.Idempotency", "mod Elzoo.WrongDuplicate")
      |> String.replace("True() -> None()", "True() -> Some(input)")

    assert wrong_proof != @receiver_source

    assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
             Cure.Compiler.compile_and_load(wrong_proof, source_roots: cure_source_roots())

    wrong_port =
      @core_source
      |> String.replace("mod Elzoo.Core", "mod Elzoo.WrongPort")
      |> String.replace(
        "input: Elzoo.Idempotency.Message) -> Transition(Int, Int)",
        "input: String) -> Transition(Int, Int)"
      )
      |> String.replace("total + input.value", "total")

    assert wrong_port != @core_source

    assert {:error,
            {:codegen_error, {:source_context, {:index_mismatch, {:cannot_unify, _, _}}, _}}} =
             Cure.Compiler.compile_and_load(wrong_port, source_roots: cure_source_roots())

    unfinished =
      @receiver_source
      |> String.replace("mod Elzoo.Idempotency", "mod Elzoo.Unfinished")
      |> String.replace("reflexive(emit(True(), input))", "?unfinished")

    assert {:error, {:codegen_error, {:unfilled_hole, info}}} =
             Cure.Compiler.compile_and_load(unfinished, source_roots: cure_source_roots())

    assert info.definition == :"Elzoo.Unfinished#duplicate_emits_nothing"
  end

  defp reference(messages) do
    Enum.map_reduce(messages, {MapSet.new(), 0}, fn message, {seen, total} ->
      fields = Elzoo.Runtime.message_fields(message)
      message_key = key(fields)

      if MapSet.member?(seen, message_key) do
        {:none, {seen, total}}
      else
        next = total + elem(fields, 3)
        {{:some, next}, {MapSet.put(seen, message_key), next}}
      end
    end)
  end

  defp key({sender, incarnation, sequence, _value}), do: {sender, incarnation, sequence}

  defp cure_source_roots do
    @cure_roots
  end
end
