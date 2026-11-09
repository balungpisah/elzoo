# integration/notification

One email through Swoosh 1.29.3's SMTP adapter and its transport gen_smtp 1.3.0,
as a `delivery/effect-intent` Adapter admitted from a `core/effect`
declaration. Provider acceptance (`250` after `DATA`) is recorded as
acceptance, never as inbox delivery. Plain SMTP with STARTTLS is the only
provider in this subset; Bamboo and push/SMS are not included.

## Outcomes

| Outcome | When | Envelope outcome / dispatch / error class | Attested no-send |
| --- | --- | --- | --- |
| `accepted{provider_id}` | `250` after `DATA` | `completed` / `dispatched` | — |
| `refused{invalid_address}` | address fails the syntax check, before any connection | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{too_large}` | request over `max_request_bytes`, before any connection | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{too_large}` | `552` reply in the transaction | `failed` / `dispatched` / `permanent` | no |
| `refused{rejected_recipient}` | `550`, `551`, `553` in the transaction | `failed` / `dispatched` / `permanent` | no |
| `refused{throttled}` | `421`, `450`, `451`, `452` in the transaction | `failed` / `dispatched` / `retryable` | no |
| `refused{throttled}` | `4xx` banner or EHLO reply (session) | `rejected` / `not_dispatched` / `retryable` | yes |
| `refused{authentication_failed}` | AUTH refused, or AUTH not offered | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{credentials_unavailable}` | the credential Need fails or returns a value outside its shape | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `refused{connect_failed}` | connection refused or lost before any transaction command; STARTTLS refused or not offered; untrusted or mismatched certificate (all before AUTH) | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `unknown{connection_lost}` | connection lost during the transaction, including after `DATA` | `unknown` / `unknown` / `unavailable` | no |
| `unknown{deadline}` | the transport process did not finish within `send_timeout_ms` | `timed_out` / `unknown` / `retryable` | no |
| `unknown{unclassified_reply}` | any other transaction reply (e.g. `554`) or a malformed one | `unknown` / `dispatched` / `unclassified` | no |
| `unknown{adapter_error}` | anything raised inside the Adapter | `unknown` / `unknown` / `unclassified` | no |

The Adapter returns `{:error, tag, :smtp}` to the owner; `Elzoo.Notification.outcome(tag)`
gives the Contract outcome. The detail is always the fixed atom `:smtp`: no
server text (which commonly echoes the recipient), address or exception leaves
the Adapter. The stage split is gen_smtp's: session failures (connect, banner,
EHLO, STARTTLS, AUTH) happen before any envelope address or message byte is
sent; transaction failures (MAIL, RCPT, DATA) do not say which command failed,
so a lost connection there is `unknown`, never `refused`. `connect_failed` is
used only when the failure is attested before MAIL (connect refused, TLS
verification failure before AUTH, session loss before MAIL); any failure after
MAIL was sent, or whose stage cannot be attested, is `unknown`.

**No blind resend.** The Adapter never retries: gen_smtp gets `retries: 0`,
`no_mx_lookups: true` and one fixed relay, so one dispatch opens at most one
SMTP session. A later send of the same identity is the owner's decision under
its own Contract: only an attested no-send outcome gives the "Adapter no-send"
ground on which the host may explicitly `:rearm`. Backoff for throttling is the
caller's retry policy. `poll/1` always returns `{:unavailable,
:smtp_has_no_status}`: SMTP has no status query, so `unknown` stays unknown
until host/operator reconciliation.

## Interface

```elixir
defmodule MyApp.InviteMail do
  use Elzoo.Notification.Binding,
    id: "invitation-email", relay: "smtp.example.com", port: 587,
    sender: "noreply@example.com", recovery_grace_ms: 60_000
end

{:ok, config} =
  Elzoo.Notification.configure(
    binding: MyApp.InviteMail,
    tenant: "tenant-a",
    credentials: &MyApp.Secrets.smtp/0,          # the credential Need
    transport_supervisor: MyApp.MailTransport,   # bounded Task.Supervisor
    tls: {:verified, :system}                    # or {:verified, {:cacerts, ders}}
  )

{:ok, admission} = Elzoo.Notification.admission(config, effect_declaration)
# Start Elzoo.EffectIntent with admission.identity/arguments/deadline,
# `binding: MyApp.InviteMail` and `adapter_context: config`, then advance it.
```

- **Binding (build time).** Relay, port and sender are fixed and form the
  EffectIntent provider account `smtp://<relay>:<port>/<sender>`, so they enter
  the binding digest and the intent key. A different relay or sender needs a
  different binding. Sender identity comes from the binding only.
