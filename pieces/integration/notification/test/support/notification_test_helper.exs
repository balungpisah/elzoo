# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.NotificationTest.SmtpServer do
  @moduledoc """
  In-process SMTP test server: gen_smtp's own `gen_smtp_server` on loopback,
  on an ephemeral port, with a scripted callback. Every session reports what
  it saw to the test process. Its own Logger level is :none, so log captures
  observe only the client side.
  """
  @behaviour :gen_smtp_server_session

  def start(mode, opts \\ []) do
    name = {__MODULE__, make_ref()}
    tls = Keyword.get(opts, :tls)

    session =
      [callbackoptions: [mode: mode, parent: self(), tls: tls != nil]] ++
        if(tls, do: [tls_options: tls], else: [])

    {:ok, _} =
      :gen_smtp_server.start(name, __MODULE__,
        port: 0,
        address: {127, 0, 0, 1},
        sessionoptions: session
      )

    {name, :ranch.get_port(name)}
  end

  def stop({name, _}), do: :gen_smtp_server.stop(name)

  @impl true
  def init(_host, _count, _peer, opts) do
    Logger.put_process_level(self(), :none)
    s = Map.new(opts)
    send(s.parent, {:smtp, :connect})

    case s.mode do
      :busy -> {:stop, :normal, "421 busy, try later"}
      _ -> {:ok, "elzoo test ESMTP", s}
    end
  end

  @impl true
  def handle_HELO(_, s), do: {:ok, 655_360, s}

  @impl true
  def handle_EHLO(_, ext, s) do
    auth = if s.mode == :no_auth, do: [], else: [{~c"AUTH", ~c"PLAIN LOGIN"}]
    tls = if s.tls, do: [{~c"STARTTLS", true}], else: []
    {:ok, ext ++ auth ++ tls, s}
  end

  @impl true
  def handle_AUTH(_type, user, password, s) do
    send(s.parent, {:smtp, {:auth, user, password}})
    if s.mode == :auth_fail, do: :error, else: {:ok, s}
  end

  @impl true
  def handle_MAIL(from, s),
    do:
      (
        send(s.parent, {:smtp, {:mail, from}})
        {:ok, s}
      )

  @impl true
  def handle_MAIL_extension(_, s), do: {:ok, s}

  @impl true
  def handle_RCPT(to, s) do
    send(s.parent, {:smtp, {:rcpt, to}})

    case s.mode do
      :reject_rcpt -> {:error, ~c"550 5.1.1 <" ++ String.to_charlist(to) ++ ~c"> no such user", s}
      :throttle_rcpt -> {:error, ~c"451 4.7.1 try again later", s}
      _ -> {:ok, s}
    end
  end

  @impl true
  def handle_RCPT_extension(_, s), do: {:ok, s}

  @impl true
  def handle_DATA(_from, _to, data, s) do
    send(s.parent, {:smtp, {:data, data}})

    case s.mode do
      # The message has been handed over; the connection drops before the reply.
      :drop_after_data ->
        exit(:kill)

      :stall_after_data ->
        Process.sleep(:infinity)
        {:ok, ~c"never", s}

      :too_big ->
        {:error, ~c"552 5.3.4 message too big", s}

      :data_554 ->
        {:error, ~c"554 5.7.1 rejected", s}

      _ ->
        {:ok, ~c"2.0.0 Ok: queued as ELZOO-TEST-1", s}
    end
  end

  @impl true
  def handle_RSET(s), do: s
  @impl true
  def handle_VRFY(_, s), do: {:error, ~c"252 no", s}
  @impl true
  def handle_other(_, _, s), do: {~c"500 no", s}
  @impl true
  def handle_STARTTLS(s),
    do:
      (
        send(s.parent, {:smtp, :starttls})
        s
      )

  @impl true
  def code_change(_, s, _), do: {:ok, s}
  @impl true
  def terminate(reason, s), do: {:ok, reason, s}

  @doc "Run-time test PKI for `host` (RSA, SAN dNSName); no key files in the repository."
  def pki(host) do
    san = [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}, extensions: san]
        },
        client_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}]
        }
      })

    %{
      server: Keyword.take(data.server_config, [:cert, :key]),
      cacerts: data.client_config[:cacerts]
    }
  end

  @doc "Defines a binding module for the server's ephemeral port at run time."
  def binding(relay, port, sender \\ "app@example.test") do
    module =
      Module.concat(
        Elzoo.NotificationTest.Binding,
        "P#{port}#{:erlang.unique_integer([:positive])}"
      )

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Elzoo.Notification.Binding,
            id: "notification-test",
            relay: unquote(relay),
            port: unquote(port),
            sender: unquote(sender),
            recovery_grace_ms: 60_000
        end
      end
    )

    module
  end
end
