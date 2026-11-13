# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AgentLoop do
  @moduledoc """
  The agent loop as one pure pattern step: a model proposes tool calls, the step
  resolves them through its registry snapshot, puts all calls of one model turn in
  one request, bounds each result and builds each model request. No model call,
  tool call, clock, storage or process. See the bundle README for the state form.
  """
  alias Elzoo.{PatternStep, PromptAssembly, ToolRegistry, ToolResultLimit}

  @spec_keys [
    :id,
    :model,
    :max_output_tokens,
    :role_instructions,
    :window,
    :max_request_bytes,
    :max_image_refs,
    :sources,
    :result_limits,
    :ask,
    :turn_limit
  ]
  @build_keys [
    :model,
    :max_output_tokens,
    :role_instructions,
    :window,
    :max_request_bytes,
    :max_image_refs
  ]
  @state_bound 65_536
  @instruction_bound 16_384
  @mark_bound 65_536
  @max_calls 64
  @tags ~w(undeclared_tool schema_mismatch not_an_object invalid_json)
  @finishes ~w(stop length tool_calls content_filter refusal)
  @kinds %{"pinned_skill" => :PinnedSkill, "host_listing" => :HostListing, "other" => :Other}
  @alias ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  @reason ~r/\A[a-z0-9_]{1,64}\z/

  @message_key "elzoo.agent-loop.message"
  @answer_key "elzoo.agent-loop.answer"
  @result_key "elzoo.agent-loop.tool-result"
  @model_result_key "elzoo.ai-text.result"

  @doc """
  Checks a spec; `{:ok, state}` or `{:error, :invalid_spec | {:sources, reason} |
  :state_too_large}`.
  """
  def new(spec) do
    with true <- spec?(spec) || {:error, :invalid_spec},
         {:ok, snapshot} <- snapshot(spec.sources),
         true <- ask?(snapshot, spec.ask) || {:error, :invalid_spec} do
      state = %{
        phase: :new,
        spec: Map.delete(spec, :sources),
        snapshot: snapshot,
        skills: [],
        history: [],
        waiting: [],
        users: 0,
        turns: 0,
        open: nil
      }

      if size(state) <= @state_bound, do: {:ok, state}, else: {:error, :state_too_large}
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  One `core/operator` transition over a neutral `Elzoo.PatternStep` input map:
  `{:Transition, new_state, :none | {:some, request}}`. `estimate` is the function
  that `Elzoo.PromptAssembly.build/2` takes; it is never stored.
  """
  def step(state, input, estimate) do
    case PatternStep.decode(input) do
      {:ok, checked} -> bounded(state, transition(state, input, checked, estimate))
      _ -> unchanged(state)
    end
  end

  # A transition never returns a state over the bound: it closes with state_over_bound.
  defp bounded(state, {:Transition, next, _} = result) do
    if size(next) <= @state_bound, do: result, else: stop(state, "state_over_bound")
  end

  ## The step table

  defp transition(%{phase: :closed} = state, _, _, _), do: unchanged(state)

  defp transition(state, %{"kind" => kind}, _, _) when kind in ["cancel", "run_ended"],
    do: {:Transition, closed(state), :none}

  defp transition(%{phase: :new} = state, %{"kind" => "start"} = input, _, estimate) do
    case message(input) do
      {:ok, text} -> state |> arrive(text) |> flush() |> model_call(estimate)
      :error -> unchanged(state)
    end
  end

  defp transition(%{phase: phase} = state, %{"kind" => "message"} = input, _, _)
       when phase != :new do
    case message(input) do
      {:ok, text} -> {:Transition, arrive(state, text), :none}
      :error -> unchanged(state)
    end
  end

  defp transition(%{phase: phase} = state, %{"kind" => kind} = input, checked, estimate)
       when phase in [:model, :tools, :stores] and kind in ["action_outcome", "person_answer"] do
    case PatternStep.accept(state.open.tracker, checked) do
      {:applied, tracker} ->
        applied(%{state | open: %{state.open | tracker: tracker}}, input, estimate)

      _ ->
        unchanged(state)
    end
  end

  defp transition(state, _, _, _), do: unchanged(state)

  defp applied(%{phase: :model} = state, input, estimate), do: model_result(state, input, estimate)

  defp applied(%{phase: :tools} = state, input, estimate) do
    index = state.open.actions[input["action_id"]]
    state = put_result(state, index, reduce(state, index, input))
    if settled?(state), do: stores(state, estimate), else: {:Transition, state, :none}
  end

  defp applied(%{phase: :stores} = state, input, estimate) do
    index = state.open.actions[input["action_id"]]
    {:stored, pending} = slot(state, index).result
    payload = if input["outcome"] == "completed", do: input["payload"], else: nil

    result =
      case ToolResultLimit.settle(pending, input["outcome"], payload) do
        {:ok, bounded} -> {:result, bounded["content"], ref(bounded)}
        {:error, _} -> notice("[tool result not readable]")
      end

    state = put_result(state, index, result)
    if settled?(state), do: close_turn(state, estimate), else: {:Transition, state, :none}
  end

  ## One model result

  defp model_result(state, input, estimate) do
    with "completed" <- input["outcome"],
         {:ok, result} <- model_view(input) do
      cond do
        result.finish == "stop" and result.proposals == [] and state.waiting == [] ->
          if result.content != "",
            do: finish(state, "answered", nil, call_id(state, state.turns)),
            else: stop(state, "model_stopped")

        result.finish not in ["stop", "tool_calls"] or
            (result.finish == "tool_calls" and result.proposals == []) ->
          stop(state, "model_stopped")

        state.turns == state.spec.turn_limit ->
          stop(state, "turn_limit")

        true ->
          run_turn(state, result, estimate)
      end
    else
      :error -> stop(state, "model_stopped")
      _ -> stop(state, "model_call_not_completed")
    end
  end

  # The JSON view of the ai-text completed map; only content, finish and
  # tool_proposals are read, and each proposal only for id, name, arguments and malformed.
  defp model_view(%{"schema_id" => @model_result_key, "schema_version" => 1, "payload" => p})
       when is_map(p) and not is_struct(p) do
    with %{"content" => content, "finish" => finish, "tool_proposals" => proposals} <- p,
         true <- text?(content) and finish?(finish) and is_list(proposals),
         false <- List.improper?(proposals),
         true <- Enum.all?(proposals, &proposal?/1) do
      {:ok, %{content: content, finish: finish, proposals: proposals}}
    else
      _ -> :error
    end
  end

  defp model_view(_), do: :error

  defp finish?(finish) when finish in @finishes, do: true
  defp finish?(%{"other" => text} = map) when map_size(map) == 1, do: text?(text)
  defp finish?(_), do: false

  defp proposal?(%{"id" => id, "name" => name, "arguments" => args, "malformed" => tag} = p)
       when not is_struct(p) do
    (is_nil(id) or text?(id)) and (is_nil(name) or text?(name)) and
      ((is_nil(tag) and object?(args)) or (tag in @tags and is_nil(args)))
  end

  defp proposal?(_), do: false

  ## One turn

  defp run_turn(state, result, estimate) do
    n = state.turns

    {slots, _} =
      result.proposals
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {proposal, index}, kept_ids ->
        case classify(proposal, kept_ids) do
          :Kept -> {kept(state, proposal, index), [proposal["id"] | kept_ids]}
          decision -> {left_out(state, proposal, index, decision), kept_ids}
        end
      end)

    actions = for %{action: action} <- slots, action != nil, do: action

    turn = %{n: n, content: result.content, slots: slots}
    state = %{state | phase: :tools, open: %{turn: turn, tracker: nil, actions: %{}}}

    if actions == [] do
      close_turn(state, estimate)
    else
      by_id = for %{action: %{"id" => id}, index: i} <- slots, into: %{}, do: {id, i}
      open_request(state, :tools, actions, by_id)
    end
  end

  defp classify(proposal, kept_ids) do
    name = proposal["name"]
    id = proposal["id"]
    has_id = is_binary(id) and byte_size(id) in 1..256

    apply(:"Cure.Elzoo.AgentLoop", :keep, [
      is_binary(name) and Regex.match?(@alias, name),
      is_nil(proposal["malformed"]),
      has_id,
      id not in kept_ids,
      length(kept_ids) < @max_calls
    ])
  end

  defp left_out(state, %{"name" => name, "malformed" => tag}, index, decision) do
    line =
      case {decision, tag} do
        {:NameOutsideGrammar, _} ->
          "[tool call left out: name_outside_grammar]"

        {:Malformed, "undeclared_tool"} ->
          "[tool call left out: #{name}: undeclared_tool: #{undeclared(state, name)}]"

        {:Malformed, tag} ->
          "[tool call left out: #{name}: #{tag}]"

        {:MissingId, _} ->
          "[tool call left out: #{name}: missing_id]"

        {:RepeatedId, _} ->
          "[tool call left out: #{name}: repeated_id]"

        {:OverCallBound, _} ->
          "[tool call left out: #{name}: over_call_bound]"
      end

    %{index: index, left_out: line}
  end

  defp undeclared(state, name) do
    case ToolRegistry.resolve(state.snapshot, name) do
      :removed -> "removed"
      {:ambiguous, _} -> "ambiguous"
      _ -> "unknown"
    end
  end

  # A kept call is echoed; it gives one action, or a notice as its result.
  defp kept(state, proposal, index) do
    echo = %{
      "id" => proposal["id"],
      "name" => proposal["name"],
      "arguments" => proposal["arguments"]
    }

    base = %{index: index, echo: echo, action: nil, source_kind: nil, result: nil}
    action_id = "#{state.spec.id}:t:#{state.turns}:#{index}"

    with {:resolved, tool} <- ToolRegistry.resolve(state.snapshot, proposal["name"]),
         :ok <- ToolRegistry.check(tool, proposal["arguments"]) do
      if tool.alias == state.spec.ask,
        do: ask(base, action_id, proposal["arguments"]),
        else: tool_action(base, action_id, tool, proposal["arguments"])
    else
      {:error, {:validator_disagreement, _}} ->
        %{base | result: notice("[tool call not run: validator_disagreement]")}

      _ ->
        %{base | result: notice("[tool call not run: not_resolved]")}
    end
  end

  defp ask(base, action_id, %{"person_id" => person, "question" => question})
       when is_binary(person) and byte_size(person) in 1..256 and is_binary(question) and
              question != "" do
    if String.valid?(person) and String.valid?(question) do
      payload = %{"person_id" => person, "question" => question}
      %{base | action: action(action_id, "ask_person", "elzoo.agent-loop.ask", payload)}
    else
      %{base | result: notice("[tool call not run: invalid_ask]")}
    end
  end

  defp ask(base, _, _), do: %{base | result: notice("[tool call not run: invalid_ask]")}

  defp tool_action(base, action_id, tool, arguments) do
    kind = if elem(tool.callable, 0) == :nested, do: "nested_callable", else: "tool_call"

    payload = %{
      "alias" => tool.alias,
      "source" => tool.source,
      "tool" => tool.tool,
      "version" => tool.version,
      "arguments" => arguments
    }

    %{
      base
      | source_kind: tool.source_kind,
        action: action(action_id, kind, "elzoo.agent-loop.tool-call", payload)
    }
  end

  # Step 3: one applied outcome of a tool or ask action, reduced when it arrives.
  defp reduce(state, index, input) do
    slot = slot(state, index)
    action_id = slot.action["id"]

    cond do
      input["kind"] == "person_answer" ->
        case input do
          %{"schema_id" => @answer_key, "schema_version" => 1, "payload" => %{"text" => text} = p}
          when map_size(p) == 1 and is_binary(text) ->
            answer = %{
              "content" => mark("person-answer", text),
              "media_type" => "text/plain",
              "encoding" => "utf8"
            }

            limit(state, answer, action_id)

          _ ->
            notice("[tool result not readable]")
        end

      input["outcome"] != "completed" ->
        not_completed(input["outcome"], input["payload"])

      input["schema_id"] != @result_key or input["schema_version"] != 1 ->
        notice("[tool result not readable]")

      declaration?(input["payload"]) ->
        {:declaration, input["payload"]["declaration"]}

      true ->
        limit(state, input["payload"], action_id)
    end
  end

  defp limit(state, result, action_id) do
    case ToolResultLimit.decide(result, state.spec.result_limits, action_id) do
      {:ok, bounded} -> {:result, bounded["content"], ref(bounded)}
      {:store, pending, payload} -> {:store, pending, payload}
      {:error, _} -> notice("[tool result not readable]")
    end
  end

  defp not_completed(class, %{"reason" => reason} = payload) when not is_struct(payload) do
    if is_binary(reason) and Regex.match?(@reason, reason),
      do: notice("[tool call not completed: #{class}: #{reason}]"),
      else: notice("[tool call not completed: #{class}]")
  end

  defp not_completed(class, _), do: notice("[tool call not completed: #{class}]")

  defp declaration?(%{"declaration" => _} = p), do: map_size(p) == 1 and not is_struct(p)
  defp declaration?(_), do: false

  # A declaration takes effect in the order of its recorded input.
  defp put_result(state, index, {:declaration, value}) do
    {result, state} = declare(state, slot(state, index), value)
    put_result(state, index, result)
  end

  defp put_result(state, index, result) do
    slots =
      Enum.map(state.open.turn.slots, fn
        %{index: ^index} = slot -> %{slot | result: result}
        slot -> slot
      end)

    put_in(state.open.turn.slots, slots)
  end

  defp slot(state, index), do: Enum.find(state.open.turn.slots, &(&1.index == index))

  # Every action of the open request is settled: no slot waits for its result or its store.
  defp settled?(state) do
    Enum.all?(state.open.turn.slots, fn
      %{left_out: _} -> true
      %{result: nil} -> false
      %{result: {:stored, _}} -> false
      _ -> true
    end)
  end

  # Step 4: the store actions of the turn, if any, in one request in call order.
  defp stores(state, estimate) do
    n = state.open.turn.n

    stored =
      for %{result: {:store, _, payload}, index: i} <- state.open.turn.slots,
          do: {"#{state.spec.id}:s:#{n}:#{i}", i, payload}

    if stored == [] do
      close_turn(state, estimate)
    else
      actions =
        for {id, _, payload} <- stored,
            do: action(id, "tool_call", "elzoo.tool-result-limit.store", payload)

      slots =
        Enum.map(state.open.turn.slots, fn
          %{result: {:store, pending, _}} = slot -> %{slot | result: {:stored, pending}}
          slot -> slot
        end)

      state = put_in(state.open.turn.slots, slots)
      open_request(state, :stores, actions, Map.new(stored, fn {id, i, _} -> {id, i} end))
    end
  end

  # Step 5: the turn closes into the history, then the next model call.
  defp close_turn(state, estimate) do
    %{n: n, content: content, slots: slots} = state.open.turn
    id = state.spec.id
    calls = for %{echo: echo} <- slots, do: echo
    lines = for %{left_out: line} <- slots, do: line

    assistant =
      if content == "" and calls == [],
        do: [],
        else: [%{kind: :assistant, id: call_id(state, n), text: content, tool_calls: calls}]

    results =
      for %{echo: echo, index: i, result: {:result, content, ref}} <- slots do
        %{
          kind: :tool_result,
          id: "#{id}:t:#{n}:#{i}",
          tool_use_id: echo["id"],
          content: content,
          ref_media_type: ref
        }
      end

    note =
      if lines == [],
        do: [],
        else: [
          %{
            kind: :content,
            id: "#{id}:n:#{n}",
            content: mark("agent-loop", Enum.join(lines, "\n")),
            ref_media_type: nil
          }
        ]

    %{state | history: state.history ++ assistant ++ results ++ note, open: nil}
    |> flush()
    |> model_call(estimate)
  end

  ## Declarations

  defp declare(state, slot, value) do
    with {:ok, skill, listing} <- declaration(value),
         :Permitted <-
           apply(:"Cure.Elzoo.AgentLoop", :permit, [
             Map.get(@kinds, slot.source_kind, :Other),
             skill != nil,
             listing != nil
           ]),
         {:ok, skills} <- load(state.skills, skill),
         {:ok, snapshot} <- list(state.snapshot, listing) do
      accepted = notice("[declaration accepted]")
      next = %{state | skills: skills, snapshot: snapshot}

      if size(put_result(next, slot.index, accepted)) <= @state_bound,
        do: {accepted, next},
        else: refused(state, "state_over_bound")
    else
      :error -> refused(state, "invalid_declaration")
      :Refused -> refused(state, "declaration_not_permitted")
      {:error, reason} -> refused(state, Atom.to_string(reason))
    end
  end

  defp refused(state, reason), do: {notice("[declaration refused: #{reason}]"), state}

  defp declaration(%{"skill" => skill, "listing" => listing} = d)
       when map_size(d) == 2 and not is_struct(d) do
    if skill?(skill) and listing?(listing) and not (is_nil(skill) and is_nil(listing)),
      do: {:ok, skill, listing},
      else: :error
  end

  defp declaration(_), do: :error

  defp skill?(nil), do: true

  defp skill?(%{"name" => name, "instructions" => text} = skill)
       when map_size(skill) == 2 and not is_struct(skill),
       do: text?(name) and byte_size(name) in 1..64 and text?(text) and text != ""

  defp skill?(_), do: false

  defp listing?(nil), do: true

  defp listing?(%{"source" => source, "tools" => tools} = listing)
       when map_size(listing) == 2 and not is_struct(listing),
       do: text?(source) and is_list(tools)

  defp listing?(_), do: false

  defp load(skills, nil), do: {:ok, skills}

  defp load(skills, %{"name" => name, "instructions" => text}) do
    cond do
      List.keymember?(skills, name, 0) ->
        {:error, :already_loaded}

      Enum.sum_by(skills, &byte_size(elem(&1, 1))) + byte_size(text) > @instruction_bound ->
        {:error, :instructions_over_bound}

      true ->
        {:ok, skills ++ [{name, text}]}
    end
  end

  defp list(snapshot, nil), do: {:ok, snapshot}

  defp list(snapshot, %{"source" => source, "tools" => tools}),
    do: ToolRegistry.refresh(snapshot, source, tools)

  ## Each model call

  defp model_call(state, estimate) do
    state = %{state | history: prune(state.history, state.snapshot)}

    input =
      state.spec
      |> Map.take(@build_keys)
      |> Map.merge(%{
        skill_instructions: Enum.map(state.skills, &elem(&1, 1)),
        memory: [],
        history: state.history,
        tools: ToolRegistry.tools(state.snapshot)
      })

    case PromptAssembly.build(input, estimate) do
      {:ok, built} ->
        gone = for %{part: :history, id: id} <- built.dropped, do: id
        n = state.turns + 1
        state = %{state | history: Enum.reject(state.history, &(&1.id in gone)), turns: n}
        action = action(call_id(state, n), "model_call", "elzoo/ai-text-request", built.request)
        open_request(state, :model, [action], %{action["id"] => n})

      {:error, _} ->
        stop(state, "request_not_built")
    end
  end

  # An echoed call whose name no longer resolves leaves its assistant entry; its result
  # becomes content behind the other results of that turn.
  defp prune(history, snapshot) do
    history
    |> chunk()
    |> Enum.flat_map(fn
      [%{kind: :assistant, tool_calls: calls} = assistant | results] when calls != [] ->
        {live, gone} =
          Enum.split_with(
            calls,
            &match?({:resolved, _}, ToolRegistry.resolve(snapshot, &1["name"]))
          )

        gone_ids = Enum.map(gone, & &1["id"])
        {moved, kept} = Enum.split_with(results, &(&1.tool_use_id in gone_ids))

        moved =
          Enum.map(
            moved,
            &%{kind: :content, id: &1.id, content: &1.content, ref_media_type: &1.ref_media_type}
          )

        head =
          if assistant.text == "" and live == [], do: [], else: [%{assistant | tool_calls: live}]

        head ++ kept ++ moved

      entries ->
        entries
    end)
  end

  # An assistant entry with the tool_result entries that follow it; each other entry alone.
  defp chunk(history) do
    history
    |> Enum.reduce([], fn
      %{kind: :tool_result} = e, [[%{kind: k} | _] = unit | rest]
      when k in [:assistant, :tool_result] ->
        [unit ++ [e] | rest]

      e, acc ->
        [[e] | acc]
    end)
    |> Enum.reverse()
  end

  ## Requests, finishes and small helpers

  defp open_request(state, phase, actions, by_id) do
    request = %{"type" => "request", "version" => 1, "actions" => actions}
    {:ok, checked} = PatternStep.decode(request)
    open = Map.merge(state.open || %{}, %{tracker: PatternStep.open(checked), actions: by_id})
    {:Transition, %{state | phase: phase, open: open}, {:some, request}}
  end

  defp stop(state, reason), do: finish(state, "stopped", reason, nil)

  defp finish(state, status, reason, action_id) do
    payload = %{
      "status" => status,
      "reason" => reason,
      "action_id" => action_id,
      "turns" => state.turns
    }

    action = action(state.spec.id <> ":finish", "finish", "elzoo.agent-loop.result", payload)

    {:Transition, closed(state),
     {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  defp closed(state), do: %{phase: :closed, id: state.spec.id, turns: state.turns}

  defp action(id, kind, schema_id, payload),
    do: %{
      "id" => id,
      "kind" => kind,
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }

  defp call_id(state, n), do: "#{state.spec.id}:m:#{n}"

  # A message of the principal: exactly {"text": text}, not empty.
  defp message(%{
         "schema_id" => @message_key,
         "schema_version" => 1,
         "payload" => %{"text" => text} = p
       })
       when map_size(p) == 1 and not is_struct(p) do
    if text?(text) and text != "", do: {:ok, text}, else: :error
  end

  defp message(_), do: :error

  defp arrive(state, text) do
    k = state.users + 1

    %{
      state
      | users: k,
        waiting: state.waiting ++ [%{kind: :user, id: "#{state.spec.id}:u:#{k}", text: text}]
    }
  end

  defp flush(state), do: %{state | history: state.history ++ state.waiting, waiting: []}

  defp notice(text), do: {:result, mark("agent-loop", text), nil}

  defp mark(source, text),
    do: %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => [source],
      "trust" => "untrusted",
      "max_bytes" => @mark_bound,
      "content" => text
    }

  defp ref(%{"cut" => %{"media_type" => media}}), do: media
  defp ref(_), do: nil

  defp unchanged(state), do: {:Transition, state, :none}

  defp size(state),
    do: byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}]))

  ## Spec checks

  defp spec?(%{} = spec) when not is_struct(spec) do
    map_size(spec) == length(@spec_keys) and Enum.all?(@spec_keys, &is_map_key(spec, &1)) and
      text?(spec.id) and byte_size(spec.id) in 1..128 and limits?(spec.result_limits) and
      (is_nil(spec.ask) or (is_binary(spec.ask) and Regex.match?(@alias, spec.ask))) and
      is_integer(spec.turn_limit) and spec.turn_limit in 1..256 and plain?(spec)
  end

  defp spec?(_), do: false

  defp limits?(%{max_bytes: max, artifact_max_bytes: artifact_max} = limits),
    do:
      map_size(limits) == 2 and not is_struct(limits) and is_integer(max) and
        max in 1_024..1_048_576 and is_integer(artifact_max) and artifact_max > 0

  defp limits?(_), do: false

  defp snapshot(sources) do
    case ToolRegistry.snapshot(sources) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:sources, reason}}
    end
  end

  defp ask?(_, nil), do: true
  defp ask?(snapshot, name), do: match?({:resolved, _}, ToolRegistry.resolve(snapshot, name))

  # Plain data only: maps that are not structs, proper lists, tuples, atoms, numbers, binaries.
  defp plain?(value) when is_map(value),
    do: not is_struct(value) and Enum.all?(value, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?([]), do: true
  defp plain?([head | rest]), do: plain?(head) and is_list(rest) and plain?(rest)
  defp plain?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&plain?/1)

  defp plain?(value),
    do: is_atom(value) or is_number(value) or is_binary(value)

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp object?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {k, v} -> text?(k) and json?(v) end)

  defp object?(_), do: false

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?([]), do: true
  defp json?([head | rest]), do: json?(head) and is_list(rest) and json?(rest)
  defp json?(value) when is_map(value), do: object?(value)
  defp json?(_), do: false
end
