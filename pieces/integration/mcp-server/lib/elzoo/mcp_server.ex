# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpServer do
  @moduledoc """
  Elzoo's bots as MCP tools. `new/1` validates the host's configuration;
  `Elzoo.McpServer.Plug` verifies each request's bearer token and hands the
  request to `ExMCP.HttpPlug` with `Elzoo.McpServer.Handler`, which lists the
  bots that `domain/authorization` allows the principal and runs one bot per
  call through the host's `start` and `result` Needs.
  """

  alias Elzoo.{Authorization, PayloadSchema, Principal, TokenVerify}

  defstruct [
    :verifier,
    :clock,
    :policy,
    :authority,
    :bots,
    :start,
    :result,
    :call_timeout_ms,
    :poll_interval_ms,
    :body_limit
  ]

  defimpl Inspect do
    def inspect(_, _), do: "#Elzoo.McpServer<redacted>"
  end

  @required [:verifier, :clock, :policy, :authority, :bots, :start, :result, :call_timeout_ms]
  @defaults [poll_interval_ms: 250, body_limit: 131_072]
  @max_bots 64
  @max_text 65_536
  @max_version 2_147_483_647
  @outcomes [:failed, :cancelled, :out_of_budget, :out_of_time]

  @doc "Validates the configuration; `{:ok, server}` or `{:error, :invalid}`."
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys),
         true <- Enum.all?(keys, &(&1 in @required or Keyword.has_key?(@defaults, &1))),
         true <- Enum.all?(@required, &Keyword.has_key?(opts, &1)),
         opts = Keyword.merge(@defaults, opts),
         true <- verifier?(opts[:verifier]),
         true <- is_function(opts[:clock], 0) and is_map(opts[:policy]),
         true <- Enum.all?([:authority, :bots, :start, :result], &is_function(opts[&1], 1)),
         true <- int_in?(opts[:call_timeout_ms], 1, 60_000),
         true <- int_in?(opts[:poll_interval_ms], 10, 5_000),
         true <- int_in?(opts[:body_limit], 1_024, 1_048_576) do
      {:ok, struct!(__MODULE__, opts)}
    else
      _ -> {:error, :invalid}
    end
  end

  defp verifier?({:jwt, %TokenVerify.JwtConfig{}}), do: true
  defp verifier?({:api_key, %TokenVerify.ApiKeyConfig{}}), do: true
  defp verifier?(_), do: false

  defp int_in?(n, min, max), do: is_integer(n) and n >= min and n <= max

  @doc false
  # The raw token (already shape-checked by the Plug) into `{:ok, principal}`,
  # else `:refused`; a clock Need that fails refuses the token.
  def verify(%__MODULE__{verifier: {kind, config}} = server, token) do
    with {:ok, now} when is_integer(now) and now >= 0 <- need(server.clock),
         {:ok, %Principal{} = principal} <- verified(kind, token, config, now) do
      {:ok, principal}
    else
      _ -> :refused
    end
  end

  defp verified(:jwt, token, config, now), do: TokenVerify.verify_jwt(token, config, now)
  defp verified(:api_key, token, config, now), do: TokenVerify.verify_api_key(token, config, now)

  @doc false
  # The tools of `tools/list`, in name byte order.
  def list_tools(%__MODULE__{} = server, %Principal{} = principal) do
    for {bot, _checked} <- runnable(server, principal) do
      %{name: bot.name, description: bot.description, inputSchema: bot.start_schema}
    end
  end

  @doc false
  # One `tools/call`: `{:ok, text}` (the completion), `{:tool_error, text}` or
  # `{:error, "unknown tool"}`.
  # ex_mcp's handler mode merges the request's `_meta` into the arguments map,
  # so that reserved MCP member is removed before the check and the start Need.
  def call_tool(%__MODULE__{} = server, %Principal{} = principal, name, arguments) do
    case Enum.find(runnable(server, principal), fn {bot, _} -> bot.name == name end) do
      nil -> {:error, "unknown tool"}
      {bot, checked} -> checked_call(server, principal, bot, checked, without_meta(arguments))
    end
  end

  defp without_meta(arguments) when is_map(arguments), do: Map.delete(arguments, "_meta")
  defp without_meta(arguments), do: arguments

  defp checked_call(server, principal, bot, checked, arguments) do
    case PayloadSchema.check(checked, port(bot), arguments) do
      :ok -> start(server, principal, bot, arguments)
      _ -> {:tool_error, "invalid_arguments"}
    end
  end

  defp start(server, principal, bot, arguments) do
    started_at = now_ms()

    request = %{
      tenant: principal.tenant,
      principal: principal,
      bot_id: bot.bot_id,
      call_id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      arguments: arguments
    }

    case need(server.start, request) do
      {:ok, {:ok, run_id}} when is_binary(run_id) ->
        if text?(run_id, 128),
          do:
            wait(
              server,
              %{tenant: principal.tenant, principal: principal, run_id: run_id},
              started_at + server.call_timeout_ms
            ),
          else: {:tool_error, "start_failed"}

      _ ->
        {:tool_error, "start_failed"}
    end
  end

  # The result Need at once, then every poll_interval_ms; a pending Run read
  # at or after the deadline is reported running.
  defp wait(server, %{run_id: run_id} = request, deadline) do
    case need(server.result, request) do
      {:ok, {:ok, %{payload: payload}}} ->
        completed(run_id, payload)

      {:ok, {:terminal, outcome}} when outcome in @outcomes ->
        tool_error(%{"run_id" => run_id, "outcome" => Atom.to_string(outcome)})

      {:ok, {:pending, :not_completed}} ->
        case deadline - now_ms() do
          remaining when remaining > 0 ->
            Process.sleep(min(server.poll_interval_ms, remaining))
            wait(server, request, deadline)

          _ ->
            tool_error(%{"run_id" => run_id, "state" => "running"})
        end

      _ ->
        tool_error(%{"run_id" => run_id, "state" => "unknown"})
    end
  end

  defp completed(run_id, payload) do
    case canonical(%{"run_id" => run_id, "payload" => payload}) do
      {:ok, text} when byte_size(text) <= @max_text -> {:ok, text}
      {:ok, _} -> tool_error(%{"run_id" => run_id, "state" => "result_too_large"})
      :error -> tool_error(%{"run_id" => run_id, "state" => "unknown"})
    end
  end

  defp tool_error(map) do
    {:ok, text} = canonical(map)
    {:tool_error, text}
  end

  # Each valid host bot that the policy allows the principal to run, with its
  # checked start schema. A failed Need or an invalid bot list gives no bot; a
  # failed decision or a schema that does not build drops that bot only.
  defp runnable(server, principal) do
    with {:ok, {:ok, own}} <- need(server.authority, principal),
         {:ok, {:ok, bots}} <- need(server.bots, principal.tenant),
         true <- bots?(bots) do
      bots
      |> Enum.sort_by(& &1.name)
      |> Enum.flat_map(fn bot ->
        with true <- allowed?(server.policy, principal, own, bot),
             {:ok, checked} <- PayloadSchema.build(port(bot), bot.start_schema) do
          [{bot, checked}]
        else
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp allowed?(policy, principal, own, bot) do
    proposal = %{
      tenant: principal.tenant,
      resource: "mcp-server",
      action_id: "mcp.run/" <> bot.bot_id,
      payload: nil,
      writes: [%{target: "bot/" <> bot.bot_id, field: "run", value: true}]
    }

    context = %{proposer: principal.id, effect_class: "mcp.run", own: own, parent: :none}

    match?(
      {:ok, {:ok, %{verdict: :allow}}},
      need(fn -> Authorization.decide(policy, proposal, context) end)
    )
  end

  defp port(bot) do
    %{
      "id" => bot.bot_id,
      "direction" => "input",
      "schema_id" => bot.bot_id,
      "schema_version" => bot.schema_version
    }
  end

  defp bots?(bots) do
    is_list(bots) and length(bots) <= @max_bots and Enum.all?(bots, &bot?/1) and
      length(Enum.uniq_by(bots, & &1.name)) == length(bots)
  end

  defp bot?(
         %{bot_id: id, name: name, description: desc, start_schema: schema, schema_version: v} = bot
       )
       when map_size(bot) == 5 do
    text?(id, 128) and is_binary(name) and name =~ ~r/\A[a-z0-9_-]{1,64}\z/ and
      text?(desc, 1_024) and is_map(schema) and not is_struct(schema) and
      int_in?(v, 1, @max_version)
  end

  defp bot?(_), do: false

  defp text?(t, max), do: is_binary(t) and byte_size(t) in 1..max and String.valid?(t)

  # A Need's result as {:ok, result}, or :need_failed when it raises, throws or exits.
  defp need(fun) do
    {:ok, fun.()}
  catch
    _, _ -> :need_failed
  end

  defp need(fun, arg) do
    {:ok, fun.(arg)}
  catch
    _, _ -> :need_failed
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Canonical JSON: object keys in byte order, no whitespace; :error for a term
  # that is not JSON.
  defp canonical(term) do
    {:ok, IO.iodata_to_binary(encode(term))}
  catch
    :not_json -> :error
  end

  defp encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn
        {k, v} when is_binary(k) -> {k, v}
        _ -> throw(:not_json)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [scalar(k), ?:, encode(v)] end)

    [?{, Enum.intersperse(pairs, ?,), ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &encode/1), ?,), ?]]

  defp encode(term), do: scalar(term)

  defp scalar(term)
       when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> throw(:not_json)
    end
  end

  defp scalar(_), do: throw(:not_json)
end
