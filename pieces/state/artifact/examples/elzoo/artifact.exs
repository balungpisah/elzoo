# SPDX-License-Identifier: Apache-2.0
# state/artifact usage sketch (not executed by mix check): call
# MyApp.ArtifactExample.run(object_store, File.read!("report.pdf"),
#   File.read!("report-v2.pdf")) with the consumer's configured binding.
#
# Requires a Store term (the ready PostgreSQL Store for durability, the
# Memory double for tests) whose fold already merges Elzoo.Artifact.kinds/0,
# and an %Elzoo.ObjectStore.Config{} whose credential is the consumer's
# injected Need.

defmodule MyApp.ArtifactExample do
  def run(%Elzoo.ObjectStore.Config{} = object_store, pdf, pdf_v2) do
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

    {:ok, art} =
      Elzoo.Artifact.new(
        store: store,
        object_store: object_store,
        max_bytes: 4 * 1024 * 1024,
        staging_ttl_ms: 3_600_000
      )

    caller = %{tenant: "acme", principal: "report-worker", scopes: ["artifacts:read"]}

    # stage + commit convenience: allocates the next version (v1 for a new id)
    {:ok, v1} =
      Elzoo.Artifact.put(art, caller, "report-2026-02", %{
        bytes: pdf,
        media_type: "application/pdf",
        access: %{tenant: "acme", principals: :any, scopes: ["artifacts:read"]},
        access_expires_at_unix_ms: :never,
        retain_until_unix_ms: 1_920_000_000_000
      })

    # head, get (integrity is recomputed under the record's stored hash_format)
    {:ok, head} = Elzoo.Artifact.head(art, caller, "report-2026-02")
    {:ok, %{bytes: bytes}} = Elzoo.Artifact.get(art, caller, "report-2026-02", :head)

    # a new version keeps v1 readable
    {:ok, v2} =
      Elzoo.Artifact.new_version(art, caller, "report-2026-02", %{
        bytes: pdf_v2
      })

    {:ok, versions} = Elzoo.Artifact.versions(art, caller, "report-2026-02")

    # explicit two-phase lifecycle and reconciliation
    {:ok, staged} = Elzoo.Artifact.stage(art, caller, "report-2026-02", %{bytes: "partial"})

    {:ok, %{record: rec, object: evidence}} =
      Elzoo.Artifact.status(art, caller, %{artifact_id: "report-2026-02", version: staged.version})

    {:ok, committed} = Elzoo.Artifact.commit(art, caller, "report-2026-02", staged.version)

    # retention: caller-driven reaping
    {:ok, %{record: _, object: outcome}} = Elzoo.Artifact.delete(art, caller, "report-2026-02", 1)
    {:ok, %{reaped: reaped, object: results}} = Elzoo.Artifact.reap(art, caller, "report-2026-02")

    %{
      first: v1,
      second: v2,
      head: head,
      versions: versions,
      bytes: bytes,
      staged: rec,
      committed: committed,
      evidence: evidence,
      delete: outcome,
      reaped: reaped,
      cleanup: results
    }
  end
end
