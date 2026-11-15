# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{RecipePackage, Skill}

# A skill folder as data: a map of relative paths to bytes. No file system is read.
folder = %{
  "SKILL.md" =>
    "---\nname: invoice-check\ndescription: Check an invoice against its order\n---\n" <>
      "Compare each line of the invoice with the order.\n",
  "references/rules.txt" => "Amounts match to the cent.\n"
}

{:ok, %{entry: entry, files: files}} = Skill.read("invoice-check", "1", ["compare-lines"], folder)

typed = fn direction ->
  %{
    "port" => %{
      "id" => direction,
      "direction" => direction,
      "schema_id" => "value",
      "schema_version" => 1
    },
    "schema" => %{"type" => "object"}
  }
end

package = %{
  "format_version" => 1,
  "name" => "example",
  "version" => "opaque-revision",
  "needs" => [],
  "permissions" => [],
  "skills" => [entry],
  "graph" => %{
    "version" => 1,
    "id" => "graph",
    "revision" => 1,
    "root" => "main",
    "callables" => [
      %{
        "name" => "main",
        "kind" => "graph",
        "input" => typed.("input"),
        "output" => typed.("output"),
        "nodes" => [],
        "links" => [],
        "input_slots" => []
      }
    ],
    "bindings" => [],
    "rules" => []
  },
  "settings" => %{
    "version" => 1,
    "id" => "independent-settings",
    "revision" => 1,
    "port" => typed.("input")["port"],
    "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
    "secrets" => []
  }
}

canonical = fn recur, value ->
  cond do
    is_map(value) ->
      fields =
        for {key, child} <- Enum.sort(value), do: [Jason.encode!(key), ?:, recur.(recur, child)]

      [?{, Enum.intersperse(fields, ?,), ?}]

    is_list(value) ->
      [?[, Enum.intersperse(Enum.map(value, &recur.(recur, &1)), ?,), ?]]

    true ->
      Jason.encode!(value)
  end
end

identity =
  "recipe-package-v1:sha256:" <>
    Base.encode16(:crypto.hash(:sha256, canonical.(canonical, package)), case: :lower)

{:ok, checked} = RecipePackage.decode(Map.put(package, "identity", identity))

# The host pins the package and keeps the files of the same version by skill name.
by_skill = %{"invoice-check" => files}

# The package says which tool the skill brings; the host says what the tool is.
descriptors = [
  %{
    "name" => "compare-lines",
    "description" => "Compare one invoice line with its order line.",
    "annotations" => nil,
    "trust" => "untrusted",
    "input_schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  }
]

# One pinned_skill source, and one empty source of kind other for the skill with a tool.
{:ok,
 [
   %{"id" => "skills", "kind" => "pinned_skill", "tools" => [_load, _read]},
   %{"id" => "skills-1", "kind" => "other", "callable" => "adapter", "tools" => []}
 ]} = Skill.sources("skills", checked, descriptors)

# A load gives the body as an instruction, and lists the descriptor of the tool for
# the source of the skill.
{:ok,
 %{
   "declaration" => %{
     "skill" => %{
       "name" => "invoice-check",
       "instructions" => "Compare each line of the invoice with the order.\n"
     },
     "listing" => %{"source" => "skills-1", "tools" => ^descriptors}
   }
 }} = Skill.load("skills", checked, descriptors, %{"name" => "invoice-check"})

# A file read gives marked content; the bytes are the file, unchanged.
{:ok,
 %{
   "media_type" => "text/plain",
   "encoding" => "utf8",
   "content" => %{
     "sources" => ["skill:invoice-check"],
     "trust" => "untrusted",
     "content" => text
   }
 }} =
  Skill.read_file(checked, by_skill, %{"skill" => "invoice-check", "path" => "references/rules.txt"})

{:error, :unknown_file} =
  Skill.read_file(checked, by_skill, %{"skill" => "invoice-check", "path" => "SKILL.md"})

%{text: text, identity: RecipePackage.encode(checked)["identity"]}
