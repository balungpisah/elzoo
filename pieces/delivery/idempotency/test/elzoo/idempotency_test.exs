# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.IdempotencyTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/idempotency.cure", __DIR__))
  @cure_roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @receiver :"Cure.Elzoo.Idempotency"

  test "exact-key duplicates drop, but a new incarnation is fresh" do
    first = apply(@receiver, :message, [1, 1, 9, 7])
    duplicate = apply(@receiver, :message, [1, 1, 9, 999])
    restarted = apply(@receiver, :message, [1, 2, 9, 7])
    assert {:Transition, history, {:some, ^first}} = apply(@receiver, :receiver, [[], first])
    assert {:Transition, ^history, :none} = apply(@receiver, :receiver, [history, duplicate])

    assert {:Transition, next, {:some, ^restarted}} =
             apply(@receiver, :receiver, [history, restarted])

    assert length(next) == 2
  end

  test "owned Cure source audit has no hidden proof assumptions" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @cure_roots)
    report = Cure.Audit.Ledger.audit_env(env)
    assert report.unaudited == []
    assert report.unresolved == []
    assert report.holes == []
    assert report.axioms == []
    assert report.not_proven_total == []
    assert report.absurd == 0
  end

  test "false emit proof and unfinished proof are rejected" do
    wrong =
      @source
      |> String.replace("mod Elzoo.Idempotency", "mod Elzoo.WrongDuplicate")
      |> String.replace("True() -> None()", "True() -> Some(input)")

    assert wrong != @source

    assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
             Cure.Compiler.compile_and_load(wrong, source_roots: @cure_roots)

    unfinished =
      @source
      |> String.replace("mod Elzoo.Idempotency", "mod Elzoo.Unfinished")
      |> String.replace("reflexive(emit(True(), input))", "?unfinished")

    assert {:error, {:codegen_error, {:unfilled_hole, info}}} =
             Cure.Compiler.compile_and_load(unfinished, source_roots: @cure_roots)

    assert info.definition == :"Elzoo.Unfinished#duplicate_emits_nothing"
  end
end
