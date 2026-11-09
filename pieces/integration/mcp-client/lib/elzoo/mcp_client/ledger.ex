# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Ledger do
  @moduledoc false
  # Every distinct token the Elzoo auth provider has handed to ex_mcp on one
  # session, so redaction covers exactly what was sent (however often the
  # credential rotates). Bounded: a 65th distinct token is refused by the
  # provider (credentials_unavailable), never sent unrecorded. The process is
  # linked to the session's client and stopped by close/1; it holds no more than
  # ex_mcp's own client state already holds.
  @max 64

  def start do
    {:ok, pid} = Agent.start(fn -> [] end)
    pid
  end

  def link(ledger, client), do: Agent.cast(ledger, fn s -> Process.link(client) && s end)

  @doc "Records a token before it is handed out; `:error` means do not send it."
  def record(ledger, token) when is_pid(ledger) do
    Agent.get_and_update(ledger, fn tokens ->
      cond do
        token in tokens -> {:ok, tokens}
        length(tokens) < @max -> {:ok, [token | tokens]}
        true -> {:error, tokens}
      end
    end)
  catch
    _, _ -> :error
  end

  def record(_, _), do: :error

  def tokens(ledger) when is_pid(ledger) do
    Agent.get(ledger, & &1)
  catch
    _, _ -> []
  end

  def tokens(_), do: []

  def stop(ledger) when is_pid(ledger) do
    Agent.stop(ledger, :normal, 1_000)
  catch
    _, _ -> :ok
  end

  def stop(_), do: :ok
end
