# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TurnPolicy do
  @moduledoc "Pure pattern step of a room Run: who speaks next, under guards that every rule keeps."
  alias Elzoo.{PatternStep, UntrustedContent}
  alias Elzoo.TurnPolicy.{Addressed, Decided, Everyone, RoundRobin}

  @builtins %{
    "addressed" => Addressed,
    "round_robin" => RoundRobin,
    "everyone" => Everyone,
    "decided" => Decided
  }
  @kinds %{"human" => :human, "bot" => :bot, "peer" => :peer}
  @notes ~w(not_member repeated_member reply_to_not_member decision_fallback host_rule_failed
            bot_turn_bound awaiting_person escalated handoff handoff_denied handoff_not_member
            turn_not_completed invalid_answer invalid_message post_failed carry_failed
            carry_queue_full link_limit restarted_queue_dropped)a
  @note_codes Map.new(@notes, &{Atom.to_string(&1), &1})
  @max_link 2_147_483_647
  @max_seq 9_007_199_254_740_991
  @fresh_seq %{"turn" => 0, "notice" => 0, "decision" => 0}
  @pick_schema %{
    "type" => "object",
    "properties" => %{
      "pick" => %{
        "oneOf" => [
          %{"const" => "several"},
          %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 16,
            "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
          }
        ]
      }
    },
    "required" => ["pick"],
    "additionalProperties" => false
  }

  @doc "Check the host rules; `{:ok, state}` or `{:error, :invalid_spec}`."
  def new(%{host_rules: rules} = spec)
      when map_size(spec) == 1 and is_map(rules) and not is_struct(rules) and
             map_size(rules) <= 8 do
    if Enum.all?(rules, fn {name, module} -> rule_name?(name) and rule_module?(module) end),
      do: {:ok, %{phase: :new, host_rules: rules, invalid_start: nil}},
      else: {:error, :invalid_spec}
  end

  def new(_), do: {:error, :invalid_spec}

  @doc "The checks that `step/2` applies to a `start` payload: `:ok` or `{:error, reason}`."
  def check_start(%{host_rules: rules}, start) do
    with :ok <- if(start?(start), do: :ok, else: {:error, :malformed}) do
      policy = start["policy"]
      bots = bots(start["members"])
      carry = start["carry"]

      cond do
        not (is_map_key(@builtins, policy["rule"]) or is_map_key(rules, policy["rule"])) ->
          {:error, :unknown_rule}

        policy["default_member"] not in [nil | bots] ->
          {:error, :default_member}

        policy["rule"] in ["everyone", "decided"] and length(bots) > policy["max_bot_turns"] ->
          {:error, :too_many_bots}

        carry != nil and not carry_fits?(carry, bots, policy["window"]) ->
          {:error, :carry}

        true ->
          :ok
      end
    end
  end

  @doc "The start of the successor of a link that ended without a carry."
  def restart_carry(%{"link" => link, "carry" => carry} = start)
      when is_integer(link) and link >= 1 and link <= @max_link do
    cond do
      link == @max_link ->
        {:error, :link_limit}

      carry == nil ->
        {:ok, %{start | "link" => link + 1}}

      is_map(carry) and is_map_key(carry, "queue") and is_list(carry["notes"]) ->
        dropped = %{"code" => "restarted_queue_dropped", "ref" => nil}
        notes = Enum.take([dropped | carry["notes"]], 16)
        {:ok, %{start | "link" => link + 1, "carry" => %{carry | "queue" => [], "notes" => notes}}}

      true ->
        {:error, :malformed}
    end
  end

  def restart_carry(_), do: {:error, :malformed}

  @doc "The decoded JSON Schema of `elzoo.room.pick` version 1."
  def pick_schema, do: @pick_schema

  @doc "One `core/operator` transition over a neutral PatternStep v1 input map."
  def step(state, input) do
    case PatternStep.decode(input) do
      {:ok, _} -> transition(state, input)
      _ -> unchanged(state)
    end
  end

  defp transition(%{phase: phase} = state, %{"kind" => kind})
       when phase != :closed and kind in ["cancel", "run_ended"],
       do: {:Transition, %{state | phase: :closed}, :none}

  defp transition(%{phase: :new} = state, %{"kind" => "start"} = input) do
    with %{"schema_id" => "elzoo.room.start", "schema_version" => 1, "payload" => start} <- input,
         :ok <- check_start(state, start) do
      started(state, start)
    else
      {:error, reason} ->
        {:Transition, %{state | phase: :invalid_start, invalid_start: reason}, :none}

      _ ->
        {:Transition, %{state | phase: :invalid_start, invalid_start: :malformed}, :none}
    end
  end

  defp transition(%{phase: phase, open: nil} = state, %{"kind" => "message"} = input)
       when phase in [:running, :carrying] do
    case input do
      %{"schema_id" => "elzoo.room.rollover", "schema_version" => 1, "payload" => payload}
      when is_map(payload) and map_size(payload) == 0 ->
        rollover(state)

      %{"schema_id" => "elzoo.room.message", "schema_version" => 1, "payload" => payload} ->
        message(state, payload)

      _ ->
        unchanged(state)
    end
  end

  defp transition(
         %{phase: phase, open: %{id: id, kind: kind} = open} = state,
         %{"kind" => "action_outcome", "action_id" => id, "outcome" => class} = input
       )
       when phase in [:running, :carrying] and class != "late",
       do: settle(kind, open, %{state | open: nil}, input)

  defp transition(state, _), do: unchanged(state)

  ## Start

  defp started(state, start) do
    carry =
      start["carry"] ||
        %{
          "window" => [],
          "bot_turns" => 0,
          "default_member" => start["policy"]["default_member"],
          "rule_state" => nil,
          "awaiting_person" => false,
          "queue" => [],
          "seq" => @fresh_seq,
          "notes" => []
        }

    state
    |> Map.merge(%{
      phase: :running,
      room: Map.delete(start, "carry"),
      window: carry["window"],
      bot_turns: carry["bot_turns"],
      default_member: carry["default_member"],
      rule_state: carry["rule_state"],
      awaiting: carry["awaiting_person"],
      queue: carry["queue"],
      seq: carry["seq"],
      notes: Enum.map(carry["notes"], &{@note_codes[&1["code"]], &1["ref"]}),
      run_turns: 0,
      carry_k: 0,
      open: nil,
      notice: nil
    })
    |> next()
  end

  ## Messages

  defp rollover(state) do
    cond do
      state.phase == :carrying -> next(state)
      link(state) == @max_link -> unchanged(note(state, :link_limit, nil))
      true -> next(%{state | phase: :carrying})
    end
  end

  defp message(state, payload) do
    if message?(payload) do
      %{"message_id" => id, "from" => from, "text" => text, "mentions" => mentions} = payload

      case kind(state, from) do
        nil ->
          next(note(state, :not_member, from))

        :human ->
          state
          |> add_window(id, from, text, "untrusted")
          |> person(payload)

        kind ->
          state =
            add_window(state, id, from, text, if(kind == :bot, do: "derived", else: "untrusted"))

          {state, bots} = mentioned(state, mentions)
          next(enqueue(state, bots, id))
      end
    else
      next(note(state, :invalid_message, nil))
    end
  end

  defp person(state, %{"message_id" => id} = payload) do
    state = %{state | awaiting: false, bot_turns: length(state.queue)}
    {state, addressed} = mentioned(state, payload["mentions"])
    reply = payload["reply_to_member"]

    {state, reply_to} =
      cond do
        reply == nil -> {state, nil}
        kind(state, reply) == :bot -> {state, {:member, reply}}
        true -> {note(state, :reply_to_not_member, reply), :invalid}
      end

    view = %{
      message: %{
        message_id: id,
        from: payload["from"],
        mentions: payload["mentions"],
        reply_to_member: reply
      },
      addressed: addressed,
      reply_to: reply_to,
      members: Enum.map(state.room["members"], &%{id: &1["id"], kind: @kinds[&1["kind"]]}),
      default_member: state.default_member
    }

    module = @builtins[rule(state)] || state.host_rules[rule(state)]

    case answer(module, :choose, [view, state.rule_state]) do
      {:turns, ids, rule_state} ->
        next(take(%{state | rule_state: rule_state}, ids, id))

      {:decide, context, rule_state} when state.phase == :running ->
        ask_decision(%{state | rule_state: rule_state}, module, view, context)

      {:decide, _context, rule_state} ->
        next(fallback(%{state | rule_state: rule_state}, id))

      _ ->
        next(note(state, :host_rule_failed, id))
    end
  end

  ## Outcomes

  defp settle(:turn, open, state, input) do
    case input do
      %{"outcome" => "completed", "schema_id" => "elzoo.room.answer", "schema_version" => 1} ->
        if answer?(input["payload"]),
          do: answered(state, open, input["payload"]),
          else: next(note(state, :invalid_answer, open.member))

      %{"outcome" => "completed"} ->
        next(note(state, :invalid_answer, open.member))

      _ ->
        next(note(state, :turn_not_completed, open.member))
    end
  end

  defp settle(:decision, open, state, input) do
    outcome = %{
      class: input["outcome"],
      schema_id: input["schema_id"],
      schema_version: input["schema_version"],
      payload: input["payload"]
    }

    message_id = open.view.message.message_id

    case answer(open.module, :read, [open.view, state.rule_state, outcome]) do
      {:turns, ids, rule_state} -> next(take(%{state | rule_state: rule_state}, ids, message_id))
      {:fallback, rule_state} -> next(fallback(%{state | rule_state: rule_state}, message_id))
      _ -> next(note(state, :host_rule_failed, message_id))
    end
  end

  defp settle(kind, open, state, %{"outcome" => class}) when kind in [:post, :notice] do
    if class == "completed",
      do: next(state),
      else: next(note(state, :post_failed, open[:member]))
  end

  defp settle(:carry, open, state, %{"outcome" => class}) do
    if class == "completed" do
      id = "f/#{link(state)}"

      ask(
        %{state | phase: :finishing, open: %{kind: :finish, id: id}},
        id,
        "finish",
        "elzoo.room.finish",
        %{
          "action_id" => open.id
        }
      )
    else
      unchanged(note(state, :carry_failed, nil))
    end
  end

  defp answered(state, open, answer) do
    %{"text" => text, "mentions" => mentions} = answer

    state =
      state
      |> add_window(open.turn_id, open.member, text, "derived")
      |> handoff(answer["handoff_to"])
      |> then(&if(answer["escalate"], do: escalate(&1, open.member), else: &1))

    {state, bots} = mentioned(state, mentions)
    state = enqueue(state, bots, open.turn_id)
    id = open.turn_id <> "/post"

    ask(
      %{state | open: %{kind: :post, id: id, member: open.member}},
      id,
      "tool_call",
      "elzoo.room.post",
      %{
        "post_to" => state.room["policy"]["post_to"],
        "turn_id" => open.turn_id,
        "member" => open.member,
        "text" => text,
        "mentions" => mentions
      }
    )
  end

  defp handoff(state, nil), do: state

  defp handoff(state, member) do
    cond do
      state.room["policy"]["handoff"] != "allowed" -> note(state, :handoff_denied, member)
      kind(state, member) != :bot -> note(state, :handoff_not_member, member)
      true -> note(%{state | default_member: member}, :handoff, member)
    end
  end

  defp escalate(state, member) do
    state = %{state | queue: []}

    if state.awaiting,
      do: note(state, :escalated, member),
      else: %{state | awaiting: true, notice: "escalated"}
  end

  ## Guards: members only, then the bot-turn bound

  # Guard 2 for the IDs a rule names; a repeat or a non-bot never reaches the queue.
  defp take(state, ids, message_id) do
    {state, picked} =
      Enum.reduce(ids, {state, []}, fn id, {state, picked} ->
        cond do
          kind(state, id) != :bot -> {note(state, :not_member, ref(id)), picked}
          id in picked -> {note(state, :repeated_member, id), picked}
          true -> {state, picked ++ [id]}
        end
      end)

    enqueue(state, picked, message_id)
  end

  defp fallback(state, message_id) do
    state = note(state, :decision_fallback, message_id)
    if state.default_member, do: enqueue(state, [state.default_member], message_id), else: state
  end

  # The mentioned bot members in mention order, without repeats; a non-member is a note.
  defp mentioned(state, mentions) do
    Enum.reduce(mentions, {state, []}, fn id, {state, bots} ->
      case kind(state, id) do
        nil -> {note(state, :not_member, id), bots}
        :bot -> {state, if(id in bots, do: bots, else: bots ++ [id])}
        _ -> {state, bots}
      end
    end)
  end

  # Guard 3: a turn is queued only while the bot turns since the last person's
  # message stay within max_bot_turns, whatever rule or answer named it.
  defp enqueue(state, bots, message_id) do
    blocked = state.awaiting
    max = state.room["policy"]["max_bot_turns"]

    Enum.reduce(bots, state, fn member, state ->
      cond do
        blocked ->
          note(state, :awaiting_person, member)

        state.phase == :carrying and length(state.queue) >= max ->
          note(state, :carry_queue_full, member)

        state.bot_turns >= max ->
          state = note(state, :bot_turn_bound, member)

          if state.awaiting or state.phase == :carrying,
            do: state,
            else: %{state | awaiting: true, notice: "bot_turn_bound"}

        true ->
          queued = %{"member" => member, "message_id" => message_id}
          %{state | queue: state.queue ++ [queued], bot_turns: state.bot_turns + 1}
      end
    end)
  end

  ## Requests: one open action at a time

  defp next(%{open: nil} = state) do
    cond do
      state.notice != nil -> ask_notice(state)
      state.phase == :carrying -> ask_carry(state)
      threshold?(state) -> ask_carry(%{state | phase: :carrying})
      state.queue != [] -> ask_turn(state)
      true -> unchanged(state)
    end
  end

  defp next(state), do: unchanged(state)

  defp threshold?(state),
    do:
      state.run_turns >= state.room["policy"]["rollover"]["max_turns"] and
        link(state) < @max_link

  defp ask_turn(%{queue: [%{"member" => member, "message_id" => message_id} | rest]} = state) do
    n = state.seq["turn"] + 1
    turn_id = "t/#{link(state)}/#{n}"
    run_turns = state.run_turns + 1

    state = %{
      state
      | queue: rest,
        seq: %{state.seq | "turn" => n},
        run_turns: run_turns,
        open: %{kind: :turn, id: turn_id <> "/turn", turn_id: turn_id, member: member}
    }

    state =
      if run_turns == state.room["policy"]["rollover"]["max_turns"] and link(state) == @max_link,
        do: note(state, :link_limit, nil),
        else: state

    ask(state, turn_id <> "/turn", "nested_callable", "elzoo.room.turn", %{
      "turn_id" => turn_id,
      "member" => member,
      "message_id" => message_id,
      "window" => state.window,
      "summary" => state.room["summary"]
    })
  end

  defp ask_notice(state) do
    n = state.seq["notice"] + 1
    id = "n/#{link(state)}/#{n}"
    humans = for %{"id" => id, "kind" => "human"} <- state.room["members"], do: id

    reason = state.notice

    state = %{
      state
      | seq: %{state.seq | "notice" => n},
        notice: nil,
        open: %{kind: :notice, id: id}
    }

    ask(state, id, "tool_call", "elzoo.room.notice", %{
      "post_to" => state.room["policy"]["post_to"],
      "notice_id" => id,
      "reason" => reason,
      "members" => humans
    })
  end

  defp ask_decision(state, module, view, context) do
    n = state.seq["decision"] + 1
    id = "d/#{link(state)}/#{n}"

    state = %{
      state
      | seq: %{state.seq | "decision" => n},
        open: %{kind: :decision, id: id, module: module, view: view}
    }

    ask(state, id, "nested_callable", "elzoo.room.decide", %{
      "decision_id" => id,
      "rule" => rule(state),
      "message_id" => view.message.message_id,
      "members" => bots(state.room["members"]),
      "window" => state.window,
      "context" => context
    })
  end

  defp ask_carry(state) do
    k = state.carry_k + 1
    id = "c/#{link(state)}/#{k}"
    state = %{state | carry_k: k, open: %{kind: :carry, id: id}}
    ask(state, id, "local_work", "elzoo.room.carry", carry(state))
  end

  defp carry(state) do
    Map.merge(state.room, %{
      "link" => link(state) + 1,
      "carry" => %{
        "window" => state.window,
        "bot_turns" => state.bot_turns,
        "default_member" => state.default_member,
        "rule_state" => state.rule_state,
        "awaiting_person" => state.awaiting,
        "queue" => state.queue,
        "seq" => state.seq,
        "notes" =>
          Enum.map(state.notes, fn {code, ref} ->
            %{"code" => Atom.to_string(code), "ref" => ref}
          end)
      }
    })
  end

  defp ask(state, id, kind, schema_id, payload) do
    action = %{
      "id" => id,
      "kind" => kind,
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }

    {:Transition, state, {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  defp unchanged(state), do: {:Transition, state, :none}

  ## The rule plug: a bad answer fails closed

  defp answer(module, callback, args) do
    result =
      try do
        {:ok, apply(module, callback, args)}
      rescue
        _ -> :bad
      catch
        _, _ -> :bad
      end

    case {callback, result} do
      {_, {:ok, {{:turns, ids}, rule_state}}} ->
        if texts?(ids, 0) and rule_state?(rule_state), do: {:turns, ids, rule_state}, else: :bad

      {:choose, {:ok, {{:decide, context}, rule_state}}} ->
        if is_map(context) and json?(context) and json_bytes(context) <= 4_096 and
             rule_state?(rule_state),
           do: {:decide, context, rule_state},
           else: :bad

      {:read, {:ok, {:fallback, rule_state}}} when module == Decided ->
        {:fallback, rule_state}

      _ ->
        :bad
    end
  end

  defp texts?([], _), do: true

  defp texts?([id | rest], n) when is_binary(id) and n < 16,
    do: String.valid?(id) and texts?(rest, n + 1)

  defp texts?(_, _), do: false

  defp rule_state?(value), do: json?(value) and json_bytes(value) <= 1_024

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value) when is_list(value), do: json_list?(value)

  defp json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(_), do: false

  defp json_list?([]), do: true
  defp json_list?([item | rest]), do: json?(item) and json_list?(rest)
  defp json_list?(_), do: false

  defp json_bytes(value), do: byte_size(Jason.encode!(value))

  ## The window

  defp add_window(state, message_id, from, text, trust) do
    {:ok, marked} =
      UntrustedContent.decode(%{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => ["room"],
        "trust" => trust,
        "max_bytes" => 4_096,
        "content" => text
      })

    entry = %{
      "message_id" => message_id,
      "from" => from,
      "content" => UntrustedContent.encode(marked)
    }

    %{"messages" => count, "bytes" => bytes} = state.room["policy"]["window"]
    %{state | window: fit(entry, state.window, count, bytes)}
  end

  # The newest entry always stays; older entries stay while both bounds hold.
  defp fit(newest, older, count, bytes) do
    older
    |> Enum.reduce_while({[newest], 2 + json_bytes(newest)}, fn entry, {kept, size} ->
      size = size + 1 + json_bytes(entry)

      if length(kept) < count and size <= bytes,
        do: {:cont, {[entry | kept], size}},
        else: {:halt, {kept, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  ## Helpers

  defp note(state, code, ref), do: %{state | notes: Enum.take([{code, ref} | state.notes], 16)}
  defp ref(id), do: if(id?(id, 155), do: id, else: nil)
  defp link(state), do: state.room["link"]
  defp rule(state), do: state.room["policy"]["rule"]
  defp bots(members), do: for(%{"id" => id, "kind" => "bot"} <- members, do: id)

  defp kind(state, id),
    do: Enum.find_value(state.room["members"], fn m -> if m["id"] == id, do: @kinds[m["kind"]] end)

  ## Shapes

  defp start?(
         %{
           "room_id" => room,
           "link" => link,
           "members" => members,
           "policy" => policy,
           "summary" => summary,
           "carry" => carry
         } = start
       )
       when map_size(start) == 6 do
    id?(room, 128) and is_integer(link) and link >= 1 and link <= @max_link and members?(members) and
      policy?(policy) and
      (summary == nil or
         (is_binary(summary) and String.valid?(summary) and json_bytes(summary) <= 8_192)) and
      (carry == nil or carry?(carry))
  end

  defp start?(_), do: false

  defp members?(members) when is_list(members) and length(members) in 1..32 do
    Enum.all?(members, fn
      %{"id" => id, "kind" => kind} = member when map_size(member) == 2 ->
        id?(id, 128) and is_map_key(@kinds, kind)

      _ ->
        false
    end) and length(Enum.uniq_by(members, & &1["id"])) == length(members)
  end

  defp members?(_), do: false

  defp policy?(
         %{
           "rule" => rule,
           "default_member" => default,
           "max_bot_turns" => max,
           "handoff" => handoff,
           "post_to" => post_to,
           "window" => %{"messages" => messages, "bytes" => bytes} = window,
           "rollover" => %{"max_turns" => max_turns} = rollover
         } = policy
       )
       when map_size(policy) == 7 and map_size(window) == 2 and map_size(rollover) == 1 do
    is_binary(rule) and (default == nil or id?(default, 128)) and int?(max, 1, 16) and
      handoff in ["allowed", "denied"] and id?(post_to, 256) and int?(messages, 1, 8) and
      int?(bytes, 1, 24_576) and int?(max_turns, 1, 63)
  end

  defp policy?(_), do: false

  defp carry?(
         %{
           "window" => window,
           "bot_turns" => bot_turns,
           "default_member" => default,
           "rule_state" => rule_state,
           "awaiting_person" => awaiting,
           "queue" => queue,
           "seq" => seq,
           "notes" => notes
         } = carry
       )
       when map_size(carry) == 8 do
    list?(window, 8, &entry?/1) and int?(bot_turns, 0, 16) and (default == nil or id?(default, 128)) and
      rule_state?(rule_state) and is_boolean(awaiting) and list?(queue, 16, &queued?/1) and
      seq?(seq) and list?(notes, 16, &note?/1)
  end

  defp carry?(_), do: false

  # The relative checks of a carry: members of this start, this window, the payload bound.
  defp carry_fits?(carry, bots, %{"messages" => count, "bytes" => bytes}) do
    Enum.all?(carry["queue"], &(&1["member"] in bots)) and carry["default_member"] in [nil | bots] and
      length(carry["window"]) <= count and
      (length(carry["window"]) <= 1 or json_bytes(carry["window"]) <= bytes) and
      json_bytes(carry) <= 65_536
  end

  defp entry?(%{"message_id" => id, "from" => from, "content" => content} = entry)
       when map_size(entry) == 3 do
    id?(id, 155) and id?(from, 128) and
      match?({:ok, _}, UntrustedContent.decode(content)) and content["sources"] == ["room"] and
      content["max_bytes"] == 4_096 and content["content"] != ""
  end

  defp entry?(_), do: false

  defp queued?(%{"member" => member, "message_id" => id} = entry) when map_size(entry) == 2,
    do: id?(member, 128) and id?(id, 155)

  defp queued?(_), do: false

  defp seq?(%{"turn" => t, "notice" => n, "decision" => d} = seq) when map_size(seq) == 3,
    do: int?(t, 0, @max_seq) and int?(n, 0, @max_seq) and int?(d, 0, @max_seq)

  defp seq?(_), do: false

  defp note?(%{"code" => code, "ref" => ref} = note) when map_size(note) == 2,
    do: is_map_key(@note_codes, code) and (ref == nil or id?(ref, 155))

  defp note?(_), do: false

  defp message?(
         %{"message_id" => id, "from" => from, "text" => text, "mentions" => mentions} = message
       )
       when map_size(message) == 4 or
              (map_size(message) == 5 and is_map_key(message, "reply_to_member")) do
    id?(id, 155) and id?(from, 128) and text?(text) and list?(mentions, 16, &id?(&1, 128)) and
      (not is_map_key(message, "reply_to_member") or id?(message["reply_to_member"], 128))
  end

  defp message?(_), do: false

  defp answer?(
         %{"text" => text, "mentions" => mentions, "handoff_to" => handoff, "escalate" => escalate} =
           answer
       )
       when map_size(answer) == 4,
       do:
         text?(text) and list?(mentions, 16, &id?(&1, 128)) and
           (handoff == nil or id?(handoff, 128)) and
           is_boolean(escalate)

  defp answer?(_), do: false

  defp list?(list, max, check), do: proper?(list, max) and Enum.all?(list, check)
  defp proper?([], _), do: true
  defp proper?([_ | rest], max) when max > 0, do: proper?(rest, max - 1)
  defp proper?(_, _), do: false

  defp int?(value, min, max), do: is_integer(value) and value >= min and value <= max
  defp text?(text), do: is_binary(text) and byte_size(text) in 1..4_096 and String.valid?(text)

  # A member ID: valid UTF-8 of 1..max bytes with no C0 or C1 control character.
  defp id?(id, max) do
    is_binary(id) and byte_size(id) >= 1 and byte_size(id) <= max and String.valid?(id) and
      not Enum.any?(String.to_charlist(id), &(&1 < 0x20 or &1 in 0x80..0x9F))
  end

  defp rule_name?(name) do
    is_binary(name) and byte_size(name) in 1..64 and not is_map_key(@builtins, name) and
      Enum.all?(:binary.bin_to_list(name), &(&1 in ?a..?z or &1 in ?0..?9 or &1 in [?., ?_, ?-]))
  end

  defp rule_module?(module) do
    is_atom(module) and Code.ensure_loaded(module) == {:module, module} and
      function_exported?(module, :choose, 2) and function_exported?(module, :read, 3)
  end
end
