# ELZ-099 — Pin and exercise the circuit and streaming providers

- Phase: provider prerequisite for the admitted streaming/circuit batch
- Catalogue IDs: none; no Piece is promoted by this task
- Dependencies: ELZ-033, ELZ-006
- Change class: X (dependency), separately merged before circuit Piece implementation

## Outcome and admission

Adopt unmodified fuse 2.5.0 as the actual trip/reset provider for the proposed
RC-26 circuit Piece. The caller is the forthcoming local provider-admission
owner. This task establishes package availability and narrow compatibility;
it does not implement or claim bounded recovery probes, circuit permit fencing,
bulkheads or a ready circuit Piece. ELZ-033 and ELZ-006 remain prerequisites;
their accepted planning and retry/backpressure boundaries are unchanged.

Independent admission review approved this exact prerequisite scope. Upstream
2.5.0 is MIT, with Jesper Louis Andersen's copyright notice, and its advertised
CI predates OTP 29. The research hand-compilation probe is limited evidence;
this task must exercise the actual Mix/rebar-built package on the pinned runtime.

## Scope and reuse

- Add normal runtime dependency `{:fuse, "== 2.5.0"}` in mix.exs and resolve only
  that addition in mix.lock. Also declare direct `{:server_sent_events, "== 1.1.0"}`,
  preserving its existing lock entry and provider record (MIT). Preserve every
  existing package and toolchain pin. Inspect ex_mcp optional fuse activation;
  do not infer a new circuit implementation from that optional declaration.
- Add registry/providers.json entry using the existing source/package/version/
  reference/license shape. Use a versioned upstream reference and MIT license.
  Record checksum and provenance in the lockfile/work record. Preserve upstream
  notices when distributing its source. No fork or copied provider implementation.
- Add an assertion-bearing, isolated provider smoke test under test/ using unique
  finite test names with cleanup. Do not kill/restart the VM-wide provider during
  unrelated concurrent tests; destructive provider probes use a separate BEAM.
- Synchronize the byte-equal task copy, manifest body hash and generated roadmap/
  ledger views through their existing generators. Work record owns evidence.

Upstream sources: https://github.com/jlouis/fuse/tree/2.5.0 and
https://hex.pm/api/packages/fuse/releases/2.5.0 . The observed release archive
SHA-256 is 7f52a1c84571731ad3c91d569e03131cc220ebaa7e2a11034405f0bac46a4fef.
Revalidate against the package actually installed; a mismatch blocks acceptance.
The provider uses OTP sasl, not an additional Hex dependency.

## Concrete acceptance

1. mix setup succeeds with Cure 208248063d64e621782cd26dd30698ee42850a89,
   Elixir 1.20.4 and OTP 29.1.2. Verify the actual loaded fuse application version.
2. Through the actual built provider, install standard zero-tolerance settings;
   a fresh ask is ok, one melt trips, cooldown eventually resets, and removal
   makes ask return not_found. Bounded waits fail explicitly. Demonstrate that
   reset alone admits concurrent asks; do not label this bounded half-open recovery.
3. Record missing-name melt and provider-restart loss of installed names in an
   isolated process probe. Preserve distinctions between observations and guarantees.
4. Incremental parser smoke uses the direct server_sent_events dependency. An
   isolated dependency consumer builds and starts both packages without Elzoo or
   ReqLLM. Preserve the existing parser license/provenance record.
   Full local mix check passes; the task's provider smoke test passes. Preserve
   existing assertions and copied consumers. New circuit copied-source startup
   belongs to the later Piece task, not this prerequisite.
5. Manifest/claims/ledger checks and byte-equal live task synchronization pass.
6. Independent review inspects exact pin/source/evidence diff; every automated
   finding has a disposition. Required exact-head hosted checks pass; coordinator
   alone runs merge queue and verifies main merge acceptance, then cleanup/closure.

## Needs, operational applicability and limits

Needs: the existing pinned Mix/rebar/OTP environment and disposable test services.
Runtime fuse owns VM-wide processes/configuration; no new global config is set.
Telemetry/Config/Control: no new Piece or operational interface; inherited provider
behavior is recorded, not promoted to an Elzoo operational guarantee.
No new Cure proof or type boundary is claimed. Grounding is finite provider tests,
package integrity/license inspection and named upstream contracts. No universal
OTP-29 compatibility, circuit recovery policy, durability or exactly-once claim.
No paid provider calls, streaming implementation, CI-policy edits or unrelated fixes.

## Ownership and verification

One implementation worker owns task/ELZ-099 after atomic remote branch creation.
The coordinator authorizes scoped metadata integration for this prerequisite;
other workers must not edit those shared files concurrently. Use an isolated
worktree/build/temp area and disposable database. Serialize any local full checks
sharing the server. Run mix setup, the provider test and mix check before push;
record exact exits, failures, source SHA and limits. Only the coordinator merges.
