# ELZ-107 — Prometheus provider prerequisite

- Phase: operational-boundaries provider prerequisite.
- Catalogue IDs: none; integration/observability remains unready.
- Dependencies: ELZ-033 and ELZ-052, both accepted.

Adopt only the exact maintained provider closure required by the reviewed RC-03 Prometheus pull-exporter slice. This is a separate dependency/configuration task, not exporter implementation or catalogue readiness.

## Scope

Add prometheus exactly 6.1.3 to root mix.exs and lock its sole required dependency ddskerl exactly 0.4.3 in mix.lock; register both provider provenance/licenses. No unrelated resolution/pin/toolchain changes. Set root configuration `config :prometheus, global_labels: []` for this admitted closed-schema use. The future Piece will declare the corresponding install\_configuration in its own manifest; this prerequisite creates no placeholder Piece or empty registry entry.

Owned paths: mix.exs, mix.lock, config/config.exs, registry/providers.json, this publication copy, docs/work/ELZ-107.md, and coordinator-serialized own release-plan row/generated views. No existing Piece behavior/metadata, root Application, source-copy harness, CI workflow or runner policy changes.

Provider sources: https://repo.hex.pm/tarballs/prometheus-6.1.3.tar, MIT, checksum bd9522b4dd21cf6670f18a647d1ef91ab2f633f02f9275b583fad1eb11f880bf; https://repo.hex.pm/tarballs/ddskerl-0.4.3.tar, Apache-2.0, checksum 4e0f6047c6a002ce38f6ea155276dd918cd635fd0a5edb9e0b46aeb6f7aff2c2. Verify exact archives/licenses and resolved closure; record actual lock checksums and any discrepancy, rather than silently updating pins. No fork/copy. Runtime provider applications and their ETS state remain upstream-owned.

## Concrete need and public boundary

The later integration/observability caller will project accepted runtime/telemetry events into two finite-label counter families and export standard Prometheus text. This prerequisite validates prometheus\_counter.new/1, inc/4, value/3, values/2, deregister/2; prometheus\_registry.collectors/1; prometheus\_text\_format.format/1 and content\_type/0 on the pinned toolchain. It adopts neither OTel nor a custom transport protocol.

Use an isolated registry and synthetic data. Demonstrate new/1 returns :ok; duplicate/conflicting creation refuses rather than silently adopting a changed schema; integer count and asymmetric microsecond total are exact; text has expected labels/content type and no default-registry VM collectors; global\_labels is empty under root configuration; provider stop/restart loses metrics and redeclaration restores use. Cleanup only fixture-owned definitions. These are finite API/compatibility observations, not guarantees of atomic scrape, durable counters or arbitrary registry exclusivity.

## Acceptance and delivery

Resolve on Elixir 1.20.4/OTP 29.1.2 with Cure commit 208248063d64e621782cd26dd30698ee42850a89 unchanged. Run mix setup and full mix check locally because this is class X. Preserve and classify failures before rerun; do not repair unrelated defects or weaken assertions. Execute the boundary probe in a clean minimal consuming Mix project with only the declared provider closure/configuration, without Elzoo.Application; record commands, exit codes, exact versions and inspected source/license evidence. Temporary probe scripts/projects may be removed after evidence is recorded.

Synchronize task copy/hash and generated views under the explicit shared-file handoff. Obtain independent exact-SHA dependency/configuration review and dispose of all automated findings. Use the single coordinated merge queue, adopt exact-head hosted checks without duplicate dispatch, verify main's merge acceptance, clean merged refs/worktree and close the issue with evidence. ELZ-106 implementation starts only after this prerequisite is merged and accepted.

No secret provider, live endpoint, paid API, server deployment, new Assembly, telemetry event change, durable-job/Store/Writer/Relay/outbox/EffectIntent change, ELZ-041 or ELZ-044 work. Proofs: none new. Grounding: executed finite provider/copy compatibility checks and named MIT/Apache-2.0 upstream contracts, with global configuration exclusivity still a consumer Need for the later Piece.
