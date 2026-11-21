# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/eval_helper.exs", __DIR__)

artifact_helper = Path.expand("../support/artifact_test_helper.exs", __DIR__)

artifact_helper =
  if File.regular?(artifact_helper),
    do: artifact_helper,
    else:
      Path.expand(
        "../../../../state/artifact/test/support/artifact_test_helper.exs",
        __DIR__
      )

Code.require_file(artifact_helper)

defmodule Elzoo.EvalTest do
  @moduledoc """
  `workflow/eval` scenarios: datasets read from the Memory Store and the fake object store of
  the `state/artifact` test helper (no live object store), run through `runtime/recipe-test`
  on disposable PostgreSQL. Finite named scenarios, not proofs.
  """
  use ExUnit.Case, async: false
  import Kernel, except: [node: 3]

  alias Elzoo.{Artifact, Eval}
  alias Elzoo.Artifact.TestHelper, as: H
  alias Elzoo.RecipeTest.{ModelBinding, ScriptedAdapter, ToolBinding}

  setup_all do
    pid = Elzoo.RunEngine.TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)
    on_exit(fn -> for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p) end)
    :ok
  end

  ## Recipe packages and base specs: literals, as in runtime/recipe-test

  defp typed(direction) do
    %{
      "port" => %{
        "id" => direction,
        "direction" => direction,
        "schema_id" => "value",
        "schema_version" => 1
      },
      "schema" => %{"type" => "object"}
    }
  end

  defp callable(name, kind, extra),
    do:
      Map.merge(
        %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")},
        extra
      )

  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp node(id, kind, needs, gives, extra),
    do:
      Map.merge(
        %{
          "id" => id,
          "kind" => kind,
          "needs" => Enum.map(needs, &slot/1),
          "gives" => Enum.map(gives, &slot/1)
        },
        extra
      )

  defp data(from, give, to, need),
    do: %{"from" => from, "to" => to, "kind" => "data", "give" => give, "need" => need}

  defp choice(from, to, name),
    do: %{"from" => from, "to" => to, "kind" => "choice", "choice" => name}

  defp canonical(value), do: Jason.encode!(ordered(value))

  defp ordered(value) when is_map(value),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(value), do: {k, ordered(v)})}

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp package(graph) do
    package = %{
      "format_version" => 1,
      "name" => "package",
      "version" => "opaque",
      "needs" => [],
      "permissions" => [],
      "graph" => graph,
      "settings" => %{
        "version" => 1,
        "id" => "independent-settings",
        "revision" => 1,
        "port" => typed("input")["port"],
        "secrets" => [],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      "skills" => []
    }

    hash = :crypto.hash(:sha256, canonical(package))
    Map.put(package, "identity", "recipe-package-v1:sha256:" <> Base.encode16(hash, case: :lower))
  end

  defp recipe(callables),
    do: %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => hd(callables)["name"],
      "callables" => callables,
      "bindings" => [
        %{"name" => "worker", "target" => "agent-config"},
        %{"name" => "judge", "target" => "decision-config"}
      ],
      "rules" => []
    }

  defp tool(name),
    do: %{
      "trust" => "untrusted",
      "name" => name,
      "description" => "Tool " <> name,
      "input_schema" => %{"type" => "object"},
      "annotations" => nil
    }

  defp files(names),
    do: %{
      "id" => "files",
      "kind" => "other",
      "callable" => "adapter",
      "tools" => Enum.map(names, &tool/1)
    }

  defp facts(costs),
    do: %{
      "provided_needs" => [],
      "granted_permissions" => [],
      "tool_requirements" => %{},
      "unit" => "credits",
      "costs" => costs,
      "cap" => 1_000
    }

  defp cost(callable, estimate), do: %{"callable" => callable, "estimate" => estimate}

  defp cost(callable, node, estimate),
    do: %{"callable" => callable, "node" => node, "estimate" => estimate}

  defp agent_config,
    do: %{
      model: "scripted-model",
      max_output_tokens: 256,
      role_instructions: ["Answer."],
      window: %{
        provider_id: "scripted",
        model_id: "scripted-model",
        size: 100_000,
        unit: :tokens,
        estimator_id: "recipe-test-bytes",
        estimator_version: 1
      },
      max_request_bytes: 65_536,
      max_image_refs: 0,
      result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
      turn_limit: 4
    }

  defp decision_config,
    do: %{
      request: %{
        "version" => 1,
        "model" => "scripted-decider",
        "max_output_tokens" => 32,
        "messages" => [%{"role" => "user", "text" => "Pick one."}]
      },
      repairs: 1
    }

  # Every recipe-test spec key but the three that a case gives: input, script, restart_after.
  defp base_spec(package, facts, sources),
    do: %{
      package: package,
      facts: facts,
      sources: sources,
      agents: %{"agent-config" => agent_config()},
      decisions: %{"decision-config" => decision_config()},
      effects: %{model: ModelBinding, tool: ToolBinding},
      adapters: [ScriptedAdapter],
      tools: %{},
      executable: nil,
      skills: nil,
      gate: nil
    }

  defp agent_base do
    graph = recipe([callable("main", "agent", %{"binding" => "worker"})])
    base_spec(package(graph), facts([cost("main", 5)]), [files(~w(read write))])
  end

  # A graph root: an agent child, a decision child and one tool node for each choice.
  # `swap: true` is the changed package: each choice leads to the node of the other one.
  defp graph_base(options \\ []) do
    {yes, no} =
      if Keyword.get(options, :swap, false), do: {"t_no", "t_yes"}, else: {"t_yes", "t_no"}

    main =
      callable("main", "graph", %{
        "nodes" => [
          node("a", "call", ["x"], ["text"], %{"callable" => "agent"}),
          node("d", "decision", ["text"], ["value"], %{"callable" => "choice"}),
          node("t_yes", "tool", [], ["yes_result"], %{"tool" => "files_read"}),
          node("t_no", "tool", [], ["no_result"], %{"tool" => "files_read"})
        ],
        "links" => [
          data("$input", "x", "a", "x"),
          data("a", "text", "d", "text"),
          choice("d", yes, "yes"),
          choice("d", no, "no")
        ],
        "input_slots" => [slot("x")]
      })

    graph =
      recipe([
        main,
        callable("agent", "agent", %{"binding" => "worker"}),
        callable("choice", "decision", %{"binding" => "judge", "choices" => ["yes", "no"]})
      ])

    costs = [cost("agent", 5), cost("choice", 3), cost("main", "t_yes", 2), cost("main", "t_no", 2)]
    base_spec(package(graph), facts(costs), [files(["read"])])
  end

  ## Dataset documents: JSON text, as an author writes it

  defp dataset(id, cases),
    do:
      Jason.encode!(%{"format_version" => 1, "dataset_id" => id, "version" => 3, "cases" => cases})

  defp ds_case(id, input, script, checks),
    do: %{
      "case_id" => id,
      "input" => input,
      "script" => script,
      "restart_after" => nil,
      "checks" => checks
    }

  defp model(name, results), do: %{"key" => %{"model" => name}, "results" => results}
  defp tool_key(name, results), do: %{"key" => %{"tool" => name}, "results" => results}
  defp completed(value), do: %{"class" => "completed", "value" => value}
  defp answer(text), do: completed(%{"content" => text, "finish" => "stop", "tool_proposals" => []})

  defp calls(names),
    do:
      completed(%{
        "content" => "",
        "finish" => "tool_calls",
        "tool_proposals" =>
          for(
            {name, i} <- Enum.with_index(names, 1),
            do: %{"id" => "c#{i}", "name" => name, "arguments" => %{}, "malformed" => nil}
          )
      })

  defp decided(member),
    do:
      completed(%{
        "content" => Jason.encode!(%{"answer" => member}),
        "finish" => "stop",
        "tool_proposals" => [],
        "structured" => %{"valid" => %{"answer" => member}}
      })

  defp outcome_is(outcome), do: %{"kind" => "outcome_is", "outcome" => outcome}
  defp equals(text), do: %{"kind" => "final_text_equals", "text" => text}
  defp contains(text), do: %{"kind" => "final_text_contains", "text" => text}
  defp matches(schema), do: %{"kind" => "structured_matches", "schema" => schema}
  defp called(name, n), do: %{"kind" => "tool_called", "alias" => name, "at_least" => n}
  defp not_called(name), do: %{"kind" => "tool_not_called", "alias" => name}
  defp max_steps(n), do: %{"kind" => "max_steps", "steps" => n}

  # Actions: d1:m:1, d1:t:1:1, d1:m:2, d1:finish.
  defp reads_script,
    do: [
      model("scripted-model", [calls(["files_read"]), answer("Done: contents")]),
      tool_key("files_read", [completed("contents")])
    ]

  defp answered_turns(n),
    do: %{
      "type" => "object",
      "required" => ["status", "turns"],
      "properties" => %{"status" => %{"const" => "answered"}, "turns" => %{"const" => n}}
    }

  defp agent_cases,
    do: [
      ds_case("reads-then-answers", "Read it.", reads_script(), [
        outcome_is("completed"),
        equals("Done: contents"),
        contains("contents"),
        matches(answered_turns(2)),
        called("files_read", 1),
        not_called("files_write"),
        max_steps(4)
      ]),
      ds_case("answers-directly", "Hello.", [model("scripted-model", [answer("Hi.")])], [
        outcome_is("completed"),
        equals("Hi."),
        not_called("files_read"),
        max_steps(2)
      ]),
      ds_case(
        "write-fails",
        "Write it.",
        [
          model("scripted-model", [calls(["files_write"]), answer("Could not write.")]),
          tool_key("files_write", [%{"class" => "failed", "reason" => "broken"}])
        ],
        [called("files_write", 1), contains("not write"), not_called("files_read")]
      )
    ]

  defp gives(name),
    do: %{
      "type" => "object",
      "required" => ["status", "gives"],
      "properties" => %{
        "status" => %{"const" => "completed"},
        "gives" => %{"type" => "object", "required" => [name]}
      }
    }

  defp graph_script(text, member),
    do: [
      model("scripted-model", [answer(text)]),
      model("scripted-decider", [decided(member)]),
      tool_key("files_read", [completed(%{"yes_result" => "r", "no_result" => "r"})])
    ]

  defp graph_cases,
    do: [
      ds_case("chooses-yes", %{"x" => "hi"}, graph_script("hello", "yes"), [
        outcome_is("completed"),
        matches(gives("yes_result")),
        called("files_read", 1)
      ]),
      ds_case("chooses-no", %{"x" => "hi"}, graph_script("hello", "no"), [
        outcome_is("completed"),
        matches(gives("no_result"))
      ]),
      ds_case("other-input", %{"x" => "bye"}, graph_script("goodbye", "yes"), [
        matches(gives("yes_result")),
        max_steps(16)
      ])
    ]

  ## Artifact fixtures

  defp artifact do
    {object_store, fake} = H.fake_s3()
    %{art: art} = H.memory(object_store: object_store, max_bytes: 1_048_576)
    %{art: art, object_store: object_store, fake: fake, caller: H.caller("tenant-eval")}
  end

  defp stored(fx, artifact_id, bytes) do
    {:ok, rec} = Artifact.put(fx.art, fx.caller, artifact_id, H.input(bytes))
    rec
  end

  defp loaded(bytes) do
    fx = artifact()
    stored(fx, "dataset", bytes)
    assert {:ok, dataset} = Eval.load(fx.art, fx.caller, "dataset", :head)
    dataset
  end

  defp statuses(report), do: for(c <- report.cases, do: {c.case_id, c.status})

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  ## Acceptance 1

  describe "passing_dataset" do
    test "an agent dataset and a graph dataset loaded from an artifact pass every case" do
      agent_bytes = dataset("agent-cases", agent_cases())
      agent = Eval.run(loaded(agent_bytes), agent_base())

      assert agent.dataset == %{dataset_id: "agent-cases", version: 3, sha256: sha256(agent_bytes)}
      assert agent.package == agent_base().package["identity"]
      assert {agent.passed, agent.failed, agent.errored} == {3, 0, 0}

      assert statuses(agent) == [
               {"reads-then-answers", :passed},
               {"answers-directly", :passed},
               {"write-fails", :passed}
             ]

      [first | _] = agent.cases
      assert first.error == nil

      assert Enum.map(first.checks, & &1.kind) == [
               :outcome_is,
               :final_text_equals,
               :final_text_contains,
               :structured_matches,
               :tool_called,
               :tool_not_called,
               :max_steps
             ]

      assert Enum.all?(first.checks, &(&1.status == :passed and &1.reason == nil))

      graph = Eval.run(loaded(dataset("graph-cases", graph_cases())), graph_base())
      assert {graph.passed, graph.failed, graph.errored} == {3, 0, 0}
      assert Enum.all?(graph.cases, &(&1.status == :passed))
    end
  end

  ## Acceptance 2

  describe "failing_checks" do
    test "one failing case per check kind gives its fixed reason" do
      direct = [model("scripted-model", [answer("Hi.")])]
      # A failed model call stops the agent; the record's outcome is not :completed.
      stopped = [model("scripted-model", [%{"class" => "failed", "reason" => "broken"}])]

      cases = [
        ds_case("outcome", "Hello.", direct, [outcome_is("failed")]),
        ds_case("equals", "Hello.", direct, [equals("Hi")]),
        ds_case("contains", "Hello.", direct, [contains("hi.")]),
        ds_case("schema", "Read it.", reads_script(), [matches(answered_turns(1))]),
        ds_case("count", "Read it.", reads_script(), [called("files_read", 2)]),
        ds_case("called", "Read it.", reads_script(), [not_called("files_read")]),
        ds_case("steps", "Read it.", reads_script(), [max_steps(3)]),
        ds_case("stopped", "Hello.", stopped, [outcome_is("completed"), equals("Hi.")])
      ]

      report = Eval.run(loaded(dataset("failing", cases)), agent_base())
      assert {report.passed, report.failed, report.errored} == {0, 8, 0}

      reasons = for c <- report.cases, do: {c.case_id, Enum.map(c.checks, & &1.reason)}

      assert reasons == [
               {"outcome", [:outcome]},
               {"equals", [:text]},
               {"contains", [:text]},
               {"schema", [:schema]},
               {"count", [:tool_count]},
               {"called", [:tool_called]},
               {"steps", [:steps]},
               {"stopped", [:outcome, :no_root_finish]}
             ]
    end

    test "a graph root has no final text; one failing check fails the case" do
      cases = [
        ds_case("graph-text", %{"x" => "hi"}, graph_script("hello", "yes"), [
          outcome_is("completed"),
          equals("hello"),
          contains("hello")
        ])
      ]

      report = Eval.run(loaded(dataset("graph-text", cases)), graph_base())
      assert [%{status: :failed, checks: checks}] = report.cases

      assert Enum.map(checks, &{&1.status, &1.reason}) == [
               {:passed, nil},
               {:failed, :no_final_text},
               {:failed, :no_final_text}
             ]
    end

    test "a record that is not completed has no root finish" do
      {:ok, dataset} =
        Eval.decode(
          dataset("pure", [
            ds_case("c", "x", [], [
              equals("a"),
              matches(%{"type" => "object"}),
              outcome_is("failed"),
              max_steps(1)
            ])
          ])
        )

      [%{checks: checks}] = dataset.cases
      finish = %{"kind" => "finish", "payload" => %{"status" => "answered", "action_id" => "m"}}
      record = %{outcome: :failed, steps: [%{step: :action, occurrence: {0, 0}, action: finish}]}

      assert Eval.score(record, checks) == %{
               status: :failed,
               checks: [
                 %{kind: :final_text_equals, status: :failed, reason: :no_root_finish},
                 %{kind: :structured_matches, status: :failed, reason: :no_root_finish},
                 %{kind: :outcome_is, status: :passed, reason: nil},
                 %{kind: :max_steps, status: :passed, reason: nil}
               ]
             }
    end
  end

  ## Acceptance 3

  describe "malformed_dataset" do
    defp refused(bytes, path, reason),
      do: assert(Eval.decode(bytes) == {:error, {:dataset, path, reason}})

    defp one_case(fields \\ %{}),
      do: Map.merge(ds_case("c", "x", [], [outcome_is("completed")]), fields)

    test "a duplicate key in a nested object is refused at its path" do
      text =
        ~s({"format_version":1,"dataset_id":"d","version":1,"cases":[{"case_id":"c",) <>
          ~s("input":{"x":{"a":1,"a":2}},"script":[],"restart_after":null,) <>
          ~s("checks":[{"kind":"outcome_is","outcome":"completed"}]}]})

      refused(text, ["cases", 0, "input", "x", "a"], :duplicate_key)

      text =
        ~s({"format_version":1,"dataset_id":"d","version":1,"cases":[{"case_id":"c",) <>
          ~s("input":"x","script":[],"restart_after":null,) <>
          ~s("checks":[{"kind":"outcome_is","outcome":"completed","outcome":"failed"}]}]})

      refused(text, ["cases", 0, "checks", 0, "outcome"], :duplicate_key)

      # Before an unknown kind, a member is still read as JSON.
      text =
        ~s({"format_version":1,"dataset_id":"d","version":1,"cases":[{"case_id":"c",) <>
          ~s("input":"x","script":[],"restart_after":null,) <>
          ~s("checks":[{"schema":{"a":1,"a":2},"kind":"judge"}]}]})

      refused(text, ["cases", 0, "checks", 0, "schema", "a"], :duplicate_key)
    end

    test "an unknown check kind is refused" do
      cases = [one_case(%{"checks" => [%{"kind" => "judge"}]})]
      refused(dataset("d", cases), ["cases", 0, "checks", 0, "kind"], :unknown_kind)
    end

    test "257 cases are out of bounds; 256 are accepted" do
      many = for i <- 1..257, do: one_case(%{"case_id" => "c#{i}"})
      refused(dataset("d", many), ["cases"], :bounds)
      assert {:ok, %{cases: cases}} = Eval.decode(dataset("d", Enum.take(many, 256)))
      assert length(cases) == 256
    end

    test "a duplicate case_id is refused at the second case" do
      refused(dataset("d", [one_case(), one_case()]), ["cases", 1, "case_id"], :duplicate_case)
    end

    test "a results entry with a bad reason is refused" do
      script = [model("m", [answer("a"), %{"class" => "failed", "reason" => "Bad"}])]
      path = ["cases", 0, "script", 0, "results", 1, "reason"]
      refused(dataset("d", [one_case(%{"script" => script})]), path, :bounds)
    end

    test "a schema that PayloadSchema.build/2 refuses is schema" do
      checks = [matches(%{"$ref" => "https://example.com/schema"})]
      path = ["cases", 0, "checks", 0, "schema"]
      refused(dataset("d", [one_case(%{"checks" => checks})]), path, :schema)
    end

    test "other root faults: version, unknown key, size and JSON" do
      refused(~s({"format_version":2,"cases":7}), ["format_version"], :format_version)

      base = %{"format_version" => 1, "dataset_id" => "d", "version" => 1, "cases" => [one_case()]}
      refused(Jason.encode!(Map.put(base, "mode", "live")), ["mode"], :unknown_key)
      refused(Jason.encode!(Map.delete(base, "version")), ["version"], :missing_key)
      refused(Jason.encode!(%{base | "dataset_id" => "a\u0085b"}), ["dataset_id"], :bounds)

      refused(
        Jason.encode!(%{
          base
          | "cases" => [one_case(%{"script" => [model("m", []), model("m", [])]})]
        }),
        ["cases", 0, "script", 0, "results"],
        :bounds
      )

      twice = [model("m", [answer("a")]), model("m", [answer("b")])]

      refused(
        Jason.encode!(%{base | "cases" => [one_case(%{"script" => twice})]}),
        ["cases", 0, "script", 1, "key"],
        :duplicate_script_key
      )

      refused(String.duplicate(" ", 16_777_217), [], :too_large)
      refused("{", [], :json)
    end
  end

  ## Acceptance 4

  describe "artifact_faults" do
    test "stored bytes that were changed are integrity_mismatch; a missing one is unavailable" do
      fx = artifact()
      rec = stored(fx, "dataset", dataset("d", agent_cases()))

      changed = dataset("d", tl(agent_cases()))
      assert %{status: :committed} = Elzoo.ObjectStore.put(fx.object_store, rec.object_key, changed)

      assert Eval.load(fx.art, fx.caller, "dataset", :head) == {:error, :integrity_mismatch}
      assert Eval.load(fx.art, fx.caller, "absent", :head) == {:error, :artifact_unavailable}
    end
  end

  ## Acceptance 5

  describe "unscripted_case" do
    test "a case whose script lacks a key is an error and the other cases still run" do
      [reads | rest] = agent_cases()
      broken = %{reads | "case_id" => "no-tool", "script" => [hd(reads["script"])]}
      report = Eval.run(loaded(dataset("d", [broken | rest])), agent_base())

      assert [%{case_id: "no-tool", status: :error, checks: [], error: :unscripted_call} | others] =
               report.cases

      assert Enum.map(others, & &1.status) == [:passed, :passed]
      assert {report.passed, report.failed, report.errored} == {2, 0, 1}
    end

    test "an atom reason of recipe-test is the case error" do
      report = Eval.run(loaded(dataset("d", agent_cases())), %{agent_base() | gate: 1})

      assert Enum.map(report.cases, &{&1.status, &1.checks, &1.error}) ==
               List.duplicate({:error, [], :invalid_spec}, 3)

      assert report.errored == 3
    end
  end

  ## Acceptance 6

  describe "same_dataset_same_report" do
    test "the same dataset run twice gives equal reports" do
      dataset = loaded(dataset("graph-cases", graph_cases()))
      first = Eval.run(dataset, graph_base())
      assert first.passed == 3
      assert Eval.run(dataset, graph_base()) == first
    end
  end

  ## Acceptance 7

  describe "changed_package" do
    test "a changed recipe package flips the expected case and its identity" do
      dataset = loaded(dataset("graph-cases", graph_cases()))
      before = Eval.run(dataset, graph_base())
      later = Eval.run(dataset, graph_base(swap: true))

      assert before.package != later.package
      assert later.dataset == before.dataset
      assert statuses(before) |> Enum.map(&elem(&1, 1)) == [:passed, :passed, :passed]
      assert statuses(later) |> Enum.map(&elem(&1, 1)) == [:failed, :failed, :failed]

      assert [%{checks: [_, %{kind: :structured_matches, reason: :schema}, _]} | _] = later.cases
    end
  end
end
