# SPDX-License-Identifier: Apache-2.0
alias Elzoo.ToolResultLimit

# A marked tool result of 3,000 bytes against a declared bound of 1,024 bytes.
result = %{
  "content" => %{
    "schema_id" => "elzoo.untrusted-content.marked",
    "schema_version" => 1,
    "sources" => ["mcp:files/read_file"],
    "trust" => "untrusted",
    "max_bytes" => 4_096,
    "content" => String.duplicate("line of a long file\n", 150)
  },
  "media_type" => "text/plain",
  "encoding" => "utf8"
}

limits = %{max_bytes: 1_024, artifact_max_bytes: 16_777_216}

# The caller sends `payload` as a tool_call action and keeps `pending`.
{:store, pending, _payload} = ToolResultLimit.decide(result, limits, "action-7")

# The store action failed: the model gets the notice and the preview.
ToolResultLimit.settle(pending, "failed", nil)
