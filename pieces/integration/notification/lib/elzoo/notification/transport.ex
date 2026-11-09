# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Transport do
  @moduledoc false
  # One SMTP session in its own short-lived process. The process sets its own
  # Logger level to :none (gen_smtp's MIME encoder debug-logs every header in the
  # calling process), calls the credential Need, checks its shape with guards
  # only, and calls Swoosh.Adapters.SMTP.deliver/2 directly (never a
  # Swoosh.Mailer, whose telemetry metadata would carry the email and config).
  # Everything raised, thrown or exited inside is turned into a fixed atom here.
  alias Elzoo.Notification.{Config, Wire}

  @doc false
  def run(%Config{} = c, settings, key, message) do
    task =
      Task.Supervisor.async(c.transport_supervisor, fn ->
        try do
          Logger.put_process_level(self(), :none)
          {:value, session(c, settings, key, message)}
        rescue
          _ -> :fault
        catch
          _, _ -> :fault
        end
      end)

    case Task.yield(task, c.send_timeout_ms) do
      {:ok, {:value, value}} ->
        value

      {:ok, :fault} ->
        {:MailCrashed, :MailMalformed, nil}

      {:exit, _} ->
        {:MailCrashed, :MailMalformed, nil}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:MailExpired, :MailLost, nil}
    end
  rescue
    _ -> {:MailCrashed, :MailMalformed, nil}
  catch
    _, _ -> {:MailCrashed, :MailMalformed, nil}
  end

  defp session(c, settings, key, message) do
    case credential(c.credentials) do
      {:ok, username, password} ->
        email =
          Swoosh.Email.new()
          |> Swoosh.Email.from(settings.sender)
          |> Swoosh.Email.to(message.to)
          |> Swoosh.Email.subject(message.subject)
          |> Swoosh.Email.text_body(message.text)
          |> html(message.html)
          |> Swoosh.Email.header("Message-ID", message_id(key, settings.sender))

        options =
          [
            relay: settings.relay,
            port: settings.port,
            hostname: c.hostname,
            username: username,
            password: password,
            auth: :always,
            retries: 0,
            no_mx_lookups: true,
            ssl: false
          ] ++ tls(c.tls, settings.relay)

        stage(Swoosh.Adapters.SMTP.deliver(email, options))

      :fault ->
        {:MailPre, :MailCredentialFault, nil}
    end
  end

  # The value is checked with guards and byte_size/1 only: never interpolated,
  # inspected or passed on before it passes.
  defp credential(fun) do
    case fun.() do
      {:ok, {u, p}}
      when is_binary(u) and is_binary(p) and byte_size(u) in 1..256 and byte_size(p) in 1..1024 ->
        if clean?(u) and clean?(p), do: {:ok, u, p}, else: :fault

      _ ->
        :fault
    end
  rescue
    _ -> :fault
  catch
    _, _ -> :fault
  end

  defp clean?(v), do: :binary.match(v, ["\r", "\n", <<0>>]) == :nomatch

  def message_id(key, sender), do: "<" <> key <> "@" <> Wire.domain(sender) <> ">"

  defp html(email, nil), do: email
  defp html(email, html), do: Swoosh.Email.html_body(email, html)

  defp tls(:plaintext_loopback, _relay), do: [tls: :never]

  defp tls({:verified, cacerts}, relay) do
    host = String.to_charlist(relay)

    [
      tls: :always,
      tls_options: [
        verify: :verify_peer,
        cacerts: cacerts,
        server_name_indication: host,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        versions: [:"tlsv1.2", :"tlsv1.3"],
        depth: 10
      ]
    ]
  end

  # gen_smtp 1.3.0: session failures (connect, banner, EHLO, STARTTLS, AUTH) come
  # back as retries_exceeded/no_more_hosts; transaction failures (MAIL, RCPT,
  # DATA) as send, without saying which command failed.
  @doc false
  def stage({:ok, receipt}), do: {:MailTransaction, :MailAccepted, receipt}

  def stage({:error, {:send, {type, _host, message}}}),
    do: {:MailTransaction, reply(type, message), nil}

  def stage({:error, {kind, {type, _host, message}}})
      when kind in [:retries_exceeded, :no_more_hosts],
      do: {:MailSession, reply(type, message), nil}

  # Any other shape does not establish the session/transaction split, so its
  # stage is unattested: unknown (adapter_error), never connect_failed.
  def stage(_), do: {:MailCrashed, :MailMalformed, nil}

  defp reply(:network_failure, _), do: :MailLost
  defp reply(:permanent_failure, :auth_failed), do: :MailAuthRefused
  defp reply(:missing_requirement, :auth), do: :MailAuthMissing
  defp reply(:missing_requirement, :tls), do: :MailTlsFailed
  defp reply(_, :tls_failed), do: :MailTlsFailed
  defp reply(_, :ssl_not_started), do: :MailTlsFailed

  defp reply(type, <<a, b, c, _::binary>>)
       when type in [:permanent_failure, :temporary_failure] and a in ?2..?5 and b in ?0..?9 and
              c in ?0..?9,
       do: {:MailCode, (a - ?0) * 100 + (b - ?0) * 10 + (c - ?0)}

  defp reply(_, _), do: :MailMalformed
end
