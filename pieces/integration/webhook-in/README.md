# integration/webhook-in

One small Plug adapter for signed first-party plain-text message ingress. It
does not start a process or server and is not a generic webhook framework.

## Interface

The only public callbacks are Elzoo.WebhookIn.init/1 and call/2. Static
configuration is a keyword list with exactly five options:

- source_id: 1–128 ASCII bytes from [A-Za-z0-9._-]
- key: zero-arity Need returning {:ok, secret} with a 32–128-byte binary, or
  {:error, :unavailable}
- clock: zero-arity Need returning a raw integer in 0..2^63-1
- principal: one-arity Need receiving the current Plug.Conn and returning
  {:ok, %{tenant: tenant, actor: actor, resources: resources}},
  {:error, :forbidden}, or {:error, :unavailable}
- admit: two-arity Need called once with the normalized event and trusted
  scope

The Plug validates scope locally: a non-struct map with exactly tenant,
actor, and resources; tenant, actor and resource IDs are valid UTF-8
strings of 1–128 bytes with no NUL; resources is a proper list of 0–64 IDs.
Repeated resource IDs are preserved. The authenticated conversation_id
must be in resources. A different valid actor vouched by the host is valid.

The event map has exactly six atom keys: version, event_id,
conversation_id, input_id, expected_revision, and text. The source_id is part
of the MAC framing, not the event. IDs and expected revision are preserved as
supplied; the Plug does not generate IDs or retry.

The configured admission callback captures the same source_id passed to
init/1; it is not added to the event map. A valid MAC proves possession of
the configured key only. It does not authenticate a human principal; the
principal Need must separately return a host-vouched scope.

## Request and admission

Only POST /elzoo/v1/messages without a query is admitted. There must be
exactly one application/json content type, no content encoding, and canonical
single security headers:

- x-elzoo-timestamp: unsigned decimal Unix seconds, 0–2^63-1, within ±300
  seconds of the clock Need
- x-elzoo-signature: v1= followed by 64 lowercase hexadecimal digits

Content-Length is optional. If supplied, it must be one canonical unsigned
decimal value no greater than 65,536. Duplicate or coalesced content/security
headers are refused. The Plug reads an entirely unread body in 8,192-byte
chunks, with a 15,000 ms monotonic total budget and a per-read timeout no
greater than min(5,000 ms, remaining budget). A no-progress read is a
timeout. The exact MAC message is shown below, with no LF after the raw body:

    elzoo-webhook-v1\n{source_id}\nPOST\n/elzoo/v1/messages\n{timestamp}\n{raw_body}

MAC verification precedes JSON parsing and the principal/admission Needs.
Ordered-object JSON decoding rejects duplicate keys recursively and accepts
only this flat JSON object, with no extra fields:

- version: the JSON integer 1
- event_id, conversation_id, input_id: 1–128 ASCII bytes from
  [A-Za-z0-9._-]
- expected_revision: an integer in 0..9,223,372,036,854,775,806
- text: nonempty valid UTF-8 of at most 4,096 bytes, with no NUL; LF and TAB
  are preserved as supplied

The host must place this Plug before parser/body-reading middleware and
provide an entirely unread body. Plug does not cache read_body/2; a prior
parser is observable through body_params, but a partial read can leave
body_params unfetched. There is no public universal prior-read flag, so this
Plug refuses observable parsed/unavailable bodies and does not claim to detect
every prior partial read. The host owns listener total-lifetime enforcement.
A read budget check cannot interrupt an adapter blocked in read_body/2; a
caller timeout does not cancel the underlying read.

## Bounded responses

Every response is halted JSON with a fixed status tag. The body contains only
status, the authenticated event_id when one exists, and a revision only for a
valid committed result.

| HTTP | Status tags |
| --- | --- |
| 202 | committed, pending_approval |
| 400 | invalid |
| 401 | unauthorized |
| 403 | forbidden |
| 404 | not_found |
| 405 | method_not_allowed |
| 408 | timeout |
| 409 | conflict |
| 413 | too_large |
| 415 | unsupported_media_type |
| 503 | unknown, unavailable |

Admission exceptions, malformed results and mismatched committed revisions
are unknown and are never retried. pending_approval is not an accepted input
or Run. A committed acknowledgement reports only the admission Need's valid
committed revision; it does not claim that a Run started or completed. Need
and provider details, credentials, request payloads and policy internals are
never returned or logged by this Piece.

The admission Need is called once with exactly the event and validated scope.
Its recognized return values are:

| Return value | Result |
| --- | --- |
| `{:committed, revision}` where `revision` is exactly `event.expected_revision + 1` | 202 `committed`, with that revision |
| `{:pending, :approval}` | 202 `pending_approval` |
| `{:rejected, :forbidden}` | 403 `forbidden` |
| `{:rejected, :conflict}` | 409 `conflict` |
| `{:rejected, :invalid}` | 400 `invalid` |
| `:unknown` | 503 `unknown` |
| `{:error, :unavailable}` | 503 `unavailable` |

Any other return, a callback exception or throw, or a committed revision
other than the exact next revision is reported as 503 `unknown`. The adapter
does not retry. Since an unknown result may follow a provider-side commit, the
host/application must reconcile and fence the original identity before any
retry: capture the configured source_id and preserve the original event_id,
input_id, conversation_id, and expected_revision. Do not invent replacement
IDs or blindly retry an unknown outcome.

## Example and limits

Run mix run pieces/integration/webhook-in/examples/elzoo/webhook_in.exs from
the repository root for a local Plug.Test invocation. Its fixed key and
pending admission are demonstration fixtures only. The tests and example do
not establish production authentication, durable admission, Run execution or
end-to-end delivery guarantees.

The provider closure is Plug 1.20.3, Plug.Crypto 2.2.1, Jason 1.4.5,
Telemetry, Elixir, and OTP crypto. Plug supplies its own transitive package
dependencies. No dependencies or pins are added by this Piece.

## Evidence

test/elzoo/webhook_in_test.exs exercises the named request, boundary, failure,
scope and callback cases with Plug's test connection and a controlled body
adapter. This finite evidence is not a proof of the host's key, principal,
admission, server ordering or listener lifetime.
