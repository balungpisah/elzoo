# integration/object-store

An S3-only object-store Adapter (ELZ-053) on [`req_s3`](https://hexdocs.pm/req_s3/0.2.5/ReqS3.html)
0.2.5 and the pinned Req. One `Elzoo.ObjectStore.Config` binds one S3-compatible endpoint and one
bucket under a named backing-store identity. Each call performs one operation and returns one
result of a finite table; the Adapter never retries. Contract record:
[docs/work/ELZ-053.md](../../../docs/work/ELZ-053.md).

## Interface

```elixir
{:ok, store} =
  Elzoo.ObjectStore.new(
    store_id: "reports-minio",
    endpoint: "http://127.0.0.1:9000",
    bucket: "reports",
    region: "us-east-1",
    credentials: {MyApp.Secrets, :object_store, []}
  )

Elzoo.ObjectStore.put(store, "r/1.pdf", bytes, content_type: "application/pdf", deadline_ms: 5_000)
Elzoo.ObjectStore.get(store, "r/1.pdf")
Elzoo.ObjectStore.head(store, "r/1.pdf")
Elzoo.ObjectStore.list(store, "r/", page_size: 100, continuation: nil)
Elzoo.ObjectStore.delete(store, "r/1.pdf")
Elzoo.ObjectStore.presign(store, "r/1.pdf", method: :get, expires_s: 900)
Elzoo.ObjectStore.reconcile_put(store, "r/1.pdf", sha256)
Elzoo.ObjectStore.to_delivery_result(result, %{"message_id" => id})
```

A put body is a binary or `{:stream, enumerable, length}`; a stream needs `content_sha256`
(32 raw bytes). Every result carries `operation`, `store`, `bucket`, and `key` for key-addressed
operations or `prefix` for `list`.

| Result | Meaning |
| --- | --- |
| `committed{etag, bytes, sha256}` | put: HTTP 200 **and** the provider echoed the SHA-256 checksum that was sent; delete: 204, which acknowledges the request, not that an object existed or that absence persists |
| `found{metadata, body}` / `found{metadata}` | get (body ≤ `max_object_bytes`, SHA-256 compared when stored) / head |
| `absent` | get/head: `NoSuchKey` only |
| `listed{keys, truncated, continuation}` | one bounded page; `continuation` is the next token when `truncated` |
| `refused{reason, origin}` | `denied`, `no_such_bucket`, `precondition_failed`, `too_large`, `invalid_key`, `checksum_mismatch`, `invalid_request`, `credentials_unavailable`; `origin` is `:local` (before any connection), `:provider` or `:adapter` |
| `unknown{reason}` | `deadline`, `transport`, `server_error`, `unverified`, `unexpected`, `integrity`, `adapter_error` |

`to_delivery_result/2` maps every row to the ELZ-011 delivery result (checked by
`Elzoo.Envelope.validate_result/1`): local refusals are `rejected/not_dispatched`, provider and
adapter refusals `failed/dispatched`, `unknown{deadline}` is `timed_out/unknown`,
`unknown{transport | adapter_error}` is `unknown/unknown`, the other unknowns `unknown/dispatched`.
An optional `declaration:` (an ELZ-011 `Elzoo.Effect` declaration) must name
`integration/object-store` and the called operation, otherwise `refused{invalid_request}`.

## Needs

- **Endpoint, bucket and region**: passed explicitly; `req_s3`'s environment fallbacks
  (`AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are never reached.
- **Credential** (main coordinator decision, no secrets Piece first): an injected reference, a
  `{module, function, args}` tuple or a zero-arity function returning
  `{:ok, %{access_key_id: binary, secret_access_key: binary}}`. It is resolved inside the request
  process at each call and never stored in the Config; the Piece never reads global configuration or
  the environment for it. Do not put the secret itself in `args`. A failing Need is
  `refused{credentials_unavailable}` and its term is not echoed.
- **Applications**: `:req` (Req's Finch pool, or a Finch pool named by `finch:`), `:crypto`.

The secret access key never appears in any Adapter result, error, `inspect` value, Adapter log or
Adapter event. The access-key ID is an identifier: it occurs in a returned presigned URL (a bearer
capability; `inspect` and errors redact it and the Adapter never logs or emits it) and in signed
upstream request headers. Telemetry handlers you install on Req/Finch events can see those headers;
their collection and redaction are your responsibility.

## Deadline and unknown outcomes

Local checks run in the caller before any connection. The request runs in a monitored process that
the caller kills at the deadline: a deadline after dispatch is `unknown{deadline}`, never `absent` or
`committed`. A dropped connection or a failing body stream is `unknown{transport}`. After an
`unknown` put, reconcile with `reconcile_put/3` (a `head` comparing the stored SHA-256): `:match`,
`:mismatch` or `:absent`. Absence is an observation at that moment, never proof that the write had
no effect; do not re-send blindly.

## delivery/effect-intent Binding

```elixir
defmodule MyApp.ReportUpload do
  use Elzoo.ObjectStore.Binding,
    id: "report-upload",
    operation: :put,
    provider_account: "s3://reports-minio/reports"
end
```

Start the `Elzoo.EffectIntent` owner with identity `[tenant, provider_account, id, "put", ref]`,
arguments `Elzoo.ObjectStore.Binding.arguments(:put, key:, sha256:, bytes:, content_type:)` (the
object reference, never the body: the argument bound is 64 KiB) and
`adapter_context: Elzoo.ObjectStore.Binding.context(store, body: fn ref -> bytes end)`. The fixed
failure table attests no-send only for checks decided before a connection (`invalid_key`,
`too_large`, `checksum_mismatch`, `invalid_request`, `credentials_unavailable`). `poll` reconciles by
`head`: a matching SHA-256 completes; `absent` or another SHA-256 is pending, never `no_effect`. A
delete binding completes when `absent` is observed at poll (an observation, not proof that this
attempt deleted anything). Results carry a process-local HMAC seal, so a public observation cannot
complete an attempt.

## Defaults (first callers C8 upload and transform, C2 report artifact)

`max_object_bytes` 64 MiB (at most 5 GiB, the single-PUT limit; no multipart, `ex_aws_s3` not
added), `default_page_size` 100, `max_page_size` 1000, `presign_default_s` 900, `presign_max_s`
3600, `default_deadline_ms` 30 000. These are first-caller Config defaults, not universal S3 limits.

## Operations

Telemetry `planned` (no event or log line is emitted); Config `supported` (construction-time and
per-call settings above, no hot update); Control `not_applicable` (call-scoped; the deadline is the
only cancellation and cannot erase a dispatched write).

## Evidence and limits

Finite tests against the pinned disposable MinIO `RELEASE.2025-09-07T16-13-09Z` (`ELZOO_TEST_S3_*`,
scripts/ci-minio.py; the tests fail closed without them) and a loopback stub; no proof is claimed.
S3 semantics, MinIO durability, `req_s3`, Req and Finch behaviour are upstream contracts. No
versioning, retention, lifecycle, ACL, content ownership (`state/artifact`), cross-store atomicity,
multipart or TLS certification. Apache-2.0 covers this source; `req_s3` and Req are Apache-2.0.
