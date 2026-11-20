# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TenantLifecycleTest do
  use ExUnit.Case, async: true

  alias Elzoo.{CheckedCommand, KillSwitch, Membership, PayloadSchema, Principal, TenantLifecycle}
  alias Elzoo.DurableLog.Memory

  @tenant "tenant-a"
  @resource "control"
  @admin "admin-1"
  @now 1_000
  @max_s 9_223_372_036_854_775
  @states ~w(none provisioned active suspended closing erased)
  @lifecycle_ops ~w(provision activate suspend close erase)
  @code :binary.copy(<<0xC3, 0x5A>>, 8)
  @digest :crypto.hash(:sha256, :binary.copy(<<0xC3, 0x5A>>, 8))
  @other_digest :crypto.hash(:sha256, "another code of sixteen")

  # ------------------------------------------------------------ helpers

  defp snapshot(fields \\ %{}, revision \\ 0),
    do: %{tenant: @tenant, resource: @resource, revision: revision, fields: fields}

  defp request(payload, revision, operation_id \\ "op"),
    do: %{
      operation_id: operation_id,
      resource: @resource,
      expected_revision: revision,
      payload: payload
    }

  # The exact facts record of each command, sorted by name as Authorization
  # normalizes it.
  defp data(op, now \\ @now, overrides \\ []) do
    base =
      case op do
        "erase" ->
          [{"vault_erased", true}]

        "invite" ->
          [{"code_digest", {:bytes, @digest}}, {"known_target", true}, {"inviter_may_grant", true}]

        "accept" ->
          [{"presented_digest", {:bytes, @digest}}]

        _ ->
          []
      end

    pairs =
      Enum.reduce(overrides, [{"now", now} | base], fn {k, v}, acc ->
        List.keystore(acc, k, 0, {k, v})
      end)

    {:record, Enum.sort_by(pairs, &elem(&1, 0))}
  end

  defp facts(data, actor \\ @admin), do: %{tenant: @tenant, actor: actor, data: data}

  defp prep(snap, payload, data, actor \\ @admin),
    do: TenantLifecycle.prepare(snap, request(payload, snap.revision), facts(data, actor))

  defp op(op), do: %{"op" => op}

  defp invite(id, opts \\ []) do
    %{
      "op" => "invite",
      "id" => id,
      "space" => Keyword.get(opts, :space, "space-1"),
      "role" => Keyword.get(opts, :role, "member"),
      "invitee" => Keyword.get(opts, :invitee, nil),
      "expires_at" => Keyword.get(opts, :expires_at, @now + 100)
    }
  end

  defp accept(id), do: %{"op" => "accept", "id" => id}
  defp revoke(id), do: %{"op" => "revoke", "id" => id}

  # Applies one successful preparation as CheckedCommand would: per-field put,
  # revision + 1.
  defp apply_ok(snap, {:ok, writes, response}) do
    assert length(writes) in 1..3
    assert Enum.all?(writes, &(&1.target == @resource and map_size(&1) == 3))
    assert length(Enum.uniq_by(writes, & &1.field)) == length(writes)
    fields = Enum.reduce(writes, snap.fields, &Map.put(&2, &1.field, &1.value))
    {%{snap | revision: snap.revision + 1, fields: fields}, writes, response}
  end

  defp step(snap, payload, data \\ nil, actor \\ @admin) do
    data = data || data(payload["op"])
    {next, _writes, _response} = apply_ok(snap, prep(snap, payload, data, actor))
    next
  end

  defp at("none"), do: snapshot()
  defp at("provisioned"), do: step(at("none"), op("provision"))
  defp at("active"), do: step(at("provisioned"), op("activate"))
  defp at("suspended"), do: step(at("active"), op("suspend"))
  defp at("closing"), do: step(at("active"), op("close"))
  defp at("erased"), do: step(at("closing"), op("erase"))

  defp lifecycle_switch(at_ms),
    do:
      {:record,
       [
         {"engaged_at", at_ms},
         {"id", {:text, @tenant}},
         {"kind", {:text, "tenant"}},
         {"reason", {:text, "lifecycle"}}
       ]}

  defp incident,
    do:
      {:record,
       [
         {"engaged_at", 5},
         {"id", {:text, @tenant}},
         {"kind", {:text, "tenant"}},
         {"reason", {:text, "incident"}}
       ]}

  defp target, do: %{tenant: @tenant, recipe: nil, tool: nil}
  defp check(snap), do: KillSwitch.check({:ok, snap}, target())
  defp state(snap), do: TenantLifecycle.status({:ok, snap})

  defp invitations(snap) do
    {:list, items} = Map.get(snap.fields, "invitations", {:list, []})

    Enum.map(items, fn {:record, fields} ->
      {"id", {:text, id}} = List.keyfind(fields, "id", 0)
      id
    end)
  end

  defp refused?(snap, payload, code, data \\ nil, actor \\ @admin),
    do: prep(snap, payload, data || data(payload["op"]), actor) == {:refused, code}

  defp invalid?(snap, payload, data \\ nil, actor \\ @admin),
    do: refused?(snap, payload, "invalid_request", data, actor)

  # ------------------------------------------------------------ 1. lifecycle

  describe "transition table" do
    test "every listed transition writes the listed lifecycle switch change" do
      now = 1_234
      d = &data(&1, now)

      {provisioned, writes, response} =
        apply_ok(snapshot(), prep(snapshot(), op("provision"), d.("provision")))

      assert writes == [
               %{target: @resource, field: "lifecycle", value: {:text, "provisioned"}},
               %{
                 target: @resource,
                 field: "switches",
                 value: {:list, [lifecycle_switch(now * 1000)]}
               }
             ]

      assert response ==
               {:record, [{"lifecycle", {:text, "provisioned"}}, {"pending", 0}, {"revision", 1}]}

      for from <- [provisioned, step(at("active"), op("suspend"), d.("suspend"))] do
        assert {active, writes, _} = apply_ok(from, prep(from, op("activate"), d.("activate")))
        assert Enum.sort(Enum.map(writes, & &1.field)) == ["lifecycle", "switches"]
        assert active.fields["lifecycle"] == {:text, "active"}
        assert active.fields["switches"] == {:list, []}
      end

      active = at("active")
      {suspended, writes, _} = apply_ok(active, prep(active, op("suspend"), d.("suspend")))
      assert length(writes) == 2
      assert suspended.fields["switches"] == {:list, [lifecycle_switch(now * 1000)]}

      # close from active engages; from suspended it keeps the engaged switch.
      {closing, writes, _} = apply_ok(active, prep(active, op("close"), d.("close")))
      assert length(writes) == 2
      assert closing.fields["lifecycle"] == {:text, "closing"}
      assert closing.fields["switches"] == {:list, [lifecycle_switch(now * 1000)]}

      {closing2, writes, _} =
        apply_ok(suspended, prep(suspended, op("close"), data("close", now + 9)))

      assert writes == [%{target: @resource, field: "lifecycle", value: {:text, "closing"}}]
      assert closing2.fields["switches"] == {:list, [lifecycle_switch(now * 1000)]}

      # erase keeps the switch.
      {erased, writes, _} = apply_ok(closing, prep(closing, op("erase"), d.("erase")))
      assert writes == [%{target: @resource, field: "lifecycle", value: {:text, "erased"}}]
      assert erased.fields["switches"] == closing.fields["switches"]
      assert state(erased) == {:ok, "erased"}
    end

    test "every other (state, lifecycle op) pair is invalid_transition, or terminal from erased" do
      allowed = %{
        {"none", "provision"} => "provisioned",
        {"provisioned", "activate"} => "active",
        {"suspended", "activate"} => "active",
        {"active", "suspend"} => "suspended",
        {"active", "close"} => "closing",
        {"suspended", "close"} => "closing",
        {"closing", "erase"} => "erased"
      }

      for from <- @states, o <- @lifecycle_ops do
        snap = at(from)
        result = prep(snap, op(o), data(o))

        case {from, Map.fetch(allowed, {from, o})} do
          {"erased", _} ->
            assert result == {:refused, "terminal"}

          {_, {:ok, to}} ->
            {next, _, _} = apply_ok(snap, result)
            assert state(next) == {:ok, to}, "#{from} #{o}"

          {_, :error} ->
            assert result == {:refused, "invalid_transition"}, "#{from} #{o}"
        end
      end
    end

    test "invite, accept and revoke outside active" do
      for from <- @states -- ["active"] do
        snap = at(from)
        code = if from == "erased", do: "terminal", else: "not_active"
        assert refused?(snap, invite("i-1"), code)
        assert refused?(snap, accept("i-1"), code)

        revoke_code = if from == "erased", do: "terminal", else: "unknown_invitation"
        assert refused?(snap, revoke("i-1"), revoke_code)
      end
    end

    test "erase without vault_erased: true is not_erased" do
      for value <- [false, nil, 1, {:text, "true"}, {:list, [true]}] do
        assert refused?(
                 at("closing"),
                 op("erase"),
                 "not_erased",
                 data("erase", @now, [{"vault_erased", value}])
               )
      end

      # Order: terminal and invalid_transition come before not_erased.
      assert refused?(
               at("active"),
               op("erase"),
               "invalid_transition",
               data("erase", @now, [{"vault_erased", false}])
             )

      assert refused?(
               at("erased"),
               op("erase"),
               "terminal",
               data("erase", @now, [{"vault_erased", false}])
             )
    end

    test "check/2 denies after provision and suspend and allows after activate" do
      assert check(at("none")) == :allow
      assert check(at("provisioned")) == {:deny, "tenant_suspended"}
      assert check(at("active")) == :allow
      assert check(at("suspended")) == {:deny, "tenant_suspended"}
      assert check(at("closing")) == {:deny, "tenant_suspended"}
      assert check(step(at("suspended"), op("activate"))) == :allow
    end

    test "an incident switch beside the lifecycle switch survives activate" do
      suspended = at("suspended")
      {:ok, both} = KillSwitch.engage(suspended.fields["switches"], incident())
      suspended = %{suspended | fields: Map.put(suspended.fields, "switches", both)}

      active = step(suspended, op("activate"))
      assert state(active) == {:ok, "active"}
      assert active.fields["switches"] == {:list, [incident()]}
      assert check(active) == {:deny, "tenant_suspended"}

      # suspend over an active tenant with an incident switch adds the lifecycle one.
      again = step(active, op("suspend"), data("suspend", 7))
      assert again.fields["switches"] == {:list, [incident(), lifecycle_switch(7_000)]}
    end

    test "a full switch list refuses a command that would engage the lifecycle switch" do
      tools =
        for n <- 1..64 do
          {:record,
           [
             {"engaged_at", 1},
             {"id", {:text, "tool-#{String.pad_leading(Integer.to_string(n), 2, "0")}"}},
             {"kind", {:text, "tool"}},
             {"reason", {:text, "incident"}}
           ]}
        end

      assert refused?(snapshot(%{"switches" => {:list, tools}}), op("provision"), "too_many")
    end

    test "engaged_at is now * 1000 up to the largest now" do
      {next, _, _} =
        apply_ok(snapshot(), prep(snapshot(), op("provision"), data("provision", @max_s)))

      assert next.fields["switches"] == {:list, [lifecycle_switch(@max_s * 1000)]}
      assert @max_s * 1000 <= 9_223_372_036_854_775_807
    end
  end

  # ------------------------------------------------------------ 2. invitations

  describe "invitations" do
    test "invite and accept" do
      active = at("active")

      {invited, [write], response} =
        apply_ok(active, prep(active, invite("i-1", invitee: "bob"), data("invite")))

      assert write.field == "invitations"

      assert write.value ==
               {:list,
                [
                  {:record,
                   [
                     {"code_digest", {:bytes, @digest}},
                     {"expires_at", @now + 100},
                     {"id", {:text, "i-1"}},
                     {"invitee", {:text, "bob"}},
                     {"issued_by", {:text, @admin}},
                     {"role", {:text, "member"}},
                     {"space", {:text, "space-1"}}
                   ]}
                ]}

      assert response ==
               {:record, [{"lifecycle", {:text, "active"}}, {"pending", 1}, {"revision", 3}]}

      {accepted, [write], membership} =
        apply_ok(invited, prep(invited, accept("i-1"), data("accept", @now + 5), "bob"))

      assert write == %{target: @resource, field: "invitations", value: {:list, []}}

      assert membership ==
               {:record,
                [
                  {"principal", {:text, "bob"}},
                  {"revoked_at", nil},
                  {"role", {:text, "member"}},
                  {"space", {:text, "space-1"}},
                  {"valid_from", @now + 5},
                  {"valid_to", nil}
                ]}

      assert invitations(accepted) == []

      assert refused?(
               accepted,
               accept("i-1"),
               "unknown_invitation",
               data("accept", @now + 5),
               "bob"
             )
    end

    test "an open invitation is accepted by any actor; invitations stay sorted by ID" do
      snap =
        Enum.reduce(["i-c", "i-a", "i-b"], at("active"), fn id, s -> step(s, invite(id)) end)

      assert invitations(snap) == ["i-a", "i-b", "i-c"]
      after_accept = step(snap, accept("i-b"), data("accept"), "carol")
      assert invitations(after_accept) == ["i-a", "i-c"]
    end

    test "accept refusals in their order, and a refused accept writes nothing" do
      snap = step(at("active"), invite("i-1", invitee: "bob", expires_at: @now + 10))
      bad = data("accept", @now, [{"presented_digest", {:bytes, @other_digest}}])
      bad_late = data("accept", @now + 10, [{"presented_digest", {:bytes, @other_digest}}])

      assert refused?(snap, accept("i-2"), "unknown_invitation", bad_late, "eve")
      # An expired invitation with a bad code is expired.
      assert refused?(snap, accept("i-1"), "expired", bad_late, "eve")
      # A bad code for another invitee is bad_code.
      assert refused?(snap, accept("i-1"), "bad_code", bad, "eve")
      assert refused?(snap, accept("i-1"), "wrong_invitee", data("accept"), "eve")
      assert {:ok, _, _} = prep(snap, accept("i-1"), data("accept"), "bob")
      assert invitations(snap) == ["i-1"]
    end

    test "expires_at == now is expired and expires_at == now + 1 passes" do
      snap = step(at("active"), invite("edge", expires_at: @now + 1))
      assert refused?(snap, accept("edge"), "expired", data("accept", @now + 1))
      assert {:ok, _, _} = prep(snap, accept("edge"), data("accept", @now))

      # An invitation must expire after now.
      assert invalid?(at("active"), invite("past", expires_at: @now))
      assert {:ok, _, _} = prep(at("active"), invite("next", expires_at: @now + 1), data("invite"))
    end

    test "duplicate, too_many at the 33rd and not_permitted" do
      ids = Enum.map(1..32, &"i-#{String.pad_leading(Integer.to_string(&1), 2, "0")}")
      full = Enum.reduce(Enum.shuffle(ids), at("active"), &step(&2, invite(&1)))
      assert invitations(full) == ids
      assert refused?(full, invite("i-33"), "too_many")
      assert refused?(full, invite("i-01"), "duplicate")
      assert refused?(step(at("active"), invite("x")), invite("x"), "duplicate")

      for key <- ["known_target", "inviter_may_grant"], value <- [false, nil, 1, {:text, "true"}] do
        assert refused?(full, invite("i-01"), "not_permitted", data("invite", @now, [{key, value}]))
      end
    end

    test "close removes every pending invitation" do
      active = Enum.reduce(["a", "b", "c"], at("active"), &step(&2, invite(&1)))
      {closing, writes, response} = apply_ok(active, prep(active, op("close"), data("close")))
      assert length(writes) == 3
      assert invitations(closing) == []
      assert {:record, [_, {"pending", 0}, _]} = response

      suspended = step(active, op("suspend"))
      assert invitations(step(suspended, op("close"))) == []
    end

    test "revoke then accept is unknown_invitation; revoke works outside active" do
      snap = step(at("active"), invite("i-1"))
      revoked = step(snap, revoke("i-1"))
      assert invitations(revoked) == []
      assert refused?(revoked, accept("i-1"), "unknown_invitation")
      assert refused?(revoked, revoke("i-1"), "unknown_invitation")

      suspended = step(step(snap, invite("i-2")), op("suspend"))
      assert invitations(step(suspended, revoke("i-2"))) == ["i-1"]
    end

    test "the code appears in no request, write or response" do
      snap = at("active")
      invite_request = request(invite("i-1"), snap.revision)
      invite_result = TenantLifecycle.prepare(snap, invite_request, facts(data("invite")))
      {invited, _, _} = apply_ok(snap, invite_result)

      accept_request = request(accept("i-1"), invited.revision)
      accept_result = TenantLifecycle.prepare(invited, accept_request, facts(data("accept"), "bob"))

      for term <- [invite_request, invite_result, invited, accept_request, accept_result] do
        assert :binary.match(:erlang.term_to_binary(term), @code) == :nomatch
      end

      assert :binary.match(:erlang.term_to_binary(invited), @digest) != :nomatch
    end
  end

  # ------------------------------------------------------------ 4. shape

  describe "shape" do
    test "payload keys and types" do
      active = step(at("active"), invite("i-1"))

      bad = [
        %{},
        %{"op" => "unknown"},
        %{"op" => 1},
        Map.put(op("provision"), "id", "x"),
        Map.delete(invite("i"), "invitee"),
        Map.put(invite("i"), "extra", 1),
        Map.put(invite("i"), "expires_at", "2000"),
        Map.put(invite("i"), "expires_at", 2000.0),
        Map.put(invite("i"), "invitee", 7),
        Map.put(invite("i"), "space", nil),
        %{"op" => "accept"},
        %{"op" => "accept", "id" => 1},
        Map.put(accept("i-1"), "code", "x"),
        %{"op" => "revoke", "id" => nil}
      ]

      for payload <- bad do
        o =
          if is_binary(payload["op"]) and payload["op"] != "unknown",
            do: payload["op"],
            else: "activate"

        assert invalid?(active, payload, data(o)), inspect(payload)
      end

      assert invalid?(active, :payload, data("activate"))

      assert TenantLifecycle.prepare(
               active,
               %{request(op("suspend"), 3) | resource: "other"},
               facts(data("suspend"))
             ) ==
               {:refused, "invalid_request"}

      assert TenantLifecycle.prepare(
               active,
               Map.put(request(op("suspend"), 3), :x, 1),
               facts(data("suspend"))
             ) ==
               {:refused, "invalid_request"}
    end

    test "texts follow the domain/principal rule" do
      ok = ["a", String.duplicate("é", 64)]
      bad = ["", String.duplicate("a", 129), <<0xFF>>, "a\0b", "a\x7Fb", "a\u0085b", 5]
      assert byte_size(Enum.at(ok, 1)) == 128

      for text <- ok do
        assert {:ok, _, _} =
                 prep(
                   at("active"),
                   invite(text, space: text, role: text, invitee: text),
                   data("invite"),
                   text
                 )
      end

      for text <- bad do
        for payload <- [
              invite(text),
              invite("i", space: text),
              invite("i", role: text),
              invite("i", invitee: text)
            ] do
          assert invalid?(at("active"), payload), inspect({text, payload})
        end

        assert invalid?(at("active"), accept(text))
        assert invalid?(at("active"), revoke(text))
        assert invalid?(at("active"), invite("i"), data("invite"), text)
      end
    end

    test "facts are the exact record of each command" do
      snap = at("active")

      for o <- @lifecycle_ops ++ ["invite", "accept", "revoke"] do
        {:record, pairs} = data(o)

        payload =
          if o in @lifecycle_ops,
            do: op(o),
            else: %{"invite" => invite("i"), "accept" => accept("i"), "revoke" => revoke("i")}[o]

        assert invalid?(snap, payload, {:record, [{"extra", 1} | pairs]})
        assert invalid?(snap, payload, {:record, tl(Enum.sort(pairs))})
        assert invalid?(snap, payload, {:record, [{"now", @now} | pairs]})
        assert invalid?(snap, payload, {:list, pairs})
        if length(pairs) > 1, do: assert(invalid?(snap, payload, {:record, Enum.reverse(pairs)}))
      end

      assert TenantLifecycle.prepare(snap, request(op("suspend"), snap.revision), %{
               facts(data("suspend"))
               | tenant: "tenant-b"
             }) ==
               {:refused, "invalid_request"}

      assert TenantLifecycle.prepare(
               snap,
               request(op("suspend"), snap.revision),
               Map.put(facts(data("suspend")), :x, 1)
             ) ==
               {:refused, "invalid_request"}
    end

    test "digests are exactly 32 bytes and times are 0..#{@max_s}" do
      snap = step(at("active"), invite("i-1"))

      for bytes <- [:binary.copy(<<1>>, 31), :binary.copy(<<1>>, 33)],
          value <- [{:bytes, bytes}, {:text, @digest}] do
        assert invalid?(at("active"), invite("i"), data("invite", @now, [{"code_digest", value}]))
        assert invalid?(snap, accept("i-1"), data("accept", @now, [{"presented_digest", value}]))
      end

      for now <- [-1, @max_s + 1, 1.0, {:text, "1"}] do
        assert invalid?(at("active"), op("suspend"), data("suspend", now))
      end

      assert {:ok, _, _} = prep(snapshot(), op("provision"), data("provision", 0))
      assert invalid?(at("active"), invite("i", expires_at: @max_s + 1))
      assert invalid?(at("active"), invite("i", expires_at: -1), data("invite", 0))
      assert {:ok, _, _} = prep(at("active"), invite("i", expires_at: @max_s), data("invite"))
    end

    test "malformed stored fields" do
      snap = Enum.reduce(["a", "b"], at("active"), &step(&2, invite(&1)))
      {:list, [a, b]} = snap.fields["invitations"]
      {:record, a_fields} = a

      broken = fn fields -> %{snap | fields: Map.merge(snap.fields, fields)} end

      malformed_invitations = [
        {:list, [b, a]},
        {:list, [a, a]},
        {:list,
         for(
           n <- 1..33,
           do:
             {:record,
              List.keyreplace(
                a_fields,
                "id",
                0,
                {"id", {:text, "i-" <> String.pad_leading(Integer.to_string(n), 2, "0")}}
              )}
         )},
        {:list, [a | b]},
        {:list,
         [{:record, List.keyreplace(a_fields, "code_digest", 0, {"code_digest", {:bytes, "x"}})}]},
        {:list, [{:record, List.keyreplace(a_fields, "invitee", 0, {"invitee", {:text, ""}})}]},
        {:list, [{:record, List.keyreplace(a_fields, "expires_at", 0, {"expires_at", -1})}]},
        {:list, [{:record, tl(a_fields)}]},
        {:list, [{:record, [{"x", 1} | a_fields]}]},
        {:record, []},
        nil
      ]

      for value <- malformed_invitations do
        for {payload, d} <- [{op("suspend"), nil}, {revoke("a"), nil}, {accept("a"), nil}] do
          assert invalid?(broken.(%{"invitations" => value}), payload, d), inspect(value)
        end
      end

      for value <- [{:text, "unknown"}, {:text, "none"}, {:text, "Active"}, "active", nil] do
        assert invalid?(broken.(%{"lifecycle" => value}), op("suspend"))
      end

      for value <- [{:list, [incident(), incident()]}, {:list, [:x]}, {:text, "x"}] do
        assert invalid?(broken.(%{"switches" => value}), invite("c"))
      end

      for s <- [
            %{snap | tenant: ""},
            %{snap | resource: "a\0"},
            %{snap | revision: -1},
            Map.put(snap, :x, 1),
            %{snap | fields: [{"lifecycle", {:text, "active"}}]}
          ] do
        assert TenantLifecycle.prepare(s, request(op("suspend"), 0), facts(data("suspend"))) ==
                 {:refused, "invalid_request"}
      end
    end

    test "status/1 over resource/3 results" do
      assert TenantLifecycle.status({:ok, snapshot()}) == {:ok, "none"}
      assert TenantLifecycle.status({:ok, at("suspended")}) == {:ok, "suspended"}

      for read <- [
            :not_found,
            {:unknown, :storage},
            {:refused, :invalid_request},
            {:ok, snapshot(%{"lifecycle" => {:text, "gone"}})},
            {:ok, snapshot(%{"lifecycle" => "active"})},
            {:ok, Map.put(snapshot(), :x, 1)},
            {:ok, %{snapshot() | fields: []}},
            nil
          ] do
        assert TenantLifecycle.status(read) == {:error, :unavailable}
      end
    end
  end

  # ------------------------------------------------------------ 3. composition

  @hash :binary.copy(<<7>>, 32)
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @tl_port %{
    "id" => "tenant-lifecycle",
    "direction" => "input",
    "schema_id" => "tenant_lifecycle/command",
    "schema_version" => 1
  }
  @ks_port %{
    "id" => "kill-switch",
    "direction" => "input",
    "schema_id" => "kill_switch/change",
    "schema_version" => 1
  }
  @tl_schema %{
    "type" => "object",
    "required" => ["op"],
    "additionalProperties" => false,
    "properties" => %{
      "op" => %{"enum" => ~w(provision activate suspend close erase invite accept revoke)},
      "id" => %{"type" => "string"},
      "space" => %{"type" => "string"},
      "role" => %{"type" => "string"},
      "invitee" => %{"type" => ["string", "null"]},
      "expires_at" => %{"type" => "integer"}
    }
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
            requirement: %{name: "lifecycle_review", version: 1, scope: :once}
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

  defp scope(actor), do: %{tenant: @tenant, actor: actor, resources: [@resource]}

  # The host builds the lifecycle descriptor over the read it took immediately
  # before each command, so the gate sees the current switches.
  defp tl_handle(store, read) do
    {:ok, schema} = PayloadSchema.build(@tl_port, @tl_schema)

    {:ok, handle} =
      CheckedCommand.new(store, %{
        id: "tenant-lifecycle/command",
        version: 1,
        content_hash: @hash,
        effect_class: "tenant_lifecycle",
        port: @tl_port,
        schema: schema,
        prepare: &TenantLifecycle.prepare/3,
        gate: TenantLifecycle.gate(read),
        approval: %{verifiers: ["command-reviewer"], max_age: 60_000},
        outbox: "notify"
      })

    handle
  end

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
        approval: %{verifiers: ["command-reviewer"], max_age: 60_000}
      })

    handle
  end

  defp read(store),
    do: CheckedCommand.resource(tl_handle(store, :not_found), scope(@admin), @resource)

  # The host takes a fresh read, gives the actor exact-value authority for the
  # writes this command produces over it, and executes.
  defp command(store, operation_id, payload, data, opts) do
    {handle, context, request} = plan(store, operation_id, payload, data, opts)
    {handle, context, request, CheckedCommand.execute(handle, context, request)}
  end

  defp plan(store, operation_id, payload, data, opts) do
    actor = Keyword.get(opts, :actor, @admin)
    {:ok, snap} = read = read(store)
    request = request(payload, snap.revision, operation_id)

    own =
      case TenantLifecycle.prepare(snap, request, facts(data, actor)) do
        {:ok, writes, _} -> writes
        {:refused, _} -> []
      end

    context = %{
      tenant: @tenant,
      actor: actor,
      policy: policy("tenant_lifecycle", Keyword.get(opts, :verdict, :allow)),
      own: own,
      parent: :none,
      facts: data
    }

    {tl_handle(store, read), context, request}
  end

  defp run(store, operation_id, payload, data, opts \\ []),
    do: elem(command(store, operation_id, payload, data, opts), 3)

  defp engage_incident(store) do
    ks = ks_handle(store)
    {:ok, snap} = CheckedCommand.resource(ks, scope(@admin), @resource)
    payload = %{"op" => "engage", "kind" => "tenant", "id" => @tenant, "reason" => "incident"}
    request = request(payload, snap.revision, "incident-1")
    data = {:record, [{"now", 5}]}
    {:ok, own, _} = KillSwitch.prepare(snap, request, facts(data))

    context = %{
      tenant: @tenant,
      actor: @admin,
      policy: policy("kill_switch", :allow),
      own: own,
      parent: :none,
      facts: data
    }

    assert {:completed, _} = CheckedCommand.execute(ks, context, request)
  end

  defp active_store do
    store = memory_store()

    assert {:completed, %{revision: 1}} =
             run(store, "provision", op("provision"), data("provision"))

    assert {:completed, %{revision: 2}} = run(store, "activate", op("activate"), data("activate"))
    store
  end

  describe "composition on the Memory Store" do
    test "provision, activate, invite and accept commit; replay; one use" do
      store = active_store()
      assert TenantLifecycle.status(read(store)) == {:ok, "active"}
      assert KillSwitch.check(read(store), target()) == :allow

      assert {:completed, %{revision: 3}} =
               run(store, "invite-1", invite("i-1", invitee: "bob"), data("invite"))

      {handle, context, request, accepted} =
        command(store, "accept-1", accept("i-1"), data("accept", @now + 1), actor: "bob")

      assert {:completed, %{revision: 4, response: membership}} = accepted

      assert {:record, fields} = membership

      assert Enum.map(fields, &elem(&1, 0)) ==
               ~w(principal revoked_at role space valid_from valid_to)

      # Replay of the accept operation returns its first result.
      assert CheckedCommand.execute(handle, context, request) == accepted

      assert CheckedCommand.result(
               handle,
               %{tenant: @tenant, actor: "bob"},
               {@tenant, "bob", "accept-1"}
             ) ==
               accepted

      # A second accept with a new operation ID at the new revision.
      assert {:conflict, {:domain, "unknown_invitation"}} =
               run(store, "accept-2", accept("i-1"), data("accept", @now + 1), actor: "bob")

      assert {:ok, %{revision: 4}} = read(store)

      # The membership response is a domain/membership fact once decoded.
      decoded =
        Map.new(fields, fn
          {name, {:text, t}} -> {String.to_existing_atom(name), t}
          {name, v} -> {String.to_existing_atom(name), v}
        end)

      assert decoded == %{
               principal: "bob",
               space: "space-1",
               role: "member",
               valid_from: @now + 1,
               valid_to: nil,
               revoked_at: nil
             }

      {:ok, bob} =
        Principal.new(%{
          kind: :human,
          id: "bob",
          tenant: @tenant,
          auth_epoch: 0,
          allowed_scopes: [],
          allowed_spaces: []
        })

      membership_facts = %{
        spaces: [%{id: "space-1", tenant: @tenant, parent: nil, block_inheritance: false}],
        roles: [%{id: "member", permissions: ["docs.read"]}],
        memberships: [decoded],
        non_inheriting: []
      }

      assert Membership.permissions(bob, "space-1", membership_facts, @now + 1) ==
               {:ok, ["docs.read"]}

      assert Membership.permissions(bob, "space-1", membership_facts, @now) == {:ok, []}
    end

    test "two accepts prepared at one revision commit at most once" do
      store = active_store()
      assert {:completed, %{revision: 3}} = run(store, "invite-1", invite("i-1"), data("invite"))

      # Both are read, authorized and prepared at revision 3 before either executes.
      {h1, c1, r1} = plan(store, "accept-a", accept("i-1"), data("accept"), actor: "bob")
      {h2, c2, r2} = plan(store, "accept-b", accept("i-1"), data("accept"), actor: "carol")
      assert r1.expected_revision == 3 and r2.expected_revision == 3
      assert c1.own == c2.own and c1.own != []

      first = CheckedCommand.execute(h1, c1, r1)
      second = CheckedCommand.execute(h2, c2, r2)

      assert {:completed, %{revision: 4, response: {:record, _}}} = first
      assert second == {:conflict, :stale_revision}

      assert CheckedCommand.result(
               h2,
               %{tenant: @tenant, actor: "carol"},
               {@tenant, "carol", "accept-b"}
             ) == second

      results = [
        CheckedCommand.result(h1, %{tenant: @tenant, actor: "bob"}, {@tenant, "bob", "accept-a"}),
        CheckedCommand.result(
          h2,
          %{tenant: @tenant, actor: "carol"},
          {@tenant, "carol", "accept-b"}
        )
      ]

      assert Enum.count(
               results,
               &match?({:completed, %{response: {:record, [{"principal", _} | _]}}}, &1)
             ) == 1

      assert {:ok, %{revision: 4, fields: %{"invitations" => {:list, []}}}} = read(store)
    end

    test "a digest mismatch commits nothing and the invitation stays pending" do
      store = active_store()
      assert {:completed, _} = run(store, "invite-1", invite("i-1"), data("invite"))

      assert {:conflict, {:domain, "bad_code"}} =
               run(
                 store,
                 "accept-bad",
                 accept("i-1"),
                 data("accept", @now, [{"presented_digest", {:bytes, @other_digest}}]),
                 actor: "bob"
               )

      assert {:ok, %{revision: 3} = snap} = read(store)
      assert invitations(snap) == ["i-1"]

      assert {:completed, %{revision: 4}} =
               run(store, "accept-good", accept("i-1"), data("accept"), actor: "bob")
    end

    test "ASK for suspend mutates nothing until a distinct reviewer releases it" do
      store = active_store()

      {handle, context, _request, pending} =
        command(store, "suspend-1", op("suspend"), data("suspend"), verdict: :ask)

      assert {:approval_pending, %{key: key}} = pending
      assert {:ok, %{revision: 2} = unchanged} = read(store)
      assert TenantLifecycle.status({:ok, unchanged}) == {:ok, "active"}

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

      release = fn reviewer ->
        Map.merge(context, %{
          approver: %{identity: reviewer, authority: context.own},
          now: 150,
          revoked: []
        })
      end

      identity = {@tenant, @admin, "suspend-1"}

      assert CheckedCommand.release(handle, release.(@admin), identity, evidence.(@admin, "e-1")) ==
               {:release_refused, :evidence}

      assert read(store) == {:ok, unchanged}

      assert {:completed, %{revision: 3}} =
               CheckedCommand.release(
                 handle,
                 release.("reviewer-1"),
                 identity,
                 evidence.("reviewer-1", "e-1")
               )

      assert TenantLifecycle.status(read(store)) == {:ok, "suspended"}
      assert KillSwitch.check(read(store), target()) == {:deny, "tenant_suspended"}
    end

    test "the lifecycle gate lets activate through a suspended tenant" do
      store = active_store()
      assert {:completed, %{revision: 3}} = run(store, "invite-1", invite("i-1"), data("invite"))
      assert {:completed, %{revision: 4}} = run(store, "suspend-1", op("suspend"), data("suspend"))
      assert KillSwitch.check(read(store), target()) == {:deny, "tenant_suspended"}

      # revoke is refused by the gate while the lifecycle switch is engaged.
      assert run(store, "revoke-1", revoke("i-1"), data("revoke")) ==
               {:denied, {:gate, "tenant_suspended"}}

      assert {:completed, %{revision: 5}} =
               run(store, "activate-2", op("activate"), data("activate"))

      assert KillSwitch.check(read(store), target()) == :allow
      assert TenantLifecycle.status(read(store)) == {:ok, "active"}
    end

    test "an incident switch on an active tenant refuses invite, accept and revoke at the gate" do
      store = active_store()

      assert {:completed, %{revision: 3}} =
               run(store, "invite-1", invite("i-1", invitee: "bob"), data("invite"))

      engage_incident(store)
      assert {:ok, %{revision: 4}} = read(store)
      assert TenantLifecycle.status(read(store)) == {:ok, "active"}

      denied = {:denied, {:gate, "tenant_suspended"}}
      assert run(store, "accept-1", accept("i-1"), data("accept"), actor: "bob") == denied
      assert run(store, "invite-2", invite("i-2"), data("invite")) == denied
      assert run(store, "revoke-1", revoke("i-1"), data("revoke")) == denied

      assert {:ok, %{revision: 4} = snap} = read(store)
      assert invitations(snap) == ["i-1"]

      # activate does not release the incident switch; close still removes invitations.
      assert {:conflict, {:domain, "invalid_transition"}} =
               run(store, "activate-x", op("activate"), data("activate"))

      assert {:completed, %{revision: 5}} = run(store, "close-1", op("close"), data("close"))
      assert {:ok, %{fields: %{"invitations" => {:list, []}}}} = read(store)
    end

    test "the gate over PatternStep frames: lifecycle ops skip check/2, others call it" do
      suspended = {:ok, at("suspended")}
      ctx = %{proposer: @admin, effect_class: "tenant_lifecycle", tenant: @tenant}

      frame = fn payload ->
        action = %{
          "id" => "a-1",
          "kind" => "local_work",
          "schema_id" => "tenant_lifecycle/command",
          "schema_version" => 1,
          "payload" => payload
        }

        {:ok, checked} =
          Elzoo.PatternStep.decode(%{"type" => "request", "version" => 1, "actions" => [action]}, 1)

        checked
      end

      for o <- @lifecycle_ops do
        assert TenantLifecycle.gate(suspended).call.(frame.(op(o)), ctx) == :allow
        assert TenantLifecycle.gate(:not_found).call.(frame.(op(o)), ctx) == :allow
      end

      for payload <- [invite("i"), accept("i"), revoke("i"), %{"op" => "other"}, %{}] do
        assert TenantLifecycle.gate(suspended).call.(frame.(payload), ctx) ==
                 {:deny, "tenant_suspended"}

        assert TenantLifecycle.gate({:ok, at("active")}).call.(frame.(payload), ctx) == :allow

        assert TenantLifecycle.gate(:not_found).call.(frame.(payload), ctx) ==
                 {:deny, "kill_switch_unavailable"}
      end
    end
  end

  # ------------------------------------------------------------ Cure and example

  test "selected Cure laws, a clean audit and the checked example" do
    source = File.read!(Path.expand("../../cure/elzoo/tenant_lifecycle.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    {result, _} = Code.eval_file(Path.expand("../../examples/tenant_lifecycle.exs", __DIR__))

    assert result == [
             {:ok, "provisioned"},
             {:deny, "tenant_suspended"},
             {:ok, "active"},
             :allow,
             {:record,
              [
                {"principal", {:text, "bob"}},
                {"revoked_at", nil},
                {"role", {:text, "member"}},
                {"space", {:text, "space-1"}},
                {"valid_from", 1_700_000_100},
                {"valid_to", nil}
              ]},
             {:refused, "unknown_invitation"}
           ]
  end
end
