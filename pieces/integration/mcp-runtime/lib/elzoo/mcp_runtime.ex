# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpRuntime do
  @moduledoc """
  One MCP server that a tenant added at run time, turned into a ready
  `integration/mcp-client` runtime config only after three steps: the
  `integration/egress-policy` admits the URL and every resolved address is
  public; the `integration/secrets` reference releases the bearer token once
  (the check before connecting); the client is configured with
  `Elzoo.McpClient.RuntimeBinding` and exactly the checked host, port and
  address set. The host then uses the ready client unchanged: `connect/2`,
  `admission/3`, `context/3` (the context bound to the admission) and
  `call_tool/3`. See the README for the Contract.
  """
  alias Elzoo.{EgressPolicy, McpClient, Secrets}
  alias Elzoo.McpClient.{RuntimeBinding, Session}

  @keys [:tenant, :server, :url, :policy, :resolver, :credential, :secrets]
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
    resolver Need, credential reference, `secrets` function and the ready
    client bounds. Inspect shows the tenant and the server text only.
    """
    @enforce_keys [:tenant, :server, :url, :policy, :resolver, :credential, :secrets, :bounds]
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
  `resolver`, `credential` (`%{ref: ref, scope: scope}`) and `secrets` (a
  one-argument function from the credential request to the trusted
  `Elzoo.Secrets` context), plus optional ready client bounds. Returns
  `{:ok, config}` or `{:error, :configuration}`; calls no Need. A URL with a
  query is `:configuration`; every other URL rule is the egress policy's, at
  `admit/1`.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.all?(@keys, &(&1 in keys)),
         true <- Enum.all?(keys, &(&1 in @keys or &1 in @bounds)),
         true <- is_binary(opts[:url]) and not query?(opts[:url]),
         %EgressPolicy{hosts: %MapSet{}, ports: %MapSet{}} <- opts[:policy],
         true <- is_function(opts[:resolver], 1) and is_function(opts[:secrets], 1),
         %{ref: ref, scope: scope} = request when map_size(request) == 2 <- opts[:credential],
         true <- not is_struct(request) and is_binary(ref) and is_binary(scope),
         config = %Config{
           tenant: opts[:tenant],
           server: opts[:server],
           url: opts[:url],
           policy: opts[:policy],
           resolver: opts[:resolver],
           credential: request,
           secrets: opts[:secrets],
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

  # The ready client refuses a query; URI.new/1 raises on invalid UTF-8, which
  # the egress policy then refuses as :malformed.
  defp query?(url),
    do: String.valid?(url) and match?({:ok, %URI{query: q}} when q != nil, URI.new(url))

  @doc """
  Admits the server: the egress policy first (`{:error, {:egress, reason}}`),
  then one credential check (`{:error, :credentials_expired}` or
  `{:error, :credentials_unavailable}`), then the ready client runtime config
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
             credentials: need(c.secrets, c.credential)
           ] ++ c.bounds
         ) do
      {:ok, client} -> {:ok, client}
      {:error, _} -> {:error, :configuration}
    end
  end

  # The zero-arity credential Need of the ready client: resolves the reference
  # again at each request; nothing is stored.
  defp need(secrets, request) do
    fn ->
      case resolve(secrets, request) do
        {:ok, credential} -> {:ok, Secrets.reveal(credential)}
        {:error, _} -> {:error, :credentials_unavailable}
      end
    end
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

  # The check before connecting or listing: one resolution in the calling
  # process; the value is dropped.
  defp check(%Config{secrets: secrets, credential: request}) do
    case resolve(secrets, request) do
      {:ok, _} -> :ok
      {:error, :expired} -> {:error, :credentials_expired}
      {:error, _} -> {:error, :credentials_unavailable}
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
