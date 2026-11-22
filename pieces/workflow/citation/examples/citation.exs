# SPDX-License-Identifier: Apache-2.0
alias Elzoo.Citation

# The items the model was given: a whole note, and a chunk of a parsed document
# that starts at byte 4096 of that document's parsed text.
items = [
  %{item_id: "note-1", source: "notes/onboarding", version: 3, content: "Badges open at 8am."},
  %{
    item_id: "chunk-7",
    source: "handbook/refunds",
    version: 12,
    content: "Refunds are paid within 14 days.",
    start_byte: 4096
  }
]

policy = %{min_citations: 1}

# The decided value of a workflow/typed-decision step that asked for
# Citation.schema().
answer = %{
  "text" => "Refunds take up to two weeks, and badges open at 8am.",
  "citations" => [
    %{"item_id" => "chunk-7", "quote" => "within 14 days"},
    %{"item_id" => "note-1", "quote" => "open at 8am"}
  ]
}

{:ok, %{citations: cited}} = Citation.check(answer, items, policy)

# A quote that is in no item is refused; the host does not show it as cited.
fabricated = %{
  "text" => "Refunds are instant.",
  "citations" => [%{"item_id" => "chunk-7", "quote" => "Refunds are instant"}]
}

{:error, :quote_not_found} = refused = Citation.check(fabricated, items, policy)

%{cited: cited, refused: refused}
