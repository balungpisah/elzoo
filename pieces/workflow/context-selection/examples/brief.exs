# SPDX-License-Identifier: Apache-2.0
# A host assembles one bounded human-review brief from its coherent snapshot.
# The host must refresh this snapshot before actual injection/use.
item = %{
  item_id: "document:7",
  version: 2,
  source: "review-library",
  content: "Approved brief.",
  estimate: 15,
  priority: 0,
  content_hash: :crypto.hash(:sha256, "Approved brief."),
  derived_from: [],
  access: %{principal: "reviewer", checked_at: 95, result: :allowed}
}

node =
  item
  |> Map.take([:item_id, :version, :source, :content_hash, :derived_from])
  |> Map.put(:tenant, "team")

check =
  node
  |> Map.delete(:derived_from)
  |> Map.merge(%{principal: "reviewer", checked_at: 100, result: :allowed})

window = %{
  provider_id: "human",
  model_id: "review-brief",
  size: 100,
  unit: :bytes,
  estimator_id: "utf8-bytes",
  estimator_version: 1
}

context = %{
  principal: "reviewer",
  tenant: "team",
  now: 100,
  snapshot_at: 100,
  window: window,
  windows: [window],
  reservations: [{"heading", 10}],
  policy: %{
    max_age: 10,
    allow_derived: false,
    priority: :input,
    recency: :input,
    max_selected_count: 5,
    max_selected_bytes: 90
  },
  provenance: [Map.put(node, :check, check)]
}

Elzoo.ContextSelection.select(%{candidates: [item]}, context)
