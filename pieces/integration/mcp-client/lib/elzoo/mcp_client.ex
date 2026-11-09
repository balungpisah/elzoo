# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient do
  @moduledoc """
  MCP client Adapter over Streamable HTTP (ex_mcp 1.8.1), bound to the ready
  `core/effect` declaration (admission) and `delivery/effect-intent` owner
  (dispatch, settlement, recovery). Discovery is inert data; one `tools/call`
  per dispatch identity. See the README for the Contract.
  """
  alias Elzoo.McpClient.{Binding, Config, Context, Discovery, Session, Snapshot, Transport, Wire}

  @capability "integration/mcp-client"
  @max_bigint 9_223_372_036_854_775_807
  @modes [:modern_only, :legacy_only, :prefer_modern]
  @keys [
    :binding,
    :tenant,
    :credentials,
    :protocol_mode,
    :call_timeout_ms,
    :handshake_timeout_ms,
    :max_request_bytes,
    :max_response_bytes,
    :max_pages,
    :max_tools,
    :max_descriptor_bytes
  ]

  @doc """
  Builds the trusted construction Config. Options: `binding`, `tenant`,
  `credentials` (zero-arity credential Need returning `{:ok, bearer_token}`),
  optional `protocol_mode` (`:modern_only` default, `:legacy_only`,
  `:prefer_modern`), `call_timeout_ms` (1..600,000, default 30,000),
  `handshake_timeout_ms` (1..60,000, default 10,000), `max_request_bytes`
  (1..65,536, default 65,536), `max_response_bytes` (1..8 MiB, default 1 MiB),
  `max_pages` (1..64, default 8), `max_tools` (1..1,024, default 128) and
  `max_descriptor_bytes` (256..65,536, default 16,384). The credential Need is
  never called here.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @keys)),
         {:ok, _b, settings} <- Binding.load(opts[:binding]),
         true <- Wire.text?(opts[:tenant], 256),
         true <- is_function(opts[:credentials], 0),
         mode when mode in @modes <- Keyword.get(opts, :protocol_mode, :modern_only),
         {:ok, call} <- int(opts, :call_timeout_ms, 30_000, 1..600_000),
         {:ok, handshake} <- int(opts, :handshake_timeout_ms, 10_000, 1..60_000),
         {:ok, max_req} <- int(opts, :max_request_bytes, 65_536, 1..65_536),
         {:ok, max_resp} <- int(opts, :max_response_bytes, 1_048_576, 1..8_388_608),
         {:ok, pages} <- int(opts, :max_pages, 8, 1..64),
         {:ok, tools} <- int(opts, :max_tools, 128, 1..1_024),
         {:ok, descriptor} <- int(opts, :max_descriptor_bytes, 16_384, 256..65_536) do
      {:ok,
       %Config{
         binding: opts[:binding],
         settings: settings,
         tenant: opts[:tenant],
         credentials: opts[:credentials],
         protocol_mode: mode,
         call_timeout_ms: call,
         handshake_timeout_ms: handshake,
         max_request_bytes: max_req,
         max_response_bytes: max_resp,
         max_pages: pages,
         max_tools: tools,
         max_descriptor_bytes: descriptor,
         seal_key: :crypto.strong_rand_bytes(32)
       }}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp int(opts, key, default, range) do
    case Keyword.get(opts, key, default) do
      v when is_integer(v) -> if v in range, do: {:ok, v}, else: :error
      _ -> :error
    end
  end

  @doc """
  Connects under the caller's `DynamicSupervisor` (the client is `:temporary`,
  never restarted). Sends only the protocol handshake. Returns `{:ok, session}`
  or `{:error, reason}` with a finite reason (`:credentials_unavailable`,
  `:authentication_failed`, `:target_refused`, `:connect_failed`).
  """
  def connect(%Config{} = c, supervisor) do
    case Transport.start(c, supervisor) do
      {:ok, pid, ledger} -> {:ok, %Session{config: c, client: pid, ledger: ledger}}
      {:error, reason} -> {:error, reason}
    end
  end

  def connect(_, _), do: {:error, :configuration}

  @doc "Ends the connection; in-flight calls end `unknown`."
  def close(%Session{client: pid, ledger: ledger}) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    Elzoo.McpClient.Ledger.stop(ledger)
    :ok
  end

  @doc """
  Bounded, inert discovery: `{:ok, %{server, protocol_version, tools, truncated}}`
  where each descriptor is untrusted data. Never sends `tools/call`.
  """
  def list_tools(%Session{} = s, _opts \\ []), do: Discovery.list(s)

  @doc """
  Admits a `core/effect` declaration: untrusted classification, capability
  `integration/mcp-client`, operation `tools/call`, command schema
  `elzoo/mcp-tool-call` version 1, explicit `idempotency_key` (logical request
  reference) and `deadline_unix_ms`; the payload carries the tool, arguments and
  the release reference. Checks against the caller's discovery snapshot narrow
  admission only. Returns the EffectIntent start parts or a refusal; it never
  creates an intent or sends anything.
  """
  def admission(%Config{} = c, declaration, discovery) do
    with {:ok, _} <- Elzoo.Effect.validate(declaration),
         "untrusted" <- declaration["classification"],
         @capability <- declaration["capability_id"],
         "tools/call" <- declaration["operation"],
         command = declaration["command"],
         "elzoo/mcp-tool-call" <- command["schema_id"],
         1 <- command["schema_version"],
         ref when is_binary(ref) <- command["idempotency_key"],
         true <- Wire.text?(ref, 256),
         deadline when is_integer(deadline) and deadline >= 0 and deadline <= @max_bigint <-
           command["deadline_unix_ms"],
         payload when is_binary(payload) <- command["payload"],
         {:ok, b, _} <- Binding.load(c.binding),
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      with {:ok, call} <- Wire.request(payload, c.max_request_bytes),
           :ok <- Snapshot.check(discovery, call.tool, call.arguments) do
        identity = [c.tenant, b.provider_account, b.id, b.operation, ref]

        {:ok,
         %{
           key: Elzoo.EffectIntent.Model.key(identity),
           identity: identity,
           arguments: payload,
           deadline: deadline
         }}
      else
        {:error, reason} -> {:error, {:refused, reason}}
      end
    else
      _ -> {:error, :declaration}
    end
  rescue
    _ -> {:error, :declaration}
  end

  def admission(_, _, _), do: {:error, :declaration}

  @doc """
  The EffectIntent Adapter context: the session and the recipient Need (a
  trusted local process that receives each classified outcome by best-effort
  mailbox delivery).
  """
  def context(%Session{} = s, recipient) when is_pid(recipient),
    do: %Context{session: s, recipient: recipient}

  @doc """
  Dispatches an admitted call through its EffectIntent `owner`, whose Adapter
  context names the calling process as recipient, and waits for the classified
  outcome: `{:completed, %{content, is_error, structured}}`, `{:refused, reason}`
  or `{:unknown, reason}`. A completion is returned only after the owner has
  durably confirmed it; if that confirmation is not observed within a bounded
  wait the result is `{:unknown, :settlement_unconfirmed}`. A second dispatch of
  the same identity is refused by the owner (`{:error, {:intent, reason}}`). No
  outcome within the call bound plus a margin is `{:unknown, :timeout}`; the
  owner's settlement stays authoritative.
  """
  def call_tool(%Session{config: c}, %{key: key}, owner) do
    case Elzoo.EffectIntent.advance(owner, :dispatch) do
      {:ok, :dispatched} ->
        receive do
          {:elzoo_mcp_result, ^key, _attempt, {:completed, _} = outcome} ->
            if confirmed?(owner, 250), do: outcome, else: {:unknown, :settlement_unconfirmed}

          {:elzoo_mcp_result, ^key, _attempt, outcome} ->
            outcome
        after
          c.call_timeout_ms + 5_000 -> {:unknown, :timeout}
        end

      other ->
        {:error, {:intent, intent_reason(other)}}
    end
  catch
    :exit, _ -> {:error, {:intent, :owner_unavailable}}
  end

  # The Adapter's message precedes the owner's commit; wait (bounded) for the
  # owner to report the confirmed phase.
  defp confirmed?(owner, tries) do
    case Elzoo.EffectIntent.status(owner) do
      %{phase: {:Confirmed, _}} ->
        true

      _ when tries > 0 ->
        Process.sleep(20)
        confirmed?(owner, tries - 1)

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  # The owner's own refusal term is not passed through: one fixed reason.
  defp intent_reason(_), do: :refused

  @doc "Contract outcome of a failure tag (`{:ok, {:refused | :unknown, reason}}`)."
  defdelegate outcome(tag), to: Binding
end