- **Admission.** Consumes a `core/effect` declaration: classification
  `untrusted`, capability `integration/notification`, operation `email`,
  command schema `elzoo/notification-email` version 1, `idempotency_key` (the
  logical request reference; fifth identity field) and `deadline_unix_ms`.
  Tenant comes from the trusted Config. Payload bytes: exact JSON object with
  `version` 1, `to` (1..50 ASCII addresses, at most 254 bytes each, no CR, LF,
  NUL, brackets, commas or whitespace), `subject` (1..255 bytes, no control
  characters), `text` and `html` (string or null); unknown or duplicate keys are
  refused. Returns `{:error, {:refused, :invalid_address | :too_large}}` or
  `{:error, :declaration}` without creating anything.
- **Dispatch identity.** The EffectIntent key derived from (tenant, provider
  account, Adapter ID, operation, logical request reference). The attempt is
  carried as `attempt_id`, never in the key. `Message-ID: <key@sender-domain>`
  is stable across attempts: a correlation hint for downstream systems, not a
  deduplication guarantee.

## Needs

- **Credential (injected Need).** `credentials` is a trusted zero-arity
  function, called only inside the transport process just before the session.
  Accepted value: exactly `{:ok, {username, password}}`, username 1..256 bytes,
  password 1..1024 bytes, both binaries without CR, LF or NUL. Anything else,
  and any raise, throw or exit, is `refused{credentials_unavailable}`. The value
  is checked with guards only, never logged, inspected, stored, put in an error
  term, envelope, status, evidence or telemetry. The Piece never reads
  application configuration for it. `integration/secrets` is not a dependency.
- **Trust (TLS).** Verified TLS is required for every relay except `127.0.0.1`
  and `localhost`: `{:verified, :system}` uses `:public_key.cacerts_get/0`,
  `{:verified, {:cacerts, ders}}` takes 1..64 DER certificates. The Adapter
  builds the TLS options itself (STARTTLS required, `verify_peer`, SNI and
  HTTPS-style hostname check against the relay, TLS 1.2/1.3); callers cannot
  pass TLS options. A relay given as an IPv4 literal can only use
  `:plaintext_loopback`. A non-loopback relay without verified TLS is refused at
  construction, so the credential Need is never called for it.
- **Swoosh's application is not started** (`runtime: false`): only
  `Swoosh.Email` and `Swoosh.Adapters.SMTP.deliver/2` are used, so no global
  `:swoosh` configuration is required. Starting Swoosh's application would
  require configuring its API client.

## Redaction

`Swoosh.Mailer` is never used: its `[:swoosh, :deliver]` telemetry metadata
carries the email and the mailer config (including the password). gen_smtp's
MIME encoder debug-logs every header in the calling process; the transport
process sets its own Logger level to `:none` before calling Swoosh, which
changes no global logger setting. `inspect/1` of the Config shows only the
binding module. The completion value is `provider_id` (the `250` text, at most
256 bytes), `message_id` and an HMAC `seal` under a random process-local key,
so a forged public completion cannot settle an attempt; this is integrity of
the Adapter's own result, not provider authentication.

## Operations

- **Telemetry: planned.** No events of its own; a bounded event surface waits
  for `runtime/telemetry` (ELZ-052).
- **Config: supported.** Binding fields at build time; TLS mode and trust,
  `max_request_bytes` (1..65,536, default 65,536), `send_timeout_ms`
  (1..600,000, default 60,000), `hostname` (EHLO name), transport supervisor and
  credential Need at construction; the deadline per request from the
  declaration. No hot update.
- **Control: not applicable.** Dispatch, rearm, poll and expiry belong to the
  EffectIntent owner.

## Evidence and limits

Tests run against gen_smtp's own `gen_smtp_server` on 127.0.0.1 inside the test
VM, on an ephemeral port, with run-time generated test certificates; no real
mail and no CI service. The Cure file type-checks the stage/reply
classification. Upstream: Swoosh 1.29.3, gen_smtp 1.3.0, ranch 2.3.0, OTP ssl
and crypto, SMTP reply semantics (RFC 5321) as named, not proved. No inbox
delivery, receipt, bounce, provider-authenticity or exactly-once claim; no
SMTPUTF8; no implicit TLS (port 465). Apache-2.0 covers this source; Swoosh is
MIT, gen_smtp BSD-2-Clause, ranch ISC, idna MIT.
