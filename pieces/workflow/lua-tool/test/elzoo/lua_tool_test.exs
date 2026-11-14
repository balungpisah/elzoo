# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaToolTest do
  use ExUnit.Case, async: true
  alias Elzoo.{LuaBinding, LuaTool, PatternStep, ToolRegistry}

  @source "return function(input) return input end"
  @policy "lua-policy-3"
  @limits %{
    "steps" => 1_000,
    "call_depth" => 8,
    "value_bytes" => 1_024,
    "memory_bytes" => 1_048_576,
    "wall_ms" => 500
  }
  @start %{"q" => 1}
  @run "elzoo.lua-tool.run"
  @run_result "elzoo.lua-tool.run-result"
  @call "elzoo.lua-tool.module-call"
  @call_result "elzoo.lua-tool.module-result"
  @finish "elzoo.lua-tool.result"
  @sandbox_runtime %{"lua" => "5.4", "seed" => 7}
  @bound 65_536
  @half String.duplicate("h", 30_000)

  # Fixtures: literal neutral maps

  defp port(name, direction),
    do: %{
      "id" => name <> "_" <> direction,
      "direction" => direction,
      "schema_id" => "elzoo.test." <> name,
      "schema_version" => 1
    }

  defp manifest(name),
    do: %{
      "name" => name,
      "version" => 1,
      "description" => "Function " <> name,
      "arguments" => %{
        "port" => port(name, "input"),
        "schema" => %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      "result" => %{
        "port" => port(name, "output"),
        "schema" => %{
          "type" => "object",
          "properties" => %{"count" => %{"type" => "integer"}, "text" => %{"type" => "string"}},
          "required" => ["count"],
          "additionalProperties" => false
        }
      },
      "cost" => %{"unit" => "call", "estimate" => 1},
      "permissions" => ["read"]
    }

  defp bindings(names \\ ["alpha", "beta"]) do
    declaration = Enum.map(names, &%{"name" => &1, "version" => 1})
    {:ok, bindings} = LuaBinding.resolve(declaration, Enum.map(names, &manifest/1))
    bindings
  end

  defp sources(bindings, id \\ "lua") do
    {:ok, source} = LuaBinding.source(bindings, id)
    [source]
  end

  defp spec(overrides \\ %{}) do
    bindings = bindings()

    Map.merge(
      %{
        id: "tool",
        source: @source,
        policy: @policy,
        limits: @limits,
        bindings: bindings,
        sources: sources(bindings),
        source_id: "lua",
        max_calls: 8
      },
      overrides
    )
  end

  defp new!(overrides \\ %{}) do
    assert {:ok, state} = LuaTool.new(spec(overrides))
    state
  end

  defp version(tool) do
    {:ok, snapshot} = ToolRegistry.snapshot(sources(bindings()))
    assert {:resolved, %{version: version}} = ToolRegistry.resolve(snapshot, "lua_" <> tool)
    version
  end

  defp input(kind, fields \\ %{}),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, fields)

  defp start(payload \\ %{"input" => @start}, schema \\ "elzoo.lua-tool.input"),
    do: input("start", %{"schema_id" => schema, "schema_version" => 1, "payload" => payload})

  defp outcome(id, class, schema, payload, schema_version \\ 1),
    do:
      input("action_outcome", %{
        "action_id" => id,
        "outcome" => class,
        "schema_id" => schema,
        "schema_version" => schema_version,
        "payload" => payload
      })

  defp run_done(n, payload), do: outcome("tool:r:#{n}", "completed", @run_result, payload)
  defp call_done(k, payload), do: outcome("tool:c:#{k}", "completed", @call_result, payload)

  defp pending(n, index, name, arguments),
    do:
      run_done(n, %{
        "pending_call" => %{"index" => index, "name" => name, "arguments" => arguments}
      })

  defp ok(n, value),
    do:
      run_done(n, %{
        "ok" => %{"value" => value, "identity" => "id-1", "runtime" => @sandbox_runtime}
      })

  defp request(id, kind, schema, payload),
    do: %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => id,
          "kind" => kind,
          "schema_id" => schema,
          "schema_version" => 1,
          "payload" => payload
        }
      ]
    }

  defp run_request(n, recorded, input \\ @start),
    do:
      request("tool:r:#{n}", "local_work", @run, %{
        "source" => @source,
        "input" => input,
        "policy" => @policy,
        "limits" => @limits,
        "calls" => %{"mode" => "replay", "names" => ["alpha", "beta"], "recorded" => recorded}
      })

  defp call_request(k, tool, arguments),
    do:
      request("tool:c:#{k}", "tool_call", @call, %{
        "alias" => "lua_" <> tool,
        "source" => "lua",
        "tool" => tool,
        "version" => version(tool),
        "arguments" => arguments
      })

  defp finish_request(payload), do: request("tool:finish", "finish", @finish, payload)

  defp failed(reason, detail, action_id),
    do:
      finish_request(%{
        "status" => "failed",
        "reason" => reason,
        "detail" => detail,
        "action_id" => action_id,
        "result" => nil
      })

  defp completed(value, action_id),
    do:
      finish_request(%{
        "status" => "completed",
        "reason" => nil,
        "detail" => nil,
        "action_id" => action_id,
        "result" => value
      })

  defp record(name, query, count),
    do: %{"name" => name, "arguments" => %{"query" => query}, "result" => %{"count" => count}}

  # One step; every request passes PatternStep.decode/1.
  defp step!(state, input) do
    {:Transition, next, request} = LuaTool.step(state, input)

    case request do
      :none -> :ok
      {:some, request} -> assert {:ok, _} = PatternStep.decode(request)
    end

    {next, request}
  end

  defp fold(state, inputs) do
    {_, steps} =
      Enum.reduce(inputs, {state, []}, fn input, {state, steps} ->
        {next, request} = step!(state, input)
        {next, steps ++ [{next, request}]}
      end)

    steps
  end

  defp requests(steps), do: for({_, {:some, request}} <- steps, do: request)

  defp ids(requests),
    do: for(%{"actions" => [%{"id" => id}]} <- requests, do: id)

  defp assert_no_change(state, input),
    do: assert({:Transition, ^state, :none} = LuaTool.step(state, input))

  # The trace of group 2: run 1, call 0, run 2, call 1, run 3, finish.
  defp two_calls do
    inputs = [
      start(),
      pending(1, 0, "alpha", %{"query" => "a"}),
      call_done(0, %{"result" => %{"count" => 1}}),
      pending(2, 1, "beta", %{"query" => "b"}),
      call_done(1, %{"result" => %{"count" => 2}}),
      ok(3, %{"answer" => 3})
    ]

    r1 = record("alpha", "a", 1)
    r2 = record("beta", "b", 2)

    expected = [
      run_request(1, []),
      call_request(0, "alpha", %{"query" => "a"}),
      run_request(2, [r1]),
      call_request(1, "beta", %{"query" => "b"}),
      run_request(3, [r1, r2]),
      completed(%{"answer" => 3}, "tool:r:3")
    ]

    {inputs, expected}
  end

  # Group 1

  test "no_module_call" do
    state = new!()
    assert state |> then(&step!(&1, start())) |> elem(1) == {:some, run_request(1, [])}

    steps = fold(state, [start(), ok(1, %{"answer" => 42})])

    assert requests(steps) == [run_request(1, []), completed(%{"answer" => 42}, "tool:r:1")]
    assert {%{phase: :closed}, _} = List.last(steps)
  end

  # Group 2

  test "two_module_calls_in_order" do
    {inputs, expected} = two_calls()
    steps = fold(new!(), inputs)

    assert requests(steps) == expected
    assert length(steps) == 6
    # One action in each request, in this order.
    assert Enum.all?(requests(steps), &(length(&1["actions"]) == 1))

    assert ids(requests(steps)) ==
             ["tool:r:1", "tool:c:0", "tool:r:2", "tool:c:1", "tool:r:3", "tool:finish"]
  end

  # Group 3

  test "restart_between_calls" do
    {inputs, expected} = two_calls()
    full = fold(new!(), inputs)
    assert requests(full) == expected

    for cut <- 0..length(inputs) do
      {head, tail} = Enum.split(inputs, cut)
      # Folded again from the start: the same states and requests.
      again = fold(new!(), head)
      assert again == Enum.take(full, cut)

      # Folded from the state after the cut: the same rest and the same result.
      state = if cut == 0, do: new!(), else: again |> List.last() |> elem(0)
      rest = fold(state, tail)
      assert again ++ rest == full
      assert requests(again ++ rest) == expected
    end

    # No action identity appears in two requests.
    all = ids(requests(full))
    assert all == Enum.uniq(all)
  end

  # Group 4

  describe "call_order_differs" do
    test "an index that is not the record length is call_mismatch" do
      steps =
        fold(new!(), [
          start(),
          pending(1, 1, "alpha", %{"query" => "a"})
        ])

      assert requests(steps) == [run_request(1, []), failed("call_mismatch", nil, "tool:r:1")]
      assert {%{phase: :closed}, _} = List.last(steps)

      # After one recorded call, index 0 again is a mismatch too.
      steps =
        fold(new!(), [
          start(),
          pending(1, 0, "alpha", %{"query" => "a"}),
          call_done(0, %{"result" => %{"count" => 1}}),
          pending(2, 0, "alpha", %{"query" => "a"})
        ])

      assert List.last(requests(steps)) == failed("call_mismatch", nil, "tool:r:2")
    end

    test "a sandbox refusal call_mismatch is sandbox_refused with the detail" do
      steps = fold(new!(), [start(), run_done(1, %{"refused" => "call_mismatch"})])

      assert requests(steps) ==
               [run_request(1, []), failed("sandbox_refused", "call_mismatch", "tool:r:1")]
    end
  end

  # Group 5

  describe "undeclared_and_wrong_arguments" do
    test "a name outside the bindings is call_mismatch" do
      steps = fold(new!(), [start(), pending(1, 0, "gamma", %{"query" => "a"})])
      assert List.last(requests(steps)) == failed("call_mismatch", nil, "tool:r:1")
    end

    test "a registry tool that is not a binding is call_mismatch" do
      # The source holds one more function than the bindings of the spec.
      extra = sources(bindings(["alpha", "beta", "gamma"]))
      state = new!(%{sources: extra})
      steps = fold(state, [start(), pending(1, 0, "gamma", %{"query" => "a"})])

      assert requests(steps) == [run_request(1, []), failed("call_mismatch", nil, "tool:r:1")]
      assert {%{phase: :closed}, _} = List.last(steps)
    end

    test "arguments that the schema refuses are invalid_arguments, with no action and no value" do
      secret = "SENTINEL-arguments-value"

      for arguments <- [%{"query" => 5, "x" => secret}, %{"other" => secret}, [secret], secret] do
        steps = fold(new!(), [start(), pending(1, 0, "alpha", arguments)])
        assert requests(steps) == [run_request(1, []), failed("invalid_arguments", nil, "tool:r:1")]
        refute inspect(requests(steps)) =~ secret
        assert {%{phase: :closed} = state, _} = List.last(steps)
        refute inspect(state) =~ secret
      end
    end

    test "a module result that the schema refuses is invalid_module_result" do
      for result <- [%{"count" => "many"}, %{}, %{"count" => 1, "extra" => true}, [1]] do
        steps =
          fold(new!(), [
            start(),
            pending(1, 0, "alpha", %{"query" => "a"}),
            call_done(0, %{"result" => result})
          ])

        assert List.last(requests(steps)) == failed("invalid_module_result", nil, "tool:r:1")
        assert {%{phase: :closed}, _} = List.last(steps)
        assert length(requests(steps)) == 3
      end

      # The action before it is the last module result that was accepted.
      steps =
        fold(new!(), [
          start(),
          pending(1, 0, "alpha", %{"query" => "a"}),
          call_done(0, %{"result" => %{"count" => 1}}),
          pending(2, 1, "beta", %{"query" => "b"}),
          call_done(1, %{"result" => %{"count" => "x"}})
        ])

      assert List.last(requests(steps)) == failed("invalid_module_result", nil, "tool:r:2")
    end
  end

  # Group 6

  describe "sandbox_stops_are_tool_failures" do
    test "refused steps and host_outcome wall_time give a failed finish with the detail" do
      steps = fold(new!(), [start(), run_done(1, %{"refused" => "steps"})])

      assert requests(steps) ==
               [run_request(1, []), failed("sandbox_refused", "steps", "tool:r:1")]

      steps = fold(new!(), [start(), run_done(1, %{"host_outcome" => "wall_time"})])

      assert requests(steps) ==
               [run_request(1, []), failed("sandbox_host_outcome", "wall_time", "tool:r:1")]
    end

    test "a run outcome of class failed, unknown or expired is run_not_completed" do
      for class <- ["failed", "unknown", "expired"] do
        state = new!()
        {running, {:some, _}} = step!(state, start())

        {closed, {:some, request}} =
          step!(running, outcome("tool:r:1", class, @run_result, %{"refused" => "steps"}))

        assert request == failed("run_not_completed", nil, nil)
        assert closed.phase == :closed

        # No second run, also for a completed result of the same action that arrives later.
        assert_no_change(closed, ok(1, 1))
        assert_no_change(closed, start())
      end
    end

    test "no run follows a failed run after a module call" do
      steps =
        fold(new!(), [
          start(),
          pending(1, 0, "alpha", %{"query" => "a"}),
          call_done(0, %{"result" => %{"count" => 1}}),
          outcome("tool:r:2", "unknown", @run_result, %{"ok" => %{}})
        ])

      assert ids(requests(steps)) == ["tool:r:1", "tool:c:0", "tool:r:2", "tool:finish"]
      assert List.last(requests(steps)) == failed("run_not_completed", nil, "tool:c:0")
    end
  end

  # Group 7

  describe "module_call_not_completed" do
    defp calling do
      {state, {:some, _}} = step!(new!(), start())
      {state, {:some, _}} = step!(state, pending(1, 0, "alpha", %{"query" => "a"}))
      state
    end

    test "each outcome class other than completed ends the tool as failed" do
      for class <- ~w(failed refused unknown out_of_budget retries_exhausted expired resource_lost) do
        {closed, {:some, request}} =
          step!(calling(), outcome("tool:c:0", class, @call_result, %{"result" => %{"count" => 1}}))

        assert request == failed("module_call_not_completed", nil, "tool:r:1")
        assert closed.phase == :closed
      end
    end

    test "unknown starts no second call and no second run" do
      {closed, {:some, request}} =
        step!(calling(), outcome("tool:c:0", "unknown", @call_result, %{}))

      assert request == failed("module_call_not_completed", nil, "tool:r:1")
      assert_no_change(closed, call_done(0, %{"result" => %{"count" => 1}}))
      assert_no_change(closed, pending(1, 1, "alpha", %{"query" => "a"}))
      assert_no_change(closed, start())
    end

    test "a late outcome is no change and the call stays open" do
      state = calling()
      late = outcome("tool:c:0", "late", @call_result, %{"result" => %{"count" => 1}})
      assert_no_change(state, late)
      assert {_, {:some, request}} = step!(state, call_done(0, %{"result" => %{"count" => 1}}))
      assert request == run_request(2, [record("alpha", "a", 1)])
    end
  end

  # Group 8

  describe "limits_and_closed" do
    test "max_calls 0 with a pending call is call_limit; a source without a call completes" do
      state = new!(%{max_calls: 0})

      steps = fold(state, [start(), pending(1, 0, "alpha", %{"query" => "a"})])
      assert List.last(requests(steps)) == failed("call_limit", nil, "tool:r:1")

      steps = fold(state, [start(), ok(1, "fine")])
      assert List.last(requests(steps)) == completed("fine", "tool:r:1")
    end

    test "with max_calls n, call n-1 is asked for and call n is call_limit" do
      steps =
        fold(new!(%{max_calls: 2}), [
          start(),
          pending(1, 0, "alpha", %{"query" => "a"}),
          call_done(0, %{"result" => %{"count" => 1}}),
          pending(2, 1, "beta", %{"query" => "b"}),
          call_done(1, %{"result" => %{"count" => 2}}),
          pending(3, 2, "alpha", %{"query" => "c"})
        ])

      assert requests(steps) |> Enum.at(3) == call_request(1, "beta", %{"query" => "b"})
      assert List.last(requests(steps)) == failed("call_limit", nil, "tool:r:3")
      assert length(requests(steps)) == 6
    end

    test "state_over_bound from a large start input" do
      big = String.duplicate("x", @bound + 1)

      assert {_, {:some, request}} = step!(new!(), start(%{"input" => big}))
      assert request == failed("state_over_bound", nil, nil)

      # The input alone fits.
      assert {_, {:some, request}} = step!(new!(), start(%{"input" => @half}))
      assert request == run_request(1, [], @half)
    end

    test "state_over_bound from large pending arguments" do
      # The schema check allows 65,536 bytes: the arguments fit it, the state with the input does not.
      big = %{"query" => String.duplicate("x", 40_000)}
      {state, {:some, _}} = step!(new!(), start(%{"input" => @half}))
      assert {closed, {:some, request}} = step!(state, pending(1, 0, "alpha", big))
      assert request == failed("state_over_bound", nil, "tool:r:1")
      assert closed == %{phase: :closed, id: "tool"}
      assert_no_change(closed, start())
    end

    test "state_over_bound from a large module result" do
      big = %{"count" => 1, "text" => String.duplicate("x", 40_000)}

      steps =
        fold(new!(), [
          start(%{"input" => @half}),
          pending(1, 0, "alpha", %{"query" => "a"}),
          call_done(0, %{"result" => big})
        ])

      assert List.last(requests(steps)) == failed("state_over_bound", nil, "tool:c:0")
      assert {%{phase: :closed}, _} = List.last(steps)
    end

    test "each refusal of new/1" do
      good = spec()
      assert {:ok, _} = LuaTool.new(good)

      invalid = fn spec -> assert LuaTool.new(spec) == {:error, :invalid_spec} end

      for bad <- [nil, [], "spec", %URI{}, Map.delete(good, :id), Map.put(good, :extra, 1)],
          do: invalid.(bad)

      overrides = [
        id: "",
        id: "a:b",
        id: String.duplicate("a", 65),
        id: <<255>>,
        id: :atom,
        source: 1,
        source: <<255>>,
        policy: "",
        policy: :policy,
        limits: nil,
        limits: Map.delete(@limits, "wall_ms"),
        limits: Map.put(@limits, "extra", 1),
        limits: %{@limits | "steps" => 0},
        limits: %{@limits | "steps" => 1.5},
        limits: Map.new(@limits, fn {k, v} -> {String.to_atom(k), v} end),
        bindings: nil,
        bindings: %{},
        bindings: {:LuaBinding, :nope},
        source_id: :lua,
        source_id: nil,
        max_calls: -1,
        max_calls: 257,
        max_calls: "1",
        max_calls: 1.0
      ]

      for {key, value} <- overrides, do: invalid.(Map.put(good, key, value))

      assert {:ok, _} = LuaTool.new(spec(%{id: String.duplicate("a", 64), max_calls: 256}))
      assert {:ok, _} = LuaTool.new(spec(%{max_calls: 0}))

      # The registry refuses the sources: its reason, unchanged.
      assert LuaTool.new(spec(%{sources: :nope})) == {:error, {:sources, :invalid_source}}
      assert LuaTool.new(spec(%{sources: [%{}]})) == {:error, {:sources, :invalid_source}}

      # A name of the bindings that has no tool under the source id: the first, sorted.
      assert LuaTool.new(spec(%{source_id: "other"})) == {:error, {:unbound_function, "alpha"}}

      only_beta = sources(bindings(["beta"]))
      assert LuaTool.new(spec(%{sources: only_beta})) == {:error, {:unbound_function, "alpha"}}

      only_alpha = sources(bindings(["alpha"]))
      assert LuaTool.new(spec(%{sources: only_alpha})) == {:error, {:unbound_function, "beta"}}

      # A first state over the bound.
      assert LuaTool.new(spec(%{source: String.duplicate("x", @bound)})) ==
               {:error, :state_too_large}
    end

    test "a start in another form is the finish invalid_input" do
      forms = [
        start(%{"input" => 1, "extra" => 2}),
        start(%{}),
        start(%{"value" => 1}),
        start("input"),
        start(%{"input" => :atom}),
        start(%{"input" => <<255>>}),
        start(%{"input" => %{1 => 2}}),
        start(%{"input" => 1}, "elzoo.lua-tool.other"),
        input("start", %{
          "schema_id" => "elzoo.lua-tool.input",
          "schema_version" => 2,
          "payload" => %{"input" => 1}
        })
      ]

      for form <- forms do
        assert {closed, {:some, request}} = step!(new!(), form)
        assert request == failed("invalid_input", nil, nil)
        assert closed.phase == :closed
      end

      # A null input is a plain value.
      assert {_, {:some, request}} = step!(new!(), start(%{"input" => nil}))
      assert request == run_request(1, [], nil)
    end

    test "a completed outcome under another schema is another form" do
      {running, {:some, _}} = step!(new!(), start())
      payload = %{"ok" => %{"value" => 1, "identity" => "i", "runtime" => %{}}}

      for {schema, version} <- [{"elzoo.lua-tool.other", 1}, {@run_result, 2}, {@call_result, 1}] do
        assert {_, {:some, request}} =
                 step!(running, outcome("tool:r:1", "completed", schema, payload, version))

        assert request == failed("run_not_completed", nil, nil)
      end

      calling = calling()

      for {schema, version} <- [{"elzoo.lua-tool.other", 1}, {@call_result, 2}, {@run_result, 1}] do
        assert {_, {:some, request}} =
                 step!(
                   calling,
                   outcome("tool:c:0", "completed", schema, %{"result" => %{"count" => 1}}, version)
                 )

        assert request == failed("module_call_not_completed", nil, "tool:r:1")
      end
    end

    test "a run payload in another form is run_not_completed" do
      ok = %{"value" => 1, "identity" => "i", "runtime" => %{}}
      call = %{"index" => 0, "name" => "alpha", "arguments" => %{"query" => "a"}}

      forms = [
        %{},
        %{"ok" => ok, "refused" => "steps"},
        %{"ok" => Map.delete(ok, "runtime")},
        %{"ok" => Map.put(ok, "extra", 1)},
        %{"pending_call" => Map.put(call, "extra", 1)},
        %{"pending_call" => %{call | "index" => -1}},
        %{"pending_call" => %{call | "index" => 0.0}},
        %{"pending_call" => %{call | "name" => ""}},
        %{"pending_call" => %{call | "name" => :alpha}},
        %{"pending_call" => Map.delete(call, "arguments")},
        %{"refused" => ""},
        %{"refused" => :steps},
        %{"host_outcome" => nil},
        %{"host_outcome" => <<255>>},
        %{"unknown" => "steps"},
        "ok",
        nil
      ]

      for form <- forms do
        {running, {:some, _}} = step!(new!(), start())
        assert {_, {:some, request}} = step!(running, run_done(1, form))
        assert request == failed("run_not_completed", nil, nil)
      end
    end

    test "a module payload in another form is module_call_not_completed" do
      for form <- [%{}, %{"result" => 1, "extra" => 2}, %{"value" => 1}, 1, %{"result" => :atom}] do
        assert {_, {:some, request}} = step!(calling(), call_done(0, form))
        assert request == failed("module_call_not_completed", nil, "tool:r:1")
      end
    end

    test "a binding name of 64 characters resolves through its cut alias" do
      long = "f" <> String.duplicate("a", 63)
      assert String.match?(long, ~r/\A[a-z][a-z0-9_]{63}\z/)
      bound = bindings([long])
      state = new!(%{bindings: bound, sources: sources(bound)})

      {running, {:some, run}} = step!(state, start())
      assert run["actions"] |> hd() |> get_in(["payload", "calls", "names"]) == [long]

      assert {_, {:some, request}} = step!(running, pending(1, 0, long, %{"query" => "a"}))
      assert %{"actions" => [%{"kind" => "tool_call", "payload" => payload}]} = request
      assert payload["tool"] == long and payload["source"] == "lua"
      assert payload["alias"] != "lua_" <> long and byte_size(payload["alias"]) <= 64

      {:ok, snapshot} = ToolRegistry.snapshot(sources(bound))
      assert {:resolved, tool} = ToolRegistry.resolve(snapshot, payload["alias"])
      assert tool.tool == long and tool.version == payload["version"]
    end

    test "cancel and run_ended close the step" do
      cancel = input("cancel", %{"attempt_id" => "attempt-1"})

      ended =
        input("run_ended", %{
          "schema_id" => "elzoo.test.ended",
          "schema_version" => 1,
          "payload" => %{}
        })

      {running, _} = step!(new!(), start())
      starts = [new!(), running, calling()]

      for state <- starts, closer <- [cancel, ended] do
        assert {closed, :none} = step!(state, closer)
        assert closed.phase == :closed

        for later <- [
              start(),
              ok(1, 1),
              cancel,
              ended,
              call_done(0, %{"result" => %{"count" => 1}})
            ],
            do: assert_no_change(closed, later)
      end
    end

    test "each input of the no-change row" do
      typed = %{"schema_id" => "elzoo.test.event", "schema_version" => 1, "payload" => %{}}
      {running, _} = step!(new!(), start())
      calling = calling()

      others = [
        input("message", typed),
        input("wake"),
        input("resource_event", typed),
        input(
          "person_answer",
          Map.merge(typed, %{"action_id" => "tool:r:1", "person_id" => "p-1"})
        ),
        start(),
        outcome("tool:r:1", "late", @run_result, %{"refused" => "steps"}),
        outcome("tool:c:0", "late", @call_result, %{"result" => %{"count" => 1}}),
        outcome("tool:r:9", "completed", @run_result, %{"refused" => "steps"}),
        outcome("tool:other", "completed", @call_result, %{"result" => %{"count" => 1}}),
        outcome("tool:finish", "completed", @run_result, %{"refused" => "steps"}),
        %{},
        nil,
        "start",
        %{"type" => "input", "version" => 2, "kind" => "wake", "at_ms" => 0},
        input("wake", %{"payload" => "extra"}),
        input("action_outcome", %{"action_id" => "tool:r:1", "outcome" => "bogus"})
      ]

      for input <- others do
        assert_no_change(running, input)
        assert_no_change(calling, input)
      end

      # A second start in the running phase and an outcome in the new phase.
      assert_no_change(new!(), ok(1, 1))
      assert_no_change(new!(), input("wake"))

      # A settled run outcome is a late one: no change, no second request.
      {closed, _} = step!(running, ok(1, 1))
      assert_no_change(closed, ok(1, 2))

      {after_call, {:some, _}} = step!(calling, call_done(0, %{"result" => %{"count" => 1}}))
      assert_no_change(after_call, call_done(0, %{"result" => %{"count" => 5}}))
      assert_no_change(after_call, outcome("tool:c:0", "failed", @call_result, %{}))
    end
  end

  # Group 9

  describe "forms_agree" do
    # A literal sandbox request (ELZ-177) and its string form.
    @sandbox_request %{
      source: @source,
      input: %{"q" => 1},
      policy: @policy,
      limits: %{
        steps: 1_000,
        call_depth: 8,
        value_bytes: 1_024,
        memory_bytes: 1_048_576,
        wall_ms: 500
      },
      calls: %{
        mode: "replay",
        names: ["alpha", "beta"],
        recorded: [
          %{name: "alpha", arguments: %{"query" => "a"}, result: %{"count" => 1}},
          %{name: "beta", arguments: %{"query" => "b"}, result: %{"count" => 2}}
        ]
      }
    }

    defp stringify(map) when is_map(map),
      do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

    defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
    defp stringify(value), do: value

    test "the run payload equals a literal request of the sandbox, member for member" do
      {inputs, _} = two_calls()
      steps = fold(new!(), Enum.take(inputs, 5))
      %{"actions" => [%{"kind" => "local_work", "payload" => payload}]} = List.last(requests(steps))

      assert payload == stringify(@sandbox_request)
      assert Enum.sort(Map.keys(payload)) == ~w(calls input limits policy source)
      assert Enum.sort(Map.keys(payload["calls"])) == ~w(mode names recorded)
      assert payload["calls"]["mode"] == "replay"
      assert payload["calls"]["names"] == Enum.sort(payload["calls"]["names"])
      assert Enum.sort(Map.keys(payload["limits"])) == Enum.sort(Map.keys(@limits))
    end

    test "256 records are the most, as in the sandbox" do
      many =
        for k <- 0..255 do
          [
            pending(k + 1, k, "alpha", %{"query" => "q"}),
            call_done(k, %{"result" => %{"count" => k}})
          ]
        end
        |> List.flatten()

      steps = fold(new!(%{max_calls: 256}), [start() | many])
      %{"actions" => [%{"payload" => payload}]} = List.last(requests(steps))
      assert length(payload["calls"]["recorded"]) == 256

      {state, _} = List.last(steps)
      assert {_, {:some, request}} = step!(state, pending(257, 256, "alpha", %{"query" => "q"}))
      assert request == failed("call_limit", nil, "tool:r:257")
    end

    test "each run-result form equals a literal string form of one reply" do
      replies = [
        {{:ok, %{value: [1, %{"a" => nil}], identity: "id-1", runtime: %{lua: "5.4", seed: 7}}},
         %{
           "ok" => %{
             "value" => [1, %{"a" => nil}],
             "identity" => "id-1",
             "runtime" => %{"lua" => "5.4", "seed" => 7}
           }
         }},
        {{:pending_call, %{index: 0, name: "alpha", arguments: %{"query" => "a"}}},
         %{"pending_call" => %{"index" => 0, "name" => "alpha", "arguments" => %{"query" => "a"}}}},
        {{:refused, :steps}, %{"refused" => "steps"}},
        {{:host_outcome, :wall_time}, %{"host_outcome" => "wall_time"}}
      ]

      for {reply, literal} <- replies do
        string_form =
          case reply do
            {:ok, map} -> %{"ok" => stringify(map)}
            {:pending_call, map} -> %{"pending_call" => stringify(map)}
            {class, reason} -> %{Atom.to_string(class) => Atom.to_string(reason)}
          end

        assert string_form == literal
      end

      # The step reads each of the four forms.
      [ok, pending, refused, host] = Enum.map(replies, &elem(&1, 1))
      read = fn form -> fold(new!(), [start(), run_done(1, form)]) |> requests() |> List.last() end

      assert read.(ok) == completed([1, %{"a" => nil}], "tool:r:1")
      assert read.(pending) == call_request(0, "alpha", %{"query" => "a"})
      assert read.(refused) == failed("sandbox_refused", "steps", "tool:r:1")
      assert read.(host) == failed("sandbox_host_outcome", "wall_time", "tool:r:1")
    end
  end

  test "checked_example" do
    {result, _} = Code.eval_file(Path.expand("../../examples/lua_tool.exs", __DIR__))

    assert result == %{
             actions: ["local_work", "tool_call", "local_work", "finish"],
             status: "completed",
             action_id: "demo:r:2",
             result: %{"total" => 3}
           }
  end

  # Not a group: the state is plain data within the bound after every transition.
  test "state_is_plain_data" do
    {inputs, _} = two_calls()
    state = new!()
    assert_plain(state)

    for {next, _} <- fold(state, inputs), do: assert_plain(next)
  end

  defp assert_plain(state) do
    assert plain?(state), "the state is not plain data"

    assert byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])) <=
             @bound
  end

  defp plain?(x) when is_atom(x) or is_number(x) or is_binary(x), do: true
  defp plain?(x) when is_list(x), do: Enum.all?(x, &plain?/1)
  defp plain?(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.all?(&plain?/1)

  defp plain?(x) when is_map(x) and not is_struct(x),
    do: Enum.all?(x, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(_), do: false
end
