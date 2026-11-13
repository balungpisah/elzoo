# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpMulti do
  @moduledoc """
  Several MCP servers for one tenant from a build-time set of compiled
  `Elzoo.McpClient.Binding` modules, over the ready one-server
  `integration/mcp-client` Contract. Each server keeps its own session, its own
  credential Need (built from an `integration/secrets` reference) and its own
  bounds. Tool lists are keyed by `{tenant, server}`; one server's failure is
  recorded for that server only. A tool call stays the ready path:
  `Elzoo.McpClient.admission/3`, `context/2` and `call_tool/3` on the values
  that `session/2` returns. See the README for the Contract.
  """
  alias Elzoo.McpClient

  @max_servers 16
  @keys [:tenant, :secrets, :servers]
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

  defmodule Config do
    @moduledoc """
    The configured set: the tenant and, for each declared server in order, its
    server text, Binding module, credential reference and ready client Config.
    Inspect shows the tenant and the Binding modules only.
    """
    @enforce_keys [:tenant, :secrets, :servers]
    defstruct @enforce_keys

    defimpl Inspect do
      def inspect(%{tenant: tenant, servers: servers}, _opts),
        do:
          "#Elzoo.McpMulti.Config<tenant: " <>
            Kernel.inspect(tenant) <>
            ", bindings: " <> Kernel.inspect(Enum.map(servers, & &1.binding)) <> ">"
    end
  end

  defmodule Set do
    @moduledoc """
    The connected set: the Config and, for each declared server in order,
    `{:ok, session}` or `{:unavailable, reason}` as `connect/2` recorded it.
    Inspect shows the tenant and the Binding modules only.
    """
    @enforce_keys [:config, :states]
    defstruct @enforce_keys

    defimpl Inspect do
      def inspect(%{config: %{tenant: tenant, servers: servers}}, _opts),
        do:
          "#Elzoo.McpMulti.Set<tenant: " <>
            Kernel.inspect(tenant) <>
            ", bindings: " <> Kernel.inspect(Enum.map(servers, & &1.binding)) <> ">"
    end
  end

  @doc """
  Builds the set from exactly `tenant`, `secrets` (a one-argument function from
  a credential request to the trusted `Elzoo.Secrets` context) and `servers`
  (1..16 keyword entries: `binding`, `credential` (`%{ref: ref, scope: scope}`)
  and optional ready client bounds). Returns `{:ok, config}` or
  `{:error, :configuration}`; calls no function of the host.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.sort(Keyword.keys(opts)) == Enum.sort(@keys),
         true <- is_function(opts[:secrets], 1),
         servers when is_list(servers) and servers != [] and length(servers) <= @max_servers <-
           opts[:servers],
         {:ok, entries} <- entries(servers, opts[:tenant], opts[:secrets]),
         names = Enum.map(entries, & &1.server),
         true <- Enum.uniq(names) == names do
      {:ok, %Config{tenant: opts[:tenant], secrets: opts[:secrets], servers: entries}}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp entries(servers, tenant, secrets) do
    Enum.reduce_while(servers, {:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry, tenant, secrets) do
        {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp entry(entry, tenant, secrets) do
    with true <- is_list(entry) and Keyword.keyword?(entry),
         keys = Keyword.keys(entry),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.all?(keys, &(&1 in [:binding, :credential | @bounds])),
         %{ref: ref, scope: scope} = request when map_size(request) == 2 <- entry[:credential],
         true <- not is_struct(request) and is_binary(ref) and is_binary(scope),
         {:ok, client} <-
           McpClient.configure(
             [
               binding: entry[:binding],
               tenant: tenant,
               credentials: need(secrets, request)
             ] ++ Keyword.take(entry, @bounds)
           ) do
      {:ok,
       %{
         server: client.settings.server,
         binding: entry[:binding],
         credential: request,
         client: client
       }}
    else
      _ -> :error
    end
  end

  # The zero-arity credential Need of the ready client: resolves again at each
  # request; nothing is stored.
  defp need(secrets, request) do
    fn ->
      case resolve(secrets, request) do
        {:ok, credential} -> {:ok, Elzoo.Secrets.reveal(credential)}
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

    Elzoo.Secrets.resolve(request, context)
  end

  # The check before the call: one resolution in the calling process; the
  # value is dropped.
  defp check(%Config{secrets: secrets}, %{credential: request}) do
    case resolve(secrets, request) do
      {:ok, _} -> :ok
      {:error, :expired} -> {:unavailable, :credentials_expired}
      {:error, _} -> {:unavailable, :credentials_unavailable}
    end
  end

  @doc """
  Connects each server in the declared order under the caller's
  `DynamicSupervisor`. A server that fails is recorded as
  `{:unavailable, reason}` and the next server is taken. Returns `{:ok, set}`.
  """
  def connect(%Config{} = config, supervisor) do
    states =
      Enum.map(config.servers, fn entry ->
        with :ok <- check(config, entry),
             {:ok, session} <- McpClient.connect(entry.client, supervisor) do
          {:ok, session}
        else
          {:unavailable, reason} -> {:unavailable, reason}
          {:error, reason} -> {:unavailable, reason}
        end
      end)

    {:ok, %Set{config: config, states: states}}
  end

  @doc """
  Lists the tools of every declared server, asking each connected server
  again: `%{{tenant, server} => {:ok, listing} | {:unavailable, reason}}`,
  where `listing` is the unchanged result of `Elzoo.McpClient.list_tools/1`.
  """
  def list_tools(%Set{config: config, states: states}) do
    config.servers
    |> Enum.zip(states)
    |> Map.new(fn {entry, state} ->
      {{config.tenant, entry.server}, listing(config, entry, state)}
    end)
  end

  defp listing(_config, _entry, {:unavailable, _} = state), do: state

  defp listing(config, entry, {:ok, session}) do
    with :ok <- check(config, entry),
         {:ok, listing} <- McpClient.list_tools(session) do
      {:ok, listing}
    else
      {:unavailable, reason} -> {:unavailable, reason}
      {:error, reason} -> {:unavailable, reason}
    end
  end

  @doc """
  The ready client values of one server, for `Elzoo.McpClient.admission/3`,
  `context/2` and `call_tool/3`: `{:ok, client_config, session}`,
  `{:unavailable, reason}` as `connect/2` recorded it, or
  `{:error, :unknown_server}`.
  """
  def session(%Set{config: config, states: states}, server) do
    case Enum.find_index(config.servers, &(&1.server == server)) do
      nil ->
        {:error, :unknown_server}

      i ->
        case Enum.at(states, i) do
          {:ok, session} -> {:ok, Enum.at(config.servers, i).client, session}
          unavailable -> unavailable
        end
    end
  end

  @doc "Closes each session; returns `:ok`."
  def close(%Set{states: states}) do
    for {:ok, session} <- states, do: McpClient.close(session)
    :ok
  end
end
