# ELZ-278 — Replace listed personal data in text with markers or opaque vault references

- Phase: Wave 5 Level 3 (sub-level 3a)
- Dependencies: ELZ-033
- Release: V1B
- Output: new `integration/pii-redaction` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/pii-redaction/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`domain/provider-data-policy`, `state/retention-erasure`, `state/audit-log`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One bounded Piece in plain Elixir (Cure where a pure decision fits; no new provider, no regex library beyond Elixir's own `Regex`). It scans one text for a closed, listed set of personal-data patterns and for exact values that the host names, and returns the text with each finding replaced. In mask mode a finding becomes a fixed marker, for logs and telemetry. In tokenize mode it becomes an opaque reference that an injected vault Need returns, for prompts and immutable streams. Then `assembly/checked-command`, `state/event-log` and `state/audit-log` rows carry references, not raw personal data (owner decision of 2026-11-20). The vault is not in this Piece. The root acceptance (ELZ-286) wires the Need to `state/retention-erasure` (ELZ-279), a sibling at this level and not a dependency.

Detection is deterministic pattern matching, not classification. A text with no finding is not public data: the host still tags data classes for `domain/provider-data-policy` (ELZ-272). No I/O, clock, process or rehydration (reference to value) function.

## Interface

`Elzoo.PiiRedaction.redact(text, opts)` returns `{:ok, %{text: out, findings: findings}}` or `{:error, reason}` with `reason` in `:malformed | :too_many | :unavailable`.

- `text`: valid UTF-8, 0..65,536 bytes.
- `opts`: a keyword list with exactly `mode` (`:mask` or `:tokenize`) and `known` (a proper list of 0..64 valid UTF-8 values of 1..256 bytes). In `:tokenize` mode it also has exactly `vault`, an arity-2 Need called as `vault.(kind, span)` that returns `{:ok, ref}`. `ref` is 1..64 bytes of `[A-Za-z0-9_-]`. In `:mask` mode `vault` is refused.
- `findings`: `[%{kind: kind, count: n}]` with one entry for each kind found, in the kind order below. It never holds a span.

Kinds, in this fixed order: `:known`, `:email`, `:card`, `:phone`.

- `:known`: an exact byte occurrence of a `known` value. Matching is case sensitive, with no normalization.
- `:email`: an ASCII local part of 1..64 bytes of `[A-Za-z0-9._%+-]`, then `@`, then a domain of 2..127 labels. Each label is 1..63 bytes of `[A-Za-z0-9-]`, neither starting nor ending with `-`. The domain is at most 253 bytes and its last label is 2..63 letters. The match is maximal: the byte before the span is not in the local-part set, and the byte after it is not a label byte or a `.` followed by a label byte.
- `:card`: 13..19 digits, either contiguous or grouped by one kind of separator (single spaces or single hyphens). The span is neither preceded nor followed by a digit, and the digits pass the Luhn check.
- `:phone`: `+` followed by 8..15 digits (E.164 length), with optional single spaces or hyphens between digits, not followed by a digit.

Order of work:

1. Shape of `text` and `opts`, giving `:malformed`.
2. Each input occurrence of the five bytes `[pii:` is rewritten to `[pii_:`. So every `[pii:` in the output is a marker of this call.
3. Candidates of every kind are collected on the rewritten text. A leftmost start wins, then the longer span, then the earlier kind. The chosen findings never overlap and are taken from left to right. More than 256 findings gives `:too_many`.
4. In `:tokenize` mode `vault` is called exactly once for each distinct `{kind, span}`, in order of first occurrence, and only after step 3 passes. A raise, throw, exit, malformed result or invalid `ref` gives `:unavailable`, and no partial text is returned.
5. Each finding is replaced by `[pii:<kind>]` (mask) or `[pii:<kind>:<ref>]` (tokenize), where `<kind>` is `known`, `email`, `card` or `phone`.

The same text, options and Need answers give the same output. Scanners are linear in the text size: no regex with nested quantifiers or backtracking over unbounded alternatives. Errors are the fixed atoms and never echo the text. The Piece emits no telemetry and no log.

## Acceptance

1. Each kind is found and replaced in both modes, with counts: an email at the start, middle and end of a text and next to punctuation; a 13-, 16- and 19-digit card that passes Luhn, and the same digits with one changed (no finding); grouped cards with spaces and with hyphens, and a mixed-separator card (no finding); `+6281234567890`, `+62 812-3456-7890`, and 7 and 16 digits after `+` (no finding); a known value inside a word.
2. Boundaries: local part of 64 and 65 bytes; label of 63 and 64 bytes; domain of 253 and 254 bytes; a one-letter and a numeric last label (no finding); a digit directly before or after a card or phone span (no finding); text of 65,536 bytes passing and 65,537 refused; 64 and 65 known values; known values of 1, 256 and 257 bytes; invalid UTF-8 and a non-binary text are `:malformed`.
3. Overlap: a known value that contains an email, and an email whose local part is all digits and would be a card. Each case shows the leftmost-then-longest-then-kind rule, with no overlapping markers.
4. Escaping: an input that already holds `[pii:email:abc]` gives an output in which that text reads `[pii_:email:abc]`. Every `[pii:` in any output of groups 1–3 is a marker that the call emitted.
5. Vault Need: called once for each distinct `{kind, span}` (the same email twice gives one call and two equal markers), in first-occurrence order; never called for `:malformed` or `:too_many` (count the calls). A raise, throw, exit, `{:ok, "bad ref!"}`, a 65-byte ref and `:error` each give `:unavailable`. 256 findings pass and 257 give `:too_many`.
6. Adversarial size: 65,536-byte texts of `a@` repeated, `+1 ` repeated, one digit run, `[pii:` repeated and a long dotted domain each complete within the default ExUnit timeout. Record the measured time as an observation only.
7. Secrecy: for every refusal, no span byte appears in the result or a captured log.
8. Negative controls, one at a time: drop the Luhn check; drop the `[pii:` rewrite; call the vault before the `:too_many` check. Each must make a case of groups 1, 4 or 5 fail. Restore before the final gates.

Limits to state: listed patterns only, with no claim of completeness, names, addresses, national IDs or numbers without `+`. `known` values match exact bytes only. No rehydration, no data-class decision and no vault. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
