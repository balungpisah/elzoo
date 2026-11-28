# ELZ-436 — state/conversation: a message text bound that holds every answer the engine can carry

- Dependencies: ELZ-419

## Outcome and scope

After ELZ-419, `state/conversation` keeps the version 1 bound on `text`:
1–4,096 valid UTF-8 bytes, for inputs and answers alike. An answer comes from
a model call. The engine accepts a completed result whose compact JSON is at
most 65,536 bytes (`core/payload-schema`), so the text of an answer can be
almost that long. Today any answer from 4,097 bytes up to that size is
refused at `append_answer/2`, and the conversation never gets the answer.

- `text` becomes 1–65,536 valid UTF-8 bytes for every record kind, NUL
  allowed, kept byte for byte. Jason's default escaping never makes an
  encoded string shorter than its text, so no answer text that the engine
  accepts is above the new upper bound. The lower bound stays: an empty text
  is still refused. No other bound changes: IDs, segments, granted
  conversations, and `limit` and `count` in 1..1,000.
- Rows keep `schema_version` 1. Every row that is valid under the old bound is
  valid under the new one.
- The worst-case payload is computed as the README computes it today: four
  128-byte IDs of the byte `0x01` and a text of 65,536 NUL bytes, each byte
  escaped to six. Today's formula gives
  `72 + 6 × (4 × 128 + 65,536) = 396,360` bytes; the task confirms that
  figure. `Record.max_payload_bytes/0` returns it, the README and
  `piece.json` state it, and the owner, `import_v1/3`, `page/5` and `tail/4`
  keep refusing a Store whose `limits.max_record_bytes` is below it.
- The owner's own reads, at start and when it catches up after another
  writer, read at most 169 rows per Store read. So the valid encoded payloads
  of one read sum to at most 66,984,840 bytes, within 67,108,864 (170 rows
  would be 67,381,200). This bounds payload bytes per read. It does not bound
  Store framing, decoding allocations, or the owner's message-ID index, which
  grows with the conversation. The README states the worst-case payload of
  one row, so a caller of `page/5` and `tail/4` can choose its `limit` or
  `count`.
- This change is breaking (README `## Changes`):
  - A Store whose `max_record_bytes` lies between the old and the new worst
    case is now refused, also for an empty stream: the owner's start and
    `import_v1/3` return `{:error, :unsupported_store}`, and `page/5` and
    `tail/4` return `{:error, :invalid_request}`. To move, raise the Store
    limit.
  - A copy taken before this change refuses a stream that holds a text above
    4,096 bytes: its owner at start, as damaged; its `page/5` and `tail/4`
    with `{:error, :damaged}`, but only when the range they read holds such a
    row. To move, give every node that writes or reads a stream the new copy
    before any node writes a longer text.
- A host may keep a stricter bound of its own. The wave 4 channel example
  keeps its 4,096-byte check, and its files do not change.

Paths: `pieces/state/conversation/**`, its `entries` row in
`docs/plans/release-plan.json` (`manifest_sha256`, and `note` equal to the
new `contract`; keep its primary `job`), and the generated files, regenerated
from current `main`. New external dependencies: none.

## Acceptance

- On Memory and on PostgreSQL:
  - An input and an answer whose text is exactly 65,536 bytes append. Each
    reads back byte for byte through `page/5` and `tail/4`, and after an owner
    restart (the start validation).
  - A text of 65,537 bytes is refused, as an over-bound text is refused today,
    and writes no row.
  - A payload with a text of 65,536 NUL bytes and four 128-byte IDs of the
    byte `0x01` encodes to the size that `Record.max_payload_bytes/0`
    returns. A worst case that is appended uses distinct IDs made only of
    control bytes that Jason escapes to six bytes each (such as `0x01` and
    `0x02`; not `\b`, `\t`, `\n`, `\f` or `\r`, which take two), so it is
    not a `duplicate_message_id`.
- A Store limit one byte below the worst case, also on an empty stream: the
  owner's start and `import_v1/3` give `{:error, :unsupported_store}`, and
  `page/5` and `tail/4` give `{:error, :invalid_request}`.
- An owner start over a stream longer than 169 rows, and an owner that
  catches up after another writer appended more than 169 rows, read in
  Store reads of at most 169 rows (assert the Store's read calls).
- The wave 4 tests pass unchanged.
- Negative control (recorded and reverted): keep the 4,096-byte bound; the
  65,536-byte tests fail.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state). Then the exact-head automated
  review, with its threads answered and resolved, or the authorized
  replacement review under `AGENTS.md` section 6.
