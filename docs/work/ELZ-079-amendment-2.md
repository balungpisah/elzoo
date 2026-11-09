# ELZ-079 Contract amendment 2 (proposed; awaiting the main coordinator)

Source: the main coordinator's decision (b) plus (c) on the per-ID consumer of the
core and the interface: no change to the shared consumer test helper or to the
check-selection module in this PR; the per-ID consumer becomes open work in
ELZ-091 (drafted by main after ELZ-079 merges). One replacement in the
"Acceptance" list; no other byte changes.

Live body of #153 before the amendment: SHA-256 of the API `body` string (UTF-8, as
`scripts/check-roadmap.py --live` computes it)
`45eb77101f752a1b6c1d8deb8b749cb865f953559fb251340ac14071629ae7bb`, 24,785 bytes
(the body after amendment 1). The "Before" text occurs exactly once in it (checked
byte for byte, including the line break and indentation).

## Before (exact bytes, lines 301–302 of the body)

```text
- [ ] The three Pieces' tests pass in the exported consumer layout, including a consumer
      that takes only the core and the interface.
```

## After

```text
- [ ] The three Pieces' tests pass in the exported consumer layout; the interface's
      tests run with a scripted test provider and load no provider dependency. A
      per-ID consumer that copies only the core and the interface is open work in
      ELZ-091.
```

Amended body: SHA-256 `46baa04113ffd8a7aa6b7fd5a4a967953b618f37c1fc066e482a6bc281ed19e4`,
24,908 bytes. After the coordinator edits the live body once, the task copy and the
release-plan `issue_body_sha256` are synchronized to it in one commit.
