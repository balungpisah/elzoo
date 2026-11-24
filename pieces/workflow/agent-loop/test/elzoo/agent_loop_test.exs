# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AgentLoopTest do
  use ExUnit.Case, async: true
  alias Elzoo.{AgentLoop, PatternStep, PayloadSchema, ToolRegistry, UntrustedContent}
  alias Elzoo.AiText.{Anthropic, OpenAI, Request}

  # Recorded-trace tests: every input is a literal neutral map; no model, no network.

  @model "claude-sonnet-4-5"
  @role "You are a test agent."
  @schema %{
    "type" => "object",
    "properties" => %{"q" => %{"type" => "string"}},
    "required" => ["q"]
  }
  @ask_schema %{
    "type" => "object",
    "properties" => %{"person_id" => %{"type" => "string"}, "question" => %{"type" => "string"}},
    "required" => ["question"]
  }
  @window %{
    provider_id: "test",
    model_id: "test",
    size: 1_000_000,
    unit: :tokens,
    estimator_id: "bytes",
    estimator_version: 1
  }
  @limits %{max_bytes: 1_024, artifact_max_bytes: 1_000_000}
  @system %{"role" => "system", "text" => @role}
  @attempt_key "elzoo.agent-loop.model-attempt"
  @attempt_port %{
    "id" => "model-attempt",
    "direction" => "output",
    "schema_id" => @attempt_key,
    "schema_version" => 1
  }
  @attempt_schema %{
    "type" => "object",
    "properties" => %{"request" => %{"type" => "object"}, "attempts" => %{"type" => "array"}},
    "required" => ["request", "attempts"],
    "additionalProperties" => false
  }

  ## Fixtures

  defp descriptor(name, schema \\ @schema),
    do: %{
      "trust" => "untrusted",
      "name" => name,
      "description" => "Tool " <> name,
      "input_schema" => schema,
      "annotations" => nil
    }

  defp source(id, kind, callable, tools),
    do: %{"id" => id, "kind" => kind, "callable" => callable, "tools" => tools}

  defp sources,
    do: [
      source("files", "other", "adapter", [descriptor("read")]),
      source("web", "other", "adapter", [descriptor("fetch")]),
      source("sub", "other", "nested", [descriptor("plan")]),
      source("skills", "pinned_skill", "adapter", [descriptor("load")]),
      source("hub", "host_listing", "adapter", [descriptor("list"), descriptor("extra")]),
      source("people", "other", "adapter", [descriptor("ask", @ask_schema)])
    ]

  # The ai-text tool shape, written by hand, sorted by alias.
  defp tool(name, own, schema \\ @schema),
    do: %{"name" => name, "description" => "Tool " <> own, "input_schema" => schema}

  defp tools,
    do: [
      tool("files_read", "read"),
      tool("hub_extra", "extra"),
      tool("hub_list", "list"),
      tool("people_ask", "ask", @ask_schema),
      tool("skills_load", "load"),
      tool("sub_plan", "plan"),
      tool("web_fetch", "fetch")
    ]

  defp spec(extra \\ %{}),
    do:
      Map.merge(
        %{
          id: "run",
          model: @model,
          max_output_tokens: 256,
          role_instructions: [@role],
          window: @window,
          max_request_bytes: 65_536,
          max_image_refs: 4,
          sources: sources(),
          result_limits: @limits,
          ask: nil,
          turn_limit: 8
        },
        extra
      )

  defp new!(extra) do
    {:ok, state} = AgentLoop.new(spec(extra))
    state
  end

  # A plain function of the byte size.
  defp estimate(bytes),
    do:
      {:ok,
       %{
         size: byte_size(bytes),
         unit: :tokens,
         direction: :upper_bound,
         estimator_id: "bytes",
         estimator_version: 1
       }}

  defp input(kind, fields),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)

  defp text_input(kind, text),
    do:
      input(kind, %{
        "schema_id" => "elzoo.agent-loop.message",
        "schema_version" => 1,
        "payload" => %{"text" => text}
      })

  defp start(text \\ "go"), do: text_input("start", text)
  defp message(text), do: text_input("message", text)

  defp outcome(id, class, schema, payload),
    do:
      input("action_outcome", %{
        "action_id" => id,
        "outcome" => class,
        "schema_id" => schema,
        "schema_version" => 1,
        "payload" => payload
      })

  defp model(n, content, finish, proposals),
    do:
      outcome("run:m:#{n}", "completed", "elzoo.ai-text.result", %{
        "content" => content,
        "finish" => finish,
        "tool_proposals" => proposals,
        "structured" => nil,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "provenance" => %{"response_id" => "r"}
      })

  defp proposal(id, name, arguments, tag \\ nil),
    do: %{
      "id" => id,
      "name" => name,
      "raw_arguments" => "{}",
      "arguments" => arguments,
      "malformed" => tag
    }

  defp call(id, name, q \\ "x"), do: proposal(id, name, %{"q" => q})

  defp marked(sources, text),
    do: %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => sources,
      "trust" => "untrusted",
      "max_bytes" => 65_536,
      "content" => text
    }

  defp result(id, text),
    do:
      outcome(id, "completed", "elzoo.agent-loop.tool-result", %{
        "content" => marked(["tool:test"], text),
        "media_type" => "text/plain",
        "encoding" => "utf8"
      })

  defp declared(id, skill, listing),
    do:
      outcome(id, "completed", "elzoo.agent-loop.tool-result", %{
        "declaration" => %{"skill" => skill, "listing" => listing}
      })

  defp answer(id, text, person \\ "p-7"),
    do:
      input("person_answer", %{
        "action_id" => id,
        "person_id" => person,
        "schema_id" => "elzoo.agent-loop.answer",
        "schema_version" => 1,
        "payload" => %{"text" => text}
      })

  defp receipt(id, payload),
    do:
      outcome(id, "completed", "elzoo.agent-loop.tool-result", %{
        "artifact_id" => "a1",
        "version" => 1,
        "sha256" => payload["sha256"],
        "size_bytes" => payload["size_bytes"],
        "media_type" => payload["media_type"]
      })

  # The one rendered form of marked content in a request.
  defp block(sources, text) do
    {:ok, marked} = UntrustedContent.decode(marked(sources, text))
    {:ok, rendered} = UntrustedContent.render(marked)
    rendered
  end

  defp notice(text), do: block(["agent-loop"], text)

  defp tool_result(id, text), do: %{"role" => "tool_result", "tool_use_id" => id, "text" => text}
  defp echo(id, name, q \\ "x"), do: %{"id" => id, "name" => name, "arguments" => %{"q" => q}}

  defp version(name) do
    {:ok, snapshot} = ToolRegistry.snapshot(sources())
    {:resolved, tool} = ToolRegistry.resolve(snapshot, name)
    tool.version
  end

  defp request(actions), do: %{"type" => "request", "version" => 1, "actions" => actions}

  defp action(id, kind, schema_id, payload),
    do: %{
      "id" => id,
      "kind" => kind,
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }

  defp tool_action(id, kind, name, source, own, q \\ "x"),
    do:
      action(id, kind, "elzoo.agent-loop.tool-call", %{
        "alias" => name,
        "source" => source,
        "tool" => own,
        "version" => version(name),
        "arguments" => %{"q" => q}
      })

  defp model_call(n, messages, tools \\ tools()),
    do:
      request([
        action("run:m:#{n}", "model_call", "elzoo/ai-text-request", %{
          "version" => 1,
          "model" => @model,
          "max_output_tokens" => 256,
          "messages" => messages,
          "tools" => tools
        })
      ])

  defp finish(status, reason, action_id, turns),
    do:
      request([
        action("run:finish", "finish", "elzoo.agent-loop.result", %{
          "status" => status,
          "reason" => reason,
          "action_id" => action_id,
          "turns" => turns
        })
      ])

  ## Running a trace

  # Steps each input; checks each request and each state; returns the state and every output.
  defp run(state, inputs) do
    {outputs, state} =
      Enum.map_reduce(inputs, state, fn input, state ->
        {:Transition, next, output} = AgentLoop.step(state, input, &estimate/1)
        checked!(next, output)
        {output, next}
      end)

    {state, outputs}
  end

  defp checked!(state, output) do
    assert plain?(state)
    assert byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])) <= 65_536

    with {:some, request} <- output do
      assert {:ok, _} = PatternStep.decode(request)

      for %{"kind" => "model_call", "payload" => payload} = action <- request["actions"] do
        if action["schema_id"] == @attempt_key do
          # The engine's payload check of an Attempt: JSON form, depth 32, 65,536 bytes.
          {:ok, schema} = PayloadSchema.build(@attempt_port, @attempt_schema)
          assert PayloadSchema.check(schema, @attempt_port, payload) == :ok
          assert {:ok, _, _} = Request.decode(Request.canonical(payload["request"]), 65_536)
        else
          assert {:ok, _, _} = Request.decode(Request.canonical(payload), 65_536)
        end
      end
    end
  end

  defp plain?(value) when is_map(value),
    do: not is_struct(value) and Enum.all?(value, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)
  defp plain?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&plain?/1)
  defp plain?(value), do: is_atom(value) or is_number(value) or is_binary(value)

  defp last({_, outputs}), do: List.last(outputs)
  defp trace(inputs, extra \\ %{}), do: run(new!(extra), inputs)

  defp messages({:some, %{"actions" => [%{"kind" => "model_call", "payload" => p}]}}),
    do: p["messages"]

  defp payload({:some, %{"actions" => [%{"payload" => p}]}}), do: p

  # One tool call of turn 1, then the given outcome of its action: the next output.
  defp after_call(name, outcome, extra \\ %{}) do
    last(trace([start(), model(1, "", "tool_calls", [call("c1", name)]), outcome], extra))
  end

  ## Fixtures of the start load

  @skill_schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string", "enum" => ["guide", "review"]}},
    "required" => ["name"]
  }

  defp skill_source,
    do: source("sk", "pinned_skill", "adapter", [descriptor("load_skill", @skill_schema)])

  defp skill_spec, do: %{sources: sources() ++ [skill_source()]}

  # The tools of a start that has the skill source, sorted by alias.
  defp skill_tools,
    do: Enum.sort_by([tool("sk_load_skill", "load_skill", @skill_schema) | tools()], & &1["name"])

  defp skill_trace(inputs), do: trace(inputs, skill_spec())

  defp skill_version do
    {:ok, snapshot} = ToolRegistry.snapshot(sources() ++ [skill_source()])
    {:resolved, tool} = ToolRegistry.resolve(snapshot, "sk_load_skill")
    tool.version
  end

  defp skill_payload(text, skill),
    do: %{"text" => text, "skill" => skill}

  defp payload_input(kind, payload),
    do:
      input(kind, %{
        "schema_id" => "elzoo.agent-loop.message",
        "schema_version" => 1,
        "payload" => payload
      })

  defp skill_start(tool_alias \\ "sk_load_skill", name \\ "guide", text \\ "go"),
    do: payload_input("start", skill_payload(text, %{"tool" => tool_alias, "name" => name}))

  defp load_request(name \\ "guide"),
    do:
      request([
        action("run:t:0:1", "tool_call", "elzoo.agent-loop.tool-call", %{
          "alias" => "sk_load_skill",
          "source" => "sk",
          "tool" => "load_skill",
          "version" => skill_version(),
          "arguments" => %{"name" => name}
        })
      ])

  defp guide, do: %{"name" => "guide", "instructions" => "Always cite the file."}
  defp user(text), do: %{"role" => "user", "text" => text}

  # The history of a state as {kind, id}.
  defp history(state), do: Enum.map(state.history, &{&1.kind, &1.id})

  ## Named acceptance groups

  test "final_answer" do
    {state, outputs} = trace([start("What is 2+2?"), model(1, "4.", "stop", [])])
    user = %{"role" => "user", "text" => "What is 2+2?"}

    assert outputs == [
             {:some, model_call(1, [@system, user])},
             {:some, finish("answered", nil, "run:m:1", 1)}
           ]

    assert {:Transition, ^state, :none} = AgentLoop.step(state, message("more"), &estimate/1)

    # A message that arrives while the call is open: the same result is not final.
    inputs = [start("What is 2+2?"), message("Also show the work."), model(1, "4.", "stop", [])]
    {state, outputs} = trace(inputs)
    assistant = %{"role" => "assistant", "text" => "4."}
    also = %{"role" => "user", "text" => "Also show the work."}
    assert Enum.at(outputs, 1) == :none
    assert List.last(outputs) == {:some, model_call(2, [@system, user, assistant, also])}

    # The trace run a second time gives equal states and requests.
    assert trace(inputs) == {state, outputs}
  end

  test "one_turn_one_request" do
    proposals = [
      call("c1", "files_read", "a"),
      call("c2", "web_fetch", "b"),
      call("c3", "sub_plan", "c")
    ]

    {state, [_, turn]} = trace([start(), model(1, "Working.", "tool_calls", proposals)])

    assert turn ==
             {:some,
              request([
                tool_action("run:t:1:1", "tool_call", "files_read", "files", "read", "a"),
                tool_action("run:t:1:2", "tool_call", "web_fetch", "web", "fetch", "b"),
                tool_action("run:t:1:3", "nested_callable", "sub_plan", "sub", "plan", "c")
              ])}

    outcomes = [result("run:t:1:1", "r1"), result("run:t:1:2", "r2"), result("run:t:1:3", "r3")]

    expected =
      {:some,
       model_call(2, [
         @system,
         %{"role" => "user", "text" => "go"},
         %{
           "role" => "assistant",
           "text" => "Working.",
           "tool_calls" => [
             echo("c1", "files_read", "a"),
             echo("c2", "web_fetch", "b"),
             echo("c3", "sub_plan", "c")
           ]
         },
         tool_result("c1", block(["tool:test"], "r1")),
         tool_result("c2", block(["tool:test"], "r2")),
         tool_result("c3", block(["tool:test"], "r3"))
       ])}

    orders = for a <- outcomes, b <- outcomes -- [a], c <- outcomes -- [a, b], do: [a, b, c]
    assert length(orders) == 6

    for order <- orders do
      {_, outputs} = run(state, order)
      # No request comes before the last outcome.
      assert outputs == [:none, :none, expected]
    end

    # A second outcome for one action changes nothing.
    {once, [:none]} = run(state, [result("run:t:1:2", "r2")])

    assert AgentLoop.step(once, result("run:t:1:2", "other"), &estimate/1) ==
             {:Transition, once, :none}
  end

  test "unknown_tool" do
    line = fn name, word ->
      notice("[tool call left out: #{name}: undeclared_tool: #{word}]")
    end

    unknown = proposal("c1", "nowhere", nil, "undeclared_tool")
    output = last(trace([start(), model(1, "", "tool_calls", [unknown])]))

    assert messages(output) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{"role" => "user", "text" => line.("nowhere", "unknown")}
           ]

    # A name that the last listing removed.
    removed = proposal("c2", "hub_extra", nil, "undeclared_tool")

    inputs = [
      start(),
      model(1, "", "tool_calls", [call("c1", "hub_list")]),
      declared("run:t:1:1", nil, %{"source" => "hub", "tools" => [descriptor("list")]}),
      model(2, "", "tool_calls", [removed])
    ]

    assert List.last(messages(last(trace(inputs)))) == %{
             "role" => "user",
             "text" => line.("hub_extra", "removed")
           }

    # An own name on two sources.
    two = [
      source("files", "other", "adapter", [descriptor("read")]),
      source("web", "other", "adapter", [descriptor("read")])
    ]

    ambiguous = proposal("c1", "read", nil, "undeclared_tool")
    output = last(trace([start(), model(1, "", "tool_calls", [ambiguous])], %{sources: two}))
    assert List.last(messages(output)) == %{"role" => "user", "text" => line.("read", "ambiguous")}
  end

  test "malformed_proposals" do
    proposals = [
      proposal("c1", "files_read", nil, "undeclared_tool"),
      proposal("c2", "files_read", nil, "schema_mismatch"),
      proposal("c3", "files_read", nil, "not_an_object"),
      proposal("c4", "files_read", nil, "invalid_json"),
      call("c5", "files.read"),
      call("c6", String.duplicate("f", 65)),
      call("c7", nil),
      call("c8", "web_fetch")
    ]

    {_, [_, turn, next]} =
      trace([start(), model(1, "", "tool_calls", proposals), result("run:t:1:8", "fetched")])

    assert turn ==
             {:some, request([tool_action("run:t:1:8", "tool_call", "web_fetch", "web", "fetch")])}

    lines = [
      "[tool call left out: files_read: undeclared_tool: unknown]",
      "[tool call left out: files_read: schema_mismatch]",
      "[tool call left out: files_read: not_an_object]",
      "[tool call left out: files_read: invalid_json]",
      "[tool call left out: name_outside_grammar]",
      "[tool call left out: name_outside_grammar]",
      "[tool call left out: name_outside_grammar]"
    ]

    assert messages(next) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{"role" => "assistant", "text" => "", "tool_calls" => [echo("c8", "web_fetch")]},
             tool_result("c8", block(["tool:test"], "fetched")),
             %{"role" => "user", "text" => notice(Enum.join(lines, "\n"))}
           ]

    refute Enum.any?(
             messages(next),
             &String.contains?(&1["text"], ["files.read", String.duplicate("f", 65)])
           )

    # All proposals left out: the next model request and no tool action.
    output = last(trace([start(), model(1, "", "tool_calls", Enum.take(proposals, 7))]))
    assert [%{"id" => "run:m:2", "kind" => "model_call"}] = elem(output, 1)["actions"]

    assert List.last(messages(output)) == %{
             "role" => "user",
             "text" => notice(Enum.join(lines, "\n"))
           }
  end

  test "listing_changes_snapshot" do
    listing = fn tools -> %{"source" => "hub", "tools" => tools} end
    many = [descriptor("list") | for(i <- 1..59, do: descriptor("n#{i}"))]

    inputs = [
      start(),
      model(1, "", "tool_calls", [call("c1", "hub_list")]),
      declared("run:t:1:1", nil, listing.([descriptor("list"), descriptor("new")])),
      model(2, "", "tool_calls", [call("c2", "hub_new")]),
      result("run:t:2:1", "new result"),
      model(3, "", "tool_calls", [call("c3", "hub_list")]),
      declared("run:t:3:1", nil, listing.(many)),
      model(4, "", "tool_calls", [call("c4", "hub_list")]),
      declared("run:t:4:1", nil, listing.([descriptor("list")]))
    ]

    {_, outputs} = trace(inputs)
    added = Enum.at(outputs, 2)
    with_new = (tools() -- [tool("hub_extra", "extra")]) ++ [tool("hub_new", "new")]
    assert payload(added)["tools"] == Enum.sort_by(with_new, & &1["name"])
    assert List.last(messages(added)) == tool_result("c1", notice("[declaration accepted]"))

    # A proposal for the new alias in the next turn gives an action.
    assert Enum.at(outputs, 3) ==
             {:some, request([tool_action_new("run:t:2:1")])}

    # 65 tools: refused, and the next request declares the old tools.
    refused = Enum.at(outputs, 6)

    assert List.last(messages(refused)) ==
             tool_result("c3", notice("[declaration refused: too_many_tools]"))

    assert payload(refused)["tools"] == payload(added)["tools"]

    # A listing that removes a called tool: not declared, not echoed, its result still content.
    removed = List.last(outputs)
    assert payload(removed)["tools"] == tools() -- [tool("hub_extra", "extra")]
    calls = for %{"tool_calls" => calls} <- messages(removed), call <- calls, do: call["name"]
    assert calls == ["hub_list", "hub_list", "hub_list"]
    assert %{"role" => "user", "text" => block(["tool:test"], "new result")} in messages(removed)
    refute Enum.any?(messages(removed), &(&1["tool_use_id"] == "c2"))
  end

  defp tool_action_new(id) do
    {:ok, snapshot} = ToolRegistry.snapshot(sources())

    {:ok, snapshot} =
      ToolRegistry.refresh(snapshot, "hub", [descriptor("list"), descriptor("new")])

    {:resolved, tool} = ToolRegistry.resolve(snapshot, "hub_new")

    action(id, "tool_call", "elzoo.agent-loop.tool-call", %{
      "alias" => "hub_new",
      "source" => "hub",
      "tool" => "new",
      "version" => tool.version,
      "arguments" => %{"q" => "x"}
    })
  end

  test "outside_set_listing" do
    {state, [_, _]} = trace([start(), model(1, "", "tool_calls", [call("c1", "hub_list")])])
    before = ToolRegistry.tools(state.snapshot)
    outside = declared("run:t:1:1", nil, %{"source" => "elsewhere", "tools" => [descriptor("x")]})
    {state, [output]} = run(state, [outside])
    assert ToolRegistry.tools(state.snapshot) == before

    assert List.last(messages(output)) ==
             tool_result("c1", notice("[declaration refused: unknown_source]"))
  end

  test "declarations_by_source_kind" do
    both = fn id ->
      declared(
        id,
        %{"name" => "guide", "instructions" => "Always cite the file."},
        %{"source" => "skills", "tools" => [descriptor("load"), descriptor("guide")]}
      )
    end

    taken = [@system |> Map.put("text", @role <> "\n\nAlways cite the file.")]
    guide = Enum.sort_by([tool("skills_guide", "guide") | tools()], & &1["name"])

    for name <- ["files_read", "hub_list"] do
      output = after_call(name, both.("run:t:1:1"))
      assert hd(messages(output)) == @system
      assert payload(output)["tools"] == tools()

      assert List.last(messages(output)) ==
               tool_result("c1", notice("[declaration refused: declaration_not_permitted]"))
    end

    output = after_call("skills_load", both.("run:t:1:1"))
    assert [hd(messages(output))] == taken
    assert payload(output)["tools"] == guide
    assert List.last(messages(output)) == tool_result("c1", notice("[declaration accepted]"))

    # A listing only: taken from host_listing, refused from other.
    only = declared("run:t:1:1", nil, %{"source" => "hub", "tools" => [descriptor("list")]})
    output = after_call("hub_list", only)
    assert payload(output)["tools"] == tools() -- [tool("hub_extra", "extra")]
    output = after_call("files_read", only)
    assert payload(output)["tools"] == tools()

    assert List.last(messages(output)) ==
             tool_result("c1", notice("[declaration refused: declaration_not_permitted]"))

    # A result of a pinned_skill tool that is not a declaration is content in a marked block.
    output = after_call("skills_load", result("run:t:1:1", "Skill file text."))
    assert hd(messages(output)) == @system

    assert List.last(messages(output)) ==
             tool_result("c1", block(["tool:test"], "Skill file text."))
  end

  test "instruction_bound" do
    skill = fn name, text -> %{"name" => name, "instructions" => text} end
    a = String.duplicate("a", 10_000)
    b = String.duplicate("b", 6_384)
    over = String.duplicate("Q", 6_385)

    turn = fn n, declaration ->
      [model(n, "", "tool_calls", [call("c#{n}", "skills_load")]), declaration.("run:t:#{n}:1")]
    end

    inputs =
      [start()] ++
        turn.(1, &declared(&1, skill.("a", a), nil)) ++
        turn.(2, &declared(&1, skill.("over", over), nil)) ++
        turn.(3, &declared(&1, skill.("b", b), nil)) ++
        turn.(4, &declared(&1, skill.("a", "another text"), nil))

    {_, outputs} = trace(inputs)
    system = fn index -> hd(messages(Enum.at(outputs, index))) end

    assert system.(2) == %{"role" => "system", "text" => @role <> "\n\n" <> a}
    # One more byte than the bound: refused, the system message unchanged.
    assert system.(4) == system.(2)

    assert List.last(messages(Enum.at(outputs, 4))) ==
             tool_result("c2", notice("[declaration refused: instructions_over_bound]"))

    refute Enum.any?(
             outputs,
             &(&1 != :none and String.contains?(Request.canonical(elem(&1, 1)), "Q"))
           )

    # Exactly 16,384 bytes: accepted.
    assert system.(6) == %{"role" => "system", "text" => @role <> "\n\n" <> a <> "\n\n" <> b}
    assert byte_size(a <> b) == 16_384
    # A second load of a loaded name, with another text, adds nothing.
    assert system.(8) == system.(6)

    assert List.last(messages(Enum.at(outputs, 8))) ==
             tool_result("c4", notice("[declaration refused: already_loaded]"))

    # A skill file over max_bytes: one store action that no tool list shows; a reference and a preview.
    file = String.duplicate("s", 2_000)

    {state, [_, _, store]} =
      trace([
        start(),
        model(1, "", "tool_calls", [call("c1", "skills_load")]),
        result("run:t:1:1", file)
      ])

    sha = :crypto.hash(:sha256, file) |> Base.encode16(case: :lower)

    stored = %{
      "source_action_id" => "run:t:1:1",
      "sha256" => sha,
      "size_bytes" => 2_000,
      "media_type" => "text/plain",
      "encoding" => "utf8"
    }

    assert store ==
             {:some,
              request([action("run:s:1:1", "tool_call", "elzoo.tool-result-limit.store", stored)])}

    {_, [next]} = run(state, [receipt("run:s:1:1", stored)])

    preview =
      "[cut: first 512 of 2000 bytes shown; whole result: artifact a1 version 1]\n" <>
        String.duplicate("s", 512)

    assert List.last(messages(next)) == tool_result("c1", block(["tool:test"], preview))
    assert payload(next)["tools"] == tools()

    # An instruction body of the same size is whole in the system message.
    output = after_call("skills_load", declared("run:t:1:1", skill.("file", file), nil))
    assert hd(messages(output)) == %{"role" => "system", "text" => @role <> "\n\n" <> file}
  end

  test "proposal_without_id" do
    {_, [_, next]} =
      trace([
        start(),
        model(1, "Let me look.", "tool_calls", [proposal(nil, "files_read", %{"q" => "x"})])
      ])

    assert [%{"kind" => "model_call"}] = elem(next, 1)["actions"]

    assert messages(next) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{"role" => "assistant", "text" => "Let me look."},
             %{"role" => "user", "text" => notice("[tool call left out: files_read: missing_id]")}
           ]
  end

  test "engine_refusal_as_content" do
    refusal = fn class, payload ->
      outcome("run:t:1:1", class, "elzoo.run-engine.refusal", payload)
    end

    reason = %{
      "reason" => "over_budget",
      "gate_id" => "g",
      "gate_version" => 1,
      "request" => 0,
      "index" => 0
    }

    inputs = fn first ->
      [
        start(),
        model(1, "", "tool_calls", [call("c1", "files_read"), call("c2", "web_fetch")]),
        first,
        result("run:t:1:2", "fetched")
      ]
    end

    next = last(trace(inputs.(refusal.("refused", reason))))
    refused = tool_result("c1", notice("[tool call not completed: refused: over_budget]"))
    assert Enum.at(messages(next), 3) == refused
    assert Enum.at(messages(next), 4) == tool_result("c2", block(["tool:test"], "fetched"))
    refute Enum.any?(messages(next), &Map.has_key?(&1, "is_error"))

    # Both ready providers translate that request; the OpenAI rule reads is_error.
    {:ok, decoded, _} = Request.decode(Request.canonical(payload(next)), 65_536)
    assert {:ok, _} = Anthropic.translate(%{decoded | model: "claude-sonnet-4-5"}, nil)
    assert {:ok, _} = OpenAI.translate(%{decoded | model: "gpt-6.1-terra"}, nil)

    flagged =
      Map.update!(
        payload(next),
        "messages",
        &List.replace_at(&1, 3, Map.put(refused, "is_error", true))
      )

    {:ok, flagged, _} = Request.decode(Request.canonical(flagged), 65_536)

    assert {:refused, :unsupported_feature} =
             OpenAI.translate(%{flagged | model: "gpt-6.1-terra"}, nil)

    expected = %{
      "unknown" => "[tool call not completed: unknown: over_budget]",
      "failed" => "[tool call not completed: failed: over_budget]",
      "out_of_budget" => "[tool call not completed: out_of_budget: over_budget]",
      "expired" => "[tool call not completed: expired: over_budget]"
    }

    rendered =
      Map.new(expected, fn {class, _} ->
        {class, Enum.at(messages(last(trace(inputs.(refusal.(class, reason))))), 3)}
      end)

    assert rendered ==
             Map.new(expected, fn {class, line} -> {class, tool_result("c1", notice(line))} end)
  end

  test "result_after_cancel" do
    proposals = [call("c1", "files_read"), call("c2", "web_fetch")]
    {open, [_, _]} = trace([start(), model(1, "", "tool_calls", proposals)])

    # A late outcome for an open action and a map that decode refuses change nothing.
    assert AgentLoop.step(open, outcome("run:t:1:1", "late", "test/any", nil), &estimate/1) ==
             {:Transition, open, :none}

    assert AgentLoop.step(open, %{"type" => "input", "kind" => "bogus"}, &estimate/1) ==
             {:Transition, open, :none}

    cancel = input("cancel", %{"attempt_id" => "attempt-1"})
    {closed, [:none]} = run(open, [cancel])
    refute closed == open

    assert AgentLoop.step(closed, result("run:t:1:1", "r1"), &estimate/1) ==
             {:Transition, closed, :none}
  end

  test "turn_limit" do
    second = [
      start(),
      model(1, "", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", "r1")
    ]

    output =
      last(
        trace(second ++ [model(2, "", "tool_calls", [call("c2", "files_read")])], %{turn_limit: 2})
      )

    assert output == {:some, finish("stopped", "turn_limit", nil, 2)}

    unknown = outcome("run:m:1", "unknown", "elzoo.run-engine.refusal", %{"reason" => "lost"})

    assert last(trace([start(), unknown])) ==
             {:some, finish("stopped", "model_call_not_completed", nil, 1)}

    assert last(trace([start(), model(1, "Partial", "length", [])])) ==
             {:some, finish("stopped", "model_stopped", nil, 1)}

    # Proposals that are not a proper list are not in the form that the step reads: no raise.
    improper = [call("c1", "files_read") | "tail"]

    assert last(trace([start(), model(1, "", "tool_calls", improper)])) ==
             {:some, finish("stopped", "model_stopped", nil, 1)}

    {state, outputs} = trace([start(), message(String.duplicate("m", 65_000))])
    assert List.last(outputs) == {:some, finish("stopped", "state_over_bound", nil, 1)}

    assert AgentLoop.step(state, model(1, "4.", "stop", []), &estimate/1) ==
             {:Transition, state, :none}
  end

  test "done_is_not_evidence" do
    tool_turn = fn content ->
      [
        start(),
        model(1, content, "tool_calls", [call("c1", "files_read")]),
        result("run:t:1:1", "r1")
      ]
    end

    {_, [_, run_tool, _]} = trace(tool_turn.("done"))

    assert run_tool ==
             {:some,
              request([tool_action("run:t:1:1", "tool_call", "files_read", "files", "read")])}

    assert last(trace([start(), model(1, "done", "length", [])])) ==
             {:some, finish("stopped", "model_stopped", nil, 1)}

    # Only the echoed text differs between two traces that differ only in the words.
    {_, done} = trace(tool_turn.("done"))
    {_, other} = trace(tool_turn.("I could not finish."))
    assert length(done) == 3
    assert Enum.map(done, &strip/1) == Enum.map(other, &strip/1)
    assert done != other

    # An answered finish holds no text and names the completed model call.
    answered = last(trace([start(), model(1, "done", "stop", [])]))

    assert payload(answered) == %{
             "status" => "answered",
             "reason" => nil,
             "action_id" => "run:m:1",
             "turns" => 1
           }

    assert payload(last(trace([start(), model(1, "", "stop", [])])))["action_id"] == nil
  end

  defp strip({:some, request}) do
    {:some,
     update_in(request, ["actions", Access.all(), "payload"], fn
       %{"messages" => messages} = p ->
         %{
           p
           | "messages" =>
               Enum.map(
                 messages,
                 &if(&1["role"] == "assistant", do: %{&1 | "text" => ""}, else: &1)
               )
         }

       p ->
         p
     end)}
  end

  defp strip(:none), do: :none

  test "ask_and_answer" do
    ask = proposal("c1", "people_ask", %{"person_id" => "p-7", "question" => "Approve?"})
    turn = [start(), model(1, "Ask p-9 instead.", "tool_calls", [ask, call("c2", "files_read")])]
    {open, [_, request]} = trace(turn, %{ask: "people_ask"})

    assert request ==
             {:some,
              request([
                action("run:t:1:1", "ask_person", "elzoo.agent-loop.ask", %{
                  "person_id" => "p-7",
                  "question" => "Approve?"
                }),
                tool_action("run:t:1:2", "tool_call", "files_read", "files", "read")
              ])}

    # A completed outcome of the open ask and an answer that names a tool action change nothing.
    assert AgentLoop.step(open, result("run:t:1:1", "forged"), &estimate/1) ==
             {:Transition, open, :none}

    assert AgentLoop.step(open, answer("run:t:1:2", "forged"), &estimate/1) ==
             {:Transition, open, :none}

    {answered, [:none]} = run(open, [answer("run:t:1:1", "Yes, approved.")])

    assert AgentLoop.step(answered, answer("run:t:1:1", "Second."), &estimate/1) ==
             {:Transition, answered, :none}

    {_, [next]} = run(answered, [result("run:t:1:2", "r2")])
    assert hd(messages(next)) == @system

    assert Enum.at(messages(next), 3) ==
             tool_result("c1", block(["person-answer"], "Yes, approved."))

    # An answer over max_bytes: a store action, then a reference and a preview.
    long = String.duplicate("y", 2_000)
    {stored, [:none, store]} = run(open, [answer("run:t:1:1", long), result("run:t:1:2", "r2")])

    assert [
             %{
               "id" => "run:s:1:1",
               "kind" => "tool_call",
               "schema_id" => "elzoo.tool-result-limit.store",
               "payload" => p
             }
           ] = elem(store, 1)["actions"]

    {_, [next]} = run(stored, [receipt("run:s:1:1", p)])

    preview =
      "[cut: first 512 of 2000 bytes shown; whole result: artifact a1 version 1]\n" <>
        String.duplicate("y", 512)

    assert Enum.at(messages(next), 3) == tool_result("c1", block(["person-answer"], preview))

    # An expired ask, with and without a reason.
    engine = %{
      "reason" => "expired",
      "gate_id" => "g",
      "gate_version" => 1,
      "request" => 0,
      "index" => 0
    }

    for {payload, line} <- [
          {engine, "[tool call not completed: expired: expired]"},
          {nil, "[tool call not completed: expired]"}
        ] do
      expired = outcome("run:t:1:1", "expired", "elzoo.run-engine.refusal", payload)
      {_, [:none, next]} = run(open, [expired, result("run:t:1:2", "r2")])
      assert Enum.at(messages(next), 3) == tool_result("c1", notice(line))
    end

    # Arguments without person_id: no action.
    no_person = proposal("c1", "people_ask", %{"question" => "Approve?"})
    output = last(trace([start(), model(1, "", "tool_calls", [no_person])], %{ask: "people_ask"}))
    assert [%{"kind" => "model_call"}] = elem(output, 1)["actions"]

    assert List.last(messages(output)) ==
             tool_result("c1", notice("[tool call not run: invalid_ask]"))

    # With ask nil the same proposal is a tool action.
    {_, [_, plain]} = trace(turn)

    assert [%{"kind" => "tool_call", "payload" => %{"alias" => "people_ask"}}, _] =
             elem(plain, 1)["actions"]
  end

  ## One named group for each further rule

  test "declaration_over_state_bound" do
    # A host listing with one long description: the snapshot holds the listing whole.
    listing = fn bytes ->
      described = %{descriptor("list") | "description" => String.duplicate("d", bytes)}
      declared("run:t:1:1", nil, %{"source" => "hub", "tools" => [described]})
    end

    # The second call stays open, so step/3 returns the state that rule 6 measures.
    proposals = [call("c1", "hub_list"), call("c2", "files_read")]
    {open, [_, _]} = trace([start(), model(1, "", "tool_calls", proposals)])

    # Exactly 65,536 bytes with the declaration applied: accepted.
    {accepted, outputs} = run(open, [listing.(55_608)])
    assert outputs == [:none]

    assert byte_size(:erlang.term_to_binary(accepted, [:deterministic, {:minor_version, 2}])) ==
             65_536

    listed = for %{"name" => name} <- ToolRegistry.tools(accepted.snapshot), do: name
    assert listed == for(%{"name" => name} <- tools(), name != "hub_extra", do: name)

    # One more byte: refused, and nothing but the result of that call changes in the state.
    {refused, outputs} = run(open, [listing.(55_609)])
    assert outputs == [:none]
    assert Map.delete(refused, :open) == Map.delete(open, :open)

    {_, [next]} = run(refused, [result("run:t:1:2", "r2")])
    assert payload(next)["tools"] == tools()

    assert Enum.take(messages(next), -2) == [
             tool_result("c1", notice("[declaration refused: state_over_bound]")),
             tool_result("c2", block(["tool:test"], "r2"))
           ]
  end

  test "repeated_id" do
    proposals = [
      proposal("c1", "files_read", nil, "invalid_json"),
      call("c1", "files_read", "a"),
      call("c1", "web_fetch", "b"),
      call("c2", "sub_plan", "c")
    ]

    {_, [_, turn, :none, next]} =
      trace([
        start(),
        model(1, "", "tool_calls", proposals),
        result("run:t:1:2", "r2"),
        result("run:t:1:4", "r4")
      ])

    # The id of a proposal that was left out is not taken; the id of a kept one is.
    assert turn ==
             {:some,
              request([
                tool_action("run:t:1:2", "tool_call", "files_read", "files", "read", "a"),
                tool_action("run:t:1:4", "nested_callable", "sub_plan", "sub", "plan", "c")
              ])}

    lines = [
      "[tool call left out: files_read: invalid_json]",
      "[tool call left out: web_fetch: repeated_id]"
    ]

    assert messages(next) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{
               "role" => "assistant",
               "text" => "",
               "tool_calls" => [echo("c1", "files_read", "a"), echo("c2", "sub_plan", "c")]
             },
             tool_result("c1", block(["tool:test"], "r2")),
             tool_result("c2", block(["tool:test"], "r4")),
             %{"role" => "user", "text" => notice(Enum.join(lines, "\n"))}
           ]
  end

  test "over_call_bound" do
    proposals = for i <- 1..65, do: call("c#{i}", "files_read", "#{i}")
    {open, [_, turn]} = trace([start(), model(1, "", "tool_calls", proposals)])

    # 64 kept calls give 64 actions in one request; proposal 65 gives none.
    assert turn ==
             {:some,
              request(
                for i <- 1..64 do
                  tool_action("run:t:1:#{i}", "tool_call", "files_read", "files", "read", "#{i}")
                end
              )}

    {_, outputs} = run(open, for(i <- 1..64, do: result("run:t:1:#{i}", "r#{i}")))
    assert Enum.drop(outputs, -1) == List.duplicate(:none, 63)
    next = List.last(outputs)

    assert Enum.at(messages(next), 2)["tool_calls"] ==
             for(i <- 1..64, do: echo("c#{i}", "files_read", "#{i}"))

    refute Enum.any?(messages(next), &(&1["tool_use_id"] == "c65"))

    assert List.last(messages(next)) == %{
             "role" => "user",
             "text" => notice("[tool call left out: files_read: over_call_bound]")
           }
  end

  test "validator_disagreement" do
    # No tag, so the proposal check passed these arguments; the schema of the tool refuses them.
    disagreed = proposal("c1", "files_read", %{"q" => 7})

    {_, [_, turn, next]} =
      trace([
        start(),
        model(1, "", "tool_calls", [disagreed, call("c2", "web_fetch")]),
        result("run:t:1:2", "fetched")
      ])

    assert turn ==
             {:some, request([tool_action("run:t:1:2", "tool_call", "web_fetch", "web", "fetch")])}

    assert messages(next) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{
               "role" => "assistant",
               "text" => "",
               "tool_calls" => [
                 %{"id" => "c1", "name" => "files_read", "arguments" => %{"q" => 7}},
                 echo("c2", "web_fetch")
               ]
             },
             tool_result("c1", notice("[tool call not run: validator_disagreement]")),
             tool_result("c2", block(["tool:test"], "fetched"))
           ]
  end

  test "not_resolved" do
    # No tag on either: a name that no entry holds, and an own name on two sources.
    two = [
      source("files", "other", "adapter", [descriptor("read")]),
      source("web", "other", "adapter", [descriptor("read")])
    ]

    proposals = [call("c1", "nowhere"), call("c2", "read"), call("c3", "files_read")]

    {_, [_, turn, next]} =
      trace(
        [start(), model(1, "", "tool_calls", proposals), result("run:t:1:3", "r3")],
        %{sources: two}
      )

    assert turn ==
             {:some,
              request([tool_action("run:t:1:3", "tool_call", "files_read", "files", "read")])}

    # No model call echoes a call that does not resolve: each notice is content behind the results.
    assert messages(next) == [
             @system,
             %{"role" => "user", "text" => "go"},
             %{"role" => "assistant", "text" => "", "tool_calls" => [echo("c3", "files_read")]},
             tool_result("c3", block(["tool:test"], "r3")),
             %{"role" => "user", "text" => notice("[tool call not run: not_resolved]")},
             %{"role" => "user", "text" => notice("[tool call not run: not_resolved]")}
           ]
  end

  test "request_not_built" do
    # A spec member that build/2 refuses at the first model call.
    {closed, outputs} = trace([start()], %{role_instructions: []})
    assert outputs == [{:some, finish("stopped", "request_not_built", nil, 0)}]
    assert AgentLoop.step(closed, start(), &estimate/1) == {:Transition, closed, :none}

    # A turn that no request of 2,000 bytes holds, also when the older unit is dropped.
    inputs = [
      start(),
      model(1, "", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", String.duplicate("r", 1_000))
    ]

    {closed, outputs} = trace(inputs, %{max_request_bytes: 2_000})
    assert [{:some, %{"actions" => [%{"id" => "run:m:1"}]}}, {:some, _}, last] = outputs
    assert last == {:some, finish("stopped", "request_not_built", nil, 1)}
    assert AgentLoop.step(closed, message("more"), &estimate/1) == {:Transition, closed, :none}
  end

  test "run_ended" do
    ended =
      input("run_ended", %{"schema_id" => "test/any", "schema_version" => 1, "payload" => nil})

    long = String.duplicate("s", 2_000)
    sha = :crypto.hash(:sha256, long) |> Base.encode16(case: :lower)
    stored = %{"sha256" => sha, "size_bytes" => 2_000, "media_type" => "text/plain"}
    turn = model(1, "", "tool_calls", [call("c1", "files_read")])

    # The trace that opens each phase, the model calls made, and an input that the phase reads.
    phases = [
      {:new, [], 0, start()},
      {:model, [start()], 1, model(1, "4.", "stop", [])},
      {:tools, [start(), turn], 1, result("run:t:1:1", "r1")},
      {:stores, [start(), turn, result("run:t:1:1", long)], 1, receipt("run:s:1:1", stored)}
    ]

    for {phase, inputs, turns, awaited} <- phases do
      {open, _} = trace(inputs)
      assert open.phase == phase
      assert {:Transition, _, {:some, _}} = AgentLoop.step(open, awaited, &estimate/1)

      assert {:Transition, closed, :none} = AgentLoop.step(open, ended, &estimate/1)
      assert closed == %{phase: :closed, id: "run", turns: turns}
      assert AgentLoop.step(closed, awaited, &estimate/1) == {:Transition, closed, :none}
    end
  end

  test "new_refusals" do
    assert AgentLoop.new(Map.delete(spec(), :ask)) == {:error, :invalid_spec}
    assert AgentLoop.new(spec(%{turn_limit: 0})) == {:error, :invalid_spec}
    assert AgentLoop.new(spec(%{id: <<0xFF>>})) == {:error, :invalid_spec}
    assert AgentLoop.new(spec(%{window: %{@window | size: self()}})) == {:error, :invalid_spec}
    assert AgentLoop.new(spec(%{ask: "nowhere"})) == {:error, :invalid_spec}

    assert AgentLoop.new(spec(%{sources: [%{"id" => "x"}]})) ==
             {:error, {:sources, :invalid_source}}

    assert AgentLoop.new(spec(%{role_instructions: [String.duplicate("r", 70_000)]})) ==
             {:error, :state_too_large}

    assert AgentLoop.new(%URI{}) == {:error, :invalid_spec}
  end

  test "laws_and_example" do
    source = File.read!(Path.expand("../../cure/elzoo/agent_loop.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
    {result, _} = Code.eval_file(Path.expand("../../examples/agent_loop.exs", __DIR__))

    assert result == %{
             actions: ["model_call", "tool_call", "model_call", "finish"],
             status: "answered",
             action_id: "demo:m:2",
             turns: 2
           }
  end

  test "start_loads_skill" do
    listing = %{
      "source" => "sk",
      "tools" => [descriptor("load_skill", @skill_schema), descriptor("lookup")]
    }

    {open, [first]} = skill_trace([skill_start()])
    assert first == {:some, load_request()}
    assert open.phase == :tools
    assert open.turns == 0
    assert history(open) == [{:user, "run:u:1"}]

    {state, [_, second]} = skill_trace([skill_start(), declared("run:t:0:1", guide(), listing)])

    listed = Enum.sort_by([tool("sk_lookup", "lookup") | skill_tools()], & &1["name"])

    assert second ==
             {:some,
              model_call(
                1,
                [
                  %{"role" => "system", "text" => @role <> "\n\n" <> "Always cite the file."},
                  user("go"),
                  user(notice("[declaration accepted]"))
                ],
                listed
              )}

    # Both ready providers translate the request that follows the notice.
    {:ok, decoded, _} = Request.decode(Request.canonical(payload(second)), 65_536)
    assert {:ok, _} = Anthropic.translate(%{decoded | model: "claude-sonnet-4-5"}, nil)
    assert {:ok, _} = OpenAI.translate(%{decoded | model: "gpt-6.1-terra"}, nil)

    # The load is no turn and no model call: no assistant and no tool_result entry.
    assert history(state) == [{:user, "run:u:1"}, {:content, "run:n:0"}]
    assert state.turns == 1
    assert state.skills == [{"guide", "Always cite the file."}]

    assert Enum.at(state.history, 1) ==
             %{
               kind: :content,
               id: "run:n:0",
               content: marked(["agent-loop"], "[declaration accepted]"),
               ref_media_type: nil
             }

    # A message that arrives while the load is open follows the notice.
    inputs = [skill_start(), message("also this"), declared("run:t:0:1", guide(), listing)]
    {state, [_, waiting, third]} = skill_trace(inputs)
    assert waiting == :none

    assert third ==
             {:some,
              model_call(
                1,
                [
                  %{"role" => "system", "text" => @role <> "\n\n" <> "Always cite the file."},
                  user("go"),
                  user(notice("[declaration accepted]")),
                  user("also this")
                ],
                listed
              )}

    assert history(state) == [{:user, "run:u:1"}, {:content, "run:n:0"}, {:user, "run:u:2"}]
    assert state.waiting == []
  end

  test "start_load_refused" do
    over = %{"name" => "big", "instructions" => String.duplicate("a", 16_385)}
    many = [descriptor("list") | for(i <- 1..58, do: descriptor("n#{i}"))]

    reason = %{
      "reason" => "over_budget",
      "gate_id" => "g",
      "gate_version" => 1,
      "request" => 0,
      "index" => 0
    }

    cases = [
      {declared("run:t:0:1", over, nil), "[declaration refused: instructions_over_bound]"},
      {declared("run:t:0:1", nil, %{"source" => "hub", "tools" => many}),
       "[declaration refused: too_many_tools]"},
      {declared("run:t:0:1", nil, nil), "[declaration refused: invalid_declaration]"},
      {outcome("run:t:0:1", "refused", "elzoo.run-engine.refusal", reason),
       "[tool call not completed: refused: over_budget]"},
      {result("run:t:0:1", "Skill file text."), "[skill not loaded: not_a_declaration]"}
    ]

    for {answer, line} <- cases do
      {state, [_, output]} = skill_trace([skill_start(), answer])

      assert output ==
               {:some, model_call(1, [@system, user("go"), user(notice(line))], skill_tools())}

      assert history(state) == [{:user, "run:u:1"}, {:content, "run:n:0"}]
      assert Enum.at(state.history, 1).content == marked(["agent-loop"], line)
      assert state.skills == []
      assert state.turns == 1
    end
  end

  test "start_load_not_pinned_skill" do
    for name <- ["files_read", "hub_list"] do
      {state, outputs} = skill_trace([skill_start(name)])
      line = "[skill not loaded: not_permitted]"

      assert outputs ==
               [{:some, model_call(1, [@system, user("go"), user(notice(line))], skill_tools())}]

      assert history(state) == [{:user, "run:u:1"}, {:content, "run:n:0"}]
    end

    # An other-kind tool whose schema accepts {"name"} is not permitted either: the kind comes first.
    open = source("open", "other", "adapter", [descriptor("load_skill", @skill_schema)])

    listed =
      Enum.sort_by(
        [tool("open_load_skill", "load_skill", @skill_schema) | skill_tools()],
        & &1["name"]
      )

    {_, outputs} =
      trace([skill_start("open_load_skill")], %{sources: sources() ++ [skill_source(), open]})

    line = "[skill not loaded: not_permitted]"
    assert outputs == [{:some, model_call(1, [@system, user("go"), user(notice(line))], listed)}]
  end

  test "start_load_not_run" do
    for {name_alias, name, line} <- [
          {"nowhere", "guide", "[skill not loaded: not_resolved]"},
          {"sk_load_skill", "other", "[skill not loaded: validator_disagreement]"}
        ] do
      {state, outputs} = skill_trace([skill_start(name_alias, name)])

      assert outputs ==
               [{:some, model_call(1, [@system, user("go"), user(notice(line))], skill_tools())}]

      assert history(state) == [{:user, "run:u:1"}, {:content, "run:n:0"}]
      assert state.skills == []
    end

    # A form that is not exactly the start form is not a start: no change and no request.
    state = new!(skill_spec())
    named = %{"tool" => "sk_load_skill", "name" => "guide"}

    for payload <- [
          skill_payload("go", Map.put(named, "extra", "x")),
          skill_payload("go", %{named | "name" => 5}),
          skill_payload("go", %{named | "tool" => nil}),
          skill_payload("go", %{"tool" => "sk_load_skill"}),
          skill_payload("go", "guide"),
          skill_payload("", named),
          skill_payload(5, named),
          Map.put(skill_payload("go", named), "more", "x")
        ] do
      refused = payload_input("start", payload)
      assert {:ok, _} = PatternStep.decode(refused)
      assert AgentLoop.step(state, refused, &estimate/1) == {:Transition, state, :none}
    end
  end

  test "start_load_survives_refold" do
    listing = %{"source" => "sk", "tools" => [descriptor("load_skill", @skill_schema)]}

    inputs = [
      skill_start(),
      declared("run:t:0:1", guide(), listing),
      model(1, "", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", "r1"),
      model(2, "Done.", "stop", [])
    ]

    {_, outputs} = skill_trace(inputs)
    assert length(outputs) == 5
    assert List.last(outputs) == {:some, finish("answered", nil, "run:m:2", 2)}

    # Each cut, run again from the new state, gives the same state and the same outputs.
    states =
      Enum.scan(inputs, new!(skill_spec()), fn input, state ->
        {:Transition, next, _} = AgentLoop.step(state, input, &estimate/1)
        next
      end)

    for k <- 1..length(inputs) do
      {state, cut} = skill_trace(Enum.take(inputs, k))
      assert cut == Enum.take(outputs, k)
      assert state == Enum.at(states, k - 1)
    end

    ids = for {:some, %{"actions" => actions}} <- outputs, a <- actions, do: a["id"]
    assert Enum.count(ids, &(&1 == "run:t:0:1")) == 1
    assert Enum.count(ids, &(&1 == "run:t:1:1")) == 1
  end

  test "model_repeat_after_start_load" do
    inputs = [
      skill_start(),
      declared("run:t:0:1", guide(), nil),
      model(1, "", "tool_calls", [proposal("c1", "sk_load_skill", %{"name" => "guide"})]),
      declared("run:t:1:1", guide(), nil)
    ]

    {state, outputs} = skill_trace(inputs)
    second = List.last(outputs)
    system = %{"role" => "system", "text" => @role <> "\n\n" <> "Always cite the file."}

    assert messages(second) == [
             system,
             user("go"),
             user(notice("[declaration accepted]")),
             %{
               "role" => "assistant",
               "text" => "",
               "tool_calls" => [
                 %{"id" => "c1", "name" => "sk_load_skill", "arguments" => %{"name" => "guide"}}
               ]
             },
             tool_result("c1", notice("[declaration refused: already_loaded]"))
           ]

    assert payload(second)["tools"] == skill_tools()
    assert state.skills == [{"guide", "Always cite the file."}]
    assert length(String.split(Request.canonical(payload(second)), "Always cite the file.")) == 2
  end

  test "existing_behaviour" do
    # A plain start: model call 1 holds the start text only; no load, no note.
    {state, [first]} = skill_trace([start()])
    assert first == {:some, model_call(1, [@system, user("go")], skill_tools())}
    assert history(state) == [{:user, "run:u:1"}]
    assert state.turns == 1

    # A message with a skill member is no message, in an open loop and in an open load.
    carrying =
      payload_input(
        "message",
        skill_payload("again", %{"tool" => "sk_load_skill", "name" => "guide"})
      )

    assert {:ok, _} = PatternStep.decode(carrying)
    assert AgentLoop.step(state, carrying, &estimate/1) == {:Transition, state, :none}
    {loading, [_]} = skill_trace([skill_start()])
    assert AgentLoop.step(loading, carrying, &estimate/1) == {:Transition, loading, :none}

    # cancel and run_ended close an open load as in any phase; the load is no turn.
    for ended <- [
          input("cancel", %{"attempt_id" => "attempt-1"}),
          input("run_ended", %{"schema_id" => "test/any", "schema_version" => 1, "payload" => nil})
        ] do
      {closed, [:none]} = run(loading, [ended])
      assert closed == %{phase: :closed, id: "run", turns: 0}
    end

    # A start after the start gives no change and no request, in the skill form too.
    for later <- [skill_start(), start("again")] do
      assert AgentLoop.step(state, later, &estimate/1) == {:Transition, state, :none}
      assert AgentLoop.step(loading, later, &estimate/1) == {:Transition, loading, :none}
    end
  end

  ## Attempts (ELZ-376)

  defp attempts(extra \\ %{}),
    do: Map.merge(%{model_attempts: 2, move_on: ["throttled"], max_request_bytes: 64_512}, extra)

  defp throttled(id, extra \\ %{}),
    do: outcome(id, "refused", "elzoo.ai-text.result", Map.merge(%{"reason" => "throttled"}, extra))

  defp entry(k, reason, retry \\ nil, candidate \\ nil),
    do: %{"attempt" => k, "reason" => reason, "retry_after" => retry, "candidate" => candidate}

  defp attempt_call(id, request, entries),
    do:
      request([
        action(id, "model_call", @attempt_key, %{"request" => request, "attempts" => entries})
      ])

  defp ids({:some, %{"actions" => actions}}), do: Enum.map(actions, & &1["id"])
  defp ids(:none), do: []

  test "attempts_golden" do
    tool_turn = [
      start(),
      message("more"),
      model(1, "Working.", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", "r1"),
      model(2, "Done.", "stop", [])
    ]

    traces = [
      {[start("What is 2+2?"), model(1, "4.", "stop", [])], %{}},
      {tool_turn, %{}},
      {[start(), outcome("run:m:1", "unknown", "elzoo.run-engine.refusal", nil)], %{}},
      {[start(), throttled("run:m:1", %{"retry_after" => 30})], %{}},
      {[start(), outcome("run:m:1", "failed", "elzoo.ai-text.result", %{"reason" => "x"})], %{}},
      {Enum.take(tool_turn, 3) ++ [result("run:t:1:1", "r1")], %{turn_limit: 1}},
      {[skill_start(), declared("run:t:0:1", guide(), nil), model(1, "ok", "stop", [])],
       skill_spec()}
    ]

    for {inputs, extra} <- traces do
      {plain_state, plain} = trace(inputs, extra)
      written = Map.merge(extra, %{model_attempts: 1, image_input: false})
      {written_state, outputs} = trace(inputs, written)
      assert outputs == plain
      # The state differs only by the two spec keys written out.
      assert written_state == plain_state
      refute Map.has_key?(plain_state, :later)
    end

    # At the state bound: the defaults written out cost no byte, so new/1 accepts both.
    size = fn state ->
      byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}]))
    end

    room = 65_536 - size.(new!(%{role_instructions: ["r"]}))
    role = [String.duplicate("r", 1 + room)]
    assert {:ok, at_bound} = AgentLoop.new(spec(%{role_instructions: role}))
    assert size.(at_bound) == 65_536

    assert AgentLoop.new(spec(%{role_instructions: role, model_attempts: 1, image_input: false})) ==
             {:ok, at_bound}
  end

  test "attempt_after_throttle" do
    {_, [first]} = trace([start("What is 2+2?")], attempts())
    request = payload(first)

    refusal = throttled("run:m:1", %{"retry_after" => 30, "candidate" => "a"})
    {state, [_, second]} = trace([start("What is 2+2?"), refusal], attempts())
    assert second == {:some, attempt_call("run:m:1:2", request, [entry(1, "throttled", 30, "a")])}
    # The Attempt 1 request byte for byte: the rebuilt request equals it.
    assert payload(second)["request"] == request

    {closed, [done]} = run(state, [model("1:2", "4.", "stop", [])])
    assert done == {:some, finish("answered", nil, "run:m:1:2", 2)}
    assert closed == %{phase: :closed, id: "run", turns: 2}

    # An outcome of Attempt 1 after Attempt 2 is asked is not open: no change.
    assert AgentLoop.step(state, model(1, "4.", "stop", []), &estimate/1) ==
             {:Transition, state, :none}

    # A failed outcome with a reason in move_on moves on too; retry_after and candidate
    # that the binding did not give, or gave outside their form, are null.
    for p <- [%{}, %{"retry_after" => 86_401, "candidate" => "A"}, %{"retry_after" => "30"}] do
      failed =
        outcome("run:m:1", "failed", "elzoo.ai-text.result", Map.put(p, "reason", "throttled"))

      out = last(trace([start("What is 2+2?"), failed], attempts()))
      assert out == {:some, attempt_call("run:m:1:2", request, [entry(1, "throttled")])}
    end
  end

  test "attempt_bound" do
    spec = attempts(%{model_attempts: 3, move_on: ["overloaded", "throttled"]})

    inputs = [
      start(),
      throttled("run:m:1", %{"retry_after" => 1}),
      outcome("run:m:1:2", "refused", "elzoo.ai-text.result", %{"reason" => "overloaded"}),
      throttled("run:m:1:3")
    ]

    {closed, [first, second, third, stopped]} = trace(inputs, spec)
    request = payload(first)
    assert second == {:some, attempt_call("run:m:1:2", request, [entry(1, "throttled", 1)])}

    assert third ==
             {:some,
              attempt_call("run:m:1:3", request, [
                entry(1, "throttled", 1),
                entry(2, "overloaded")
              ])}

    assert stopped == {:some, finish("stopped", "model_call_not_completed", nil, 3)}
    assert closed.turns == 3

    # A call at the turn_limit stops turn_limit instead of asking; Attempts count, so
    # call 1 at turn_limit 2 stops after its second Attempt, not its first.
    two = [start(), throttled("run:m:1"), throttled("run:m:1:2")]
    {_, outputs} = trace(two, attempts(%{model_attempts: 3, turn_limit: 2}))
    assert Enum.map(outputs, &ids/1) == [["run:m:1"], ["run:m:1:2"], ["run:finish"]]
    assert List.last(outputs) == {:some, finish("stopped", "turn_limit", nil, 2)}

    assert last(trace([start(), throttled("run:m:1")], attempts(%{turn_limit: 1}))) ==
             {:some, finish("stopped", "turn_limit", nil, 1)}

    tool_turn = [
      start(),
      model(1, "", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", "r1")
    ]

    assert last(trace(tool_turn ++ [throttled("run:m:2")], attempts(%{turn_limit: 2}))) ==
             {:some, finish("stopped", "turn_limit", nil, 2)}

    # Each Attempt counts as one model call: after Attempt 2 of call 1, a tool turn
    # at turn_limit 2 stops turn_limit, as a second call would.
    inputs = [
      start(),
      throttled("run:m:1"),
      model("1:2", "", "tool_calls", [call("c1", "files_read")])
    ]

    assert last(trace(inputs, attempts(%{turn_limit: 2}))) ==
             {:some, finish("stopped", "turn_limit", nil, 2)}

    assert {:some, %{"actions" => [%{"kind" => "tool_call"}]}} =
             last(trace(inputs, attempts(%{turn_limit: 3})))
  end

  # A value of `levels` JSON levels, objects and arrays in turn.
  defp nest(0), do: "x"
  defp nest(levels) when rem(levels, 2) == 1, do: %{"a" => nest(levels - 1)}
  defp nest(levels), do: [nest(levels - 1)]

  defp schema_check(payload) do
    {:ok, schema} = PayloadSchema.build(@attempt_port, %{"type" => "object"})
    PayloadSchema.check(schema, @attempt_port, payload)
  end

  test "attempt_refusals" do
    stop = {:some, finish("stopped", "model_call_not_completed", nil, 1)}
    spec = attempts(%{move_on: ["throttled", "not_found"]})

    for outcome <- [
          outcome("run:m:1", "unknown", "elzoo.ai-text.result", %{"reason" => "throttled"}),
          outcome("run:m:1", "refused", "elzoo.ai-text.result", %{"reason" => "invalid_request"}),
          outcome("run:m:1", "refused", "elzoo.ai-text.result", %{"retry_after" => 30}),
          outcome("run:m:1", "refused", "elzoo.ai-text.result", nil),
          outcome("run:m:1", "refused", "elzoo.run-engine.refusal", %{"reason" => "throttled"}),
          outcome("run:m:1", "out_of_budget", "elzoo.ai-text.result", %{"reason" => "throttled"}),
          outcome("run:m:1", "refused", "elzoo.ai-text.result", %{"reason" => "overloaded"}),
          Map.put(throttled("run:m:1"), "schema_version", 2)
        ] do
      assert last(trace([start(), outcome], spec)) == stop
    end

    # A request at the engine's depth bound gets no Attempt 2; one level less does.
    deep = fn levels ->
      args = %{"q" => "x", "deep" => nest(levels)}

      [
        start(),
        model(1, "", "tool_calls", [proposal("c1", "files_read", args)]),
        result("run:t:1:1", "r1")
      ]
    end

    {_, [_, _, at_32]} = trace(deep.(26), attempts())
    {_, [_, _, at_31]} = trace(deep.(25), attempts())
    # Depth by core/payload-schema's count: 32 levels pass, one wrapper more does not.
    assert schema_check(payload(at_32)) == :ok
    assert schema_check(%{"request" => payload(at_32)}) == {:error, :too_deep}
    assert schema_check(%{"request" => payload(at_31)}) == :ok
    assert schema_check(%{"request" => %{"w" => payload(at_31)}}) == {:error, :too_deep}

    assert last(trace(deep.(26) ++ [throttled("run:m:2")], attempts())) ==
             {:some, finish("stopped", "model_call_not_completed", nil, 2)}

    # checked!/2 runs the engine's payload check on the Attempt payload.
    assert last(trace(deep.(25) ++ [throttled("run:m:2")], attempts())) ==
             {:some, attempt_call("run:m:2:2", payload(at_31), [entry(1, "throttled")])}
  end

  test "attempt_spec" do
    move = %{move_on: ["throttled"]}

    for extra <- [
          %{model_attempts: 0},
          %{model_attempts: 0, move_on: ["throttled"]},
          %{model_attempts: 5, move_on: ["throttled"]},
          %{model_attempts: "2", move_on: ["throttled"]},
          %{model_attempts: 2},
          %{model_attempts: 1, move_on: ["throttled"]},
          move,
          %{model_attempts: 2, move_on: ["throttled", "timeout"]},
          %{model_attempts: 2, move_on: ["throttled", "throttled"]},
          %{model_attempts: 2, move_on: []},
          %{model_attempts: 2, move_on: "throttled"},
          %{model_attempts: 2, move_on: ["throttled" | "overloaded"]},
          %{model_attempts: 2, move_on: [:throttled]},
          %{model_attempts: 2, move_on: ["throttled"], max_request_bytes: 64_513},
          %{image_input: nil},
          %{image_input: "true"},
          %{other: 1}
        ] do
      assert AgentLoop.new(spec(extra)) == {:error, :invalid_spec}, inspect(extra)
    end

    for reason <- ~w(timeout transport malformed_response provider_error invalid_request
                     too_large credentials_unavailable input_unavailable unsupported_feature) do
      assert AgentLoop.new(spec(attempts(%{move_on: [reason]}))) == {:error, :invalid_spec}
    end

    all = ~w(throttled overloaded authentication_failed permission_denied not_found)
    assert {:ok, _} = AgentLoop.new(spec(attempts(%{model_attempts: 4, move_on: all})))
    assert {:ok, _} = AgentLoop.new(spec(%{model_attempts: 1}))
    assert {:ok, _} = AgentLoop.new(spec(%{image_input: true}))

    # A request of 64,512 bytes, and an Attempt payload with three entries at their largest.
    spec = attempts(%{model_attempts: 4, move_on: all})
    size = fn text -> byte_size(Request.canonical(payload(last(trace([start(text)], spec))))) end
    room = 64_512 - size.("a")
    # Escaped text: each quote is one byte in the state and two in the JSON request.
    text = "a" <> String.duplicate("a", rem(room, 2)) <> String.duplicate("\"", div(room, 2))
    assert size.(text) == 64_512

    largest = %{
      "reason" => "authentication_failed",
      "retry_after" => 86_400,
      "candidate" => String.duplicate("c", 64)
    }

    inputs =
      [start(text)] ++
        for id <- ["run:m:1", "run:m:1:2", "run:m:1:3"],
            do: outcome(id, "refused", "elzoo.ai-text.result", largest)

    {_, outputs} = trace(inputs, spec)
    fourth = payload(List.last(outputs))
    assert length(fourth["attempts"]) == 3
    assert byte_size(Request.canonical(fourth["request"])) == 64_512
    # Counted by hand: 13 + 3 entries of 145 bytes and 2 commas + 12 + 64,512 + 1.
    assert byte_size(Jason.encode!(fourth)) == 64_975
  end

  test "attempt_identities" do
    inputs = [
      start(),
      message("more"),
      throttled("run:m:1"),
      model("1:2", "Working.", "tool_calls", [call("c1", "files_read")]),
      result("run:t:1:1", "r1"),
      throttled("run:m:2"),
      model("2:2", "Done.", "stop", [])
    ]

    {_, outputs} = trace(inputs, attempts())

    assert Enum.map(outputs, &ids/1) == [
             ["run:m:1"],
             [],
             ["run:m:1:2"],
             ["run:t:1:1"],
             ["run:m:2"],
             ["run:m:2:2"],
             ["run:finish"]
           ]

    [first, _, second, _, third, fourth, done] = outputs
    # The message that arrived during Attempt 1 waits until call 1 is done.
    assert payload(second)["request"] == payload(first)
    refute user("more") in messages(first)
    assert payload(fourth)["attempts"] == [entry(1, "throttled")]

    assert messages(third) == [
             @system,
             user("go"),
             %{
               "role" => "assistant",
               "text" => "Working.",
               "tool_calls" => [echo("c1", "files_read")]
             },
             tool_result("c1", block(["tool:test"], "r1")),
             user("more")
           ]

    assert payload(fourth)["request"] == payload(third)
    assert done == {:some, finish("answered", nil, "run:m:2:2", 4)}

    # The assistant entry of call 1 keeps the id of the call, not of its Attempt.
    {open, _} = trace(Enum.take(inputs, 5), attempts())
    assert {:assistant, "run:m:1"} in history(open)
  end

  ## Images (ELZ-376)

  defp ref(id, media \\ "image/png"),
    do: %{"artifact" => %{"id" => id, "version" => 1}, "media_type" => media}

  defp part(id, media \\ "image/png"),
    do: %{"type" => "image", "artifact" => %{"id" => id, "version" => 1}, "media_type" => media}

  defp with_images(kind, text, images),
    do: payload_input(kind, %{"text" => text, "images" => images})

  test "person_images" do
    images = %{image_input: true}
    binary = Base.encode64("\x89PNG")
    sha = :crypto.hash(:sha256, "\x89PNG") |> Base.encode16(case: :lower)

    image_result =
      outcome("run:t:1:1", "completed", "elzoo.agent-loop.tool-result", %{
        "content" => marked(["tool:test"], binary),
        "media_type" => "image/png",
        "encoding" => "base64"
      })

    inputs = [
      start(),
      model(1, "", "tool_calls", [call("c1", "files_read")]),
      with_images("message", "see these", [ref("img-1"), ref("img.2", "image/jpeg")]),
      image_result
    ]

    {state, [_, _, :none, store]} = trace(inputs, images)
    stored = payload(store)
    assert stored["media_type"] == "image/png" and stored["sha256"] == sha

    {state, [next]} = run(state, [receipt("run:s:1:1", stored)])

    reference =
      block(["tool:test"], "[binary result: 4 bytes, image/png; artifact a1 version 1]")

    assert messages(next) == [
             @system,
             user("go"),
             %{"role" => "assistant", "text" => "", "tool_calls" => [echo("c1", "files_read")]},
             tool_result("c1", reference),
             %{
               "role" => "user",
               "parts" => [
                 %{"type" => "text", "text" => "see these"},
                 part("img-1"),
                 part("img.2", "image/jpeg")
               ]
             }
           ]

    assert Enum.find(state.history, &(&1.id == "run:u:2")).images == [
             %{artifact_id: "img-1", version: 1, media_type: "image/png"},
             %{artifact_id: "img.2", version: 1, media_type: "image/jpeg"}
           ]

    # A start may hold images, in both start forms; an empty list adds no key.
    {_, [first]} = trace([with_images("start", "look", [ref("i1")])], images)

    assert messages(first) == [
             @system,
             %{"role" => "user", "parts" => [%{"type" => "text", "text" => "look"}, part("i1")]}
           ]

    skill_images =
      payload_input("start", %{
        "text" => "go",
        "skill" => %{"tool" => "sk_load_skill", "name" => "guide"},
        "images" => [ref("i1")]
      })

    {loading, [load]} = trace([skill_images], Map.merge(skill_spec(), images))
    assert load == {:some, load_request()}
    assert hd(loading.history).images == [%{artifact_id: "i1", version: 1, media_type: "image/png"}]

    {empty, [_]} = trace([with_images("start", "look", [])], images)
    assert hd(empty.history) == %{kind: :user, id: "run:u:1", text: "look"}

    # Malformed: images without image_input, nine images, a malformed reference.
    {open, _} = trace([start()], images)
    {plain, _} = trace([start()])

    assert AgentLoop.step(plain, with_images("message", "see", [ref("i1")]), &estimate/1) ==
             {:Transition, plain, :none}

    assert AgentLoop.step(plain, with_images("message", "see", []), &estimate/1) ==
             {:Transition, plain, :none}

    new_plain = new!(%{})

    assert AgentLoop.step(new_plain, with_images("start", "see", [ref("i1")]), &estimate/1) ==
             {:Transition, new_plain, :none}

    malformed = [
      for(k <- 1..9, do: ref("i#{k}")),
      [ref("..")],
      [ref(".")],
      [ref(String.duplicate("i", 65))],
      [ref("i/1")],
      [ref("i1", "image/svg+xml")],
      [%{"artifact" => %{"id" => "i1", "version" => 0}, "media_type" => "image/png"}],
      [Map.put(ref("i1"), "extra", 1)],
      [%{"artifact" => %{"id" => "i1", "version" => 1, "x" => 1}, "media_type" => "image/png"}],
      [ref("i1") | ref("i2")],
      "i1",
      nil
    ]

    for refs <- malformed do
      assert AgentLoop.step(open, with_images("message", "see", refs), &estimate/1) ==
               {:Transition, open, :none},
             inspect(refs)
    end

    assert {:Transition, waiting, :none} =
             AgentLoop.step(
               open,
               with_images("message", "see", for(k <- 1..8, do: ref("i#{k}"))),
               &estimate/1
             )

    assert length(List.last(waiting.waiting).images) == 8
  end
end
