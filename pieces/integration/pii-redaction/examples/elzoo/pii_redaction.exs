# SPDX-License-Identifier: Apache-2.0
text = "Ann (ann@example.com, +62 812-3456-7890) paid with 4111 1111 1111 1111."

# Mask mode, for logs and telemetry.
{:ok, %{text: masked, findings: findings}} =
  Elzoo.PiiRedaction.redact(text, mode: :mask, known: ["Ann"])

IO.puts(masked)
IO.inspect(findings)

# Tokenize mode, for prompts and immutable streams. A fixed in-memory vault
# keeps the example offline; a host wires a real vault Need here.
vault = fn kind, span -> {:ok, "#{kind}-#{:erlang.phash2(span)}"} end

{:ok, %{text: tokenized}} =
  Elzoo.PiiRedaction.redact(text, mode: :tokenize, known: ["Ann"], vault: vault)

IO.puts(tokenized)
