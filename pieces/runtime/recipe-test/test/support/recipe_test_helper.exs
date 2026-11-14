# SPDX-License-Identifier: Apache-2.0
engine_helper = Path.expand("run_engine_test_helper.exs", __DIR__)

engine_helper =
  if File.regular?(engine_helper),
    do: engine_helper,
    else:
      Path.expand(
        "../../../../assembly/run-engine/test/support/run_engine_test_helper.exs",
        __DIR__
      )

Code.require_file(engine_helper)

defmodule Elzoo.RecipeTest do
  @moduledoc """
  Runs a recipe package against scripted model and tool results through the real
  Run engine and the real pattern Pieces, and gives back the record of every step.
  Call it inside an ExUnit test of a module that started the repository and the
  two Registries of the engine helper.
  """

  alias Elzoo.{
    AgentLoop,
    GraphRun,
    PayloadSchema,
    RecipeCheck,
    RunEngine,
    ToolRegistry,
    TypedDecision
  }

  alias Elzoo.EffectIntent.Binding
  alias Elzoo.RecipeTest.Glue
  alias Elzoo.RunEngine.TestHelper

  @keys Enum.sort(~w(package facts sources agents decisions script effects adapters input)a)
  @max_polls 2_000
  @budget_exponent 62
  @extra_schemas ~w(elzoo/ai-text-request elzoo.ai-text.result elzoo.agent-loop.message
    elzoo.agent-loop.tool-call elzoo.agent-loop.tool-result elzoo.agent-loop.result
    elzoo.graph-run.input elzoo.graph-run.call elzoo.graph-run.tool-call
    elzoo.graph-run.node-result elzoo.graph-run.result elzoo.typed-decision.result
    elzoo.recipe-test.input)
  @tool_results %{
    "elzoo.agent-loop.tool-call" => "elzoo.agent-loop.tool-result",
    "elzoo.graph-run.tool-call" => "elzoo.graph-run.node-result"
  }

  @doc "Run the recipe of `spec`; `{:ok, record}` or `{:error, reason}`."
  def run(spec) do
    with :ok <- check_shape(spec),
         {:ok, descriptors} <- check_effects(spec),
         :ok <- check_script(spec.script),
         {:ok, snapshot} <- check_sources(spec.sources),
         :ok <- check_recipe(spec, snapshot),
         :ok <- check_callables(spec),
         :ok <- check_tools(snapshot),
         :ok <- check_input(spec) do
      execute(spec, descriptors)
    end
  end

  ## Checks at start

  defp check_shape(spec) when is_map(spec) and not is_struct(spec) do
    effects = spec[:effects]

    valid? =
      Enum.sort(Map.keys(spec)) == @keys and is_map(spec.package) and is_map(spec.facts) and
        is_list(spec.sources) and maps_of_maps?(spec.agents) and maps_of_maps?(spec.decisions) and
        is_map(spec.script) and is_map(effects) and Enum.sort(Map.keys(effects)) == [:model, :tool] and
        is_atom(effects.model) and is_atom(effects.tool) and is_list(spec.adapters) and
        Enum.all?(spec.adapters, &is_atom/1)

    if valid?, do: :ok, else: {:error, :invalid_spec}
  end

  defp check_shape(_), do: {:error, :invalid_spec}

  defp maps_of_maps?(map), do: is_map(map) and Enum.all?(map, fn {_, v} -> is_map(v) end)

  defp check_effects(spec) do
    Enum.reduce_while([:model, :tool], {:ok, %{}}, fn which, {:ok, found} ->
      with {:ok, descriptor} <- Binding.load(Map.fetch!(spec.effects, which)),
           true <- descriptor.adapter in spec.adapters do
        {:cont, {:ok, Map.put(found, which, descriptor)}}
      else
        {:error, _} -> {:halt, {:error, {:invalid_binding, which}}}
        false -> {:halt, {:error, {:adapter_not_allowed, which}}}
      end
    end)
  end

  defp check_script(script) do
    invalid =
      script
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find(fn key -> not valid_entries?(key, Map.fetch!(script, key)) end)

    if invalid == nil, do: :ok, else: {:error, {:invalid_script, invalid}}
  end

  defp valid_entries?({kind, name} = key, entries)
       when kind in [:model, :tool] and is_binary(name) and is_list(entries),
       do: Enum.all?(entries, &valid_entry?(key, &1))

  defp valid_entries?(_, _), do: false

  defp valid_entry?({:model, _}, {:completed, value}), do: is_map(value) and json?(value)
  defp valid_entry?({:tool, _}, {:completed, value}), do: json?(value)

  defp valid_entry?(_, {class, reason}) when class in [:failed, :refused, :unknown],
    do: is_binary(reason) and Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, reason)

  defp valid_entry?(_, _), do: false

  defp json?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(text) when is_binary(text), do: String.valid?(text)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  defp check_sources(sources) do
    case ToolRegistry.snapshot(sources) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:sources, reason}}
    end
  end

  defp check_recipe(spec, snapshot) do
    case RecipeCheck.check(spec.package, Map.put(spec.facts, "tools", snapshot)) do
      {:ok, _} -> :ok
      {:error, :invalid_facts} -> {:error, :invalid_facts}
      {:refused, reasons} -> {:error, {:recipe_refused, reasons}}
    end
  end

  defp check_callables(spec) do
    Enum.find_value(spec.package["graph"]["callables"], :ok, fn callable ->
      name = callable["name"]

      case check_callable(spec, callable) do
        :ok -> nil
        :unbound -> {:error, {:unbound_callable, name}}
        {:invalid, reason} -> {:error, {:invalid_callable, name, reason}}
      end
    end)
  end

  defp check_callable(spec, callable) do
    case build(spec, callable, "d1", :root, :none) do
      {:ok, _} -> check_callable_forms(spec, callable)
      {:error, reason} -> reason
    end
  end

  defp check_callable_forms(_spec, %{"kind" => "decision"}), do: :ok
  defp check_callable_forms(_spec, %{"kind" => "agent"}), do: :ok

  defp check_callable_forms(spec, %{"kind" => "graph", "nodes" => nodes}) do
    kinds = Map.new(spec.package["graph"]["callables"], &{&1["name"], &1["kind"]})

    allowed = fn
      "agent" -> ["text"]
      "decision" -> ["value"]
      _ -> nil
    end

    wrong? =
      Enum.any?(nodes, fn node ->
        node["kind"] in ["call", "decision"] and
          case allowed.(kinds[node["callable"]]) do
            nil -> false
            names -> Enum.any?(node["gives"], &(&1["name"] not in names))
          end
      end)

    if wrong?, do: {:invalid, :gives}, else: :ok
  end

  defp check_tools(snapshot) do
    nested =
      snapshot
      |> ToolRegistry.tools()
      |> Enum.map(& &1["name"])
      |> Enum.sort()
      |> Enum.find(fn name ->
        match?({:resolved, %{callable: {:nested, _, _}}}, ToolRegistry.resolve(snapshot, name))
      end)

    if nested == nil, do: :ok, else: {:error, {:unsupported_tool, nested}}
  end

  defp check_input(spec) do
    valid? =
      case root(spec)["kind"] do
        "agent" -> is_binary(spec.input) and spec.input != ""
        _ -> is_map(spec.input) and json?(spec.input)
      end

    if valid?, do: :ok, else: {:error, :invalid_input}
  end

  ## The callables

  defp root(spec), do: callable(spec, spec.package["graph"]["root"])

  defp callable(spec, name),
    do: Enum.find(spec.package["graph"]["callables"], &(&1["name"] == name))

  defp target(spec, callable) do
    Enum.find_value(spec.package["graph"]["bindings"], fn binding ->
      if binding["name"] == callable["binding"], do: binding["target"]
    end)
  end

  # The Glue state of one callable. `input` is `:none` for a check or `{:input, value}`.
  defp build(spec, %{"kind" => "agent"} = callable, id, to, _input) do
    with {:ok, config} <- configured(spec.agents, target(spec, callable)),
         {:ok, inner} <-
           invalid(AgentLoop.new(Map.merge(config, %{id: id, sources: spec.sources, ask: nil}))) do
      {:ok, %{kind: :agent, to: to, inner: inner, content: nil}}
    end
  end

  defp build(spec, %{"kind" => "decision"} = callable, id, to, input) do
    with {:ok, config} <- configured(spec.decisions, target(spec, callable)),
         true <-
           Enum.sort(Map.keys(config)) == [:repairs, :request] or
             {:error, {:invalid, :invalid_spec}},
         {:ok, inner} <-
           invalid(
             TypedDecision.new(%{
               id: id,
               request: decision_request(config.request, input),
               port: callable["output"]["port"],
               answer: {:set, callable["choices"]},
               repairs: config.repairs
             })
           ),
         true <- is_binary(config.request["model"]) or {:error, {:invalid, :invalid_spec}} do
      {:ok, %{kind: :decision, to: to, inner: inner}}
    end
  end

  defp build(spec, %{"kind" => "graph", "name" => name, "nodes" => nodes}, id, to, _input) do
    maps =
      for %{"kind" => "map", "id" => node} <- nodes,
          into: %{},
          do: {node, %{concurrency: 1, on_item_failure: :fail}}

    spec = %{
      id: id,
      recipe: spec.package["graph"],
      callable: name,
      sources: spec.sources,
      maps: maps,
      max_open: 64
    }

    with {:ok, inner} <- invalid(GraphRun.new(spec)) do
      {:ok, %{kind: :graph, to: to, inner: inner}}
    end
  end

  defp configured(configs, target) do
    case Map.fetch(configs, target) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :unbound}
    end
  end

  defp invalid({:ok, state}), do: {:ok, state}
  defp invalid({:error, reason}), do: {:error, {:invalid, reason}}

  defp decision_request(request, :none), do: request

  defp decision_request(%{"messages" => messages} = request, {:input, input})
       when is_list(messages),
       do: %{request | "messages" => messages ++ [%{"role" => "user", "text" => canonical(input)}]}

  defp decision_request(request, _), do: request

  defp start_form(%{"kind" => "graph"}, _to, input),
    do: {"elzoo.graph-run.input", %{"input" => input}}

  defp start_form(%{"kind" => "agent"}, :root, input),
    do: {"elzoo.agent-loop.message", %{"text" => input}}

  defp start_form(%{"kind" => "agent"}, :node, input),
    do: {"elzoo.agent-loop.message", %{"text" => canonical(input)}}

  defp start_form(%{"kind" => "decision"}, _to, input),
    do: {"elzoo.recipe-test.input", %{"input" => input}}

  # Compact JSON with object keys in byte order.
  defp canonical(value), do: Jason.encode!(ordered(value))

  defp ordered(map) when is_map(map),
    do: %Jason.OrderedObject{
      values: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
    }

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  ## The host

  defp execute(spec, descriptors) do
    root = root(spec)
    {:ok, state} = build(spec, root, "d1", :root, {:input, spec.input})
    {schema_id, payload} = start_form(root, :root, spec.input)

    c =
      TestHelper.fixture(
        effect_bindings: %{
          "recipe-test-model" => {spec.effects.model, self()},
          "recipe-test-tool" => {spec.effects.tool, self()}
        }
      )

    engine =
      TestHelper.start(c,
        pattern: {Glue, :step, state},
        schemas: Map.merge(c.opts[:schemas], Map.new(@extra_schemas, &schema_entry/1)),
        bindings: bindings(spec, c.opts[:bindings]["finish"], descriptors),
        request_cap: 256,
        budget: %{
          cap: Integer.pow(2, @budget_exponent),
          unit: "credits",
          id: "budget",
          incarnation: "sealed"
        }
      )

    start = %{
      "type" => "input",
      "version" => 1,
      "kind" => "start",
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }

    st = %{engine: engine, c: c, script: spec.script, asked: %{}, held: %{}}

    case RunEngine.input(engine, "rt:start", start, TestHelper.verified()) do
      {:ok, :applied} -> loop(st, 0)
      reply -> {:error, {:input_refused, reply, record(st)}}
    end
  end

  defp schema_entry(id) do
    schema = %{"type" => "object"}
    port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
    {:ok, compiled} = PayloadSchema.build(port, schema)

    {{id, 1},
     %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, Jason.encode!(schema))}}
  end

  defp bindings(spec, finish, descriptors) do
    base = %{version: 1, proposal: finish.proposal}

    effect = fn id, result, which, reference ->
      Map.merge(base, %{
        id: id,
        effect_class: "publish",
        result: {result, 1},
        facts: &effect_facts(&1, which, reference, descriptors[which])
      })
    end

    nested =
      Map.merge(base, %{
        id: "recipe-test.nested.call",
        effect_class: "compute",
        result: {"elzoo.graph-run.node-result", 1},
        facts: fn action ->
          %{estimate: nested_estimate(action["id"]), unit: "credits", deadline_ms: 40_000}
        end,
        nested: &nested(spec, &1)
      })

    %{
      "finish" => finish,
      "model_call" =>
        effect.("recipe-test.model", "elzoo.ai-text.result", :model, "recipe-test-model"),
      "tool_call" => %{
        "elzoo.agent-loop.tool-call" =>
          effect.(
            "recipe-test.tool.agent",
            "elzoo.agent-loop.tool-result",
            :tool,
            "recipe-test-tool"
          ),
        "elzoo.graph-run.tool-call" =>
          effect.(
            "recipe-test.tool.graph",
            "elzoo.graph-run.node-result",
            :tool,
            "recipe-test-tool"
          )
      },
      "nested_callable" => %{"elzoo.graph-run.call" => nested}
    }
  end

  defp effect_facts(action, which, reference, descriptor) do
    key =
      case which do
        :model -> ["model", action["payload"]["model"]]
        :tool -> ["tool", action["payload"]["alias"]]
      end

    %{
      estimate: 1,
      unit: "credits",
      deadline_ms: 40_000,
      intent: %{
        identity: [
          "tenant",
          descriptor.provider_account,
          descriptor.id,
          descriptor.operation,
          action["id"]
        ],
        arguments:
          Jason.encode!(%{
            "action_id" => action["id"],
            "key" => key,
            "schema_id" => action["schema_id"]
          }),
        binding: reference,
        binding_digest: descriptor.digest,
        deadline_ms: 40_000
      }
    }
  end

  # The depth of a callable is the number after "d" in the ids of its actions.
  defp depth(action_id) do
    [_, depth] = Regex.run(~r/\Ad(\d+)/, action_id)
    String.to_integer(depth)
  end

  defp nested_estimate(action_id),
    do: Integer.pow(2, max(0, @budget_exponent - 7 * depth(action_id)))

  defp nested(spec, action) do
    hex = digest(action["id"], 24)
    child = callable(spec, action["payload"]["callable"])
    input = action["payload"]["input"]
    {:ok, state} = build(spec, child, "d#{depth(action["id"]) + 1}x" <> hex, :node, {:input, input})
    {schema_id, payload} = start_form(child, :node, input)

    %{
      budget_id: "b" <> hex,
      incarnation: "sealed",
      mfa: {Glue, :step},
      initial_state: state,
      schema_id: schema_id,
      schema_version: 1,
      payload: payload
    }
  end

  defp digest(text, length),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, length)

  ## The driver

  defp loop(st, polls) do
    st = drain(st)
    {:ok, view} = RunEngine.status(st.engine)
    occurrences = Map.new(view.slots, fn {occurrence, slot} -> {slot.action_id, occurrence} end)

    cond do
      view.reconciliation != nil ->
        {:error, {:halted, view.reconciliation, record(st)}}

      stable?(view, st, occurrences) and done?(view, st) ->
        {:ok, record(st)}

      stable?(view, st, occurrences) and st.held != %{} ->
        deliver(st, occurrences)

      polls >= @max_polls ->
        {:error, {:stalled, record(st)}}

      true ->
        Process.sleep(5)
        loop(st, polls + 1)
    end
  end

  defp drain(st) do
    receive do
      {:recipe_test_call, adapter, request} ->
        %{"action_id" => id, "key" => [kind, name], "schema_id" => schema_id} =
          Jason.decode!(request.arguments)

        key = {if(kind == "model", do: :model, else: :tool), name}
        held = Map.put(st.held, id, %{adapter: adapter, key: key, schema_id: schema_id})
        drain(%{st | held: held, asked: Map.update(st.asked, key, 1, &(&1 + 1))})
    after
      0 -> st
    end
  end

  defp stable?(view, st, occurrences) do
    Enum.all?(view.slots, fn {_, slot} ->
      slot.phase == :settled or (slot.kind == "nested_callable" and slot.phase == :running) or
        Map.has_key?(st.held, slot.action_id)
    end) and Enum.all?(st.held, fn {id, _} -> Map.has_key?(occurrences, id) end)
  end

  defp done?(view, st) do
    view.outcome != nil or
      (st.held == %{} and Enum.all?(view.slots, fn {_, slot} -> slot.phase == :settled end))
  end

  defp deliver(st, occurrences) do
    {id, held} = Enum.min_by(st.held, fn {id, _} -> Map.fetch!(occurrences, id) end)

    case Map.get(st.script, held.key, []) do
      [] ->
        {:error, {:unscripted_call, held.key, record(st)}}

      [entry | rest] ->
        {class, dispatch} = classes(entry)
        context = TestHelper.verified(%{occurrence: occurrences[id], actual: 0, dispatch: dispatch})
        input = outcome(id, held, entry, class)
        st = %{st | script: Map.put(st.script, held.key, rest), held: Map.delete(st.held, id)}

        case RunEngine.input(st.engine, "rt:" <> digest(id, 32), input, context) do
          {:ok, :applied} ->
            send(
              held.adapter,
              {:recipe_test_reply, if(class == "completed", do: :completed, else: :other)}
            )

            loop(st, 0)

          reply ->
            {:error, {:input_refused, reply, record(st)}}
        end
    end
  end

  defp classes({:completed, _}), do: {"completed", "dispatched"}
  defp classes({:failed, _}), do: {"failed", "dispatched"}
  defp classes({:refused, _}), do: {"refused", "not_dispatched"}
  defp classes({:unknown, _}), do: {"unknown", "unknown"}

  defp outcome(action_id, held, entry, class) do
    schema_id =
      case held.key do
        {:model, _} -> "elzoo.ai-text.result"
        {:tool, _} -> Map.fetch!(@tool_results, held.schema_id)
      end

    %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "action_id" => action_id,
      "outcome" => class,
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload(entry, held)
    }
  end

  defp payload({:completed, value}, %{key: {:model, _}}), do: value

  defp payload({:completed, value}, %{schema_id: "elzoo.graph-run.tool-call"}),
    do: %{"gives" => value}

  defp payload({:completed, value}, _held) do
    text = if is_binary(value), do: value, else: canonical(value)

    %{
      "content" => %{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => ["recipe-test:tool"],
        "trust" => "untrusted",
        "max_bytes" => 16_777_216,
        "content" => text
      },
      "media_type" => "text/plain",
      "encoding" => "utf8"
    }
  end

  defp payload({_, reason}, _held), do: %{"reason" => reason}

  ## The record

  defp record(st) do
    {:ok, view} = RunEngine.status(st.engine)

    %{
      outcome: view.outcome,
      steps: steps(st, 1, []),
      asked: st.asked,
      unused: for({key, [_ | _] = left} <- st.script, into: %{}, do: {key, length(left)})
    }
  end

  defp steps(st, from, acc) do
    {:ok, rows, _head} = Elzoo.DurableLog.read(st.c.store, st.c.prefix, from, 1_000)

    case rows do
      [] ->
        Enum.reverse(acc)

      _ ->
        found = for %{kind: "input"} = row <- rows, step <- step(row), do: step
        steps(st, List.last(rows).sequence + 1, Enum.reverse(found, acc))
    end
  end

  defp step(row) do
    {1, {_id, record}} = :erlang.binary_to_term(row.payload, [:safe])

    case record do
      %{kind: :protocol, input: input} ->
        [%{step: :input, input: input}]

      %{kind: :admission, occurrence: occurrence, facts: %{action: action}} ->
        [%{step: :action, occurrence: occurrence, action: action}]

      %{kind: :nested, occurrence: occurrence, facts: facts} ->
        [
          %{
            step: :nested,
            occurrence: occurrence,
            schema_id: facts.schema_id,
            schema_version: facts.schema_version,
            payload: facts.payload
          }
        ]

      _ ->
        []
    end
  end
end
