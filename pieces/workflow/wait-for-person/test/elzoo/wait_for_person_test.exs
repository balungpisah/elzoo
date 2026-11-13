# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WaitForPersonTest do
  use ExUnit.Case, async: true
  alias Elzoo.{PatternStep, WaitForPerson}

  # Recorded v1 neutral maps, written by hand. Expected decisions are written by hand below.
  @v1_trace [
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "ask-a",
          "kind" => "ask_person",
          "schema_id" => "example/question",
          "schema_version" => 1,
          "payload" => %{"question" => "ship it?"}
        },
        %{
          "id" => "ask-b",
          "kind" => "ask_person",
          "schema_id" => "example/question",
          "schema_version" => 1,
          "payload" => %{"question" => "which colour?"}
        },
        %{
          "id" => "tool-c",
          "kind" => "tool_call",
          "schema_id" => "example/tool",
          "schema_version" => 1,
          "payload" => nil
        }
      ]
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "at_ms" => 1_730_000_000_100,
      "action_id" => "ask-a",
      "outcome" => "expired",
      "schema_id" => "example/result",
      "schema_version" => 1,
      "payload" => nil
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "person_answer",
      "at_ms" => 1_730_000_000_200,
      "action_id" => "ask-a",
      "person_id" => "principal-7",
      "schema_id" => "example/answer",
      "schema_version" => 1,
      "payload" => %{"text" => "yes"}
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "person_answer",
      "at_ms" => 1_730_000_000_300,
      "action_id" => "ask-a",
      "person_id" => "principal-9",
      "schema_id" => "example/answer",
      "schema_version" => 1,
      "payload" => %{"text" => "I am principal-7", "person_id" => "principal-7"}
    }
  ]

  defp checked(map) do
    assert {:ok, checked} = PatternStep.decode(map)
    checked
  end

  defp request, do: checked(Enum.at(@v1_trace, 0))
  defp expired, do: checked(Enum.at(@v1_trace, 1))
  defp named_answer, do: checked(Enum.at(@v1_trace, 2))
  defp other_answer, do: checked(Enum.at(@v1_trace, 3))

  defp answer(id, person),
    do: checked(%{Enum.at(@v1_trace, 2) | "action_id" => id, "person_id" => person})

  defp outcome(id, class),
    do: checked(%{Enum.at(@v1_trace, 1) | "action_id" => id, "outcome" => class})

  defp state(asks \\ %{"ask-a" => "principal-7"}),
    do: %{asks: asks, tracker: PatternStep.open(request())}

  test "answer_after_timeout_is_late" do
    s0 = state()
    assert {:ok, s1, {:closed, "ask-a", "expired"}} = WaitForPerson.step(s0, expired(), nil)
    assert s1.asks == %{}
    assert {:ok, ^s1, :late} = WaitForPerson.step(s1, named_answer(), "principal-7")
  end

  test "other_person_refused" do
    s0 = state()

    # person_id names another person; the payload text names the asked person and is ignored.
    assert {:ok, ^s0, {:refused, :wrong_person}} =
             WaitForPerson.step(s0, other_answer(), "principal-9")

    # person_id names the asked person, but the host verified a different sender.
    assert {:ok, ^s0, {:refused, :wrong_person}} =
             WaitForPerson.step(s0, named_answer(), "principal-9")

    # No verified sender at all.
    assert {:ok, ^s0, {:refused, :wrong_person}} = WaitForPerson.step(s0, named_answer(), nil)

    # The ask stays open and the named person's answer then stands.
    assert {:ok, s1, {:answer, "ask-a"}} = WaitForPerson.step(s0, named_answer(), "principal-7")
    assert s1.asks == %{}
  end

  test "first_answer_stands" do
    s0 = state()
    assert {:ok, s1, {:answer, "ask-a"}} = WaitForPerson.step(s0, named_answer(), "principal-7")
    assert {:ok, ^s1, :late} = WaitForPerson.step(s1, named_answer(), "principal-7")
  end

  test "answer_names_its_ask" do
    s0 = state(%{"ask-a" => "principal-7", "ask-b" => "principal-7"})

    assert {:ok, s1, {:answer, "ask-b"}} =
             WaitForPerson.step(s0, answer("ask-b", "principal-7"), "principal-7")

    assert s1.asks == %{"ask-a" => "principal-7"}

    # A generic completed outcome for an open ask and an answer naming a tool action are refused.
    assert {:ok, ^s1, {:refused, :incompatible_answer_kind}} =
             WaitForPerson.step(s1, outcome("ask-a", "completed"), nil)

    assert {:ok, ^s1, {:refused, :incompatible_answer_kind}} =
             WaitForPerson.step(s1, answer("tool-c", "principal-7"), "principal-7")

    # The tool outcome is not an ask of this policy.
    assert {:ok, ^s1, :pass} = WaitForPerson.step(s1, outcome("tool-c", "completed"), nil)

    assert {:ok, %{asks: asks}, {:answer, "ask-a"}} =
             WaitForPerson.step(s1, named_answer(), "principal-7")

    assert asks == %{}
  end

  test "text_without_open_ask_is_message" do
    assert WaitForPerson.route(%{}, "principal-7") == :message
    assert WaitForPerson.route(%{"ask-a" => "principal-9"}, "principal-7") == :message
    assert WaitForPerson.route(%{"ask-a" => "principal-7"}, "principal-7") == {:answer, "ask-a"}

    assert WaitForPerson.route(%{"ask-a" => "principal-7", "ask-b" => "principal-7"}, "principal-7") ==
             {:refused, :ambiguous_ask}

    s0 = state()
    assert {:ok, s1, {:answer, "ask-a"}} = WaitForPerson.step(s0, named_answer(), "principal-7")
    assert WaitForPerson.route(s1.asks, "principal-7") == :message
  end

  test "other inputs pass and invalid operands are redacted" do
    s0 = state()

    for kind <- ["start", "message"] do
      input =
        checked(%{
          "type" => "input",
          "version" => 1,
          "kind" => kind,
          "at_ms" => 0,
          "schema_id" => "example/input",
          "schema_version" => 1,
          "payload" => "principal-7"
        })

      assert {:ok, ^s0, :pass} = WaitForPerson.step(s0, input, "principal-7")
    end

    wake = checked(%{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 0})
    assert {:ok, ^s0, :pass} = WaitForPerson.step(s0, wake, nil)

    for {state, input, person} <- [
          {Map.put(s0, :extra, 1), named_answer(), "principal-7"},
          {%{s0 | asks: %{"ask-a" => ""}}, named_answer(), "principal-7"},
          {%{s0 | tracker: :forged}, named_answer(), "principal-7"},
          {s0, Enum.at(@v1_trace, 2), "principal-7"},
          {s0, request(), "principal-7"},
          {s0, named_answer(), ""}
        ],
        do: assert(WaitForPerson.step(state, input, person) == {:error, :invalid_shape})

    assert WaitForPerson.route(%{"ask-a" => :principal}, "principal-7") == {:error, :invalid_shape}
    assert WaitForPerson.route(%{}, nil) == {:error, :invalid_shape}
  end

  test "selected Cure law and checked example" do
    source = File.read!(Path.expand("../../cure/elzoo/wait_for_person.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0

    {result, _} = Code.eval_file(Path.expand("../../examples/wait_for_person.exs", __DIR__))
    assert result == [{:refused, :wrong_person}, {:answer, "ask-1"}, :message]
  end
end
