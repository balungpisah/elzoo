# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Redact do
  @moduledoc false
  # The credential never appears in a result: every occurrence of the exact
  # resolved credential bytes in any string (keys included) of server-supplied
  # data is replaced before the data leaves the Adapter. Other encodings of the
  # credential (base64, split, escaped) are not detected (a stated limit).
  alias Elzoo.McpClient.AuthProvider

  @mark "[redacted]"

  @doc "The credential values to redact: the Need resolved now (failures give none)."
  def secrets(need) do
    case AuthProvider.token(need) do
      {:ok, t} -> [t]
      :error -> []
    end
  end

  def value(term, []), do: term
  def value(term, secrets), do: walk(term, Enum.uniq(secrets))

  defp walk(s, secrets) when is_binary(s), do: :binary.replace(s, secrets, @mark, [:global])

  defp walk(m, secrets) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {walk(k, secrets), walk(v, secrets)} end)

  defp walk(l, secrets) when is_list(l), do: Enum.map(l, &walk(&1, secrets))
  defp walk(other, _), do: other
end
