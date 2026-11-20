# SPDX-License-Identifier: Apache-2.0
# Provision and activate a tenant, invite a person and accept the invitation
# with the pure preparer, reading the state and the kill switch after each
# step. A real host commits each write through Elzoo.CheckedCommand with a
# descriptor whose gate is Elzoo.TenantLifecycle.gate/1 over a fresh read, and
# reads the resource back with CheckedCommand.resource/3.
defmodule TenantLifecycleExample do
  alias Elzoo.{KillSwitch, TenantLifecycle}

  @tenant "tenant-1"

  def run do
    # The host makes a random code of at least 128 bits, sends it out of band
    # and keeps only its SHA-256 in the command facts.
    code = :crypto.strong_rand_bytes(16)
    digest = :crypto.hash(:sha256, code)
    target = %{tenant: @tenant, recipe: nil, tool: nil}

    empty = %{tenant: @tenant, resource: "control", revision: 0, fields: %{}}
    {provisioned, _} = step(empty, %{"op" => "provision"}, [{"now", 1_700_000_000}])
    {active, _} = step(provisioned, %{"op" => "activate"}, [{"now", 1_700_000_010}])

    invite = %{
      "op" => "invite",
      "id" => "inv-1",
      "space" => "space-1",
      "role" => "member",
      "invitee" => "bob",
      "expires_at" => 1_700_086_400
    }

    {invited, _} =
      step(active, invite, [
        {"code_digest", {:bytes, digest}},
        {"inviter_may_grant", true},
        {"known_target", true},
        {"now", 1_700_000_020}
      ])

    # Bob presents the code; the host hashes it into the accept facts.
    presented = [
      {"now", 1_700_000_100},
      {"presented_digest", {:bytes, :crypto.hash(:sha256, code)}}
    ]

    {accepted, membership} = step(invited, %{"op" => "accept", "id" => "inv-1"}, presented, "bob")

    [
      TenantLifecycle.status({:ok, provisioned}),
      KillSwitch.check({:ok, provisioned}, target),
      TenantLifecycle.status({:ok, active}),
      KillSwitch.check({:ok, active}, target),
      membership,
      TenantLifecycle.prepare(
        accepted,
        request(accepted, %{"op" => "accept", "id" => "inv-1"}),
        facts(presented, "bob")
      )
    ]
  end

  defp step(snapshot, payload, data, actor \\ "admin-1") do
    {:ok, writes, response} =
      TenantLifecycle.prepare(snapshot, request(snapshot, payload), facts(data, actor))

    fields = Enum.reduce(writes, snapshot.fields, &Map.put(&2, &1.field, &1.value))
    {%{snapshot | revision: snapshot.revision + 1, fields: fields}, response}
  end

  defp request(snapshot, payload),
    do: %{
      operation_id: "op-#{snapshot.revision}",
      resource: "control",
      expected_revision: snapshot.revision,
      payload: payload
    }

  defp facts(data, actor), do: %{tenant: @tenant, actor: actor, data: {:record, data}}
end

IO.inspect(TenantLifecycleExample.run())
