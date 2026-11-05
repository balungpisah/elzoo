# ADR-0004: Distribute source pieces with a checked provenance ledger

Status: accepted for implementation under ELZ-013

## Context

The owner wants developers to take pieces into their own projects, as with
shadcn, and weave them there. A monolithic Mix application with a prose
catalogue makes that difficult: its generic Unit depended on the sample
Runtime, and reusable decisions shared a source file with an example assembly.
A library-only distribution would keep all updates coupled to one package.

## Decision

Keep Zoo's pure Operator, Unit and nested Assembly concepts. Make the delivery
unit a source bundle under pieces/<family>/<name>, with conventional lib/,
cure/, test/ and examples/ paths plus a contract and piece.json. Remove
sample-to-shell coupling and separate generic composition/idempotency from the
sample assembly. The root Mix application develops and checks the catalogue.
It is not required in a consuming application's supervision tree.

Use authored JSON metadata and a generated LEDGER.md. Registry validation
checks IDs, source/evidence paths, provider pins, dependency closure and the
readable ledger. It does not infer semantic correctness from metadata. Proof,
type, test, upstream contract and assumptions remain claim-level records.

Direct upstream reuse is a first-class recipe with no mandatory wrapper.
Adopt Req for the narrow HTTP client recipe using local HTTP and failure
checks; Finch is its transitive implementation, not a second independent
abstraction. Defer durable/provider contracts not yet exercised. This advances
library usability without declaring the later HTTP/job assembly complete.

Copy selected sources with their dependencies, tests, license and provenance
receipt. Do not automatically edit a consumer's mix.exs or overwrite changes.
The application owns copies; updates are explicit source review. The owner
selected Apache-2.0 for Elzoo-owned code. Upstream licenses are retained.

## Consequences

Pieces can be used without Elzoo.Application or the whole catalogue. Tests and
proofs travel with the copied source. Library-only recipes need no Cure build.
We trade automatic package upgrades for application ownership and explicit
merges. A receipt identifies original bytes and assumptions; modifications
must be rechecked. Named/versioned ports and semantic compatibility remain
ELZ-002/003 work. No runtime registry, package solver or task engine is added.
