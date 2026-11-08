# core/effect

A data-only request declaration that wraps an unchanged Envelope command.
It adds `capability_id`, `operation` and `classification`; identity, schema and
payload remain in `command`. `Elzoo.Effect.decode/1`, `encode/1`, `validate/1`
and `declared?/2` perform no I/O. The wrapper is an ordinary Operator output;
a Unit port expecting an Envelope must explicitly unwrap its command.

Neutral form is an exact string-keyed map with those three fields and `command`.
Capability and operation are nonempty UTF-8, at most 128 bytes, without NUL.
Classification is `untrusted` or `trusted`, never authorization. The command is
validated by unchanged `Elzoo.Envelope.decode/1`, must have kind `command`, and
retains its opaque payload. `declared?/2` checks membership in at most 64 textual
Needs; it does not grant execution, authenticate a caller or validate payloads.
Malformed declarations return `{:error, :declaration}`; invalid Needs return false.
`encode/1` requires a checked record, like Envelope's encoder.

Cure checks `EffectDeclaration(a)` with an `EnvelopeMessage(a)` command and owns
the pure kind/classification and Needs decisions. Elixir checks foreign maps
and the measured nominal String ABI. The tests exercise those translations and
audit owned source; no proof that arbitrary consumer Operators are I/O-free or
that a declared capability has been authorized is claimed. No runtime,
telemetry, configuration service or control lifecycle is added.

The `assembly/http-job` consumer uses the declaration at admission to derive
identity, exact body bytes and deadline, and refuses trusted classification.
Apache-2.0 covers this source; Cure and Elixir behavior remain upstream contracts.
