# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Redact do
  @moduledoc false
  # The credential never appears in a result: every occurrence of the exact
  # credential bytes in server-supplied data is replaced by "[redacted]" before
  # the data leaves the Adapter. String values are always redacted; map keys are
  # redacted too, except keys of the MCP and JSON Schema vocabulary below, which
  # keep the protocol shape intact (a credential identical to such a word is not
  # redacted in key position: the word discloses nothing beyond the protocol).
  # Redaction runs on server data before the Adapter builds its own fixed shapes,
  # so adapter-owned keys are never touched. Other encodings of the credential
  # (base64, split or escaped forms) are not detected. Two server keys that become
  # equal after redaction keep one value (data loss, never disclosure).
  alias Elzoo.McpClient.AuthProvider

  @mark "[redacted]"
  @vocabulary MapSet.new(~w(
    type text data mimeType uri resource blob name title description inputSchema
    outputSchema annotations _meta icons size content isError structuredContent
    readOnlyHint destructiveHint idempotentHint openWorldHint audience priority
    lastModified properties required items additionalProperties enum const default
    format minimum maximum exclusiveMinimum exclusiveMaximum minLength maxLength
    pattern minItems maxItems uniqueItems anyOf oneOf allOf not $ref $defs
    definitions examples nullable
  ))

  @doc "The credential value to redact as resolved now through the Need (none on failure)."
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
    do: Map.new(m, fn {k, v} -> {key(k, secrets), walk(v, secrets)} end)

  defp walk(l, secrets) when is_list(l), do: Enum.map(l, &walk(&1, secrets))
  defp walk(other, _), do: other

  defp key(k, secrets) when is_binary(k) do
    if MapSet.member?(@vocabulary, k), do: k, else: walk(k, secrets)
  end

  defp key(k, _), do: k
end
