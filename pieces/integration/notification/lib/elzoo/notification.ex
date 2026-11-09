# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification do
  @moduledoc """
  Email notification Adapter over Swoosh's SMTP transport, bound to the ready
  `core/effect` declaration (admission) and `delivery/effect-intent` owner
  (dispatch, settlement, recovery). See the README for the Contract.
  """
  alias Elzoo.Notification.{Binding, Config, Wire}

  @capability "integration/notification"
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  Builds the trusted construction Config. Options: `binding`, `tenant`,
  `credentials` (zero-arity credential Need), `transport_supervisor`, `tls`
  (`{:verified, :system}`, `{:verified, {:cacerts, ders}}` or
  `:plaintext_loopback`), optional `max_request_bytes` (1..65,536, default
  65,536), `send_timeout_ms` (1..600,000, default 60,000) and `hostname`
  (EHLO name, default `"localhost"`). Verified TLS is required for every relay
  other than `127.0.0.1` and `localhost`, and a relay given as an IPv4 literal
  can only be used with `:plaintext_loopback`.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Enum.all?(
             Keyword.keys(opts),
             &(&1 in [
                 :binding,
                 :tenant,
                 :credentials,
                 :transport_supervisor,
                 :tls,
                 :max_request_bytes,
                 :send_timeout_ms,
                 :hostname
               ])
           ),
         {:ok, _b, settings} <- Binding.load(opts[:binding]),
         true <- Wire.text?(opts[:tenant], 256),
         true <- is_function(opts[:credentials], 0),
         true <- not is_nil(opts[:transport_supervisor]),
         max when is_integer(max) and max in 1..65_536 <-
           Keyword.get(opts, :max_request_bytes, 65_536),
         timeout when is_integer(timeout) and timeout in 1..600_000 <-
           Keyword.get(opts, :send_timeout_ms, 60_000),
         hostname = Keyword.get(opts, :hostname, "localhost"),
         true <- Wire.relay?(hostname) and not Wire.ipv4?(hostname),
         {:ok, tls} <- tls(opts[:tls], settings.relay) do
      {:ok,
       %Config{
         binding: opts[:binding],
         settings: settings,
         tenant: opts[:tenant],
         credentials: opts[:credentials],
         transport_supervisor: opts[:transport_supervisor],
         tls: tls,
         max_request_bytes: max,
         send_timeout_ms: timeout,
         hostname: hostname,
         seal_key: :crypto.strong_rand_bytes(32)
       }}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp tls(:plaintext_loopback, relay),
    do: if(Wire.loopback?(relay), do: {:ok, :plaintext_loopback}, else: :error)

  defp tls({:verified, trust}, relay) do
    with false <- Wire.ipv4?(relay),
         {:ok, ders} <- trust(trust) do
      {:ok, {:verified, ders}}
    else
      _ -> :error
    end
  end

  defp tls(_, _), do: :error

  defp trust(:system) do
    case :public_key.cacerts_get() do
      [_ | _] = certs -> {:ok, Enum.map(certs, &der/1)}
      _ -> :error
    end
  end

  defp trust({:cacerts, ders}) when is_list(ders) and length(ders) in 1..64 do
    if Enum.all?(
         ders,
         &(is_binary(&1) and
             match?({:Certificate, _, _, _}, :public_key.pkix_decode_cert(&1, :plain)))
       ),
       do: {:ok, ders},
       else: :error
  end

  defp trust(_), do: :error

  defp der({:cert, der, _}), do: der
  defp der(der) when is_binary(der), do: der

  @doc """
  Admits a `core/effect` declaration: untrusted classification, capability
  `integration/notification`, operation `email`, command schema
  `elzoo/notification-email` version 1, explicit `idempotency_key` (logical
  request reference) and `deadline_unix_ms`. Returns the EffectIntent start
  parts or a refusal; it never creates an intent or sends anything.
  """
  def admission(%Config{} = c, declaration) do
    with {:ok, _} <- Elzoo.Effect.validate(declaration),
         "untrusted" <- declaration["classification"],
         @capability <- declaration["capability_id"],
         "email" <- declaration["operation"],
         command = declaration["command"],
         "elzoo/notification-email" <- command["schema_id"],
         1 <- command["schema_version"],
         ref when is_binary(ref) <- command["idempotency_key"],
         true <- Wire.text?(ref, 256),
         deadline when is_integer(deadline) and deadline >= 0 and deadline <= @max_bigint <-
           command["deadline_unix_ms"],
         payload when is_binary(payload) <- command["payload"],
         {:ok, b, _} <- Binding.load(c.binding),
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      case Wire.request(payload, c.max_request_bytes) do
        {:ok, _} ->
          identity = [c.tenant, b.provider_account, b.id, b.operation, ref]

          {:ok,
           %{
             key: Elzoo.EffectIntent.Model.key(identity),
             identity: identity,
             arguments: payload,
             deadline: deadline
           }}

        {:error, reason} when reason in [:too_large, :invalid_address] ->
          {:error, {:refused, reason}}

        _ ->
          {:error, :declaration}
      end
    else
      _ -> {:error, :declaration}
    end
  rescue
    _ -> {:error, :declaration}
  end

  def admission(_, _), do: {:error, :declaration}

  @doc "Contract outcome of a failure tag (`{:ok, {:refused | :unknown, reason}}`)."
  defdelegate outcome(tag), to: Binding
end
