# ELZ-079 Contract amendment 1 (proposed; awaiting the main coordinator)

Source: [early review](ELZ-079-early-review.md), finding 1 (blocking), using the
reviewer's exact replacement text; only the line wraps are fitted to the live body's
five-space indentation in Admission record item 2 ("Text interface", outputs).

Live body of #153 before the amendment: SHA-256 of the API `body` string (UTF-8, as
`scripts/check-roadmap.py --live` computes it)
`348d338c4fc1fb5408f62ef648fc577dc8cf74c9ab870fd7c124944b910d667f`, 24,444 bytes.
The "Before" text occurs exactly once in it (checked byte for byte, including the
line breaks and indentation).

## Before (exact bytes, lines 133–136 of the body, from `` `throttled` and``)

```text
`throttled` and
     `overloaded` are provider rejections before generation, retryable under
     `delivery/retry-timeout`; `unknown` is possibly dispatched and not retried by
     default.
```

## After

```text
`throttled` and
     `overloaded` are provider-reported rejections after the request reached
     transport. The provider documentation may describe them as before generation,
     but that is an unverified upstream assumption, not a no-send attestation. They
     map to `failed/dispatched/retryable` and are not automatically redispatched in
     `delivery/retry-timeout`'s default mode; a later retry needs a provider
     idempotency or final no-effect ground. `unknown` is possibly dispatched and
     not retried by default.
```

The text after the replaced span (" Provider behaviour callbacks: `capabilities/0`
(features, cache mechanism,") is unchanged and continues on the same line.

Amended body: SHA-256 `45eb77101f752a1b6c1d8deb8b749cb865f953559fb251340ac14071629ae7bb`,
24,785 bytes. No other byte of the body changes. After the coordinator edits the live
body once, the task copy `tasks/ELZ-079-*.md` and the release-plan
`issue_body_sha256` are synchronized to it in one commit.
