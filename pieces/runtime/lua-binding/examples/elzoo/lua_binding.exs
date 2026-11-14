# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{LuaBinding, ToolRegistry}

port = fn id, direction ->
  %{
    "id" => id,
    "direction" => direction,
    "schema_id" => "elzoo.example." <> id,
    "schema_version" => 1
  }
end

manifest = fn name, permissions ->
  %{
    "name" => name,
    "version" => 1,
    "description" => "Count the open issues that match a query.",
    "arguments" => %{
      "port" => port.(name <> "_in", "input"),
      "schema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "additionalProperties" => false
      }
    },
    "result" => %{
      "port" => port.(name <> "_out", "output"),
      "schema" => %{
        "type" => "object",
        "properties" => %{"count" => %{"type" => "integer"}},
        "required" => ["count"],
        "additionalProperties" => false
      }
    },
    "cost" => %{"unit" => "call", "estimate" => 2},
    "permissions" => permissions
  }
end

manifests = [manifest.("issues_count", ["issues.read"]), manifest.("docs_count", ["docs.read"])]

declaration = [
  %{"name" => "issues_count", "version" => 1},
  %{"name" => "docs_count", "version" => 1}
]

# Load time: resolve the declaration once; a missing function would be refused here.
{:ok, bindings} = LuaBinding.resolve(declaration, manifests)

{:refused, [%{name: "ghost", code: :unknown_function}]} =
  LuaBinding.resolve([%{"name" => "ghost", "version" => 1}], manifests)

# The two things that other Pieces need: names for the sandbox, one registry source.
["docs_count", "issues_count"] = LuaBinding.names(bindings)
{:ok, source} = LuaBinding.source(bindings, "lua")
{:ok, snapshot} = ToolRegistry.snapshot([source])
{:resolved, tool} = ToolRegistry.resolve(snapshot, "lua_issues_count")
:ok = ToolRegistry.check(tool, %{"query" => "open bugs"})

# One call: arguments before the call, result before it returns to Lua.
:ok = LuaBinding.check_arguments(bindings, "issues_count", %{"query" => "open bugs"})

{:refused, %{name: "issues_count", violations: violations}} =
  LuaBinding.check_arguments(bindings, "issues_count", %{"query" => 1})

:ok = LuaBinding.check_result(bindings, "issues_count", %{"count" => 3})
{:refused, %{name: "issues_count"}} = LuaBinding.check_result(bindings, "issues_count", %{})

{:ok, %{"unit" => "call", "estimate" => 2}} = LuaBinding.cost(bindings, "docs_count")

%{
  names: LuaBinding.names(bindings),
  permissions: LuaBinding.permissions(bindings),
  refused_at_member: [:key] in Enum.map(violations, & &1.path),
  identity_bytes: byte_size(LuaBinding.identity(bindings)),
  alias: tool.alias
}
