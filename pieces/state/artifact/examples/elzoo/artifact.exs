# SPDX-License-Identifier: Apache-2.0
# state/artifact usage sketch (not executed by mix check): a tenant puts and
# reads a versioned artifact reference; bytes live in object storage.
#
# Requires a Store term (the ready PostgreSQL Store for durability, the
# Memory double for tests) whose fold already merges Elzoo.Artifact.kinds/0,
# and an %Elzoo.ObjectStore.Config{} whose credential is the consumer's
# injected Need.

fold = %{
  initial: 0,
  kinds: Elzoo.Artifact.kinds(),
  versions: [1],
  destinations: [],
  reduce: fn n, _row, _seq, _rev -> n + 1 end
}

limits = %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 10_000}

{:ok, mem} = Elzoo.DurableLog.Memory.start_link(fold: fold, limits: limits)
store = Elzoo.DurableLog.Memory.store(mem)

# In a consumer, object_store = Elzoo.ObjectStore.new!(...injected credentials...)
object_store = nil

{:ok, art} =
  Elzoo.Artifact.new(
    store: store,
    object_store: object_store,
    max_bytes: 4 * 1024 * 1024,
    staging_ttl_ms: 3_600_000
  )

caller = %{tenant: "acme", principal: "report-worker", scopes: ["artifacts:read"]}

# stage + commit convenience: allocates the next version (v1 for a new id)
{:ok, %{record: v1}} =
  Elzoo.Artifact.put(art, caller, "report-2026-02", %{
    bytes: :file.read!("report.pdf") |> elem(1),
    media_type: "application/pdf",
    access: %{tenant: "acme", principals: :any, scopes: ["artifacts:read"]},
    access_expires_at: :never,
    retain_until: 1_920_000_000_000
  })

# head, get (integrity is recomputed under the record's stored hash_format)
{:ok, %{record: head}} = Elzoo.Artifact.head(art, caller, "report-2026-02")
{:ok, %{bytes: bytes}} = Elzoo.Artifact.get(art, caller, "report-2026-02", :head)

# a new version keeps v1 readable
{:ok, %{record: v2}} =
  Elzoo.Artifact.new_version(art, caller, "report-2026-02", %{
    bytes: :file.read!("report-v2.pdf") |> elem(1)
  })

{:ok, versions} = Elzoo.Artifact.versions(art, caller, "report-2026-02")

# explicit two-phase lifecycle and reconciliation
{:ok, %{record: staged}} = Elzoo.Artifact.stage(art, caller, "report-2026-02", %{bytes: "partial"})

{:ok, %{record: rec, object: evidence}} =
  Elzoo.Artifact.status(art, caller, %{artifact_id: "report-2026-02", version: staged.version})

{:ok, %{record: committed}} = Elzoo.Artifact.commit(art, caller, "report-2026-02", staged.version)

# retention: caller-driven reaping
{:ok, %{record: _, object: outcome}} = Elzoo.Artifact.delete(art, caller, "report-2026-02", 1)
{:ok, %{reaped: reaped, object: results}} = Elzoo.Artifact.reap(art, caller, "report-2026-02")
