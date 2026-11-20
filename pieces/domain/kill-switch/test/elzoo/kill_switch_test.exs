# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.KillSwitchTest.Snapshot do
  defstruct [:tenant, :resource, :revision, :fields]
end

defmodule Elzoo.KillSwitchTest do
  use ExUnit.Case, async: true

  alias Elzoo.{CheckedCommand, KillSwitch, PayloadSchema}
  alias Elzoo.DurableLog.Memory

  @tenant "tenant-a"
  @resource "control"
  @max_ms 9_223_372_036_854_775_807

  # ------------------------------------------------------------ helpers

  defp switch(kind, id, reason, at \\ 1_000),
    do:
      {:record,
       [
         {"engaged_at", at},
         {"id", {:text, id}},
         {"kind", {:text, kind}},
         {"reason", {:text, reason}}
       ]}

  defp snapshot(fields \\ %{}, revision \\ 0),
    do: %{tenant: @tenant, resource: @resource, revision: revision, fields: fields}

  defp payload(op, kind, id, reason),
    do: %{"op" => op, "kind" => kind, "id" => id, "reason" => reason}

  defp request(payload, revision \\ 0),
    do: %{
      operation_id: "op-#{revision}",
      resource: @resource,
      expected_revision: revision,
      payload: payload
    }

  defp facts(now \\ 1_000),
    do: %{tenant: @tenant, actor: "operator", data: {:record, [{"now", now}]}}

  defp prep(snap, payload, now \\ 1_000),
    do: KillSwitch.prepare(snap, request(payload, snap.revision), facts(now))

  # Applies one successful preparation as CheckedCommand would: per-field put, revision + 1.
  defp step(snap, payload, now \\ 1_000) do
    assert {:ok, [write], {:record, [{"engaged", count}, {"revision", revision}]}} =
             prep(snap, payload, now)

    assert write.target == @resource and write.field == "switches"
    assert Enum.sort(Map.keys(write)) == [:field, :target, :value]
    assert revision == snap.revision + 1
    assert {:list, list} = write.value
    assert length(list) == count
    %{snap | revision: revision, fields: Map.put(snap.fields, "switches", write.value)}
  end

  defp read(snap), do: {:ok, snap}
  defp target(recipe \\ nil, tool \\ nil), do: %{tenant: @tenant, recipe: recipe, tool: tool}

  defp invalid?(snap, payload, now \\ 1_000),
    do: prep(snap, payload, now) == {:refused, "invalid_request"}

  # ------------------------------------------------------------ 1. prepare

  describe "prepare/3" do
    test "engages and releases each kind" do
      for {kind, id} <- [{"tenant", @tenant}, {"recipe", "recipe-1"}, {"tool", "send_email"}] do
        engaged = step(snapshot(), payload("engage", kind, id, "incident"), 1_234)
        assert engaged.fields["switches"] == {:list, [switch(kind, id, "incident", 1_234)]}
        assert engaged.revision == 1

        assert {:ok, [%{value: {:list, []}}], {:record, [{"engaged", 0}, {"revision", 2}]}} =
                 prep(engaged, payload("release", kind, id, "incident"))
      end
    end

    test "two reasons hold one target; releasing one leaves it suspended" do
      one = step(snapshot(), payload("engage", "tenant", @tenant, "incident"))
      two = step(one, payload("engage", "tenant", @tenant, "maintenance"))
      assert KillSwitch.check(read(two), target()) == {:deny, "tenant_suspended"}
      three = step(two, payload("release", "tenant", @tenant, "incident"))
      assert three.fields["switches"] == {:list, [switch("tenant", @tenant, "maintenance")]}
      assert KillSwitch.check(read(three), target()) == {:deny, "tenant_suspended"}
      four = step(three, payload("release", "tenant", @tenant, "maintenance"))
      assert KillSwitch.check(read(four), target()) == :allow
    end

    test "already_engaged, not_engaged and too_many at 65 entries" do
      one = step(snapshot(), payload("engage", "tool", "t", "incident"))

      assert prep(one, payload("engage", "tool", "t", "incident"), 9_999) ==
               {:refused, "already_engaged"}

      assert prep(snapshot(), payload("release", "tool", "t", "incident")) ==
               {:refused, "not_engaged"}

      assert prep(one, payload("release", "tool", "t", "other")) == {:refused, "not_engaged"}
      assert prep(one, payload("release", "recipe", "t", "incident")) == {:refused, "not_engaged"}

      ids = Enum.map(1..64, &"tool-#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

      full =
        Enum.reduce(Enum.shuffle(ids), snapshot(), fn id, snap ->
          step(snap, payload("engage", "tool", id, "incident"))
        end)

      assert {:list, list} = full.fields["switches"]
      assert list == Enum.map(ids, &switch("tool", &1, "incident"))

      assert prep(full, payload("engage", "tool", "tool-65", "incident")) ==
               {:refused, "too_many"}

      assert prep(full, payload("engage", "tool", "tool-01", "incident")) ==
               {:refused, "already_engaged"}

      assert {:ok, _, {:record, [{"engaged", 63}, _]}} =
               prep(full, payload("release", "tool", "tool-64", "incident"))
    end

    test "reserved_reason is a byte prefix and comes before cross_tenant and transitions" do
      for reason <- ["lifecycle", "lifecycle_x", "lifecyclex"], op <- ["engage", "release"] do
        assert prep(snapshot(), payload(op, "tool", "t", reason)) == {:refused, "reserved_reason"}

        assert prep(snapshot(), payload(op, "tenant", "tenant-b", reason)) ==
                 {:refused, "reserved_reason"}
      end

      for reason <- ["lifecycl", "x_lifecycle", "life_cycle"],
          do: step(snapshot(), payload("engage", "tool", "t", reason))

      # Shape wins over the reserved reason.
      assert invalid?(snapshot(), payload("engage", "tool", "", "lifecycle"))
    end

    test "cross_tenant for a tenant switch of another tenant, before transitions" do
      for op <- ["engage", "release"] do
        assert prep(snapshot(), payload(op, "tenant", "tenant-b", "incident")) ==
                 {:refused, "cross_tenant"}
      end

      # Recipe and tool IDs are not tenant IDs.
      step(snapshot(), payload("engage", "recipe", "tenant-b", "incident"))
    end

    test "other fields are ignored and never written" do
      fields = %{"lifecycle" => {:text, "active"}, "invitations" => {:list, [{:text, "x"}]}}
      snap = step(snapshot(fields, 7), payload("engage", "tool", "t", "incident"))
      assert Map.delete(snap.fields, "switches") == fields

      assert {:ok, [write], _} = prep(snap, payload("release", "tool", "t", "incident"))
      assert write.field == "switches"
    end

    test "the stored list is canonical whatever the engage order" do
      keys = [
        {"tool", "b", "incident"},
        {"tenant", @tenant, "maintenance"},
        {"recipe", "z", "incident"},
        {"tool", "a", "zeta"},
        {"tool", "a", "alpha"},
        {"recipe", "Z", "incident"},
        {"tenant", @tenant, "incident"}
      ]

      expected = keys |> Enum.sort() |> Enum.map(fn {k, i, r} -> switch(k, i, r) end)

      for _ <- 1..20 do
        snap =
          Enum.reduce(Enum.shuffle(keys), snapshot(), fn {k, i, r}, s ->
            step(s, payload("engage", k, i, r))
          end)

        assert snap.fields["switches"] == {:list, expected}
      end
    end

    test "engage/2 and release/2 accept reserved reasons and refuse malformed input" do
      lifecycle = switch("tenant", @tenant, "lifecycle")
      assert {:ok, {:list, [^lifecycle]} = list} = KillSwitch.engage({:list, []}, lifecycle)
      assert KillSwitch.engage(list, lifecycle) == {:error, :already_engaged}
      assert KillSwitch.release(list, {"tenant", @tenant, "lifecycle"}) == {:ok, {:list, []}}
      assert KillSwitch.release({:list, []}, {"tool", "t", "x"}) == {:error, :not_engaged}

      full =
        Enum.reduce(1..64, {:list, []}, fn n, acc ->
          {:ok, acc} = KillSwitch.engage(acc, switch("tool", "t#{1000 + n}", "x"))
          acc
        end)

      assert KillSwitch.engage(full, switch("tool", "u", "x")) == {:error, :too_many}

      for bad <- [nil, {:list, [:x]}, {:list, [lifecycle | :improper]}, [], {:text, "x"}] do
        assert KillSwitch.engage(bad, lifecycle) == {:error, :invalid}
        assert KillSwitch.release(bad, {"tenant", @tenant, "lifecycle"}) == {:error, :invalid}
      end

      assert KillSwitch.engage({:list, []}, switch("Tenant", "t", "x")) == {:error, :invalid}
      assert KillSwitch.engage({:list, []}, switch("tool", "t", "x", -1)) == {:error, :invalid}
      assert KillSwitch.release({:list, []}, {"tool", "t"}) == {:error, :invalid}
      assert KillSwitch.release({:list, []}, {"tool", "t", "X"}) == {:error, :invalid}
    end
  end

  # ------------------------------------------------------------ 2. shape

  describe "shape" do
    test "payload keys and kinds" do
      base = payload("engage", "tool", "t", "incident")
      step(snapshot(), base)

      assert invalid?(snapshot(), Map.delete(base, "reason"))
      assert invalid?(snapshot(), Map.put(base, "extra", "x"))
      assert invalid?(snapshot(), base |> Map.delete("id") |> Map.put(:id, "t"))
      assert invalid?(snapshot(), %{base | "id" => 5})
      assert invalid?(snapshot(), %{base | "reason" => nil})
      assert invalid?(snapshot(), %{base | "op" => "toggle"})
      assert invalid?(snapshot(), %{base | "kind" => "Tenant"})
      assert invalid?(snapshot(), %{base | "kind" => "space"})
    end

    test "IDs follow the domain/principal text rule" do
      long = String.duplicate("a", 128)
      step(snapshot(), payload("engage", "tool", "a", "incident"))
      step(snapshot(), payload("engage", "tool", long, "incident"))
      step(snapshot(), payload("engage", "tool", "é" <> String.duplicate("a", 126), "incident"))

      for id <- ["", long <> "a", <<0xFF>>, <<"a", 0xC3>>, "a\0b", "a\x7Fb", "a\u0085b", "a\nb"],
          do: assert(invalid?(snapshot(), payload("engage", "tool", id, "incident")))
    end

    test "reasons follow the gate code rule" do
      step(snapshot(), payload("engage", "tool", "t", String.duplicate("r", 64)))

      for reason <- [String.duplicate("r", 65), "", "Incident", "in-cident", "in cident", "é"],
          do: assert(invalid?(snapshot(), payload("engage", "tool", "t", reason)))
    end

    test "now is an integer 0..2^63-1 in exactly one record field" do
      base = payload("engage", "tool", "t", "incident")
      step(snapshot(), base, 0)
      step(snapshot(), base, @max_ms)

      for now <- [-1, @max_ms + 1, 1.0, nil, {:text, "1"}],
          do: assert(invalid?(snapshot(), base, now))

      req = request(base)

      for data <- [
            {:record, []},
            {:record, [{"now", 1}, {"zone", 1}]},
            {:record, [{"time", 1}]},
            {:list, [1]}
          ] do
        assert KillSwitch.prepare(snapshot(), req, %{facts() | data: data}) ==
                 {:refused, "invalid_request"}
      end

      assert KillSwitch.prepare(snapshot(), req, Map.put(facts(), :extra, 1)) ==
               {:refused, "invalid_request"}

      assert KillSwitch.prepare(snapshot(), req, nil) == {:refused, "invalid_request"}
    end

    test "a malformed stored list" do
      base = payload("engage", "tool", "m", "incident")
      a = switch("tool", "a", "x")
      b = switch("tool", "b", "x")
      sixty_five = Enum.map(1000..1064, &switch("tool", "t#{&1}", "x"))

      for stored <- [
            {:list, [b, a]},
            {:list, [a, a]},
            {:list, [a, switch("tool", "a", "x", 5)]},
            {:list, sixty_five},
            {:list, [a | b]},
            {:list, [{:record, [{"id", {:text, "a"}}]}]},
            {:list, [switch("tool", "a", "x", -1)]},
            {:list, [switch("tool", "a", "lifecycle_X")]},
            {:text, "x"},
            []
          ] do
        assert invalid?(snapshot(%{"switches" => stored}), base)
        assert invalid?(snapshot(%{"switches" => stored}), payload("release", "tool", "a", "x"))
      end

      # A sorted stored list with a reserved reason is valid (written by a composer).
      snap = snapshot(%{"switches" => {:list, [switch("tenant", @tenant, "lifecycle")]}})
      step(snap, base)
    end

    test "snapshot and request shape" do
      base = payload("engage", "tool", "t", "incident")
      req = request(base)

      for snap <- [
            Map.put(snapshot(), :extra, 1),
            Map.delete(snapshot(), :fields),
            %{snapshot() | revision: -1},
            %{snapshot() | revision: @max_ms},
            %{snapshot() | fields: [{"switches", {:list, []}}]},
            %{snapshot() | tenant: ""},
            struct(Elzoo.KillSwitchTest.Snapshot, snapshot()),
            nil
          ] do
        assert KillSwitch.prepare(snap, req, facts()) == {:refused, "invalid_request"}
      end

      for r <- [
            %{req | resource: "other"},
            Map.put(req, :extra, 1),
            Map.delete(req, :payload),
            %{req | payload: [base]}
          ] do
        assert KillSwitch.prepare(snapshot(), r, facts()) == {:refused, "invalid_request"}
      end

      assert {:ok, _, {:record, [_, {"revision", @max_ms}]}} =
               KillSwitch.prepare(%{snapshot() | revision: @max_ms - 1}, req, facts())
    end
  end

  # ------------------------------------------------------------ 3. check

  describe "check/2" do
    test "each deny code and its order" do
      tenant = switch("tenant", @tenant, "incident")
      recipe = switch("recipe", "recipe-1", "incident")
      tool = switch("tool", "send_email", "incident")
      t = target("recipe-1", "send_email")

      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, [recipe, tenant, tool]}})), t) ==
               {:deny, "tenant_suspended"}

      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, [tenant]}})), target()) ==
               {:deny, "tenant_suspended"}

      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, [recipe, tool]}})), t) ==
               {:deny, "recipe_suspended"}

      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, [tool]}})), t) ==
               {:deny, "tool_suspended"}

      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, [recipe]}})), t) ==
               {:deny, "recipe_suspended"}

      lifecycle = snapshot(%{"switches" => {:list, [switch("tenant", @tenant, "lifecycle")]}})
      assert KillSwitch.check(read(lifecycle), target()) == {:deny, "tenant_suspended"}
    end

    test "allows with switches for other targets and with no switches" do
      others =
        {:list,
         [
           switch("recipe", "recipe-2", "incident"),
           switch("recipe", "send_email", "incident"),
           switch("tenant", "tenant-b", "incident"),
           switch("tool", "recipe-1", "incident"),
           switch("tool", "send_email_v2", "incident")
         ]}

      assert KillSwitch.check(
               read(snapshot(%{"switches" => others})),
               target("recipe-1", "send_email")
             ) ==
               :allow

      assert KillSwitch.check(read(snapshot(%{"switches" => others})), target()) == :allow

      only_recipe = snapshot(%{"switches" => {:list, [switch("recipe", "recipe-1", "x")]}})
      assert KillSwitch.check(read(only_recipe), target(nil, "tool")) == :allow

      assert KillSwitch.check(read(snapshot()), target("recipe-1", "send_email")) == :allow
      assert KillSwitch.check(read(snapshot(%{"other" => 1}, 5)), target()) == :allow
      assert KillSwitch.check(read(snapshot(%{"switches" => {:list, []}}, 3)), target()) == :allow
    end

    test "an unavailable read or a malformed target is kill_switch_unavailable" do
      unavailable = {:deny, "kill_switch_unavailable"}
      good = snapshot()

      for r <- [
            :not_found,
            {:refused, :invalid_request},
            {:unknown, :storage},
            {:ok, %{good | tenant: "tenant-b"}},
            {:ok, Map.put(good, :extra, 1)},
            {:ok, Map.delete(good, :revision)},
            {:ok, %{good | fields: nil}},
            {:ok, struct(Elzoo.KillSwitchTest.Snapshot, good)},
            {:error, good},
            good,
            {:ok,
             %{
               good
               | fields: %{
                   "switches" => {:list, [switch("tool", "b", "x"), switch("tool", "a", "x")]}
                 }
             }},
            {:ok,
             %{
               good
               | fields: %{
                   "switches" => {:list, [switch("tool", "a", "x"), switch("tool", "a", "x")]}
                 }
             }},
            {:ok,
             %{
               good
               | fields: %{
                   "switches" => {:list, Enum.map(1000..1064, &switch("tool", "t#{&1}", "x"))}
                 }
             }},
            {:ok, %{good | fields: %{"switches" => {:text, "none"}}}},
            {:ok, %{good | fields: %{"switches" => {:list, [switch("tool", "a", "x") | :tail]}}}}
          ] do
        assert KillSwitch.check(r, target()) == unavailable
      end

      for t <- [
            %{tenant: "tenant-b", recipe: nil, tool: nil},
            %{tenant: @tenant, recipe: nil},
            %{tenant: @tenant, recipe: nil, tool: nil, space: nil},
            %{tenant: @tenant, recipe: "", tool: nil},
            %{tenant: @tenant, recipe: nil, tool: :send_email},
            %{tenant: @tenant, recipe: nil, tool: "a\0b"},
            {@tenant, nil, nil},
            nil
          ] do
        assert KillSwitch.check(read(good), t) == unavailable
      end
    end

    test "arbitrary terms never raise" do
      :rand.seed(:exsss, {281, 645, 2026})
      tool = switch("tool", "t", "x")
      valid = {:ok, snapshot(%{"switches" => {:list, [tool]}})}

      for _ <- 1..3_000 do
        r = Enum.random([term(3), {:ok, term(3)}, mutate(valid), valid])
        t = Enum.random([term(3), target(term(1), term(1)), target(nil, "t")])
        result = KillSwitch.check(r, t)

        assert result in [
                 :allow,
                 {:deny, "kill_switch_unavailable"},
                 {:deny, "tool_suspended"},
                 {:deny, "tenant_suspended"},
                 {:deny, "recipe_suspended"}
               ]
      end
    end
  end

  defp term(0), do: Enum.random([nil, true, 1, -1, 1.5, "t", "", <<0xFF>>, :ok, @tenant, []])

  defp term(depth) do
    case :rand.uniform(7) do
      1 ->
        {:list, Enum.map(1..:rand.uniform(3), fn _ -> term(depth - 1) end)}

      2 ->
        {:record, [{"id", term(depth - 1)}]}

      3 ->
        %{
          tenant: @tenant,
          resource: term(0),
          revision: term(0),
          fields: %{"switches" => term(depth - 1)}
        }

      4 ->
        [term(depth - 1) | term(0)]

      5 ->
        {term(depth - 1), term(depth - 1)}

      6 ->
        %{term(0) => term(depth - 1)}

      _ ->
        term(0)
    end
  end

  defp mutate({:ok, %{fields: %{"switches" => {:list, [{:record, fields}]}}} = s}) do
    i = :rand.uniform(4) - 1
    {name, _} = Enum.at(fields, i)
    fields = List.replace_at(fields, i, {name, term(2)})
    {:ok, %{s | fields: %{"switches" => {:list, [{:record, fields}]}}}}
  end

  # ------------------------------------------------------------ 4. composition

  @hash :binary.copy(<<9>>, 32)
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @ks_port %{
    "id" => "kill-switch",
    "direction" => "input",
    "schema_id" => "kill_switch/change",
    "schema_version" => 1
  }
  @work_port %{
    "id" => "work",
    "direction" => "input",
    "schema_id" => "work/run",
    "schema_version" => 1
  }
  @ks_schema %{
    "type" => "object",
    "required" => ["op", "kind", "id", "reason"],
    "additionalProperties" => false,
    "properties" => %{
      "op" => %{"enum" => ["engage", "release"]},
      "kind" => %{"enum" => ["tenant", "recipe", "tool"]},
      "id" => %{"type" => "string"},
      "reason" => %{"type" => "string"}
    }
  }
  @operator "operator-1"
  @worker "worker-1"
  @scope %{tenant: @tenant, actor: @operator, resources: [@resource]}

  defp fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: ["notify"],
      reduce: fn model, _sequence, _kind, _payload -> model end
    }
  end

  defp memory_store do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: @limits, append_visibility: :atomic)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Memory.store(pid, %{fold: fold()})
  end

  defp policy(class, verdict) do
    rule =
      case verdict do
        :ask ->
          %{
            id: "review",
            effect_class: class,
            verdict: :ask,
            requirement: %{name: "kill_switch_review", version: 1, scope: :once}
          }

        :allow ->
          %{id: "allow", effect_class: class, verdict: :allow}
      end

    %{
      id: "policy-#{class}",
      version: 1,
      content_hash: @hash,
      effect_classes: [class],
      rules: [rule]
    }
  end

  defp approval, do: %{verifiers: ["command-reviewer"], max_age: 60_000}

  # The kill-switch descriptor's gate is the host's own policy: it never calls
  # check/2, so a suspended tenant can still be released.
  defp ks_handle(store) do
    {:ok, schema} = PayloadSchema.build(@ks_port, @ks_schema)

    {:ok, handle} =
      CheckedCommand.new(store, %{
        id: "kill-switch/change",
        version: 1,
        content_hash: @hash,
        effect_class: "kill_switch",
        port: @ks_port,
        schema: schema,
        prepare: &KillSwitch.prepare/3,
        gate: %{call: fn _frame, _context -> :allow end},
        approval: approval()
      })

    handle
  end

  # The README gate: the host maps the frame to a trusted target and calls check/2
  # over the read it took immediately before building this handle.
  defp readme_gate(read, tools) do
    %{
      call: fn {:PatternStep, %{"actions" => [action]}}, %{tenant: tenant} ->
        KillSwitch.check(read, %{
          tenant: tenant,
          recipe: nil,
          tool: Map.get(tools, action["schema_id"])
        })
      end
    }
  end

  defp work_handle(store, read) do
    {:ok, schema} = PayloadSchema.build(@work_port, %{})

    {:ok, handle} =
      CheckedCommand.new(store, %{
        id: "work/run",
        version: 1,
        content_hash: @hash,
        effect_class: "work",
        port: @work_port,
        schema: schema,
        prepare: fn _snapshot, request, _facts ->
          {:ok, [%{target: request.resource, field: "state", value: {:text, "done"}}],
           {:record, [{"done", true}]}}
        end,
        gate: readme_gate(read, %{"work/run" => "send_email"}),
        approval: approval()
      })

    handle
  end

  defp run_work(store, ks, operation_id) do
    read = CheckedCommand.resource(ks, @scope, @resource)

    CheckedCommand.execute(
      work_handle(store, read),
      %{
        tenant: @tenant,
        actor: @worker,
        policy: policy("work", :allow),
        own: [%{target: "job-1", field: "state", value: {:text, "done"}}],
        parent: :none,
        facts: {:record, []}
      },
      %{operation_id: operation_id, resource: "job-1", expected_revision: 0, payload: %{}}
    )
  end

  # The host gives the operator exact-value authority (Authorization's rule) for
  # the one switches value this change produces over the read it just took.
  defp ks_command(ks, operation_id, payload, now, verdict \\ :allow) do
    {:ok, snap} = CheckedCommand.resource(ks, @scope, @resource)

    request = %{
      operation_id: operation_id,
      resource: @resource,
      expected_revision: snap.revision,
      payload: payload
    }

    facts = {:record, [{"now", now}]}

    own =
      case KillSwitch.prepare(snap, request, %{tenant: @tenant, actor: @operator, data: facts}) do
        {:ok, writes, _response} -> writes
        {:refused, _} -> []
      end

    context = %{
      tenant: @tenant,
      actor: @operator,
      policy: policy("kill_switch", verdict),
      own: own,
      parent: :none,
      facts: facts
    }

    {context, request}
  end

  describe "composition on the Memory Store" do
    test "engage, gate denial retained under its operation ID, release, replay" do
      store = memory_store()
      ks = ks_handle(store)

      assert {:ok, %{revision: 0, fields: %{}}} =
               before = CheckedCommand.resource(ks, @scope, @resource)

      assert KillSwitch.check(before, target()) == :allow

      {ctx, engage} =
        ks_command(ks, "engage-1", payload("engage", "tenant", @tenant, "incident"), 5_000)

      assert {:completed, %{revision: 1, response: {:record, [{"engaged", 1}, {"revision", 1}]}}} =
               engaged = CheckedCommand.execute(ks, ctx, engage)

      read = CheckedCommand.resource(ks, @scope, @resource)

      assert {:ok, %{revision: 1, fields: %{"switches" => {:list, [switch]}}}} = read
      assert switch == switch("tenant", @tenant, "incident", 5_000)
      assert KillSwitch.check(read, target()) == {:deny, "tenant_suspended"}

      assert run_work(store, ks, "work-1") == {:denied, {:gate, "tenant_suspended"}}

      assert CheckedCommand.result(
               ks,
               %{tenant: @tenant, actor: @worker},
               {@tenant, @worker, "work-1"}
             ) ==
               {:denied, {:gate, "tenant_suspended"}}

      # Replay of the engage operation returns its retained result.
      assert CheckedCommand.execute(ks, ctx, engage) == engaged

      # The kill-switch descriptor releases the tenant switch while it is engaged.
      {ctx, release} =
        ks_command(ks, "release-1", payload("release", "tenant", @tenant, "incident"), 6_000)

      assert {:completed, %{revision: 2, response: {:record, [{"engaged", 0}, {"revision", 2}]}}} =
               CheckedCommand.execute(ks, ctx, release)

      released = CheckedCommand.resource(ks, @scope, @resource)
      assert {:ok, %{revision: 2, fields: %{"switches" => {:list, []}}}} = released
      assert KillSwitch.check(released, target()) == :allow

      # The retained denial replays under the old ID; a new ID commits.
      assert run_work(store, ks, "work-1") == {:denied, {:gate, "tenant_suspended"}}

      assert {:completed, %{revision: 1, response: {:record, [{"done", true}]}}} =
               run_work(store, ks, "work-2")
    end

    test "the README gate denies a tool switch and an unavailable read" do
      store = memory_store()
      ks = ks_handle(store)

      {ctx, engage} =
        ks_command(ks, "engage-tool", payload("engage", "tool", "send_email", "incident"), 1)

      assert {:completed, %{revision: 1}} = CheckedCommand.execute(ks, ctx, engage)
      assert run_work(store, ks, "work-tool") == {:denied, {:gate, "tool_suspended"}}

      handle = work_handle(store, {:unknown, :storage})

      assert {:denied, {:gate, "kill_switch_unavailable"}} =
               CheckedCommand.execute(
                 handle,
                 %{
                   tenant: @tenant,
                   actor: @worker,
                   policy: policy("work", :allow),
                   own: [%{target: "job-1", field: "state", value: {:text, "done"}}],
                   parent: :none,
                   facts: {:record, []}
                 },
                 %{
                   operation_id: "work-unavailable",
                   resource: "job-1",
                   expected_revision: 0,
                   payload: %{}
                 }
               )
    end

    test "ASK keeps the switch unchanged until a reviewer other than the proposer releases it" do
      store = memory_store()
      ks = ks_handle(store)

      {ctx, engage} =
        ks_command(ks, "engage-ask", payload("engage", "recipe", "recipe-1", "incident"), 100, :ask)

      assert {:approval_pending, %{key: key}} = CheckedCommand.execute(ks, ctx, engage)
      unchanged = CheckedCommand.resource(ks, @scope, @resource)
      assert {:ok, %{revision: 0, fields: %{}}} = unchanged
      assert KillSwitch.check(unchanged, target("recipe-1")) == :allow

      evidence = fn reviewer, id ->
        %{
          purpose: :command,
          tenant: @tenant,
          evidence: %{
            verifier: "command-reviewer",
            evidence_id: id,
            reviewer: reviewer,
            request: key,
            decision: :approve,
            scope: :once,
            issued_at: 100,
            expiry: 200
          }
        }
      end

      release_ctx = fn reviewer ->
        Map.merge(ctx, %{approver: %{identity: reviewer, authority: ctx.own}, now: 150, revoked: []})
      end

      identity = {@tenant, @operator, "engage-ask"}

      # The same evidence ID with the proposer as reviewer is refused by the ready
      # Approval self-approval rule and consumes nothing.
      assert CheckedCommand.release(
               ks,
               release_ctx.(@operator),
               identity,
               evidence.(@operator, "e-1")
             ) ==
               {:release_refused, :evidence}

      assert CheckedCommand.resource(ks, @scope, @resource) == unchanged

      assert {:approval_pending, _} =
               CheckedCommand.result(ks, %{tenant: @tenant, actor: @operator}, identity)

      assert {:completed, %{revision: 1, response: {:record, [{"engaged", 1}, {"revision", 1}]}}} =
               CheckedCommand.release(
                 ks,
                 release_ctx.("reviewer-1"),
                 identity,
                 evidence.("reviewer-1", "e-1")
               )

      after_release = CheckedCommand.resource(ks, @scope, @resource)
      assert KillSwitch.check(after_release, target("recipe-1")) == {:deny, "recipe_suspended"}
      assert KillSwitch.check(after_release, target("recipe-2")) == :allow
    end
  end

  # ------------------------------------------------------------ Cure and example

  test "selected Cure laws, a clean audit and the checked example" do
    source = File.read!(Path.expand("../../cure/elzoo/kill_switch.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    {result, _} = Code.eval_file(Path.expand("../../examples/kill_switch.exs", __DIR__))

    assert result == [
             :allow,
             {:record, [{"engaged", 1}, {"revision", 1}]},
             {:deny, "tool_suspended"},
             {:record, [{"engaged", 0}, {"revision", 2}]},
             :allow,
             {:deny, "kill_switch_unavailable"}
           ]
  end
end
