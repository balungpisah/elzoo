# SPDX-License-Identifier: Apache-2.0
alias Elzoo.ToolRegistry

search = fn description ->
  %{
    "trust" => "untrusted",
    "name" => "search",
    "description" => description,
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    },
    "annotations" => nil
  }
end

{:ok, snapshot} =
  ToolRegistry.snapshot([
    %{
      "id" => "guide",
      "kind" => "pinned_skill",
      "callable" => "nested",
      "tools" => [search.("Search docs")]
    },
    %{
      "id" => "issues",
      "kind" => "host_listing",
      "callable" => "adapter",
      "tools" => [search.(nil)]
    }
  ])

{:ambiguous, ["guide_search", "issues_search"]} = ToolRegistry.resolve(snapshot, "search")

# A resolved call: the model proposed the alias; the arguments pass the one check.
{:resolved, held} = ToolRegistry.resolve(snapshot, "issues_search")
:ok = ToolRegistry.check(held, %{"query" => "open bugs"})

# A fresh listing changes the descriptor; the held version is now a changed call.
{:ok, snapshot} = ToolRegistry.refresh(snapshot, "issues", [search.("Search open issues")])
{:changed, version} = ToolRegistry.resolve(snapshot, "issues_search", held.version)

%{callable: held.callable, changed: version != held.version}
