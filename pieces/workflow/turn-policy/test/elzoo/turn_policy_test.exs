# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TurnPolicyTest do
  use ExUnit.Case, async: true
  alias Elzoo.{PatternStep, PayloadSchema, TurnPolicy, TypedDecision}

  # A host rule scripted by the message ID, so one module gives every answer form.
  defmodule ScriptRule do
    @behaviour Elzoo.TurnPolicy.Rule

    @impl true
    def choose(%{message: %{message_id: id}} = view, rule_state) do
      case id do
        "turns" ->
          {{:turns, ["b2", "b1"]}, rule_state}

        "decide" <> _ ->
          {{:decide, %{"asked" => id}}, %{"asked" => id}}

        "raise" ->
          raise "host rule bug"

        "throw" ->
          throw(:host_rule_bug)

        "exit" ->
          exit(:host_rule_bug)

        "shape" ->
          {:turns, ["b1"]}

        "not-text" ->
          {{:turns, [:b1]}, rule_state}

        "seventeen" ->
          {{:turns, List.duplicate("b1", 17)}, rule_state}

        "big" ->
          {{:turns, ["b1"]}, String.duplicate("x", 1_023)}

        "fits" ->
          {{:turns, ["b1"]}, String.duplicate("x", 1_022)}

        "atom-state" ->
          {{:turns, ["b1"]}, :not_json}

        "context" ->
          {{:decide, %{"x" => String.duplicate("y", 4_089)}}, rule_state}

        "context-fits" ->
          {{:decide, %{"x" => String.duplicate("y", 4_088)}}, rule_state}

        "outsider" ->
          {{:turns, ["zz", "h1", "p1", "b1", "b1"]}, rule_state}

        "nest-30" ->
          {{:turns, ["b1"]}, Elzoo.TurnPolicyTest.nested(30)}

        "nest-31" ->
          {{:turns, ["b1"]}, Elzoo.TurnPolicyTest.nested(31)}

        "nest-41" ->
          {{:turns, ["b1"]}, Elzoo.TurnPolicyTest.nested(41)}

        "context-nest-30" ->
          {{:decide, %{"x" => Elzoo.TurnPolicyTest.nested(29)}}, rule_state}

        "context-nest-31" ->
          {{:decide, %{"x" => Elzoo.TurnPolicyTest.nested(30)}}, rule_state}

        "view" ->
          {{:turns, []}, %{"addressed" => view.addressed, "reply_to" => inspect(view.reply_to)}}

        _ ->
          {{:turns, []}, rule_state}
      end
    end

    @impl true
    def read(%{message: %{message_id: id}}, rule_state, outcome) do
      case id do
        "decide-twice" -> {{:decide, %{}}, rule_state}
        "decide-raise" -> raise "host rule bug"
        "decide-outsider" -> {{:turns, ["zz", "b2"]}, rule_state}
        _ -> {{:turns, ["b3"]}, Map.put(rule_state, "class", outcome.class)}
      end
    end
  end

  defmodule NoRead do
    def choose(_view, rule_state), do: {{:turns, []}, rule_state}
  end

  @members [
    %{"id" => "h1", "kind" => "human"},
    %{"id" => "h2", "kind" => "human"},
    %{"id" => "b1", "kind" => "bot"},
    %{"id" => "b2", "kind" => "bot"},
    %{"id" => "b3", "kind" => "bot"},
    %{"id" => "p1", "kind" => "peer"}
  ]
  @max_link 2_147_483_647

  # A JSON array nested n deep: [[...[1]...]].
  def nested(n), do: Enum.reduce(1..n//1, 1, fn _, acc -> [acc] end)

  # The engine checks every action payload with core/payload-schema, at most 32 levels deep.
  defp engine_check(action) do
    port = %{
      "id" => "p",
      "direction" => "input",
      "schema_id" => action["schema_id"],
      "schema_version" => 1
    }

    {:ok, checked} = PayloadSchema.build(port, %{})
    PayloadSchema.check(checked, port, action["payload"])
  end

  ## Inputs

  defp policy(extra) do
    Map.merge(
      %{
        "rule" => "addressed",
        "default_member" => nil,
        "max_bot_turns" => 4,
        "handoff" => "allowed",
        "post_to" => "chan:room",
        "window" => %{"messages" => 8, "bytes" => 24_576},
        "rollover" => %{"max_turns" => 63}
      },
      extra
    )
  end

  defp room(policy \\ %{}, extra \\ %{}) do
    Map.merge(
      %{
        "room_id" => "room-1",
        "link" => 1,
        "members" => @members,
        "policy" => policy(policy),
        "summary" => nil,
        "carry" => nil
      },
      extra
    )
  end

  defp input(kind, fields),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)

  defp typed(kind, schema, payload),
    do: input(kind, %{"schema_id" => schema, "schema_version" => 1, "payload" => payload})

  defp start(payload), do: typed("start", "elzoo.room.start", payload)

  defp msg(id, from, mentions \\ [], extra \\ %{}),
    do:
      typed(
        "message",
        "elzoo.room.message",
        Map.merge(
          %{"message_id" => id, "from" => from, "text" => "text of " <> id, "mentions" => mentions},
          extra
        )
      )

  defp rollover, do: typed("message", "elzoo.room.rollover", %{})

  defp outcome(id, class, schema \\ "test/none", payload \\ nil),
    do:
      input("action_outcome", %{
        "action_id" => id,
        "outcome" => class,
        "schema_id" => schema,
        "schema_version" => 1,
        "payload" => payload
      })

  defp answer(id, extra \\ %{}),
    do:
      outcome(
        id,
        "completed",
        "elzoo.room.answer",
        Map.merge(
          %{"text" => "answer", "mentions" => [], "handoff_to" => nil, "escalate" => false},
          extra
        )
      )

  defp done(id), do: outcome(id, "completed")

  defp decided(value),
    do: %{"status" => "decided", "value" => value, "repairs" => 0, "action_id" => "d/1/1:call:0"}

  defp pick(id, value),
    do: outcome(id, "completed", "elzoo.typed-decision.result", decided(value))

  defp entry(id, from, text, trust),
    do: %{
      "message_id" => id,
      "from" => from,
      "content" => %{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => ["room"],
        "trust" => trust,
        "max_bytes" => 4_096,
        "content" => text
      }
    }

  ## Driving the step

  defp new!(rules \\ %{"script" => ScriptRule}) do
    {:ok, state} = TurnPolicy.new(%{host_rules: rules})
    state
  end

  # One input; every request holds exactly one action and passes PatternStep.decode/1.
  defp step(state, input) do
    {:Transition, next, output} = TurnPolicy.step(state, input)

    case output do
      :none ->
        {next, nil}

      {:some, request} ->
        assert {:ok, _} = PatternStep.decode(request)
        assert [action] = request["actions"]
        {next, action}
    end
  end

  defp started(policy \\ %{}, extra \\ %{}) do
    {state, nil} = step(new!(), start(room(policy, extra)))
    assert state.phase == :running
    state
  end

  # The host side of a trace: `turn` gives the answer fields of a turn (or
  # `{:outcome, class}`); a decision picks "several"; every other action completes.
  defp host(turn \\ fn _ -> %{} end) do
    fn action ->
      case action["schema_id"] do
        "elzoo.room.turn" ->
          case turn.(action["payload"]) do
            {:outcome, class} -> outcome(action["id"], class)
            extra -> answer(action["id"], extra)
          end

        "elzoo.room.decide" ->
          pick(action["id"], %{"pick" => "several"})

        "elzoo.room.carry" ->
          outcome(action["id"], "completed", "elzoo.room.carry", action["payload"])

        _ ->
          done(action["id"])
      end
    end
  end

  # Answers each action until the step asks nothing, at most `n` actions. At a
  # finish the room starts the successor from the carry that the finish names.
  defp drive(state, action, reply, log \\ [], n \\ 256)
  defp drive(state, nil, _reply, log, _n), do: {state, Enum.reverse(log)}
  defp drive(state, _action, _reply, log, 0), do: {state, Enum.reverse(log)}

  defp drive(_state, %{"kind" => "finish"} = action, reply, log, n) do
    carry = Enum.find(log, &(&1["id"] == action["payload"]["action_id"]))["payload"]
    {state, next} = step(new!(), start(carry))
    drive(state, next, reply, [action | log], n - 1)
  end

  defp drive(state, action, reply, log, n) do
    {state, next} = step(state, reply.(action))
    drive(state, next, reply, [action | log], n - 1)
  end

  defp feed(state, inputs, reply \\ host()) do
    Enum.reduce(inputs, {state, []}, fn input, {state, log} ->
      {state, action} = step(state, input)
      {state, more} = drive(state, action, reply, [], 256 - length(log))
      {state, log ++ more}
    end)
  end

  defp ids(log), do: Enum.map(log, & &1["id"])

  defp turns(log),
    do: for(%{"schema_id" => "elzoo.room.turn", "payload" => p} <- log, do: p["member"])

  defp notices(log), do: for(%{"schema_id" => "elzoo.room.notice", "payload" => p} <- log, do: p)
  defp notes(state), do: state.notes

  ## 1. Built-in rules over a person's message

  test "addressed_lead_bot_and_mention_only" do
    lead = started(%{"default_member" => "b1"})
    {_, log} = feed(lead, [msg("m1", "h1")])
    assert ids(log) == ["t/1/1/turn", "t/1/1/post"]

    assert hd(log) == %{
             "id" => "t/1/1/turn",
             "kind" => "nested_callable",
             "schema_id" => "elzoo.room.turn",
             "schema_version" => 1,
             "payload" => %{
               "turn_id" => "t/1/1",
               "member" => "b1",
               "message_id" => "m1",
               "window" => [entry("m1", "h1", "text of m1", "untrusted")],
               "summary" => nil
             }
           }

    assert Enum.at(log, 1)["payload"] == %{
             "post_to" => "chan:room",
             "turn_id" => "t/1/1",
             "member" => "b1",
             "text" => "answer",
             "mentions" => []
           }

    # Mention order, each bot once, no turn for a mentioned person.
    {_, log} = feed(lead, [msg("m1", "h1", ["b3", "b2", "h2", "b3"])])
    assert ids(log) == ["t/1/1/turn", "t/1/1/post", "t/1/2/turn", "t/1/2/post"]
    assert turns(log) == ["b3", "b2"]

    mention_only = started(%{"default_member" => nil})
    assert {_, nil} = step(mention_only, msg("m1", "h1"))
    {_, log} = feed(mention_only, [msg("m1", "h1", ["b2"])])
    assert turns(log) == ["b2"]
  end

  test "round_robin_carries_its_position" do
    state = started(%{"rule" => "round_robin", "default_member" => "b3"})
    # Mentions and reply-to do not change the next bot.
    inputs = [
      msg("m1", "h1", ["b3"]),
      msg("m2", "h2", [], %{"reply_to_member" => "b1"}),
      msg("m3", "h1")
    ]

    {state, log} = feed(state, inputs)
    assert turns(log) == ["b1", "b2", "b3"]
    assert state.rule_state == 2

    {_, carry} = step(state, rollover())
    assert carry["payload"]["carry"]["rule_state"] == 2
    {state, nil} = step(new!(), start(carry["payload"]))
    {state, log} = feed(state, [msg("m4", "h2"), msg("m5", "h1")])
    assert turns(log) == ["b1", "b2"]
    assert ids(log) == ["t/2/4/turn", "t/2/4/post", "t/2/5/turn", "t/2/5/post"]
    assert state.rule_state == 1
  end

  test "everyone_in_member_order" do
    state = started(%{"rule" => "everyone", "default_member" => "b2"})
    {_, log} = feed(state, [msg("m1", "h1", ["b3"], %{"reply_to_member" => "b2"})])
    assert turns(log) == ["b1", "b2", "b3"]
    assert notices(log) == []
  end

  test "decided_asks_only_for_an_unaddressed_message" do
    state = started(%{"rule" => "decided", "default_member" => "b1"})
    {_, decision} = step(state, msg("m1", "h1"))

    assert decision == %{
             "id" => "d/1/1",
             "kind" => "nested_callable",
             "schema_id" => "elzoo.room.decide",
             "schema_version" => 1,
             "payload" => %{
               "decision_id" => "d/1/1",
               "rule" => "decided",
               "message_id" => "m1",
               "members" => ["b1", "b2", "b3"],
               "window" => [entry("m1", "h1", "text of m1", "untrusted")],
               "context" => %{}
             }
           }

    {_, log} = feed(state, [msg("m1", "h1", ["b2"])])
    assert ids(log) == ["t/1/1/turn", "t/1/1/post"] and turns(log) == ["b2"]
    {_, log} = feed(state, [msg("m1", "h1", [], %{"reply_to_member" => "b3"})])
    assert ids(log) == ["t/1/1/turn", "t/1/1/post"] and turns(log) == ["b3"]
  end

  ## 2. Reply-to

  test "reply_to" do
    for rule <- ["addressed", "decided"] do
      state = started(%{"rule" => rule, "default_member" => "b1"})
      {_, action} = step(state, msg("m1", "h1", [], %{"reply_to_member" => "b2"}))
      assert action["payload"]["member"] == "b2"

      for other <- ["h2", "zz", "p1"] do
        {next, action} = step(state, msg("m1", "h1", [], %{"reply_to_member" => other}))
        assert action["id"] == "t/1/1/turn" and action["payload"]["member"] == "b1"
        assert notes(next) == [{:reply_to_not_member, other}]
      end

      # A mention wins over a reply-to.
      {_, action} = step(state, msg("m1", "h1", ["b3"], %{"reply_to_member" => "b2"}))
      assert action["payload"]["member"] == "b3"
    end
  end

  ## 3. The pick is untrusted model output

  defp typed_finish(content, structured) do
    port = %{
      "id" => "pick",
      "direction" => "output",
      "schema_id" => "elzoo.room.pick",
      "schema_version" => 1
    }

    request = %{
      "version" => 1,
      "model" => "test-model",
      "max_output_tokens" => 64,
      "messages" => [%{"role" => "user", "text" => "Who answers?"}]
    }

    {:ok, decision} =
      TypedDecision.new(%{
        id: "d/1/1",
        request: request,
        port: port,
        answer: {:schema, TurnPolicy.pick_schema()},
        repairs: 0
      })

    {:Transition, decision, {:some, _call}} =
      TypedDecision.step(decision, typed("start", "test/any", nil))

    result = %{"content" => content, "structured" => structured, "finish" => "stop"}

    {:Transition, _, {:some, %{"actions" => [finish]}}} =
      TypedDecision.step(
        decision,
        outcome("d/1/1:call:0", "completed", "elzoo.ai-text.result", result)
      )

    assert finish["kind"] == "finish" and finish["schema_id"] == "elzoo.typed-decision.result"
    outcome("d/1/1", "completed", "elzoo.typed-decision.result", finish["payload"])
  end

  test "pick_is_untrusted_output" do
    schema_port = %{
      "id" => "pick",
      "direction" => "output",
      "schema_id" => "elzoo.room.pick",
      "schema_version" => 1
    }

    assert {:ok, checked} = PayloadSchema.build(schema_port, TurnPolicy.pick_schema())
    assert :ok = PayloadSchema.check(checked, schema_port, %{"pick" => "several"})
    assert :ok = PayloadSchema.check(checked, schema_port, %{"pick" => ["b1"]})
    assert {:error, {:violations, _}} = PayloadSchema.check(checked, schema_port, %{"pick" => 3})

    for default <- ["b1", nil] do
      {state, %{"id" => "d/1/1"}} =
        step(started(%{"rule" => "decided", "default_member" => default}), msg("m1", "h1"))

      real = typed_finish(~s({"pick":["b2","b1"]}), %{"valid" => %{"pick" => ["b2", "b1"]}})
      assert real["payload"]["status"] == "decided"
      {_, log} = drive_from(state, real)
      assert ids(log) == ["t/1/1/turn", "t/1/1/post", "t/1/2/turn", "t/1/2/post"]
      assert turns(log) == ["b2", "b1"]

      {_, log} = drive_from(state, pick("d/1/1", %{"pick" => "several"}))
      assert turns(log) == ["b1", "b2", "b3"]

      seventeen = for i <- 1..17, do: "b#{i}"

      bad = [
        pick("d/1/1", %{"pick" => ["zz"]}),
        pick("d/1/1", %{"pick" => ["b2", "h1"]}),
        pick("d/1/1", %{"pick" => ["b1", "b1"]}),
        pick("d/1/1", %{"pick" => seventeen}),
        pick("d/1/1", %{"pick" => ["b1", "b2", "b3" | List.duplicate("b3", 14)]}),
        pick("d/1/1", %{"pick" => []}),
        pick("d/1/1", %{"pick" => 3}),
        pick("d/1/1", %{"pick" => "everyone"}),
        pick("d/1/1", %{"pick" => ["b1"], "extra" => true}),
        pick("d/1/1", "b1"),
        outcome("d/1/1", "completed", "elzoo.typed-decision.result", %{
          "status" => "failed",
          "value" => %{"pick" => ["b1"]}
        }),
        outcome("d/1/1", "completed", "other.schema", decided(%{"pick" => ["b2"]})),
        typed_finish(~s({"pick":3}), %{"invalid" => "schema_mismatch"}),
        typed_finish(~s({"pick":["b2","zz"]}), %{"valid" => %{"pick" => ["b2", "zz"]}}),
        outcome("d/1/1", "failed", "elzoo.typed-decision.result", decided(%{"pick" => ["b2"]})),
        outcome("d/1/1", "expired")
      ]

      for input <- bad do
        {next, log} = drive_from(state, input)
        assert turns(log) == List.wrap(default), inspect(input)
        assert {:decision_fallback, "m1"} in notes(next)
      end

      # A late outcome changes nothing.
      assert {^state, nil} = step(state, outcome("d/1/1", "late"))
    end
  end

  defp drive_from(state, input) do
    {state, action} = step(state, input)
    drive(state, action, host())
  end

  ## 4. Host rules

  test "host_rules_fail_closed" do
    state = started(%{"rule" => "script", "default_member" => "b1"})
    {_, log} = feed(state, [msg("turns", "h1")])
    assert turns(log) == ["b2", "b1"]

    {waiting, decision} = step(state, msg("decide", "h1"))
    assert decision["id"] == "d/1/1"

    assert decision["payload"]["rule"] == "script" and
             decision["payload"]["context"] == %{"asked" => "decide"}

    {next, log} = drive_from(waiting, outcome("d/1/1", "failed"))
    assert turns(log) == ["b3"]
    assert next.rule_state == %{"asked" => "decide", "class" => "failed"}

    {_, %{"id" => "d/1/1"}} = step(state, msg("context-fits", "h1"))

    for id <- ~w(raise throw exit shape not-text seventeen big atom-state context) do
      {next, nil} = step(state, msg(id, "h1"))
      assert notes(next) == [{:host_rule_failed, id}], id
      assert next.rule_state == nil and next.queue == []
    end

    for id <- ~w(decide-twice decide-raise) do
      {waiting, %{"id" => "d/1/1"}} = step(state, msg(id, "h1"))
      {next, nil} = step(waiting, pick("d/1/1", %{"pick" => ["b1"]}))
      assert hd(notes(next)) == {:host_rule_failed, id}
      # The rule state of the valid choose answer stays; read changed nothing.
      assert next.rule_state == %{"asked" => id} and next.queue == []
    end

    {next, log} = feed(state, [msg("fits", "h1")])
    assert turns(log) == ["b1"] and next.rule_state == String.duplicate("x", 1_022)

    {next, log} = feed(state, [msg("outsider", "h1")])
    assert turns(log) == ["b1"]

    assert notes(next) == [
             {:repeated_member, "b1"},
             {:not_member, "p1"},
             {:not_member, "h1"},
             {:not_member, "zz"}
           ]

    {waiting, _} = step(state, msg("decide-outsider", "h1"))
    {_, log} = drive_from(waiting, outcome("d/1/1", "failed"))
    assert turns(log) == ["b2"]

    # A host rule gets the addressing and decides itself: no fallback to b1.
    {next, nil} = step(state, msg("view", "h1", ["b2", "zz"], %{"reply_to_member" => "h2"}))
    assert next.rule_state == %{"addressed" => ["b2"], "reply_to" => ":invalid"}

    # The spec of new/1.
    assert {:error, :invalid_spec} = TurnPolicy.new(%{host_rules: %{"addressed" => ScriptRule}})
    assert {:error, :invalid_spec} = TurnPolicy.new(%{host_rules: %{"Big" => ScriptRule}})

    assert {:error, :invalid_spec} =
             TurnPolicy.new(%{host_rules: %{String.duplicate("a", 65) => ScriptRule}})

    assert {:ok, _} = TurnPolicy.new(%{host_rules: %{String.duplicate("a", 64) => ScriptRule}})
    assert {:error, :invalid_spec} = TurnPolicy.new(%{host_rules: %{"x" => NoRead}})
    assert {:error, :invalid_spec} = TurnPolicy.new(%{host_rules: %{"x" => Elzoo.NotLoaded}})

    assert {:error, :invalid_spec} =
             TurnPolicy.new(%{host_rules: Map.new(1..9, &{"r#{&1}", ScriptRule})})

    assert {:ok, _} = TurnPolicy.new(%{host_rules: Map.new(1..8, &{"r#{&1}", ScriptRule})})
    assert {:error, :invalid_spec} = TurnPolicy.new(%{host_rules: %{}, extra: 1})
  end

  test "host_rule_nesting_keeps_the_carry" do
    state = started(%{"rule" => "script", "default_member" => "b1"})

    for id <- ~w(nest-31 nest-41 context-nest-31) do
      {next, nil} = step(state, msg(id, "h1"))
      assert notes(next) == [{:host_rule_failed, id}], id
      assert next.rule_state == nil
    end

    # At the edge, the decide payload and the carry payload stay within 32 levels.
    {_, decide} = step(state, msg("context-nest-30", "h1"))
    assert decide["id"] == "d/1/1" and engine_check(decide) == :ok

    {next, _} = feed(state, [msg("nest-30", "h1")])
    assert next.rule_state == nested(30)
    {_, carry} = step(next, rollover())
    assert carry["id"] == "c/1/1" and engine_check(carry) == :ok

    # A rule state 41 levels deep never reaches the carry, so the room can still roll over.
    {next, _} = feed(state, [msg("nest-41", "h1")])
    {next, carry} = step(next, rollover())
    assert carry["id"] == "c/1/1" and engine_check(carry) == :ok
    {_, finish} = step(next, outcome("c/1/1", "completed", "elzoo.room.carry", carry["payload"]))
    assert finish["payload"] == %{"action_id" => "c/1/1"}
  end

  ## 5. The guards under each rule

  test "one_open_turn_at_a_time" do
    # Each request of a trace holds one action (step/2 asserts it), and each turn
    # is followed by its own post before anything else is asked.
    for {rule, expected} <- [
          {"addressed", ["b1", "b2"]},
          {"round_robin", ["b1"]},
          {"everyone", ["b1", "b2", "b3"]},
          {"decided", ["b1", "b2"]},
          {"script", ["b2", "b1"]}
        ] do
      state = started(%{"rule" => rule, "default_member" => "b1"})
      {_, log} = feed(state, [msg("turns", "h1", ["b1", "b2"])])
      assert turns(log) == expected

      assert ids(log) ==
               Enum.flat_map(1..length(expected), &["t/1/#{&1}/turn", "t/1/#{&1}/post"])
    end

    state = started(%{"rule" => "everyone"})
    {state, %{"id" => "t/1/1/turn"}} = step(state, msg("m1", "h1"))
    # While the turn is open, no message, no other outcome and no decision changes anything.
    assert {^state, nil} = step(state, msg("m2", "h1", ["b2"]))
    assert {^state, nil} = step(state, outcome("t/1/2/turn", "completed"))
    assert {^state, nil} = step(state, outcome("t/1/1/post", "completed"))
    {state, %{"id" => "t/1/1/post"}} = step(state, answer("t/1/1/turn"))
    assert {^state, nil} = step(state, outcome("t/1/2/turn", "completed"))
    {_state, %{"id" => "t/1/2/turn"}} = step(state, done("t/1/1/post"))

    decided = started(%{"rule" => "decided", "default_member" => "b1"})
    {decided, %{"id" => "t/1/1/turn"}} = step(decided, msg("m1", "h1", ["b1"]))
    assert {^decided, nil} = step(decided, msg("m2", "h1"))
  end

  test "members_only" do
    for rule <- ["addressed", "round_robin", "everyone", "decided", "script"] do
      state = started(%{"rule" => rule, "default_member" => "b1"})
      {next, nil} = step(state, msg("m1", "zz", ["b1", "b2"]))
      assert notes(next) == [{:not_member, "zz"}]
      assert next.window == [] and next.queue == [] and next.bot_turns == 0
    end

    state = started(%{"default_member" => nil})
    {next, log} = feed(state, [msg("m1", "h1", ["zz", "b2"])])
    assert turns(log) == ["b2"]
    assert {:not_member, "zz"} in notes(next)

    # An answer that mentions a non-member queues no turn for it.
    {next, log} =
      feed(state, [msg("m1", "h1", ["b1"])], host(fn _ -> %{"mentions" => ["zz", "h2"]} end))

    assert turns(log) == ["b1"]
    assert {:not_member, "zz"} in notes(next)
  end

  defp ping_pong(turn \\ nil) do
    turn =
      turn ||
        fn %{"member" => member} -> %{"mentions" => [if(member == "b1", do: "b2", else: "b1")]} end

    host(turn)
  end

  test "bot_turn_bound_at_its_edge" do
    for rule <- ["addressed", "decided", "script", "round_robin"] do
      state = started(%{"rule" => rule, "max_bot_turns" => 3, "default_member" => "b1"})
      first = if rule == "script", do: "turns", else: "m1"
      {state, log} = feed(state, [msg(first, "h1", ["b1"])], ping_pong())

      # The trace stops by itself: the host would answer for 256 entries.
      assert length(log) < 256, rule
      expected_first = if rule == "script", do: "b2", else: "b1"
      assert length(turns(log)) == 3, rule
      assert hd(turns(log)) == expected_first

      assert [%{"reason" => "bot_turn_bound", "members" => ["h1", "h2"], "notice_id" => "n/1/1"}] =
               notices(log)

      assert "n/1/1" in ids(log)
      assert state.awaiting == true and state.queue == []

      # A bot's message while awaiting a person queues nothing.
      {state, nil} = step(state, msg("m2", "b3", ["b1"]))
      assert hd(notes(state)) == {:awaiting_person, "b1"}

      # A person's message resumes the room.
      {state, log} = feed(state, [msg(first, "h2", ["b2"])], host())
      assert state.awaiting == false and length(turns(log)) >= 1
    end

    state = started(%{"max_bot_turns" => 3})
    {_, log} = feed(state, [msg("m1", "h1", ["b1"])], ping_pong())

    assert ids(log) == [
             "t/1/1/turn",
             "t/1/1/post",
             "t/1/2/turn",
             "t/1/2/post",
             "t/1/3/turn",
             "t/1/3/post",
             "n/1/1"
           ]

    assert turns(log) == ["b1", "b2", "b1"]

    # A person's message that names more bots than the bound starts exactly the bound.
    state = started(%{"max_bot_turns" => 2})
    {next, log} = feed(state, [msg("m1", "h1", ["b1", "b2", "b3"])])
    assert turns(log) == ["b1", "b2"]
    assert ids(log) == ["n/1/1", "t/1/1/turn", "t/1/1/post", "t/1/2/turn", "t/1/2/post"]
    assert {:bot_turn_bound, "b3"} in notes(next)

    # A bound of 1.
    state = started(%{"max_bot_turns" => 1})
    {_, log} = feed(state, [msg("m1", "h1", ["b1"])], ping_pong())
    assert turns(log) == ["b1"] and length(notices(log)) == 1
  end

  test "everyone_exactly_at_the_bound_posts_no_notice" do
    state = started(%{"rule" => "everyone", "max_bot_turns" => 3})
    {next, log} = feed(state, [msg("m1", "h1")])
    assert turns(log) == ["b1", "b2", "b3"] and notices(log) == []
    assert next.awaiting == false and next.bot_turns == 3

    # Any further bot turn passes the bound, whatever named it.
    {_, log} = feed(state, [msg("m1", "h1")], host(fn _ -> %{"mentions" => ["b1"]} end))
    assert turns(log) == ["b1", "b2", "b3"] and length(notices(log)) == 1
  end

  defp two_rooms(peer_kind \\ "peer") do
    a =
      room(%{"max_bot_turns" => 3}, %{
        "room_id" => "room-a",
        "members" => [
          %{"id" => "h1", "kind" => "human"},
          %{"id" => "a1", "kind" => "bot"},
          %{"id" => "rb", "kind" => peer_kind}
        ]
      })

    b =
      room(%{"max_bot_turns" => 3}, %{
        "room_id" => "room-b",
        "members" => [
          %{"id" => "h9", "kind" => "human"},
          %{"id" => "b9", "kind" => "bot"},
          %{"id" => "ra", "kind" => peer_kind}
        ]
      })

    {a, nil} = step(new!(), start(a))
    {b, nil} = step(new!(), start(b))
    exchange(%{a: a, b: b}, [{:a, msg("m1", "h1", ["a1"])}], [])
  end

  # Each room's bot answers by mentioning the other room's bot; each post is
  # delivered to the other room as a message from its peer member.
  defp exchange(states, [], log), do: {states, log}
  defp exchange(states, _, log) when length(log) >= 256, do: {states, log}

  defp exchange(states, [{room, input} | rest], log) do
    {other, other_bot, peer} = if room == :a, do: {:b, "b9", "ra"}, else: {:a, "a1", "rb"}
    {state, action} = step(states[room], input)
    {state, actions} = drive(state, action, host(fn _ -> %{"mentions" => [other_bot]} end))

    delivered =
      for %{"schema_id" => "elzoo.room.post", "payload" => p} <- actions,
          do: {other, msg("#{room}:#{p["turn_id"]}", peer, p["mentions"])}

    exchange(Map.put(states, room, state), rest ++ delivered, log ++ Enum.map(actions, &{room, &1}))
  end

  test "two_rooms_stop_at_the_bound" do
    {states, log} = two_rooms()
    assert length(log) < 256
    a = for {:a, action} <- log, do: action
    b = for {:b, action} <- log, do: action
    assert length(turns(a)) == 3 and length(turns(b)) == 3
    assert length(notices(a)) == 1 and notices(b) == []
    assert states.a.awaiting and not states.b.awaiting
  end

  test "escalation" do
    state = started(%{"max_bot_turns" => 4})
    reply = host(fn %{"member" => m} -> if m == "b1", do: %{"escalate" => true}, else: %{} end)
    {next, log} = feed(state, [msg("m1", "h1", ["b1", "b2"])], reply)
    assert ids(log) == ["t/1/1/turn", "t/1/1/post", "n/1/1"]
    assert [%{"reason" => "escalated", "members" => ["h1", "h2"]}] = notices(log)
    assert next.awaiting and next.queue == []

    # A peer's message mentioning a bot while awaiting a person queues nothing.
    {next, nil} = step(next, msg("m2", "p1", ["b2"]))
    assert hd(notes(next)) == {:awaiting_person, "b2"}
    {next, log} = feed(next, [msg("m3", "h2", ["b2"])])
    assert turns(log) == ["b2"] and not next.awaiting
  end

  test "bound_then_escalation_posts_one_notice" do
    state = started(%{"max_bot_turns" => 2})

    reply =
      host(fn
        %{"member" => "b1"} -> %{"mentions" => ["b3"]}
        %{"member" => "b2"} -> %{"escalate" => true}
      end)

    {next, log} = feed(state, [msg("m1", "h1", ["b1", "b2"])], reply)
    assert ids(log) == ["t/1/1/turn", "t/1/1/post", "n/1/1", "t/1/2/turn", "t/1/2/post"]
    assert [%{"reason" => "bot_turn_bound"}] = notices(log)
    assert Enum.take(notes(next), 2) == [{:escalated, "b2"}, {:bot_turn_bound, "b3"}]
  end

  test "handoff" do
    state = started(%{"default_member" => "b1", "handoff" => "allowed"})
    {next, _} = feed(state, [msg("m1", "h1")], host(fn _ -> %{"handoff_to" => "b2"} end))
    assert next.default_member == "b2" and hd(notes(next)) == {:handoff, "b2"}
    {_, log} = feed(next, [msg("m2", "h1")])
    assert turns(log) == ["b2"]

    for target <- ["zz", "h1", "p1"] do
      {next, _} = feed(state, [msg("m1", "h1")], host(fn _ -> %{"handoff_to" => target} end))
      assert next.default_member == "b1" and hd(notes(next)) == {:handoff_not_member, target}
    end

    denied = started(%{"default_member" => "b1", "handoff" => "denied"})
    {next, log} = feed(denied, [msg("m1", "h1")], host(fn _ -> %{"handoff_to" => "b2"} end))
    # The answer is still posted.
    assert ids(log) == ["t/1/1/turn", "t/1/1/post"]
    assert next.default_member == "b1" and hd(notes(next)) == {:handoff_denied, "b2"}
  end

  test "window_eviction_at_its_edges" do
    one = entry("m1", "h1", "text of m1", "untrusted")
    two = entry("m2", "h1", "text of m2", "untrusted")
    three = entry("m3", "h1", "text of m3", "untrusted")
    inputs = [msg("m1", "h1"), msg("m2", "h1"), msg("m3", "h1")]

    {next, _} = feed(started(%{"window" => %{"messages" => 2, "bytes" => 24_576}}), inputs)
    assert next.window == [three, two]
    {next, _} = feed(started(%{"window" => %{"messages" => 3, "bytes" => 24_576}}), inputs)
    assert next.window == [three, two, one]

    exact = byte_size(Jason.encode!([three, two]))
    {next, _} = feed(started(%{"window" => %{"messages" => 8, "bytes" => exact}}), inputs)
    assert next.window == [three, two]
    {next, _} = feed(started(%{"window" => %{"messages" => 8, "bytes" => exact - 1}}), inputs)
    assert next.window == [three]

    # The newest message stays alone even when it is larger than the bound.
    {next, _} = feed(started(%{"window" => %{"messages" => 8, "bytes" => 1}}), inputs)
    assert next.window == [three]

    # A bot's message and a bot's answer are derived; a peer's message is untrusted.
    {next, _} = feed(started(), [msg("m1", "b2"), msg("m2", "p1")])

    assert next.window == [
             entry("m2", "p1", "text of m2", "untrusted"),
             entry("m1", "b2", "text of m1", "derived")
           ]
  end

  ## 6. Start edges

  defp id(n, fill \\ "x"), do: String.duplicate(fill, n)

  test "start_edges_agree" do
    bots = fn n -> for i <- 1..n, do: %{"id" => "b#{i}", "kind" => "bot"} end
    many = fn n -> [%{"id" => "h1", "kind" => "human"} | bots.(n - 1)] end

    cases = [
      {room(%{}, %{"members" => many.(32)}), :ok},
      {room(%{}, %{"members" => many.(33)}), {:error, :malformed}},
      {room(%{"max_bot_turns" => 0}), {:error, :malformed}},
      {room(%{"max_bot_turns" => 1}), :ok},
      {room(%{"max_bot_turns" => 16}), :ok},
      {room(%{"max_bot_turns" => 17}), {:error, :malformed}},
      {room(%{"rollover" => %{"max_turns" => 63}}), :ok},
      {room(%{"rollover" => %{"max_turns" => 64}}), {:error, :malformed}},
      {room(%{"rollover" => %{"max_turns" => 0}}), {:error, :malformed}},
      {room(%{"window" => %{"messages" => 1, "bytes" => 1}}), :ok},
      {room(%{"window" => %{"messages" => 8, "bytes" => 24_576}}), :ok},
      {room(%{"window" => %{"messages" => 0, "bytes" => 1}}), {:error, :malformed}},
      {room(%{"window" => %{"messages" => 9, "bytes" => 1}}), {:error, :malformed}},
      {room(%{"window" => %{"messages" => 1, "bytes" => 0}}), {:error, :malformed}},
      {room(%{"window" => %{"messages" => 1, "bytes" => 24_577}}), {:error, :malformed}},
      {room(%{"window" => %{"messages" => 1}}), {:error, :malformed}},
      {room(%{}, %{"members" => [%{"id" => id(128), "kind" => "bot"}]}), :ok},
      {room(%{}, %{"members" => [%{"id" => id(129), "kind" => "bot"}]}), {:error, :malformed}},
      {room(%{}, %{"members" => [%{"id" => "b\u0085", "kind" => "bot"}]}), {:error, :malformed}},
      {room(%{}, %{"members" => [%{"id" => "b\n", "kind" => "bot"}]}), {:error, :malformed}},
      {room(%{}, %{"members" => [%{"id" => "b1", "kind" => "robot"}]}), {:error, :malformed}},
      {room(%{}, %{
         "members" => [%{"id" => "b1", "kind" => "bot"}, %{"id" => "b1", "kind" => "human"}]
       }), {:error, :malformed}},
      {room(%{}, %{"members" => []}), {:error, :malformed}},
      {room(%{}, %{"room_id" => id(128)}), :ok},
      {room(%{}, %{"room_id" => id(129)}), {:error, :malformed}},
      {room(%{}, %{"link" => 0}), {:error, :malformed}},
      {room(%{}, %{"link" => @max_link}), :ok},
      {room(%{}, %{"link" => @max_link + 1}), {:error, :malformed}},
      {room(%{"post_to" => id(256)}), :ok},
      {room(%{"post_to" => id(257)}), {:error, :malformed}},
      {room(%{"handoff" => "maybe"}), {:error, :malformed}},
      {room(%{}, %{"summary" => id(8_190)}), :ok},
      {room(%{}, %{"summary" => id(8_191)}), {:error, :malformed}},
      {room(%{}, %{"summary" => String.duplicate(<<1>>, 1_365)}), :ok},
      {room(%{}, %{"summary" => String.duplicate(<<1>>, 1_366)}), {:error, :malformed}},
      {room(%{"rule" => "everyone", "max_bot_turns" => 3}), :ok},
      {room(%{"rule" => "everyone", "max_bot_turns" => 2}), {:error, :too_many_bots}},
      {room(%{"rule" => "decided", "max_bot_turns" => 2}), {:error, :too_many_bots}},
      {room(%{"rule" => "round_robin", "max_bot_turns" => 1}), :ok},
      {room(%{"rule" => "script", "max_bot_turns" => 1}), :ok},
      {room(%{"rule" => "nope"}), {:error, :unknown_rule}},
      {room(%{"rule" => 3}), {:error, :malformed}},
      {room(%{"default_member" => "h1"}), {:error, :default_member}},
      {room(%{"default_member" => "p1"}), {:error, :default_member}},
      {room(%{"default_member" => "zz"}), {:error, :default_member}},
      {room(%{"default_member" => "b3"}), :ok},
      {room(%{"extra" => 1}), {:error, :malformed}},
      {Map.delete(room(), "summary"), {:error, :malformed}},
      {Map.put(room(), "extra", 1), {:error, :malformed}},
      {"not a map", {:error, :malformed}}
    ]

    for {payload, expected} <- cases do
      assert TurnPolicy.check_start(new!(), payload) == expected, inspect(payload, limit: 8)
      {state, nil} = step(new!(), start(payload))

      case expected do
        :ok -> assert state.phase == :running
        {:error, reason} -> assert state.phase == :invalid_start and state.invalid_start == reason
      end
    end

    # A carry-over start keeps the bot-turn bound: every queued turn is counted in
    # bot_turns, and bot_turns stays within this start's max_bot_turns.
    carried = fn max, queued, bot_turns ->
      room(%{"max_bot_turns" => max}, %{
        "link" => 2,
        "carry" => %{
          "window" => [],
          "bot_turns" => bot_turns,
          "default_member" => nil,
          "rule_state" => nil,
          "awaiting_person" => false,
          "queue" => for(_ <- 1..queued//1, do: %{"member" => "b1", "message_id" => "m1"}),
          "seq" => %{"turn" => 0, "notice" => 0, "decision" => 0},
          "notes" => []
        }
      })
    end

    for {payload, expected} <- [
          {carried.(3, 3, 3), :ok},
          {carried.(3, 3, 2), {:error, :carry}},
          {carried.(3, 3, 0), {:error, :carry}},
          {carried.(3, 0, 3), :ok},
          {carried.(3, 0, 4), {:error, :carry}},
          {carried.(2, 2, 2), :ok},
          {carried.(2, 16, 16), {:error, :carry}},
          {carried.(2, 16, 0), {:error, :carry}},
          {carried.(16, 16, 16), :ok}
        ] do
      assert TurnPolicy.check_start(new!(), payload) == expected,
             inspect(payload["carry"], limit: 4)

      {state, action} = step(new!(), start(payload))

      case expected do
        :ok ->
          assert state.phase == :running

        {:error, reason} ->
          assert action == nil and state.phase == :invalid_start and state.invalid_start == reason
      end
    end

    # A successor that starts at the bound runs its queued turns and no more.
    {state, first} = step(new!(), start(carried.(3, 3, 3)))
    {_, log} = drive(state, first, host(fn _ -> %{"mentions" => ["b2"]} end))
    assert turns(log) == ["b1", "b1", "b1"] and length(notices(log)) == 1

    # A carried rule state keeps the nesting bound: 30 levels pass, 31 are malformed.
    deep = fn n -> put_in(carried.(3, 0, 0), ["carry", "rule_state"], nested(n)) end
    assert TurnPolicy.check_start(new!(), deep.(30)) == :ok
    assert TurnPolicy.check_start(new!(), deep.(31)) == {:error, :malformed}
    {state, nil} = step(new!(), start(deep.(31)))
    assert state.invalid_start == :malformed

    # A host rule name is known only from the state of new/1.
    assert TurnPolicy.check_start(new!(%{}), room(%{"rule" => "script"})) == {:error, :unknown_rule}

    # A start of another schema is malformed.
    {state, nil} = step(new!(), typed("start", "other.schema", room()))
    assert state.invalid_start == :malformed
  end

  ## 7. The carry

  test "carry_at_max_turns_and_the_successor" do
    state = started(%{"rollover" => %{"max_turns" => 2}})
    {state, log} = drive_until_carry(state, msg("m1", "h1", ["b1", "b2", "b3"]))
    assert ids(log) == ["t/1/1/turn", "t/1/1/post", "t/1/2/turn", "t/1/2/post", "c/1/1"]
    carry = List.last(log)
    assert carry["kind"] == "local_work" and carry["schema_id"] == "elzoo.room.carry"

    expected =
      Map.merge(room(%{"rollover" => %{"max_turns" => 2}}), %{
        "link" => 2,
        "carry" => %{
          "window" => [
            entry("t/1/2", "b2", "answer", "derived"),
            entry("t/1/1", "b1", "answer", "derived"),
            entry("m1", "h1", "text of m1", "untrusted")
          ],
          "bot_turns" => 3,
          "default_member" => nil,
          "rule_state" => nil,
          "awaiting_person" => false,
          "queue" => [%{"member" => "b3", "message_id" => "m1"}],
          "seq" => %{"turn" => 2, "notice" => 0, "decision" => 0},
          "notes" => []
        }
      })

    assert carry["payload"] == expected
    assert TurnPolicy.check_start(new!(), expected) == :ok

    # While the carry is open nothing else is asked.
    assert {^state, nil} = step(state, msg("m2", "h1", ["b1"]))
    {finished, finish} = step(state, outcome("c/1/1", "completed", "elzoo.room.carry", expected))

    assert finish == %{
             "id" => "f/1",
             "kind" => "finish",
             "schema_id" => "elzoo.room.finish",
             "schema_version" => 1,
             "payload" => %{"action_id" => "c/1/1"}
           }

    assert {^finished, nil} = step(finished, msg("m2", "h1", ["b1"]))

    # The successor runs the queued turn first, continues the sequences and
    # counts its own turns from zero.
    {next, first} = step(new!(), start(expected))
    assert first["id"] == "t/2/3/turn" and first["payload"]["member"] == "b3"
    assert first["payload"]["message_id"] == "m1"
    assert next.bot_turns == 3 and next.run_turns == 1
    {next, log} = drive(next, first, host())
    assert ids(log) == ["t/2/3/turn", "t/2/3/post"]
    assert next.phase == :running
    {_next, log} = feed(next, [msg("m2", "h1", ["b1"])])
    assert ids(log) |> Enum.take(3) == ["t/2/4/turn", "t/2/4/post", "c/2/1"]
  end

  defp drive_until_carry(state, input) do
    {state, action} = step(state, input)

    stop = fn
      %{"kind" => "local_work"} -> true
      _ -> false
    end

    walk(state, action, stop, [])
  end

  defp walk(state, nil, _stop, log), do: {state, Enum.reverse(log)}

  defp walk(state, action, stop, log) do
    if stop.(action) do
      {state, Enum.reverse([action | log])}
    else
      {state, next} = step(state, host().(action))
      walk(state, next, stop, [action | log])
    end
  end

  test "carry_continues_default_rule_state_bot_turns_and_sequences" do
    state = started(%{"rule" => "round_robin", "default_member" => "b1", "max_bot_turns" => 3})
    {state, log} = feed(state, [msg("m1", "h1")], host(fn _ -> %{"handoff_to" => "b3"} end))
    assert turns(log) == ["b1"]
    {state, _} = feed(state, [msg("m2", "b2", ["b1"])])
    {_, carry} = step(state, rollover())
    assert carry["id"] == "c/1/1"
    c = carry["payload"]["carry"]
    assert c["default_member"] == "b3" and c["rule_state"] == 0 and c["bot_turns"] == 2
    assert c["seq"] == %{"turn" => 2, "notice" => 0, "decision" => 0}
    assert c["notes"] == [%{"code" => "handoff", "ref" => "b3"}]

    {next, nil} = step(new!(), start(carry["payload"]))
    assert next.default_member == "b3" and next.rule_state == 0 and next.bot_turns == 2
    assert next.notes == [{:handoff, "b3"}]
    {_, log} = feed(next, [msg("m3", "h1")])
    assert turns(log) == ["b2"] and hd(ids(log)) == "t/2/3/turn"

    # awaiting_person is carried too.
    bound = started(%{"max_bot_turns" => 1})
    {bound, _} = feed(bound, [msg("m1", "h1", ["b1", "b2"])])
    {_, carry} = step(bound, rollover())
    assert carry["payload"]["carry"]["awaiting_person"] == true
    {next, nil} = step(new!(), start(carry["payload"]))
    assert {_, nil} = step(next, msg("m2", "b1", ["b2"]))
  end

  test "restart_carry" do
    with_queue =
      Map.merge(room(), %{
        "link" => 4,
        "carry" => %{
          "window" => [entry("m1", "h1", "hi", "untrusted")],
          "bot_turns" => 2,
          "default_member" => "b1",
          "rule_state" => %{"k" => 1},
          "awaiting_person" => false,
          "queue" => [%{"member" => "b2", "message_id" => "m1"}],
          "seq" => %{"turn" => 7, "notice" => 1, "decision" => 2},
          "notes" => [%{"code" => "handoff", "ref" => "b1"}]
        }
      })

    assert {:ok, restarted} = TurnPolicy.restart_carry(with_queue)

    assert restarted ==
             Map.merge(with_queue, %{
               "link" => 5,
               "carry" =>
                 Map.merge(with_queue["carry"], %{
                   "queue" => [],
                   "notes" => [
                     %{"code" => "restarted_queue_dropped", "ref" => nil},
                     %{"code" => "handoff", "ref" => "b1"}
                   ]
                 })
             })

    assert TurnPolicy.check_start(new!(), restarted) == :ok
    {next, nil} = step(new!(), start(restarted))
    assert next.queue == [] and next.phase == :running

    assert TurnPolicy.restart_carry(room(%{}, %{"link" => 9})) == {:ok, room(%{}, %{"link" => 10})}
    assert TurnPolicy.restart_carry(room(%{}, %{"link" => @max_link})) == {:error, :link_limit}
    assert TurnPolicy.restart_carry(%{"link" => "1"}) == {:error, :malformed}
    assert TurnPolicy.restart_carry(:nope) == {:error, :malformed}

    sixteen = for i <- 1..16, do: %{"code" => "post_failed", "ref" => "b#{i}"}
    {:ok, full} = TurnPolicy.restart_carry(put_in(with_queue, ["carry", "notes"], sixteen))
    assert length(full["carry"]["notes"]) == 16
    assert hd(full["carry"]["notes"])["code"] == "restarted_queue_dropped"
  end

  test "failed_carry_then_message_then_completed_carry" do
    state = started(%{"rollover" => %{"max_turns" => 1}})
    {state, log} = drive_until_carry(state, msg("m1", "h1", ["b1"]))
    assert ids(log) == ["t/1/1/turn", "t/1/1/post", "c/1/1"]
    {state, nil} = step(state, outcome("c/1/1", "failed"))
    assert state.phase == :carrying and hd(notes(state)) == {:carry_failed, nil}

    {state, carry} = step(state, msg("m2", "h1", ["b2"]))
    assert carry["id"] == "c/1/2"
    assert carry["payload"]["carry"]["queue"] == [%{"member" => "b2", "message_id" => "m2"}]
    assert hd(carry["payload"]["carry"]["window"])["message_id"] == "m2"
    {_, finish} = step(state, outcome("c/1/2", "completed", "elzoo.room.carry", carry["payload"]))
    assert finish["payload"] == %{"action_id" => "c/1/2"}

    # The rollover message while carrying asks the carry again, once.
    {state, nil} = step(state, outcome("c/1/2", "failed"))
    {_, carry} = step(state, rollover())
    assert carry["id"] == "c/1/3"
  end

  test "carrying_queue_keeps_max_bot_turns" do
    state = started(%{"max_bot_turns" => 3, "rollover" => %{"max_turns" => 1}})
    {state, log} = drive_until_carry(state, msg("m1", "h1", ["b1", "b2", "b3"]))
    assert List.last(log)["payload"]["carry"]["queue"] |> length() == 2
    {state, nil} = step(state, outcome("c/1/1", "failed"))

    {state, carry} = step(state, msg("m2", "h1", ["b1", "b2", "b3"]))
    assert carry["id"] == "c/1/2"

    assert carry["payload"]["carry"]["queue"] == [
             %{"member" => "b2", "message_id" => "m1"},
             %{"member" => "b3", "message_id" => "m1"},
             %{"member" => "b1", "message_id" => "m2"}
           ]

    assert hd(carry["payload"]["carry"]["window"])["message_id"] == "m2"
    assert Enum.take(notes(state), 2) == [{:carry_queue_full, "b3"}, {:carry_queue_full, "b2"}]

    # A turn that the bound leaves out while carrying is only a note.
    state = started(%{"max_bot_turns" => 3, "rollover" => %{"max_turns" => 1}})
    {state, _} = drive_until_carry(state, msg("m1", "h1", ["b1", "b2"]))
    {state, nil} = step(state, outcome("c/1/1", "failed"))
    assert state.bot_turns == 2 and length(state.queue) == 1
    {state, %{"id" => "c/1/2"}} = step(state, msg("m2", "b1", ["b3"]))
    {state, nil} = step(state, outcome("c/1/2", "failed"))
    assert state.bot_turns == 3 and length(state.queue) == 2
    {state, carry} = step(state, msg("m3", "b1", ["b1"]))
    assert carry["id"] == "c/1/3" and length(carry["payload"]["carry"]["queue"]) == 2
    assert hd(notes(state)) == {:bot_turn_bound, "b1"}
    refute state.awaiting
    assert state.notice == nil
  end

  test "decided_while_carrying_asks_no_decision" do
    state =
      started(%{"rule" => "decided", "default_member" => "b1", "rollover" => %{"max_turns" => 1}})

    {state, _} = drive_until_carry(state, msg("m1", "h1", ["b2"]))
    {state, nil} = step(state, outcome("c/1/1", "failed"))
    {state, carry} = step(state, msg("m2", "h1"))
    assert carry["id"] == "c/1/2"
    assert carry["payload"]["carry"]["queue"] == [%{"member" => "b1", "message_id" => "m2"}]
    assert hd(notes(state)) == {:decision_fallback, "m2"}
    assert carry["payload"]["carry"]["seq"]["decision"] == 0

    host_rule =
      started(%{"rule" => "script", "default_member" => nil, "rollover" => %{"max_turns" => 1}})

    {host_rule, _} = drive_until_carry(host_rule, msg("turns", "h1"))
    {host_rule, nil} = step(host_rule, outcome("c/1/1", "failed"))
    {host_rule, %{"id" => "c/1/2"}} = step(host_rule, msg("decide", "h1"))
    assert hd(notes(host_rule)) == {:decision_fallback, "decide"}
  end

  test "link_limit" do
    state = started(%{"rollover" => %{"max_turns" => 1}}, %{"link" => @max_link})
    {state, log} = feed(state, [msg("m1", "h1", ["b1"]), msg("m2", "h1", ["b2"])])

    assert ids(log) == [
             "t/2147483647/1/turn",
             "t/2147483647/1/post",
             "t/2147483647/2/turn",
             "t/2147483647/2/post"
           ]

    assert {:link_limit, nil} in notes(state)
    {state, nil} = step(state, rollover())
    assert hd(notes(state)) == {:link_limit, nil} and state.phase == :running
  end

  ## 8. Action IDs

  test "action_ids_are_distinct" do
    state = started(%{"rule" => "decided", "default_member" => "b1"})

    {_, log} =
      feed(state, [
        msg("m1", "h1", ["b1"]),
        msg("m2", "h1", ["b1"]),
        msg("m3", "h1"),
        msg("m4", "h1")
      ])

    assert ["t/1/1/turn", "t/1/1/post", "t/1/2/turn", "t/1/2/post", "d/1/1" | rest] = ids(log)
    assert "d/1/2" in rest
    assert Enum.filter(turns(log), &(&1 == "b1")) |> length() >= 2

    # A long trace across several links: decisions, notices, carries and finishes.
    state =
      started(%{
        "rule" => "decided",
        "default_member" => "b1",
        "max_bot_turns" => 3,
        "rollover" => %{"max_turns" => 5}
      })

    reply = ping_pong()

    {_, log} =
      Enum.reduce_while(1..200, {state, []}, fn i, {state, log} ->
        mentions = if rem(i, 2) == 0, do: [], else: ["b2"]
        {state, action} = step(state, msg("m#{i}", "h#{rem(i, 2) + 1}", mentions))
        {state, more} = drive(state, action, reply)
        log = log ++ more
        if length(log) >= 256, do: {:halt, {state, log}}, else: {:cont, {state, log}}
      end)

    assert length(log) >= 256
    assert length(Enum.uniq(ids(log))) == length(log)
    assert Enum.any?(log, &(&1["kind"] == "finish")) and Enum.any?(log, &(&1["id"] == "n/1/1"))

    # The longest turn ID, whatever the member ID.
    long = id(128, "\"")
    seq = %{"turn" => 9_007_199_254_740_990, "notice" => 0, "decision" => 0}

    carried =
      Map.merge(
        room(%{}, %{"members" => [%{"id" => long, "kind" => "bot"}], "link" => @max_link}),
        %{
          "carry" => %{
            "window" => [],
            "bot_turns" => 1,
            "default_member" => nil,
            "rule_state" => nil,
            "awaiting_person" => false,
            "queue" => [%{"member" => long, "message_id" => "m1"}],
            "seq" => seq,
            "notes" => []
          }
        }
      )

    {_, turn} = step(new!(), start(carried))
    assert turn["payload"]["turn_id"] == "t/2147483647/9007199254740991"
    assert byte_size(turn["payload"]["turn_id"]) <= 43
    assert byte_size(turn["id"]) <= 128
  end

  ## 9. Sizes

  defp bytes(term),
    do: byte_size(:erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}]))

  defp json(term), do: byte_size(Jason.encode!(term))

  defp largest_start do
    q = "\""
    name = fn prefix -> prefix <> String.duplicate(q, 128 - byte_size(prefix)) end
    humans = for i <- 10..25, do: %{"id" => name.("h#{i}"), "kind" => "human"}
    bots = for i <- 10..25, do: %{"id" => name.("b#{i}"), "kind" => "bot"}
    message_id = "m" <> String.duplicate(q, 154)
    control = String.duplicate(<<1>>, 4_096)

    %{
      "room_id" => name.("r"),
      "link" => @max_link - 1,
      "members" => humans ++ bots,
      "policy" => %{
        "rule" => "decided",
        "default_member" => name.("b10"),
        "max_bot_turns" => 16,
        "handoff" => "allowed",
        "post_to" => "p" <> String.duplicate(q, 255),
        "window" => %{"messages" => 8, "bytes" => 24_576},
        "rollover" => %{"max_turns" => 63}
      },
      "summary" => String.duplicate(<<1>>, 1_365),
      "carry" => %{
        "window" => [entry(message_id, name.("h10"), control, "untrusted")],
        "bot_turns" => 16,
        "default_member" => name.("b10"),
        "rule_state" => String.duplicate(<<1>>, 170) <> "ab",
        "awaiting_person" => false,
        "queue" => for(%{"id" => id} <- bots, do: %{"member" => id, "message_id" => message_id}),
        "seq" => %{
          "turn" => 9_007_199_254_740_000,
          "notice" => 9_007_199_254_740_000,
          "decision" => 9_007_199_254_740_000
        },
        "notes" => for(_ <- 1..16, do: %{"code" => "restarted_queue_dropped", "ref" => message_id})
      }
    }
  end

  test "sizes_fit_the_engine_bounds" do
    start = largest_start()
    assert json(start["summary"]) == 8_192 and json(start["carry"]["rule_state"]) == 1_024
    assert TurnPolicy.check_start(new!(), start) == :ok
    assert json(start) <= 65_536
    assert json(start["carry"]) <= 65_536

    bots = for %{"id" => id, "kind" => "bot"} <- start["members"], do: id
    message_id = "m" <> String.duplicate("\"", 154)
    control = String.duplicate(<<1>>, 4_096)

    # Every queued turn fails except the first, whose answer is the largest.
    reply = fn action ->
      case action["schema_id"] do
        "elzoo.room.turn" ->
          if action["id"] == "t/2147483646/9007199254740001/turn",
            do: answer(action["id"], %{"text" => control, "mentions" => Enum.take(bots, 16)}),
            else: outcome(action["id"], "failed")

        "elzoo.room.decide" ->
          pick(action["id"], %{"pick" => "several"})

        _ ->
          host().(action)
      end
    end

    inputs = [
      start(start),
      msg(message_id, hd(start["members"])["id"], [], %{"text" => control}),
      rollover()
    ]

    {state, measured} =
      Enum.reduce(inputs, {new!(), []}, fn input, {state, measured} ->
        {state, action} = step(state, input)
        measure(state, action, reply, [{bytes(state), nil} | measured])
      end)

    assert state.phase == :finishing

    kinds =
      measured |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    assert kinds ==
             Enum.sort(
               ~w(elzoo.room.carry elzoo.room.decide elzoo.room.finish elzoo.room.notice elzoo.room.post elzoo.room.turn)
             )

    for {state_bytes, _} <- measured, do: assert(state_bytes <= 65_536)

    for {_, schema, payload_bytes} <- Enum.filter(measured, &(tuple_size(&1) == 3)),
        do: assert(payload_bytes <= 65_536, schema)
  end

  test "sizes_with_a_full_window" do
    for {fill, text} <- [{"x", "y"}, {"\"", "\""}] do
      name = fn prefix, n -> prefix <> String.duplicate(fill, n - byte_size(prefix)) end
      humans = for i <- 10..25, do: %{"id" => name.("h#{i}", 128), "kind" => "human"}
      bots = for i <- 10..25, do: %{"id" => name.("b#{i}", 128), "kind" => "bot"}
      bot_ids = Enum.map(bots, & &1["id"])
      mid = fn i -> name.("m#{i}", 155) end
      plain = fill == "x"

      start = %{
        "room_id" => name.("r", 128),
        "link" => 5,
        "members" => humans ++ bots,
        "policy" => %{
          "rule" => "decided",
          "default_member" => hd(bot_ids),
          "max_bot_turns" => 16,
          "handoff" => "allowed",
          "post_to" => name.("p", 256),
          "window" => %{"messages" => 8, "bytes" => 24_576},
          # 16 carried turns, 7 messages and the first picked turn reach the threshold.
          "rollover" => %{"max_turns" => 24}
        },
        "summary" => if(plain, do: id(8_190, "s"), else: id(4_094, "\"")),
        "carry" => %{
          "window" => [],
          "bot_turns" => 16,
          "default_member" => hd(bot_ids),
          "rule_state" => if(plain, do: id(1_022, "r"), else: id(510, "\"")),
          "awaiting_person" => false,
          "queue" => for(id <- bot_ids, do: %{"member" => id, "message_id" => mid.(0)}),
          "seq" => %{"turn" => 9_007_199_254_740_000, "notice" => 0, "decision" => 0},
          "notes" => for(_ <- 1..16, do: %{"code" => "restarted_queue_dropped", "ref" => mid.(0)})
        }
      }

      assert TurnPolicy.check_start(new!(), start) == :ok
      fail = fn action -> outcome(action["id"], "failed") end
      {state, first} = step(new!(), start(start))
      {state, _} = drive(state, first, fail)

      say = fn i, mentions ->
        msg(mid.(i), hd(humans)["id"], mentions, %{"text" => id(3_400, text)})
      end

      state =
        Enum.reduce(1..7, state, fn i, state ->
          {state, action} = step(state, say.(i, [hd(bot_ids)]))
          elem(drive(state, action, fail), 0)
        end)

      # An unaddressed message that mentions every person opens a decision; its view holds them.
      {state, decide} = step(state, say.(8, Enum.map(humans, & &1["id"])))
      assert decide["schema_id"] == "elzoo.room.decide"
      assert json(state.window) <= 24_576 and length(state.window) >= 3
      assert bytes(state) <= 65_536 and engine_check(decide) == :ok
      if plain, do: assert(bytes(state) > 45_000)

      {state, turn} = step(state, pick(decide["id"], %{"pick" => "several"}))
      assert length(state.queue) == 15 and json(turn["payload"]) <= 65_536
      {state, carry} = step(state, outcome(turn["id"], "failed"))
      assert carry["schema_id"] == "elzoo.room.carry" and length(state.queue) == 15
      assert bytes(state) <= 65_536 and json(carry["payload"]) <= 65_536
      assert engine_check(carry) == :ok and TurnPolicy.check_start(new!(), carry["payload"]) == :ok
      unless plain, do: assert(json(carry["payload"]) > 55_000)
    end
  end

  defp measure(state, nil, _reply, measured), do: {state, measured}

  defp measure(state, %{"kind" => "finish"} = action, _reply, measured),
    do: {state, [{bytes(state), action["schema_id"], json(action["payload"])} | measured]}

  defp measure(state, action, reply, measured) do
    measured = [{bytes(state), action["schema_id"], json(action["payload"])} | measured]
    {state, next} = step(state, reply.(action))
    measure(state, next, reply, [{bytes(state), nil} | measured])
  end

  ## 10. Malformed inputs

  test "malformed_inputs_give_fixed_reasons" do
    state = started(%{"default_member" => "b1"})

    bad_messages = [
      %{"message_id" => "m1", "from" => "h1", "text" => "", "mentions" => []},
      %{
        "message_id" => "m1",
        "from" => "h1",
        "text" => String.duplicate("x", 4_097),
        "mentions" => []
      },
      %{"message_id" => "m1", "from" => "h1", "text" => "hi", "mentions" => "b1"},
      %{"message_id" => "m1", "from" => "h1", "text" => "hi", "mentions" => [3]},
      %{
        "message_id" => "m1",
        "from" => "h1",
        "text" => "hi",
        "mentions" => List.duplicate("b1", 17)
      },
      %{"message_id" => "m1", "from" => "h1", "text" => "hi", "mentions" => ["b1" | "b2"]},
      %{"message_id" => "m1", "from" => "h1", "text" => "hi", "mentions" => [], "extra" => 1},
      %{
        "message_id" => "m1",
        "from" => "h1",
        "text" => "hi",
        "mentions" => [],
        "reply_to_member" => nil
      },
      %{"message_id" => id(156), "from" => "h1", "text" => "hi", "mentions" => []},
      %{"message_id" => "m1", "from" => "h\u0000", "text" => "hi", "mentions" => []},
      %{"message_id" => "m1", "from" => "h1", "text" => <<0xFF>>, "mentions" => []},
      %{"message_id" => "m1", "from" => "h1", "text" => "hi"},
      "text",
      nil
    ]

    for payload <- bad_messages do
      {next, nil} = step(state, typed("message", "elzoo.room.message", payload))
      assert notes(next) == [{:invalid_message, nil}], inspect(payload)
      assert next.window == []
    end

    {_, %{"id" => "t/1/1/turn"}} =
      step(state, msg(id(155), "h1", [], %{"text" => String.duplicate("x", 4_096)}))

    {open, %{"id" => "t/1/1/turn"}} = step(state, msg("m1", "h1", ["b1", "b2"]))

    bad_answers = [
      %{"text" => "", "mentions" => [], "handoff_to" => nil, "escalate" => false},
      %{"text" => "hi", "mentions" => [], "handoff_to" => nil, "escalate" => "yes"},
      %{"text" => "hi", "mentions" => [], "handoff_to" => "", "escalate" => false},
      %{"text" => "hi", "mentions" => [], "handoff_to" => nil, "escalate" => false, "extra" => 1},
      %{"text" => "hi", "mentions" => [], "handoff_to" => nil},
      %{
        "text" => "hi",
        "mentions" => List.duplicate("b1", 17),
        "handoff_to" => nil,
        "escalate" => false
      },
      "hi"
    ]

    for payload <- bad_answers do
      {next, action} = step(open, outcome("t/1/1/turn", "completed", "elzoo.room.answer", payload))
      assert hd(notes(next)) == {:invalid_answer, "b1"}, inspect(payload)
      # Nothing is posted; the next queued turn runs.
      assert action["id"] == "t/1/2/turn"
    end

    {next, %{"id" => "t/1/2/turn"}} =
      step(open, answer("t/1/1/turn") |> Map.put("schema_id", "other.answer"))

    assert hd(notes(next)) == {:invalid_answer, "b1"}

    for class <- ~w(failed refused unknown out_of_budget retries_exhausted expired resource_lost) do
      {next, %{"id" => "t/1/2/turn"}} = step(open, outcome("t/1/1/turn", class))
      assert hd(notes(next)) == {:turn_not_completed, "b1"}
      assert next.run_turns == 2
    end

    assert {^open, nil} = step(open, outcome("t/1/1/turn", "late"))

    {posting, %{"id" => "t/1/1/post"}} = step(open, answer("t/1/1/turn"))
    {next, %{"id" => "t/1/2/turn"}} = step(posting, outcome("t/1/1/post", "failed"))
    assert hd(notes(next)) == {:post_failed, "b1"}

    # Inputs that change nothing.
    for input <- [
          input("wake", %{}),
          start(room()),
          typed("message", "other.schema", %{}),
          typed("message", "elzoo.room.rollover", %{"x" => 1}),
          typed("resource_event", "test/x", nil),
          %{"type" => "input"},
          :garbage
        ] do
      assert {^state, nil} = step(state, input)
    end

    # A malformed start opens nothing, and nothing after it does.
    {invalid, nil} = step(new!(), start(Map.delete(room(), "policy")))
    assert invalid.invalid_start == :malformed
    assert {^invalid, nil} = step(invalid, msg("m1", "h1", ["b1"]))
    assert {^invalid, nil} = step(invalid, rollover())

    for kind <- ["cancel", "run_ended"] do
      fields =
        if kind == "cancel",
          do: %{"attempt_id" => "a1"},
          else: %{"schema_id" => "test/x", "schema_version" => 1, "payload" => nil}

      {closed, nil} = step(open, input(kind, fields))
      assert closed.phase == :closed
      assert {^closed, nil} = step(closed, answer("t/1/1/turn"))
    end
  end

  test "random_inputs_never_raise" do
    state = started(%{"rule" => "decided", "default_member" => "b1"})
    values = [nil, true, 0, -1, 1.5, "", "b1", "h1", "zz", [], ["b1"], %{}, %{"a" => 1}, [1 | 2]]
    keys = ~w(message_id from text mentions reply_to_member)

    for _ <- 1..500 do
      payload = Map.new(Enum.take_random(keys, Enum.random(0..5)), &{&1, Enum.random(values)})
      {next, _} = step(state, typed("message", "elzoo.room.message", payload))
      assert is_map(next)

      {next, _} =
        step(
          new!(),
          start(
            Map.merge(
              room(),
              Map.new(Enum.take_random(Map.keys(room()), 2), &{&1, Enum.random(values)})
            )
          )
        )

      assert next.phase in [:running, :invalid_start]
    end
  end

  test "example" do
    {result, _} = Code.eval_file(Path.expand("../../examples/turn_policy.exs", __DIR__))

    assert result == [
             "t/1/1/turn",
             "t/1/1/post",
             "d/1/1",
             "t/1/2/turn",
             "t/1/2/post",
             "t/1/3/turn",
             "t/1/3/post"
           ]
  end
end
