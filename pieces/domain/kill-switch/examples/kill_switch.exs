# SPDX-License-Identifier: Apache-2.0
# Engage and release a tool switch with the pure preparer, and check a
# resource/3-shaped read after each step. A real host commits each write
# through Elzoo.CheckedCommand and reads it back with CheckedCommand.resource/3.
defmodule KillSwitchExample do
  alias Elzoo.KillSwitch

  def run do
    empty = %{tenant: "tenant-1", resource: "control", revision: 0, fields: %{}}
    target = %{tenant: "tenant-1", recipe: "recipe-1", tool: "send_email"}

    {:ok, [write], engaged} =
      KillSwitch.prepare(empty, request(0, "engage"), facts(1_700_000_000_000))

    after_engage = %{empty | revision: 1, fields: %{write.field => write.value}}

    {:ok, [write], released} =
      KillSwitch.prepare(after_engage, request(1, "release"), facts(1_700_000_060_000))

    after_release = %{after_engage | revision: 2, fields: %{write.field => write.value}}

    [
      KillSwitch.check({:ok, empty}, target),
      engaged,
      KillSwitch.check({:ok, after_engage}, target),
      released,
      KillSwitch.check({:ok, after_release}, target),
      KillSwitch.check({:unknown, :storage}, target)
    ]
  end

  defp request(revision, op) do
    %{
      operation_id: "switch-#{revision}",
      resource: "control",
      expected_revision: revision,
      payload: %{"op" => op, "kind" => "tool", "id" => "send_email", "reason" => "incident"}
    }
  end

  defp facts(now), do: %{tenant: "tenant-1", actor: "operator", data: {:record, [{"now", now}]}}
end

IO.inspect(KillSwitchExample.run())
