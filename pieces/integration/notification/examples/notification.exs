# SPDX-License-Identifier: Apache-2.0
# Construction and admission only: no SMTP session is opened and no mail is sent.
# A host then starts Elzoo.EffectIntent with the admission parts and
# `adapter_context: config`, and dispatches through the owner.
defmodule Elzoo.Notification.ExampleBinding do
  use Elzoo.Notification.Binding,
    id: "invitation-email",
    relay: "smtp.example.test",
    port: 587,
    sender: "noreply@example.test",
    recovery_grace_ms: 60_000
end

{:ok, transport} = Task.Supervisor.start_link()

{:ok, config} =
  Elzoo.Notification.configure(
    binding: Elzoo.Notification.ExampleBinding,
    tenant: "tenant-a",
    # The credential Need: the host's secret source, called only inside the transport.
    credentials: fn -> {:error, :unavailable} end,
    transport_supervisor: transport,
    tls: {:verified, :system}
  )

payload =
  Jason.encode!(%{
    "version" => 1,
    "to" => ["invitee@example.test"],
    "subject" => "You are invited",
    "text" => "Join the workspace.",
    "html" => nil
  })

declaration = %{
  "capability_id" => "integration/notification",
  "operation" => "email",
  "classification" => "untrusted",
  "command" => %{
    "version" => 1,
    "message_id" => "message-1",
    "schema_id" => "elzoo/notification-email",
    "schema_version" => 1,
    "kind" => "command",
    "producer" => %{"unit_id" => "membership", "port_id" => "invite"},
    "idempotency_key" => "invitation-42",
    "deadline_unix_ms" => 1_900_000_000_000,
    "payload" => payload
  }
}

{:ok, admission} = Elzoo.Notification.admission(config, declaration)
true = byte_size(admission.key) == 64
true = admission.arguments == payload
{:ok, {:refused, :connect_failed}} = Elzoo.Notification.outcome(:connect_failed)
{:ok, {:unknown, :connection_lost}} = Elzoo.Notification.outcome(:connection_lost)
false = inspect(config) =~ "invitee"
Supervisor.stop(transport)
