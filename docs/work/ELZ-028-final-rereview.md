# ELZ-028 final re-review (redacted)

Original review SHA-256:
`bf611dacfe0c390c499370b528f2cf9f3dbdd6ab62dc86971fa7fc242c01d34a`.

Reviewer: independent reviewer in a separate review role.

Source reviewed: `8c2a0826d7845150d5b178b0bc94b1a13df53c45`.
Comparison base: `e9df7233919b01740c7628fcb1a657d97aa8d732`.

The task branch later advanced to documentation head
`6d075523f4f47e65735e4e38d3fb03a0257ef1a4`; its only later commit changed
the task record and no source, tests or manifest. Code findings are bound to
`8c2a082`; the evidence-record comparison is bound to `6d07552`.

## Commands

| Command | Exit | Result |
| --- | ---: | --- |
| fetch and source-diff inspection | 0 | The source diff was restricted to the authorized Piece, its task record and own derived catalogue paths. |
| source and documentation whitespace checks | 0 | No whitespace errors. |
| issue/task-copy comparison | 0 | The task copy and live Contract had identical content and matched the release-plan record. |
| review-thread inspection | 0 | Six review threads were resolved and each had a disposition reply. |
| hosted source-check inspection | 0 | The requested source SHA had successful hosted check and Gleam runs. |
| claims and roadmap checks | 0 | No tracked claim remained and the roadmap check passed. |

No Mix command was run by the reviewer; the recorded full source check was
reviewed as evidence, not re-executed.

## Finding

### BLOCKING — `confirm/2` bypasses the required Adapter fences

`Elzoo.Lease.confirm/2` directly called the ready Store confirmation helper
instead of its selected Adapter. On Memory, the confirmation read therefore
bypassed the single owner. On PostgreSQL, the confirmation read bypassed the
OD-1a schema pin that is required before every unlocked read. The source had
no Memory-owner seam for confirmation and LS23 had no post-construction schema
mutation case for `confirm/2`.

The repair must route confirmation through each Adapter: the Memory Adapter
executes it in the owner, and the PostgreSQL Adapter performs the
caller-transaction and schema checks before delegating to the ready Store.
It must add an owner-serialization test and an LS23 mutation test, preserve
the public Contract wording, and receive a focused re-review at the resulting
immutable head.

No other new code finding was identified in this read-only review.

## Requested-item assessment

| Item | Status at the reviewed SHA | Evidence |
| --- | --- | --- |
| Authorized scope and retained catalogue material | PASS | The source was based after the relevant main merges; its name-only diff was limited to authorized paths. |
| Memory owner boundary | NOT CLEAR | `write/4` used the owner, but public `confirm/2` directly read the Store. |
| OD-1b Store fold, limits and readable rows | PASS | Construction uses the Store term's fold and limits; LS24 exercises conformance, replay, confirmation and retention. |
| OD-1a schema pin | NOT CLEAR | The pin covered the migration shape and other entry points, but not `confirm/2` before its unlocked reads. |
| Evidence consistency | PASS | The task report and PR body named the checked source, exact commands, exits and superseded runs consistently. |
| Automated-review dispositions | PASS | Six findings were resolved with disposition replies. |
| Public-record redaction | PASS | The reviewed public record contained no operational identifiers or credentials. |
| Hosted CI for the source head | PASS | Both required hosted runs completed successfully for the exact source SHA. |
| Contract fit | NOT CLEAR | The confirmation bypass contradicted the stated Memory-owner and pre-unlocked-read obligations. |

## Grounding and limits

The recorded full source check and hosted runs are evidence for their named
source SHA only. This review establishes neither a universal runtime proof nor
provider durability, cross-store agreement, authorization or merge completion.

**NOT CLEAR — route `confirm/2` through the required Memory owner and
PostgreSQL pre-unlocked-read schema pin, add focused tests, then re-review the
resulting immutable head.**
