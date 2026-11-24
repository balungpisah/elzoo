# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpRuntime do
  @moduledoc """
  One MCP server that a tenant added at run time, turned into a ready
  `integration/mcp-client` runtime config only after three steps: the
  `integration/egress-policy` admits the URL and every resolved address is
  public; the credential releases a token once (the check before connecting):
  an `integration/secrets` reference, or the host's OAuth Need for a tenant
  OAuth connection; the client is configured with
  `Elzoo.McpClient.RuntimeBinding` and exactly the checked host, port and
  address set. The host then uses the ready client unchanged: `connect/2`,
  `admission/3`, `context/3` (the context bound to the admission) and
  `call_tool/3`. See the README for the Contract.
  """
  alias Elzoo.{EgressPolicy, McpClient, Secrets}
  alias Elzoo.McpClient.{RuntimeBinding, Session}

  @keys [:tenant, :server, :url, :policy, :resolver, :credential]
  @bounds [
    :protocol_mode,
    :call_timeout_ms,
    :handshake_timeout_ms,
    :max_request_bytes,
    :max_response_bytes,
    :max_pages,
    :max_tools,
    :max_descriptor_bytes
  ]

  # Only for configure/1's run of the ready client's own checks of the tenant,
  # the server text and the bounds; admit/1 configures with the checked URL
  # and addresses instead.
  @stand_in %{endpoint: "https://stand-in.invalid/", addresses: [{192, 0, 2, 1}]}

  defmodule Config do
    @moduledoc """
    One tenant-added server: tenant, server text, URL, egress policy and
    resolver Need, credential, its Need (`secrets` for a reference, `oauth`
    for an OAuth connection; the other is nil) and the ready client bounds.
    Inspect shows the tenant and the server text only.
    """
    @enforce_keys [
      :tenant,
      :server,
      :url,
      :policy,
      :resolver,
      :credential,
      :secrets,
      :oauth,
      :bounds
    ]
    defstruct @enforce_keys

    defimpl Inspect do
      def inspect(%{tenant: tenant, server: server}, _opts),
        do:
          "#Elzoo.McpRuntime.Config<tenant: " <>
            Kernel.inspect(tenant) <> ", server: " <> Kernel.inspect(server) <> ">"
    end
  end

  @doc """
  Builds the config from exactly `tenant`, `server`, `url`, `policy`,
  `resolver` and `credential`, plus the Need of the credential form, plus
  optional ready client bounds. `%{ref: ref, scope: scope}` takes `secrets` (a
  one-argument function from the credential request to the trusted
  `Elzoo.Secrets` context); `%{oauth: connection_id}` (1..128 bytes of
  printable UTF-8) takes `oauth` (a one-argument function given
  `%{tenant: tenant, connection_id: connection_id}` that returns
  `{:ok, token}` or `{:error, atom}`). Returns
  `{:ok, config}` or `{:error, :configuration}`; calls no Need. A URL with a
  query is `:configuration`; every other URL rule is the egress policy's, at
  `admit/1`.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.uniq(keys) == keys,
         {:ok, need} <- form(opts[:credential]),
         true <- Enum.all?([need | @keys], &(&1 in keys)),
         true <- Enum.all?(keys, &(&1 in [need | @keys] or &1 in @bounds)),
         true <- is_binary(opts[:url]) and not query?(opts[:url]),
         %EgressPolicy{hosts: %MapSet{}, ports: %MapSet{}} <- opts[:policy],
         true <- is_function(opts[:resolver], 1) and is_function(opts[need], 1),
         config = %Config{
           tenant: opts[:tenant],
           server: opts[:server],
           url: opts[:url],
           policy: opts[:policy],
           resolver: opts[:resolver],
           credential: opts[:credential],
           secrets: opts[:secrets],
           oauth: opts[:oauth],
           bounds: Keyword.take(opts, @bounds)
         },
         {:ok, _} <- client(config, @stand_in.endpoint, @stand_in.addresses) do
      {:ok, config}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  # The credential form and the key of its Need.
  defp form(%{ref: ref, scope: scope} = request)
       when map_size(request) == 2 and not is_struct(request) and is_binary(ref) and
              is_binary(scope),
       do: {:ok, :secrets}

  defp form(%{oauth: id} = request)
       when map_size(request) == 1 and not is_struct(request) and is_binary(id) and
              byte_size(id) in 1..128,
       do: if(printable?(id), do: {:ok, :oauth}, else: :error)

  defp form(_), do: :error

  # oauth-client's connection_id text: UTF-8 with no C0 or C1 control or DEL.
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  # The ready client refuses a query; URI.new/1 raises on invalid UTF-8, which
  # the egress policy then refuses as :malformed.
  defp query?(url),
    do: String.valid?(url) and match?({:ok, %URI{query: q}} when q != nil, URI.new(url))

  @doc """
  Admits the server: the egress policy first (`{:error, {:egress, reason}}`),
  then one credential check (`{:error, :credentials_expired}` or
  `{:error, :credentials_unavailable}`; an OAuth credential is
  `:credentials_unavailable` on any answer but `{:ok, binary}`), then the ready
  client runtime config
  pinned to the checked host, port and addresses (`{:ok, client_config}`, or
  `{:error, :configuration}` on a refusal). Nothing later runs after a
  refusal; no client or socket is started.
  """
  def admit(%Config{} = c) do
    # The ready client parses the same URL (URI.new/1), so its endpoint host and
    # port are the egress host and port.
    with {:ok, target} <- egress(c),
         :ok <- check(c) do
      client(c, c.url, target.addresses)
    end
  end

  def admit(_), do: {:error, :configuration}

  defp egress(c) do
    case EgressPolicy.resolve(c.url, c.policy, c.resolver) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, {:egress, reason}}
    end
  end

  defp client(c, endpoint, addresses) do
    case McpClient.configure(
           [
             binding: RuntimeBinding,
             runtime: %{
               server: c.server,
               endpoint: endpoint,
               network: :public,
               addresses: addresses
             },
             tenant: c.tenant,
             credentials: need(c)
           ] ++ c.bounds
         ) do
      {:ok, client} -> {:ok, client}
      {:error, _} -> {:error, :configuration}
    end
  end

  # The zero-arity credential Need of the ready client: resolves the reference,
  # or asks the OAuth Need, again at each request; nothing is stored.
  defp need(%Config{oauth: nil, secrets: secrets, credential: request}) do
    fn ->
      case resolve(secrets, request) do
        {:ok, credential} -> {:ok, Secrets.reveal(credential)}
        {:error, _} -> {:error, :credentials_unavailable}
      end
    end
  end

  defp need(%Config{oauth: oauth, tenant: tenant, credential: %{oauth: id}}) do
    fn ->
      case ask(oauth, tenant, id) do
        {:ok, token} -> {:ok, token}
        :error -> {:error, :credentials_unavailable}
      end
    end
  end

  # One call of the host's OAuth Need: only {:ok, binary} passes.
  defp ask(oauth, tenant, id) do
    case oauth.(%{tenant: tenant, connection_id: id}) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp resolve(secrets, request) do
    context =
      try do
        secrets.(request)
      catch
        _, _ -> :none
      end

    Secrets.resolve(request, context)
  end

  # The check before connecting or listing: one resolution, or one OAuth Need
  # call, in the calling process; the value is dropped.
  defp check(%Config{oauth: nil, secrets: secrets, credential: request}) do
    case resolve(secrets, request) do
      {:ok, _} -> :ok
      {:error, :expired} -> {:error, :credentials_expired}
      {:error, _} -> {:error, :credentials_unavailable}
    end
  end

  defp check(%Config{oauth: oauth, tenant: tenant, credential: %{oauth: id}}) do
    case ask(oauth, tenant, id) do
      {:ok, _} -> :ok
      :error -> {:error, :credentials_unavailable}
    end
  end

  @doc """
  Lists the tools of the server through a runtime session whose client config
  has this config's tenant, server text and URL, as `admit/1` gives it (any
  other session is a `FunctionClauseError`):
  `%{{tenant, server} => {:ok, listing} | {:unavailable, reason}}`. The
  credential check runs first; `listing` is the unchanged result of
  `Elzoo.McpClient.list_tools/1`.
  """
  def list_tools(
        %Config{tenant: tenant, server: server, url: url} = c,
        %Session{
          config: %McpClient.Config{
            binding: RuntimeBinding,
            tenant: tenant,
            runtime: %{server: server, endpoint: url}
          }
        } = session
      ) do
    listing =
      with :ok <- check(c),
           {:ok, listing} <- McpClient.list_tools(session) do
        {:ok, listing}
      else
        {:error, reason} -> {:unavailable, reason}
      end

    %{{tenant, server} => listing}
  end
end
