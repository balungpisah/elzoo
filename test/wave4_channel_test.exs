Code.require_file("support/wave4_channel_helper.exs", __DIR__)

defmodule Elzoo.Wave4ChannelTest do
  use ExUnit.Case, async: false

  alias Elzoo.{
    CheckedCommand,
    Conversation,
    DurableUnit,
    DynamicUnits,
    Outbox,
    RunApprovalRelease,
    RunEngine,
    Wave4ChannelExample
  }

  setup_all do
    repo = Elzoo.Wave4ChannelTestHelper.start_database!()
    on_exit(fn -> if Process.alive?(repo), do: GenServer.stop(repo) end)
    :ok
  end

  setup do
    {:ok, fixture: Elzoo.Wave4ChannelTestHelper.fixture()}
  end

  test "startup requires a unique compatible binding and the fixed ASCII profile", %{
    fixture: fixture
  } do
    Process.flag(:trap_exit, true)
    options = fixture.host_options
    [binding] = options[:bindings]

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, []))

    ambiguous = Map.put(binding, "id", "second-channel-binding")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, [binding, ambiguous]))

    wrong_target = put_in(binding["target"]["callable"], "other")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, [wrong_target]))

    arbitrary =
      Map.put(
        options[:profile],
        :native_target,
        Map.put(options[:profile].native_target, "callable", "other")
      )

    arbitrary_binding = put_in(binding["target"]["callable"], "other")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(
               options
               |> Keyword.put(:profile, arbitrary)
               |> Keyword.put(:bindings, [arbitrary_binding])
             )

    non_ascii = Map.put(options[:profile], :conversation_id, "channel-café")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :profile, non_ascii))

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, "no-run-created")

    assert %{state: :redacted, message: :redacted, reason: :redacted, log: :redacted} =
             Wave4ChannelExample.format_status(%{
               state: "sensitive-event",
               message: "sensitive-credential",
               reason: "sensitive-reason",
               log: "sensitive-log"
             })

    refute inspect(:sys.get_status(fixture.host)) =~ fixture.profile.source_id
  end

  test "ASK survives reopen and releases only once with fresh command evidence", %{
    fixture: fixture
  } do
    gate_control =
      start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]

    normalized = %{
      version: event["version"],
      event_id: event["event_id"],
      conversation_id: event["conversation_id"],
      input_id: event["input_id"],
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    assert {:ok, {{_, 202, _}, _, body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert %{"event_id" => ^event_id, "status" => "pending_approval"} = Jason.decode!(body)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert take_hash_calls() == []

    before_replay = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    GenServer.stop(fixture.host, :normal)
    reopened_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :reopen, [])
    {:ok, reopened_handles} = Elzoo.Wave4ChannelExample.CommandBindings.build(reopened_store, gates)

    host_options =
      fixture.host_options
      |> Keyword.put(:command_store, reopened_store)
      |> Keyword.put(:handles, reopened_handles)

    fixture = %{
      fixture
      | command_store: reopened_store,
        handles: reopened_handles,
        host_options: host_options
    }

    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    fixture = %{fixture | host: host}
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    assert {:ok, {{_, 202, _}, _, replay_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "status" => "pending_approval"} =
             Jason.decode!(replay_body)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_replay

    before_refusals = before_replay

    assert {:rejected, :conflict} =
             Wave4ChannelExample.release(
               fixture.host,
               %{normalized | text: "changed original event"},
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{purpose: :command, tenant: fixture.profile.tenant, evidence: %{}}
             )

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "release-valid",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    release_authority = %{
      approver: %{identity: "human-reviewer", authority: writes},
      now: now,
      revoked: []
    }

    Agent.update(authority_control, fn _ -> release_authority end)

    assert {:rejected, :invalid} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | purpose: :run}
             )

    wrong_request = %{
      evidence
      | evidence_id: "release-wrong-request",
        request: put_elem(key, 1, "other")
    }

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: wrong_request}
             )
           )

    Agent.update(policy_control, fn _ -> :deny end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-changed-policy"}}
             )
           )

    Agent.update(policy_control, fn _ -> :ask end)

    revoked = %{
      release_authority
      | revoked: [{evidence.verifier, "release-revoked"}]
    }

    Agent.update(authority_control, fn _ -> revoked end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-revoked"}}
             )
           )

    self_approval = %{
      release_authority
      | approver: %{identity: fixture.profile.actor, authority: writes}
    }

    Agent.update(authority_control, fn _ -> self_approval end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-self"}}
             )
           )

    Agent.update(authority_control, fn _ -> release_authority end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{
                 envelope
                 | evidence: %{
                     evidence
                     | evidence_id: "release-stale",
                       issued_at: now - 60_001,
                       expiry: now + 60_000
                   }
               }
             )
           )

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{
                 envelope
                 | evidence: %{
                     evidence
                     | evidence_id: "release-expired",
                       issued_at: now - 1_000,
                       expiry: now - 1
                   }
               }
             )
           )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_refusals

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    set_gate_fault(gate_control, fixture.command_store, :reply_loss)

    assert {:unknown, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:error, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:reconciled, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    released_item = assert_input_outbox(fixture, event, 2)

    assert {:ok, {{_, 202, _}, _, committed_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(committed_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    Agent.update(policy_control, fn _ -> :allow end)
    assert {:ok, %{run_id: first_run}} = process_event(fixture, listener, event, 3, 2, 4)

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ask-followup",
        "input_id" => "ask-followup-input",
        "expected_revision" => 3,
        "text" => "continued after release"
      })

    assert {:ok, %{run_id: second_run}} = process_event(fixture, listener, second, 6, 5, 7)
    assert first_run != second_run
    assert {:ok, %{revision: 7}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []
  end

  test "initial ASK reply loss recovers the same pending requirement after a read outage", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())
    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event_id)
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event_id, event["input_id"])
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    unit_after_ask = Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :append) == nil
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             unit_after_ask

    pending_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :input} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read) == nil

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:reconciled, :approval_pending} = Wave4ChannelExample.advance(fixture.host)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert %{key: ^key, requirement: ^requirement} = :sys.get_state(fixture.host).approval

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:ok, {{_, 202, _}, _, pending_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "status" => "pending_approval"} = Jason.decode!(pending_body)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "initial-ask-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    normalized = %{
      version: event["version"],
      event_id: event_id,
      conversation_id: event["conversation_id"],
      input_id: event["input_id"],
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    assert {:committed, 1} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    released_item = assert_input_outbox(fixture, event, 2)
    released_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, {{_, 202, _}, _, committed_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(committed_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             released_state

    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "a paused release writer cannot reconcile from the earlier ASK receipt", %{fixture: fixture} do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())
    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]
    input_id = event["input_id"]
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event_id)
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event_id, input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    normalized = %{
      version: event["version"],
      event_id: event_id,
      conversation_id: event["conversation_id"],
      input_id: input_id,
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "paused-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    before_release = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    token = :wave4_release_writer
    set_gate_fault(gate_control, fixture.command_store, {:pause, token})

    caller =
      Task.async(fn ->
        Wave4ChannelExample.release(
          fixture.host,
          normalized,
          Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
          envelope
        )
      end)

    writer = wait_for_paused(fixture.controller, token, System.monotonic_time(:millisecond) + 5_000)
    assert writer.operation == :append
    assert is_integer(writer.backend)
    assert Process.alive?(writer.pid)
    assert {:unknown, :unavailable} = Task.await(caller, 10_000)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :append) == nil

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:unknown, :release} = Wave4ChannelExample.advance(fixture.host)
    assert Process.alive?(writer.pid)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    blocked_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-by-release-unknown",
        "input_id" => "blocked-release-input",
        "expected_revision" => 0
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked_event)

    assert {:error, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    writer_ref = Process.monitor(writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [token])

    assert_receive {:DOWN, ^writer_ref, :process, writer_pid, _reason}, 5_000
    assert writer_pid == writer.pid
    assert Agent.get(fixture.controller, &Map.get(&1.paused, token)) == nil

    refute Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    assert {:reconciled, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    released_item = assert_input_outbox(fixture, event, 2)
    released_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    assert {:ok, {{_, 202, _}, _, replay_body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(replay_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             released_state

    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "committed input reply loss stays fenced through read outage until identity confirmation", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert_input_outbox(fixture, event, 1)

    committed_state =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :input} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-during-input-unknown",
                 "input_id" => "blocked-input",
                 "expected_revision" => 1
               })
             )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert {:reconciled, :input} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:ok, {{_, 202, _}, _, replay_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"revision" => 1, "status" => "committed"} = Jason.decode!(replay_body)

    assert ^committed_state =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, %{run_id: _run_id}} = process_event(fixture, listener, event, 3, 1, 4)

    next =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-input-confirmation",
        "input_id" => "after-confirmation-input",
        "expected_revision" => 3,
        "text" => "approval state was cleared"
      })

    assert {:ok, {{_, 202, _}, _, next_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, next)

    assert %{"revision" => 4, "status" => "committed"} = Jason.decode!(next_body)
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "paused input writer is not treated as non-commit and stays fenced until it exits", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    token = :wave4_input_writer
    set_gate_fault(gate_control, fixture.command_store, {:pause, token})

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    paused = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, token)
    assert Process.alive?(paused.pid)

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-live-writer",
                 "input_id" => "blocked-live-input"
               })
             )

    _ = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [token])

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-after-writer-exit",
                 "input_id" => "blocked-after-exit-input",
                 "expected_revision" => 1
               })
             )

    assert {:reconciled, :input} = Wave4ChannelExample.advance(fixture.host)
    item = assert_input_outbox(fixture, event, 1)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert item.idempotency_key == "#{checked_stream(fixture.profile.tenant)}/1/1"
  end

  test "association reply loss stays fenced with zero native allocation until confirmation", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: fn _, _ -> :allow end,
      association: controlled_gate(gate_control),
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)
    input_id = event["input_id"]
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)

    assert {:unknown, :association} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert take_hash_calls() == []

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :association} = Wave4ChannelExample.advance(fixture.host)

    before_reads = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, {{_, 503, _}, _, unavailable_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(unavailable_body) == %{"status" => "unavailable"}

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-after-association-loss",
        "input_id" => "blocked-association-input",
        "expected_revision" => 2
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_reads

    assert item == assert_input_outbox(fixture, event, 1)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert take_hash_calls() == []

    assert {:reconciled, :association} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 2}} =
             CheckedCommand.result(
               fixture.handles.association,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.association_operation(
                  fixture.profile,
                  event["event_id"],
                  event["input_id"]
                )}
             )

    assert {:run_created, _owner_revision} = Wave4ChannelExample.advance(fixture.host)
    assert item == assert_input_outbox(fixture, event, 1)
    assert {:attempt_started, _attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
  end

  test "committed answer reply loss reconciles without rerunning native work or replacing the answer",
       %{
         fixture: fixture
       } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: fn _, _ -> :allow end,
      association: fn _, _ -> :allow end,
      answer: controlled_gate(gate_control)
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    input_id = event["input_id"]
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _owner_revision} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert resource.revision == 3
    assert item == assert_input_outbox(fixture, event, 1)
    committed_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3}} = Jason.decode!(view_body)

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-after-answer-loss",
        "input_id" => "blocked-answer-input",
        "expected_revision" => 3
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert item == assert_input_outbox(fixture, event, 1)
    assert take_hash_calls() == []

    assert {:reconciled, :answer} = Wave4ChannelExample.advance(fixture.host)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    assert {:completed, %{revision: 3}} =
             CheckedCommand.result(
               fixture.handles.answer,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert item == assert_input_outbox(fixture, event, 1)
    assert take_hash_calls() == []

    assert {:acknowledged, input_id} = Wave4ChannelExample.advance(fixture.host)
    assert input_id == event["input_id"]
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked, ack_nonce: nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [item.idempotency_key]
             )

    assert nonce == item.nonce
    assert take_hash_calls() == []
  end

  test "fenced reopen recovers association, native result, and answer without replacement work", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "before-recovery",
        "expected_revision" => 1
      })

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, stale)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 2)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    input_id = event["input_id"]

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, %{current_attempt: ^attempt_id, outcome: nil}} =
             RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]

    assert {:ok, run_status_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, unit_before} = DynamicUnits.find(fixture.directory, unit_id)
    [{engine_before, _}] = Registry.lookup(fixture.native.registry, unit_id)
    unit_status_before = RunEngine.status(engine_before)
    budget_before = DurableUnit.snapshot(unit_before).control.budgets["root"].state

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == []
    assert {:ok, run_status_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert stable_run_status(run_status_after) == stable_run_status(run_status_before)
    assert {:ok, unit_after} = DynamicUnits.find(fixture.directory, unit_id)
    [{engine_after, _}] = Registry.lookup(fixture.native.registry, unit_id)
    assert {:ok, engine_status_after} = RunEngine.status(engine_after)
    assert {:ok, engine_status_before} = unit_status_before
    assert engine_status_after.request_count == engine_status_before.request_count
    assert DurableUnit.snapshot(unit_after).control.budgets["root"].state == budget_before

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, sequence: 2, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce

    assert {:ok, {{_, 200, _}, _, view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages}} =
             Jason.decode!(view)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1
  end

  test "ack reply loss is positively confirmed by the original canonical key and nonce", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ack-prerequisite",
        "expected_revision" => 1
      })

    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, stale)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 2)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    input_id = event["input_id"]
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :reply_loss]
             )

    ack_result = Wave4ChannelExample.advance(fixture.host)
    faults = Agent.get(fixture.controller, & &1.faults)
    assert Map.get(faults, :ack) == nil
    assert {:acknowledged, ^input_id} = ack_result

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3}} = Jason.decode!(body)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == [event["text"]]

    assert {:idle, :no_input} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, sequence: 2, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "ack rollback remains fenced and reopens directly from the retained answer", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    ack_key = item.idempotency_key
    ack_nonce = item.nonce

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :rollback]
             )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_ack, :unavailable]
             )

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read_ack) == nil
    assert {:ack, ^ack_key, ^ack_nonce, _receipt} = :sys.get_state(fixture.host).poison

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_ack, :malformed]
             )

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read_ack) == nil
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages}} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, ack_nonce: nonce, idempotency_key: key, sequence: 1}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => recovered_messages}} =
             Jason.decode!(view_body)

    assert Enum.count(recovered_messages, &(&1["role"] == "assistant")) == 1
  end

  test "a different nonce winning the original ack key never clears the host poison", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    original_key = item.idempotency_key
    original_nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == original_nonce

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :rollback]
             )

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:committed, _sequence} =
             Elzoo.Outbox.ack(fixture.command_store, original_key, other_nonce)

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:ack, ^original_key, ^original_nonce, _receipt} = :sys.get_state(fixture.host).poison

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert :superseded =
             Elzoo.DurableLog.confirm_ack(
               fixture.command_store,
               Elzoo.DurableLog.Codec.ack_receipt(original_key, original_nonce)
             )

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages}} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:ack, ^original_key, ^original_nonce, _receipt} = :sys.get_state(fixture.host).poison
    assert take_hash_calls() == [event["text"]]
  end

  test "native input append remains live and unresolved until its PostgreSQL writer is released", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    token = :wave4_native_input_writer

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)

    before_native_write =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(
      fixture.native.unit_store,
      :inject,
      [:append, {:pause, token}]
    )

    caller = Task.async(fn -> Wave4ChannelExample.advance(fixture.host) end)
    writer = wait_for_paused(fixture.controller, token, System.monotonic_time(:millisecond) + 5_000)
    assert writer.operation == :append
    assert is_integer(writer.backend)
    assert Process.alive?(writer.pid)
    assert {:unknown, :native_input} = Task.await(caller, 10_000)
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Process.alive?(writer.pid)

    assert before_native_write ==
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert take_hash_calls() == []

    writer_ref = Process.monitor(writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :release, [token])

    assert_receive {:DOWN, ^writer_ref, :process, _, _}, 5_000
    assert Agent.get(fixture.controller, &Map.get(&1.paused, token)) == nil

    refute before_native_write ==
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
  end

  test "volatile local work is recorded as terminal loss after fenced reopen", %{fixture: fixture} do
    token = make_ref()
    deadline = fixture.profile.deadline_ms
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _actual_result}, 5_000
    assert Process.alive?(task_pid)
    assert task_pid in Task.Supervisor.children(fixture.native.task_supervisor)
    [{engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

    assert {:pending, _} =
             RunEngine.result(
               engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               %{max_records: 2_048, max_bytes: 16_777_216}
             )

    assert take_hash_calls() == [event["text"]]
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    fixture = without_native_hash_barrier(fixture)
    {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    refute Process.alive?(task_pid)
    assert fixture.profile.deadline_ms == deadline
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)
    [{recovered_engine, _}] = Registry.lookup(fixture.native.registry, unit_id)
    assert {:ok, native_status} = RunEngine.status(recovered_engine)

    assert native_status.run_id == run_id
    assert native_status.attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert is_nil(native_status.outcome)

    assert Enum.any?(Map.values(native_status.slots), fn slot ->
             slot.kind == "local_work" and slot.outcome == "failed"
           end)

    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert is_nil(run.outcome)

    assert {:ok, _revision, _} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :complete,
               run_id: run_id,
               attempt_id: run.current_attempt,
               outcome: :failed,
               reason: "local_restart",
               evidence_ref: nil,
               expected_revision: run.revision
             })

    assert {:terminal, :failed} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run.outcome == :failed
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))

    assert {:ok, %{state: :acked, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
  end

  test "cancelled real native work produces no answer and is fenced before ack", %{fixture: fixture} do
    assert_terminal_work_outcome(fixture, :cancelled)
  end

  test "out-of-budget real native work produces no answer and is fenced before ack", %{
    fixture: fixture
  } do
    assert_terminal_work_outcome(fixture, :out_of_budget)
  end

  test "out-of-time real native work produces no answer and is fenced before ack", %{
    fixture: fixture
  } do
    assert_terminal_work_outcome(fixture, :out_of_time)
  end

  test "uncertain native input stays fenced until safe reopen and original-ID confirmation", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert {:engine_started, unit_id} = Wave4ChannelExample.advance(fixture.host)

    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    before_native_input =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:append, :reply_loss])

    assert {:unknown, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Agent.get(fixture.controller, &Map.get(&1.faults, :append)) == nil

    after_native_input =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    refute before_native_input == after_native_input
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(view_body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert item.sequence == 1
    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert is_nil(run_before.outcome)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    [{recovered_engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

    assert {:ok, _native_result} =
             wait_public_result(
               recovered_engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert take_hash_calls() == [event["text"]]

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:read, :unavailable])
    assert {:unknown, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Agent.get(fixture.controller, &Map.get(&1.faults, :read)) == nil
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(view_body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.attempts == run_before.attempts
    assert run_after.current_attempt == attempt_id
    assert run_after.outcome == :completed
    assert is_integer(run_after.completion_revision)
    assert is_map(run_after.evidence_ref)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "unavailable authoritative result reader cannot append an answer or acknowledge", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    [{engine, _}] =
      Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    result_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, _result} =
             wait_public_result(engine, result_scope, System.monotonic_time(:millisecond) + 10_000)

    resource_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.evidence_store, :inject, [
      :read,
      :unavailable
    ])

    assert {:pending, _reason} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, ^snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  test "Run creation and Attempt reply loss retain identities without early native allocation", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, [input_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :inject, [:append, :reply_loss])
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []
    assert {:ok, [^input_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []

    Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :inject, [:append, :reply_loss])
    assert {:unknown, :attempt} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :attempt} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run.current_attempt == attempt_id
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
  end

  test "partial Engine startup is fenced and cleaned before reopening the same Attempt", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:read, :unavailable])

    assert {:unknown, :engine_start} = Wave4ChannelExample.advance(fixture.host)
    assert {:blocked, :engine_start} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.attempts == run_before.attempts
    assert run_after.current_attempt == attempt_id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.outcome == :completed
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "HTTP and read guards return fixed statuses without mutation", %{fixture: fixture} do
    event = Elzoo.Wave4ChannelTestHelper.event()
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    bad_mac = "v1=" <> String.duplicate("0", 64)

    assert {:ok, {{_, 401, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event, signature: bad_mac)

    assert {:ok, {{_, 400, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event,
               headers: [{"x-elzoo-signature", "bad"}]
             )

    assert {:ok, {{_, 405, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(listener, :get, "/elzoo/v1/messages")

    assert {:ok, {{_, 405, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(
               listener,
               :post,
               "/elzoo/v1/conversations/channel-conversation"
             )

    assert {:ok, {{_, 404, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(listener, :get, "/not-a-route")

    assert {:ok, {{_, 404, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id,
               query: "x=1"
             )

    unauthorized = fn _ ->
      {:ok,
       %{
         tenant: "other",
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id]
       }}
    end

    unauthorized_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: unauthorized)
    trace_read_apis(fixture.host)

    assert {:ok, {{_, 403, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(
               unauthorized_listener,
               fixture.profile.conversation_id
             )

    await_trace_delivery(fixture.host)
    refute_receive {:trace, _, :call, {CheckedCommand, :resource, _}}, 100
    refute_receive {:trace, _, :call, {RunApprovalRelease, :status, _}}, 100

    principals = [
      {fn _ ->
         {:ok,
          %{
            tenant: "other",
            actor: fixture.profile.actor,
            resources: [fixture.profile.conversation_id]
          }}
       end, 403},
      {fn _ ->
         {:ok,
          %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, resources: :malformed}}
       end, 503},
      {fn _ -> raise "sensitive principal failure" end, 503},
      {fn _ -> exit({:sensitive, :principal}) end, 503}
    ]

    for {principal, expected} <- principals do
      authorized = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: principal)
      response = Elzoo.Wave4ChannelTestHelper.get(authorized, fixture.profile.conversation_id)
      assert {:ok, {{_, status, _}, _, body}} = response
      assert status == expected
      assert Jason.decode!(body) in [%{"status" => "forbidden"}, %{"status" => "unavailable"}]
    end

    repeated = fn _ ->
      {:ok,
       %{
         tenant: fixture.profile.tenant,
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id, fixture.profile.conversation_id]
       }}
    end

    repeated_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: repeated)

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(repeated_listener, fixture.profile.conversation_id)

    unavailable_host_listener =
      Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: :wave4_channel_missing_host)

    assert {:ok, {{_, 503, _}, _, unavailable_body}} =
             Elzoo.Wave4ChannelTestHelper.get(
               unavailable_host_listener,
               fixture.profile.conversation_id
             )

    assert Jason.decode!(unavailable_body) == %{"status" => "unavailable"}

    assert {:ok, %{revision: 0}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "retained identities reach CheckedCommand conflicts while deadline survives reopen", %{
    fixture: fixture
  } do
    event = Elzoo.Wave4ChannelTestHelper.event()
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, %{run_id: run_id}} = process_event(fixture, listener, event, 3, 1, 4)
    assert take_hash_calls() == []

    duplicate =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "domain-invalid",
        "input_id" => event["input_id"],
        "expected_revision" => 3
      })

    assert {:ok, {{_, 400, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, duplicate)

    duplicate_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, duplicate["event_id"])

    assert {:conflict, {:domain, _}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, duplicate_operation}
             )

    before = public_state(fixture, [event], [run_id])
    changed_bytes = Map.put(event, "text", event["text"] <> " changed")
    changed_revision = Map.put(event, "expected_revision", 1)

    grants = fn _ ->
      {:ok,
       %{
         tenant: fixture.profile.tenant,
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id, "other-conversation"]
       }}
    end

    wide_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, webhook_principal: grants)
    changed_resource = Map.put(event, "conversation_id", "other-conversation")
    changed_events = [changed_bytes, changed_revision, changed_resource]
    trace_checked_execute(fixture.host)

    for changed <- changed_events do
      assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(wide_listener, changed)
    end

    executed_requests = take_checked_execute_requests()
    :erlang.trace(fixture.host, false, [:call])
    :erlang.trace_pattern({CheckedCommand, :execute, 3}, false, [:local])

    assert Enum.map(executed_requests, &{&1.resource, &1.expected_revision, &1.payload}) ==
             Enum.map(changed_events, fn changed ->
               {
                 changed["conversation_id"],
                 changed["expected_revision"],
                 %{"message_id" => changed["input_id"], "text" => changed["text"]}
               }
             end)

    assert public_state(fixture, [event], [run_id]) == before

    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    Elzoo.Wave4ChannelTestHelper.stop_listener!(wide_listener)
    GenServer.stop(fixture.host, :normal)
    expired_clock = fn -> fixture.profile.deadline_ms + 1 end
    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, clock: expired_clock)
    reopened = %{fixture | host: host}
    reopened_listener = Elzoo.Wave4ChannelTestHelper.listener!(reopened)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(reopened_listener, event)

    new_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-deadline",
        "input_id" => "after-deadline-input",
        "expected_revision" => 3
      })

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reopened_listener, new_event)

    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    after_deadline_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, new_event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, after_deadline_operation}
             )

    assert take_hash_calls() == []
  end

  test "admission callback exceptions and exits return fixed errors without writes", %{
    fixture: fixture
  } do
    for {event_id, failure} <- [{"policy-raised", :raise}, {"policy-exited", :exit}] do
      parent = self()

      policy = fn _mode, event, _now ->
        send(parent, {:policy_callback, event.event_id})

        case failure do
          :raise -> raise "sensitive policy failure for #{event.event_id}"
          :exit -> exit({:sensitive, event.event_id})
        end
      end

      host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, policy: policy)
      scoped_fixture = %{fixture | host: host}
      listener = Elzoo.Wave4ChannelTestHelper.listener!(scoped_fixture)

      event =
        Elzoo.Wave4ChannelTestHelper.event(%{
          "event_id" => event_id,
          "input_id" => "#{event_id}-input"
        })

      assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

      assert {:ok, resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
                 fixture.profile.conversation_id
               )

      assert {:ok, {{_, 503, _}, _, body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
      assert Jason.decode!(body) == %{"event_id" => event_id, "status" => "unavailable"}
      refute body =~ "sensitive"
      assert_receive {:policy_callback, ^event_id}
      assert Process.alive?(host)
      assert {:idle, :no_input} = Wave4ChannelExample.advance(host)
      assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
      assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

      assert {:ok, ^resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
                 fixture.profile.conversation_id
               )
    end
  end

  test "input gate and policy denials retain refusal without resource, outbox, or native work", %{
    fixture: fixture
  } do
    denied_gate = %{
      input: fn _frame, _context -> :deny end,
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    {:ok, handles} =
      Elzoo.Wave4ChannelExample.CommandBindings.build(fixture.command_store, denied_gate)

    gate_host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, handles: handles)
    gate_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: gate_host)
    gate_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "gate-denied"})

    assert {:ok, {{_, 403, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(gate_listener, gate_event)

    gate_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, gate_event["event_id"])

    assert {:denied, _} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, gate_operation}
             )

    artifact = Elzoo.Wave4ChannelTestHelper.policy()
    denied_rule = %{hd(artifact.rules) | verdict: :deny}
    unsigned = %{artifact | rules: [denied_rule]}

    denied_policy =
      Map.put(
        unsigned,
        :content_hash,
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(Map.delete(unsigned, :content_hash), [:deterministic])
        )
      )

    policy = fn _mode, _event, _now -> denied_policy end
    policy_host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, policy: policy)
    policy_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: policy_host)
    policy_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "policy-denied"})

    assert {:ok, {{_, 403, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(policy_listener, policy_event)

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    assert resource.revision == 0

    assert :not_found =
             DynamicUnits.find(
               fixture.directory,
               Elzoo.Wave4ChannelTestHelper.unit_id("never-created")
             )
  end

  test "GET fails closed when the already-open run owner is unavailable", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    before_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_outbox = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Process.exit(fixture.owner, :kill)

    assert {:ok, {{_, 503, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(body) == %{"status" => "unavailable"}

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == before_head
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == before_outbox

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id)) ==
             []
  end

  test "GET reports not_recorded only for the known pre-creation phase", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, resource_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{
             "status" => "ok",
             "view" => %{"runs" => [%{"outcome" => "not_recorded", "run_id" => ^run_id}]}
           } = Jason.decode!(body)

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, ^resource_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, ^outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id)) ==
             []
  end

  test "GET fails closed when a retained run has a mismatched native operation", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _, _} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :create,
               run_id: run_id,
               operation_id: "wrong-native-operation",
               provider_refs: %{},
               expected_revision: fixture.held.live.revision
             })

    before_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_outbox = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(body) == %{"status" => "unavailable"}
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == before_head
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == before_outbox
  end

  test "future capacity accounts for the association and answer before input admission", %{
    fixture: fixture
  } do
    for index <- 1..15 do
      assert {:completed, %{revision: ^index}} =
               seed_message!(fixture, index, String.duplicate("x", 4_096))
    end

    resource_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    candidate =
      Enum.find_value(4_096..1//-16, fn size ->
        event =
          Elzoo.Wave4ChannelTestHelper.event(%{
            "event_id" => "capacity-event",
            "input_id" => "capacity-input",
            "expected_revision" => snapshot.revision,
            "text" => String.duplicate("y", size)
          })

        case hypothetical_capacity(snapshot, fixture.profile, event) do
          {:future_refusal, stage} -> {event, stage}
          _ -> nil
        end
      end)

    assert {event, stage} = candidate
    assert stage in [:association, :answer]
    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:ok, ^snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert {:error, :not_found} =
             RunApprovalRelease.status(
               fixture.owner,
               Elzoo.Wave4ChannelTestHelper.run_id(
                 fixture.profile,
                 event["event_id"],
                 event["input_id"]
               )
             )
  end

  test "signed loopback processes two distinct inputs and replays the first", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    first = Elzoo.Wave4ChannelTestHelper.event()

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "stale-event",
        "input_id" => "stale-input",
        "expected_revision" => 1
      })

    assert {:ok, {{_, 409, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, stale)

    stale_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, stale["event_id"])

    assert {:conflict, :stale_revision} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, stale_operation}
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, {{_, 202, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first)

    first_outbox = assert_input_outbox(fixture, first, 2)

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "event-2",
        "input_id" => "input-2",
        "expected_revision" => 3,
        "text" => "second native input"
      })

    assert {:ok, {{_, 503, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second)

    assert ^first_outbox = assert_input_outbox(fixture, first, 2)

    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    GenServer.stop(fixture.host, :normal)
    reopened = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    fixture = %{fixture | host: reopened}
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:ok, {{_, 503, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second)

    assert {:ok, {{_, 202, _}, _headers, body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first)

    assert %{"status" => "committed", "revision" => 1} = Jason.decode!(body)
    assert ^first_outbox = assert_input_outbox(fixture, first, 2)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, %{run_id: first_run, unit_id: first_unit, status: first_status}} =
             process_event(fixture, listener, first, 3, 2, 4)

    assert {:ok, %{run_id: second_run, unit_id: second_unit, status: second_status}} =
             process_event(fixture, listener, second, 6, 5, 7)

    assert {:ok, %{revision: 7}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert first_run != second_run
    assert first_unit != second_unit
    assert first_status.current_attempt != second_status.current_attempt
    assert first_status.attempts == [first_status.current_attempt]
    assert second_status.attempts == [second_status.current_attempt]
    assert {:ok, current_first_status} = RunApprovalRelease.status(fixture.owner, first_run)
    assert {:ok, current_second_status} = RunApprovalRelease.status(fixture.owner, second_run)
    assert stable_run_status(current_first_status) == stable_run_status(first_status)
    assert stable_run_status(current_second_status) == stable_run_status(second_status)
    before_reads = public_state(fixture, [first, second], [first_run, second_run])

    assert {:ok, replay} = Elzoo.Wave4ChannelTestHelper.post(listener, first)
    assert {{_, 202, _}, _headers, body} = replay
    assert %{"status" => "committed", "revision" => 1} = Jason.decode!(body)

    assert {:ok, []} =
             Outbox.pending(fixture.command_store, checked_stream(fixture.profile.tenant), 64)

    assert {:ok, {{_, 200, _}, _headers, before_view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _headers, after_view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert before_view == after_view
    assert public_state(fixture, [first, second], [first_run, second_run]) == before_reads
    assert take_hash_calls() == []

    assert %{
             "status" => "ok",
             "view" => %{
               "revision" => 6,
               "messages" => messages,
               "associations" => associations,
               "runs" => runs
             }
           } =
             Jason.decode!(after_view)

    assert messages == [
             %{
               "actor" => fixture.profile.actor,
               "message_id" => first["input_id"],
               "role" => "source",
               "text" => first["text"]
             },
             %{
               "actor" => fixture.profile.actor,
               "input_message_id" => first["input_id"],
               "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(first["input_id"]),
               "role" => "assistant",
               "run_id" => first_run,
               "text" => expected_answer(first)
             },
             %{
               "actor" => fixture.profile.actor,
               "message_id" => second["input_id"],
               "role" => "source",
               "text" => second["text"]
             },
             %{
               "actor" => fixture.profile.actor,
               "input_message_id" => second["input_id"],
               "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(second["input_id"]),
               "role" => "assistant",
               "run_id" => second_run,
               "text" => expected_answer(second)
             }
           ]

    assert associations == [
             %{"input_message_id" => first["input_id"], "run_id" => first_run},
             %{"input_message_id" => second["input_id"], "run_id" => second_run}
           ]

    assert runs == [
             %{
               "run_id" => first_run,
               "operation_id" =>
                 Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, first_run),
               "outcome" => "completed",
               "revision" => 7
             },
             %{
               "run_id" => second_run,
               "operation_id" =>
                 Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, second_run),
               "outcome" => "completed",
               "revision" => 7
             }
           ]

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert resource.revision == 6
    assert Map.keys(resource.fields) == ["conversation"]
    assert {:ok, projection} = Conversation.view(resource, scope)
    assert projection.revision == 6
    assert length(projection.messages) == 4
    assert length(projection.associations) == 2

    assert {:ok, []} =
             Outbox.pending(fixture.command_store, checked_stream(fixture.profile.tenant), 64)

    assert :not_found = DynamicUnits.find(fixture.directory, first_unit)
    assert :not_found = DynamicUnits.find(fixture.directory, second_unit)
    assert Registry.lookup(fixture.native.registry, first_unit) == []
    assert Registry.lookup(fixture.native.registry, second_unit) == []
  end

  defp process_event(
         fixture,
         listener,
         event,
         answer_revision,
         outbox_sequence,
         completion_revision
       ) do
    expected_input_revision = event["expected_revision"] + 1

    with {:ok, {{_, 202, _}, _headers, response}} <-
           Elzoo.Wave4ChannelTestHelper.post(listener, event),
         %{"status" => "committed", "revision" => ^expected_input_revision} <-
           Jason.decode!(response) do
      run_id =
        Elzoo.Wave4ChannelTestHelper.run_id(
          fixture.profile,
          event["event_id"],
          event["input_id"]
        )

      unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
      input_id = event["input_id"]
      stream = checked_stream(fixture.profile.tenant)

      assert_input_outbox(fixture, event, outbox_sequence)

      assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:ok, unit} = DynamicUnits.find(fixture.directory, unit_id)
      assert Map.keys(DurableUnit.snapshot(unit).control.budgets) == ["root"]
      assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

      assert {:result, :completed} =
               wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

      native_calls = take_hash_calls()
      assert native_calls == [event["text"]]

      assert {:answered, ^answer_revision} = Wave4ChannelExample.advance(fixture.host)

      assert [{engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

      assert {:ok,
              %{
                run_id: ^run_id,
                attempt_id: attempt_id,
                outcome: :completed,
                request_count: 2,
                slots: slots
              } = engine_status} = RunEngine.status(engine)

      assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
      assert map_size(slots) == 2

      work_count =
        Enum.count(slots, fn {_key, slot} ->
          slot.kind == "local_work" and slot.phase == :settled and slot.outcome == "completed"
        end)

      assert work_count == 1

      budget_count = map_size(DurableUnit.snapshot(unit).control.budgets)
      assert budget_count == 1
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 1, reserved: 0}}}} =
               Elzoo.Budget.step(budget, {fixture.clock.(), :status})

      assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:ok, []} = Outbox.pending(fixture.command_store, stream, 64)

      expected_answer =
        "answer:" <> Base.encode16(:crypto.hash(:sha256, event["text"]), case: :lower)

      assert {:ok, {{_, 200, _}, _headers, view}} =
               Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

      assert %{"status" => "ok", "view" => %{"messages" => messages}} = Jason.decode!(view)
      assert Enum.any?(messages, &(&1["text"] == expected_answer))
      assert {:ok, status} = RunApprovalRelease.status(fixture.owner, run_id)
      assert status.current_attempt == attempt_id
      assert status.attempts == [attempt_id]

      assert status.operation_id ==
               Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, run_id)

      assert status.outcome == :completed
      assert status.completion_revision == completion_revision
      assert_command_receipts(fixture, event, run_id, answer_revision)
      assert take_hash_calls() == []

      {:ok,
       %{
         run_id: run_id,
         unit_id: unit_id,
         status: status,
         engine_status: engine_status,
         work_count: work_count,
         native_calls: native_calls,
         budget_count: budget_count
       }}
    end
  end

  defp seed_message!(fixture, index, text) do
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    event_id = "seed-event-#{index}"
    message_id = "seed-message-#{index}"

    request = %{
      operation_id: Elzoo.Wave4ChannelTestHelper.input_operation(profile, event_id),
      resource: profile.conversation_id,
      expected_revision: snapshot.revision,
      payload: %{"message_id" => message_id, "text" => text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: profile.tenant, actor: profile.actor, data: facts}
    assert {:ok, writes, _} = Conversation.prepare(snapshot, request, prepared_facts)

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: facts
    }

    result = CheckedCommand.execute(fixture.handles.input, context, request)
    assert {:completed, _} = result
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:committed, _} =
             Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)

    result
  end

  defp hypothetical_capacity(snapshot, profile, event) do
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(profile, event["event_id"], event["input_id"])
    base = %{tenant: profile.tenant, actor: profile.actor}

    input_request = %{
      operation_id: operation,
      resource: event["conversation_id"],
      expected_revision: snapshot.revision,
      payload: %{"message_id" => event["input_id"], "text" => event["text"]}
    }

    input_facts =
      Map.put(
        base,
        :data,
        {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
      )

    with {:ok, input_writes, _} <- Conversation.prepare(snapshot, input_request, input_facts),
         input_snapshot <- apply_test_writes(snapshot, input_writes),
         association_request <- %{
           operation_id:
             Elzoo.Wave4ChannelTestHelper.association_operation(
               profile,
               event["event_id"],
               event["input_id"]
             ),
           resource: event["conversation_id"],
           expected_revision: snapshot.revision + 1,
           payload: %{"message_id" => event["input_id"]}
         },
         association_facts <-
           Map.put(
             base,
             :data,
             {:record, [{"mode", {:text, "associate_run"}}, {"run_id", {:text, run_id}}]}
           ) do
      case Conversation.prepare(input_snapshot, association_request, association_facts) do
        {:refused, _} ->
          {:future_refusal, :association}

        {:ok, association_writes, _} ->
          associated_snapshot = apply_test_writes(input_snapshot, association_writes)

          answer_request = %{
            operation_id:
              Elzoo.Wave4ChannelTestHelper.answer_operation(
                profile,
                event["event_id"],
                event["input_id"]
              ),
            resource: event["conversation_id"],
            expected_revision: snapshot.revision + 2,
            payload: %{
              "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(event["input_id"]),
              "text" => String.duplicate("x", 71)
            }
          }

          answer_facts =
            Map.put(
              base,
              :data,
              {:record,
               [
                 {"completed", true},
                 {"input_message_id", {:text, event["input_id"]}},
                 {"mode", {:text, "append_answer"}},
                 {"run_id", {:text, run_id}}
               ]}
            )

          case Conversation.prepare(associated_snapshot, answer_request, answer_facts) do
            {:refused, _} -> {:future_refusal, :answer}
            {:ok, _, _} -> :fits
          end
      end
    else
      _ -> :input_does_not_fit
    end
  end

  defp apply_test_writes(snapshot, writes) do
    fields = Enum.reduce(writes, snapshot.fields, &Map.put(&2, &1.field, &1.value))
    %{snapshot | revision: snapshot.revision + 1, fields: fields}
  end

  defp trace_native_hash(task_supervisor) do
    module = Elzoo.Wave4ChannelExample.NativeWork
    Process.put(:wave4_channel_hash_trace_target, task_supervisor)
    :erlang.trace_pattern({module, :hash, 1}, true, [:local])
    :erlang.trace(task_supervisor, true, [:call, :set_on_spawn])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(task_supervisor), do: :erlang.trace(task_supervisor, false, [:all])
      :erlang.trace_pattern({module, :hash, 1}, false, [:local])
      take_hash_calls()
    end)
  end

  defp trace_engine_input(host) do
    Process.put(:wave4_channel_engine_input_trace_target, host)
    :erlang.trace_pattern({RunEngine, :input, 4}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:all])
      :erlang.trace_pattern({RunEngine, :input, 4}, false, [:local])
      take_engine_input_ids()
    end)
  end

  defp take_engine_input_ids(acc \\ []) do
    await_trace_delivery(Process.get(:wave4_channel_engine_input_trace_target))

    receive do
      {:trace, _pid, :call, {RunEngine, :input, [_engine, input_id, _input, _context]}} ->
        take_engine_input_ids([input_id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp trace_read_apis(host) do
    Process.put(:wave4_channel_read_trace_target, host)
    :erlang.trace_pattern({CheckedCommand, :resource, 3}, true, [:local])
    :erlang.trace_pattern({RunApprovalRelease, :status, 2}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:all])
      :erlang.trace_pattern({CheckedCommand, :resource, 3}, false, [:local])
      :erlang.trace_pattern({RunApprovalRelease, :status, 2}, false, [:local])
      flush_trace_calls()
    end)
  end

  defp trace_checked_execute(host) do
    Process.put(:wave4_channel_execute_trace_target, host)
    :erlang.trace_pattern({CheckedCommand, :execute, 3}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:call])
      :erlang.trace_pattern({CheckedCommand, :execute, 3}, false, [:local])
      take_checked_execute_requests()
    end)
  end

  defp take_checked_execute_requests(acc \\ []) do
    await_trace_delivery(Process.get(:wave4_channel_execute_trace_target))

    receive do
      {:trace, _pid, :call, {CheckedCommand, :execute, [_handle, _context, request]}} ->
        take_checked_execute_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_trace_calls do
    await_trace_delivery(Process.get(:wave4_channel_read_trace_target))

    receive do
      {:trace, _pid, :call, _} -> flush_trace_calls()
    after
      0 -> :ok
    end
  end

  defp take_hash_calls do
    await_trace_delivery(Process.get(:wave4_channel_hash_trace_target))
    take_hash_calls([])
  end

  defp take_hash_calls(acc) do
    receive do
      {:trace, _pid, :call, {Elzoo.Wave4ChannelExample.NativeWork, :hash, [text]}} ->
        take_hash_calls([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_trace_delivery(target) when is_pid(target) do
    if Process.alive?(target) do
      delivered = :erlang.trace_delivered(target)
      assert_receive {:trace_delivered, ^target, ^delivered}, 5_000
    end
  end

  defp await_trace_delivery(_), do: :ok

  defp public_state(fixture, events, run_ids) do
    profile = fixture.profile
    scope = %{tenant: profile.tenant, actor: profile.actor}
    resource_scope = Map.put(scope, :resources, [profile.conversation_id])

    {:ok, resource} =
      CheckedCommand.resource(fixture.handles.input, resource_scope, profile.conversation_id)

    {:ok, head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    {:ok, outbox} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    receipts =
      Enum.map(events, fn event ->
        input_id = event["input_id"]
        input_op = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])

        association_op =
          Elzoo.Wave4ChannelTestHelper.association_operation(profile, event["event_id"], input_id)

        answer_op =
          Elzoo.Wave4ChannelTestHelper.answer_operation(profile, event["event_id"], input_id)

        {
          CheckedCommand.result(
            fixture.handles.input,
            scope,
            {profile.tenant, profile.actor, input_op}
          ),
          CheckedCommand.result(
            fixture.handles.association,
            scope,
            {profile.tenant, profile.actor, association_op}
          ),
          CheckedCommand.result(
            fixture.handles.answer,
            scope,
            {profile.tenant, profile.actor, answer_op}
          )
        }
      end)

    units =
      Enum.map(
        run_ids,
        &DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(&1))
      )

    unit_states =
      Enum.map(units, fn
        {:ok, unit} -> DurableUnit.snapshot(unit)
        other -> other
      end)

    engines =
      Enum.map(
        run_ids,
        &Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(&1))
      )

    engine_states =
      Enum.map(engines, fn
        [{engine, _}] -> RunEngine.status(engine)
        other -> other
      end)

    runs = Enum.map(run_ids, &RunApprovalRelease.status(fixture.owner, &1))

    %{
      resource: resource,
      head: head,
      outbox: outbox,
      receipts: receipts,
      runs: runs,
      units: units,
      unit_states: unit_states,
      engines: engines,
      engine_states: engine_states
    }
  end

  defp wait_for_result(host, deadline) do
    case Wave4ChannelExample.advance(host) do
      {:result, :completed} = result ->
        result

      {:pending, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "native result did not become observable before the deadline: " <>
              "reason=#{inspect(reason)}"
          )
        else
          Process.sleep(1)
          wait_for_result(host, deadline)
        end

      other ->
        flunk("unexpected native completion state: #{inspect(other)}")
    end
  end

  defp wait_public_result(engine, scope, deadline) do
    case RunEngine.result(engine, scope, %{max_records: 2_048, max_bytes: 16_777_216}) do
      {:ok, _} = result ->
        result

      {:pending, _} ->
        retry_public_result(engine, scope, deadline)

      {:error, :unavailable} ->
        retry_public_result(engine, scope, deadline)

      other ->
        other
    end
  end

  defp retry_public_result(engine, scope, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)
      wait_public_result(engine, scope, deadline)
    else
      {:error, :timeout}
    end
  end

  defp wait_for_paused(controller, token, deadline) do
    case Agent.get(controller, &Map.get(&1.paused, token)) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_for_paused(controller, token, deadline)
        else
          flunk("Postgres writer did not reach the pause barrier")
        end

      paused ->
        paused
    end
  end

  defp assert_input_outbox(fixture, event, sequence) do
    profile = fixture.profile
    stream = checked_stream(profile.tenant)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])
    idempotency_key = "#{stream}/#{sequence}/1"

    assert {:ok, [item]} = Outbox.pending(fixture.command_store, stream, 64)

    assert %{
             stream: ^stream,
             sequence: ^sequence,
             position: 1,
             destination: "wave4-channel-input",
             state: :pending,
             idempotency_key: ^idempotency_key,
             ack_nonce: nil,
             ack_digest: nil
           } = item

    assert is_binary(item.nonce) and byte_size(item.nonce) == 16
    assert is_binary(item.digest) and byte_size(item.digest) == 32

    assert Jason.decode!(item.payload) == %{
             "actor" => profile.actor,
             "operation_id" => operation,
             "resource" => profile.conversation_id,
             "revision" => event["expected_revision"] + 1,
             "tenant" => profile.tenant,
             "type" => "checked_command",
             "version" => 1
           }

    item
  end

  defp assert_command_receipts(fixture, event, run_id, answer_revision) do
    profile = fixture.profile
    scope = %{tenant: profile.tenant, actor: profile.actor}
    input_id = event["input_id"]
    input_revision = event["expected_revision"] + 1
    input_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])

    association_operation =
      Elzoo.Wave4ChannelTestHelper.association_operation(profile, event["event_id"], input_id)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(profile, event["event_id"], input_id)

    answer_id = Elzoo.Wave4ChannelTestHelper.answer_id(input_id)

    assert {:completed, %{revision: ^input_revision, response: {:record, input_fields}}} =
             CheckedCommand.result(
               fixture.handles.input,
               scope,
               {profile.tenant, profile.actor, input_operation}
             )

    assert Map.new(input_fields) == %{
             "message_id" => {:text, input_id},
             "revision" => input_revision
           }

    assert {:completed, %{revision: association_revision, response: {:record, association_fields}}} =
             CheckedCommand.result(
               fixture.handles.association,
               scope,
               {profile.tenant, profile.actor, association_operation}
             )

    assert association_revision == input_revision + 1

    assert Map.new(association_fields) == %{
             "message_id" => {:text, input_id},
             "revision" => association_revision,
             "run_id" => {:text, run_id}
           }

    assert {:completed, %{revision: ^answer_revision, response: {:record, answer_fields}}} =
             CheckedCommand.result(
               fixture.handles.answer,
               scope,
               {profile.tenant, profile.actor, answer_operation}
             )

    assert Map.new(answer_fields) == %{
             "input_message_id" => {:text, input_id},
             "message_id" => {:text, answer_id},
             "revision" => answer_revision,
             "run_id" => {:text, run_id}
           }
  end

  defp controlled_gate(control) do
    fn _frame, _context ->
      {fault, store} =
        Agent.get_and_update(control, fn state ->
          {{state.fault, state.store}, %{state | fault: nil}}
        end)

      case fault do
        :reply_loss ->
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:read_at, :unavailable])
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:append, :reply_loss])

        {:pause, token} ->
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:append, {:pause, token}])

        nil ->
          :ok
      end

      :allow
    end
  end

  defp host_with_gates(fixture, gates, overrides \\ []) do
    {:ok, handles} = Wave4ChannelExample.CommandBindings.build(fixture.command_store, gates)
    if Process.alive?(fixture.host), do: GenServer.stop(fixture.host, :normal)
    host_options = Keyword.merge(fixture.host_options, Keyword.merge([handles: handles], overrides))

    host =
      Elzoo.Wave4ChannelTestHelper.start_host!(
        fixture,
        Keyword.merge([handles: handles], overrides)
      )

    %{fixture | host: host, handles: handles, host_options: host_options}
  end

  defp host_with_native_hash_barrier(fixture, parent, token) do
    if Process.alive?(fixture.host), do: GenServer.stop(fixture.host, :normal, 5_000)

    engine = fixture.native.engine
    work = engine.bindings["local_work"]

    instrumented_work =
      Map.put(work, :work, fn action ->
        {__MODULE__, :blocked_native_hash, [action["payload"]["text"], parent, token]}
      end)

    native_engine = %{engine | bindings: Map.put(engine.bindings, "local_work", instrumented_work)}
    native = %{fixture.native | engine: native_engine}
    host_options = Keyword.put(fixture.host_options, :native, native)
    fixture = %{fixture | native: native, host_options: host_options}
    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    %{fixture | host: host}
  end

  defp without_native_hash_barrier(fixture) do
    native = %{
      fixture.native
      | engine: Elzoo.Wave4ChannelExample.NativeBindings.build(fixture.profile)
    }

    %{fixture | native: native, host_options: Keyword.put(fixture.host_options, :native, native)}
  end

  def blocked_native_hash(text, parent, token) do
    result = Elzoo.Wave4ChannelExample.NativeWork.hash(text)
    send(parent, {:wave4_native_hash_blocked, self(), token, result})

    receive do
      {:release_wave4_native_hash, ^token} -> result
    end
  end

  defp assert_terminal_work_outcome(fixture, outcome) do
    token = make_ref()
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _actual_result}, 5_000
    assert Process.alive?(task_pid)
    assert task_pid in Task.Supervisor.children(fixture.native.task_supervisor)
    host_state = :sys.get_state(fixture.host)
    assert host_state.phase == :result
    engine_pid = host_state.engine
    async_pid = host_state.async_work
    writer_pid = host_state.writer
    assert is_pid(engine_pid) and Process.alive?(engine_pid)
    assert is_pid(async_pid) and Process.alive?(async_pid)
    assert take_hash_calls() == [event["text"]]

    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert run_before.attempts == [attempt_id]
    assert is_nil(run_before.outcome)

    case outcome do
      :cancelled ->
        assert {:ok, _, :cancelled} =
                 RunApprovalRelease.command(fixture.owner, %{
                   kind: :cancel,
                   run_id: run_id,
                   attempt_id: attempt_id,
                   expected_revision: run_before.revision
                 })

      outcome when outcome in [:out_of_budget, :out_of_time] ->
        assert {:ok, _, ^outcome} =
                 RunApprovalRelease.command(fixture.owner, %{
                   kind: :complete,
                   run_id: run_id,
                   attempt_id: attempt_id,
                   outcome: outcome,
                   reason: nil,
                   evidence_ref: nil,
                   expected_revision: run_before.revision
                 })
    end

    assert {:terminal, ^outcome} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_terminal} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_terminal.id == run_before.id
    assert run_terminal.operation_id == run_before.operation_id
    assert run_terminal.current_attempt == attempt_id
    assert run_terminal.attempts == [attempt_id]
    assert run_terminal.revision == run_before.revision + 1
    assert run_terminal.outcome == outcome
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    refute Process.alive?(task_pid)
    refute Process.alive?(engine_pid)
    refute Process.alive?(async_pid)
    if is_pid(writer_pid), do: refute(Process.alive?(writer_pid))
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, sequence: 1, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "source")) == 1
    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert take_hash_calls() == []
  end

  defp set_gate_fault(control, store, fault) do
    Agent.update(control, fn state -> %{state | store: store, fault: fault} end)
  end

  defp expected_answer(event),
    do: "answer:" <> Base.encode16(:crypto.hash(:sha256, event["text"]), case: :lower)

  defp stable_run_status(status),
    do:
      Map.take(status, [
        :id,
        :operation_id,
        :current_attempt,
        :attempts,
        :outcome,
        :completion_revision,
        :evidence_ref
      ])

  defp checked_stream(tenant) do
    "cc1:" <>
      Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]), padding: false)
  end
end
