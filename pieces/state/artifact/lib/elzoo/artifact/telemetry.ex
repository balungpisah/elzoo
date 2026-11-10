# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Artifact.Telemetry do
  @moduledoc """
  The declared telemetry of `state/artifact`: one small event family
  `[:elzoo, :artifact, event]` emitted through `:telemetry.execute/3`.

  The `runtime/telemetry` schema (ELZ-052) is a closed family covering only
  the two ready assemblies, so this Piece declares its own bounded events
  rather than editing a ready Piece (recorded on issue #179).

  | event | when | measurements | metadata |
  | --- | --- | --- | --- |
  | `[:elzoo, :artifact, :staged]` | a staging record committed | `size_bytes`, `version` | `tenant`, `artifact_id`, `upload` |
  | `[:elzoo, :artifact, :committed]` | a version record committed | `size_bytes`, `version` | `tenant`, `artifact_id` |
  | `[:elzoo, :artifact, :deleted]` | abort or delete moved a version to `:deleted` | `version` | `tenant`, `artifact_id`, `cause` (`abort`/`delete`/`reap`), `object` (`:deleted`, `:refused`, `:unknown`, `:absent`) |
  | `[:elzoo, :artifact, :integrity_failure]` | `get`/`status`/`commit` found hash evidence disagreeing with the record | `version` | `tenant`, `artifact_id`, `via` (`:get`, `:commit`, `:status`) |

  Artifact bytes never appear in events; neither do object keys, credentials
  or stored checksums (ids, hashes, sizes and terms may, per the Contract —
  this family emits ids and sizes only). Handlers are synchronous and may be
  absent; a failed or missing event never changes an operation result.
  """

  @events [
    [:elzoo, :artifact, :staged],
    [:elzoo, :artifact, :committed],
    [:elzoo, :artifact, :deleted],
    [:elzoo, :artifact, :integrity_failure]
  ]

  @uploads [:committed, :uncertain]
  @causes [:abort, :delete, :reap]
  @objects [:deleted, :refused, :unknown, :absent]
  @vias [:get, :commit, :status]

  def events, do: @events

  @doc false
  def staged(%{tenant: t, artifact_id: id, version: v, size_bytes: s, upload: u})
      when u in @uploads,
      do:
        emit([:elzoo, :artifact, :staged], %{size_bytes: s, version: v}, %{
          tenant: t,
          artifact_id: id,
          upload: u
        })

  def committed(%{tenant: t, artifact_id: id, version: v, size_bytes: s}),
    do:
      emit([:elzoo, :artifact, :committed], %{size_bytes: s, version: v}, %{
        tenant: t,
        artifact_id: id
      })

  def deleted(%{tenant: t, artifact_id: id, version: v}, cause, object)
      when cause in @causes and object in @objects,
      do:
        emit([:elzoo, :artifact, :deleted], %{version: v}, %{
          tenant: t,
          artifact_id: id,
          cause: cause,
          object: object
        })

  def integrity_failure(%{tenant: t, artifact_id: id, version: v}, via) when via in @vias,
    do:
      emit([:elzoo, :artifact, :integrity_failure], %{version: v}, %{
        tenant: t,
        artifact_id: id,
        via: via
      })

  defp emit(event, measurements, metadata) when event in @events,
    do: :telemetry.execute(event, measurements, metadata)
end
