# integration/pii-redaction

`Elzoo.PiiRedaction` scans one text for a closed, listed set of personal-data
patterns and for exact values that the host names, and returns the text with
each finding replaced. Mask mode writes a fixed marker, for logs and
telemetry. Tokenize mode writes an opaque reference that an injected vault Need
returns, for prompts and immutable streams, so that rows of
`assembly/checked-command`, `state/event-log` and `state/audit-log` carry
references instead of raw personal data.

Detection is deterministic pattern matching, not classification. **A text with
no finding is not public data**: the host still tags data classes for
`domain/provider-data-policy`. No I/O, clock, process, telemetry, log or
rehydration (reference to value). The vault is not in this Piece.

## Interface

`redact(text, opts)` returns `{:ok, %{text: out, findings: findings}}` or
`{:error, reason}` with `reason` in `:malformed | :too_many | :unavailable`.

- `text`: valid UTF-8, 0..65,536 bytes.
- `opts`: a keyword list with exactly `mode` (`:mask` or `:tokenize`) and
  `known` (a proper list of 0..64 valid UTF-8 values of 1..256 bytes). In
  `:tokenize` mode it also has exactly `vault`, an arity-2 Need called as
  `vault.(kind, span)` that returns `{:ok, ref}`, where `ref` is 1..64 bytes
  of `[A-Za-z0-9_-]`. In `:mask` mode `vault` is refused.
- `findings`: `[%{kind: kind, count: n}]`, one entry for each kind found, in
  kind order. It never holds a span.

Kinds, in this fixed order:

- `:known`: an exact byte occurrence of a `known` value; case sensitive, no
  normalization.
- `:email`: an ASCII local part of 1..64 bytes of `[A-Za-z0-9._%+-]`, `@`, and
  a domain of 2..127 labels of 1..63 bytes of `[A-Za-z0-9-]` that neither start
  nor end with `-`; the domain is at most 253 bytes and its last label is 2..63
  letters. The span is maximal: no local-part byte before it, and after it no
  label byte and no `.` followed by a label byte.
- `:card`: 13..19 digits, contiguous or grouped by one kind of separator
  (single spaces or single hyphens), that pass the Luhn check. The span is a
  whole run: no digit, and no separator next to a digit, on either side.
- `:phone`: `+` and 8..15 digits with optional single spaces or hyphens
  between digits. No digit stands before the `+` and the run does not go on.

## Order

1. Shape of `text` and `opts`: `:malformed`.
2. Each input `[pii:` is rewritten to `[pii_:`, so every `[pii:` in the output
   is a marker of this call.
3. Candidates of every kind are found on the rewritten text. The leftmost
   start wins, then the longer span, then the earlier kind; the chosen
   findings never overlap. More than 256 findings: `:too_many`.
4. `:tokenize` only: `vault` is called once for each distinct `{kind, span}`,
   in order of first occurrence. A raise, throw, exit, malformed result or
   invalid `ref` gives `:unavailable` and no partial text.
5. Each finding becomes `[pii:<kind>]` (mask) or `[pii:<kind>:<ref>]`
   (tokenize).

```elixir
Elzoo.PiiRedaction.redact("Ann: ann@example.com, +62 812-3456-7890",
  mode: :mask, known: ["Ann"])
#=> {:ok, %{text: "[pii:known]: [pii:email], [pii:phone]",
#=>   findings: [%{kind: :known, count: 1}, %{kind: :email, count: 1},
#=>              %{kind: :phone, count: 1}]}}
```

See `examples/elzoo/pii_redaction.exs` for tokenize mode.

## Grounding, Needs and Limits

Tests only: `mix test pieces/integration/pii-redaction/test` runs the groups
kinds in both modes, boundaries, overlap, escaping, vault Need, adversarial
size (65,536-byte texts with printed timings, observations only) and secrecy.
Three negative controls, each a temporary edit (drop the Luhn check; drop the
`[pii:` rewrite; call the vault before the `:too_many` check), failed cases of
groups 1, 2, 4, 5 and 7. Finite scenarios, not a universal proof.

Needs: the host supplies the vault Need (the root acceptance wires
`state/retention-erasure`), names the exact `known` values, tags data classes
itself and redacts before text reaches a log, a prompt or a stream.

Limits: listed patterns only, with no claim of completeness, names,
addresses, national IDs or numbers without `+`. `known` values match exact
bytes of the rewritten text only. A card or phone number directly followed by
a space or hyphen and another digit is read as the longer run: it is not found
when that run fails the pattern (`4111 1111 1111 1111 7 items`, a 17-digit run
that fails Luhn), and it is found with the extra digit when the run passes. No
rehydration, no data-class decision and no vault. Errors are fixed atoms that
never echo the text. Telemetry and Control are not applicable; Config is the
per-call options.

Module application-owned under `Elzoo.PiiRedaction`. Apache-2.0; no new
dependency or pin. See [consumption instructions](../../../docs/consuming.md).
