# domain/authorization

> **Stage 1 Contract draft (ELZ-024, issue #38).** No implementation exists yet.
> This file states the proposed Contract for early independent review. Nothing
> here is executed evidence. `piece.json` and the ledger row are added only with
> the implementation.

Pure decision for one proposed action: reduce an ordered list of typed policy
rules to **ALLOW**, **ASK** or **DENY**, after checking the proposal against the
proposer's current bounding authority. It returns the permitted writes, the
escrowed writes and an approval requirement. It never grants authority and
never records consent. Consent lives in the separate
[`workflow/approval`](../../workflow/approval/README.md) Piece.

This Piece is a decision policy. It is **not** a security certification, an
identity guarantee, authentication, a principal service, a policy-engine
provider or durable storage.

## Callers and product aims

- P03/C5 human review and P07/C6 agent publication / child-run authority.
- C3 refund approval and C1 invitation challenge generality with different
  rules, expiry and settlement; they share this mechanism, not its policy.

## Preflight acknowledgments (docs/plans/preflight.md)

The B24 decisions are binding. This Contract adopts them without change:

| Decision | How this Contract holds it |
| --- | --- |
| **B24.1** structural exact-action binding | Portable value domain and write set below; structural equality of validated, normalized values; no JSON/BEAM term hash for binding; duplicate-preserving record input; finite bounds rejected before evaluation; policy identity `(id, version, content_hash)` from trusted config; conflicting writes fail closed; identical duplicates coalesce. |
| **B24.3** current authority outside proposals | Own authority and parent effective authority are separate trusted inputs; child bound is the intersection; whole-proposal rejection on containment failure; three distinct failure classes; re-evaluation at release/restore (called by `workflow/approval`). |
| **B24.2** evidence/time/scope | Owned by `workflow/approval`. This Piece supplies the re-evaluation and containment functions that B24.2 release and restore call. |

## Portable value domain (B24.1)

Values cross the Elixir boundary as **tagged** terms, so no type is guessed or
coerced:

| Input term | Meaning |
| --- | --- |
| `nil` | null |
| `true`, `false` | boolean |
| integer | integer (any size inside the byte bound) |
| `{:text, binary}` | valid UTF-8 text; **not** normalized (no NFC/NFD, no case fold) |
| `{:bytes, binary}` | byte string; never equal to text with the same bytes |
| `{:list, [value]}` | ordered list; compared in order |
| `{:record, [{name, value}]}` | record; `name` is valid UTF-8 text; input is a **duplicate-preserving list of pairs** |

Rejected before evaluation, with `{:invalid_input, reason}`: floats, atoms other
than `nil`/`true`/`false`, maps, tuples of another shape, pids, refs, ports,
functions, improper lists, invalid UTF-8, a duplicate record field name, and
any bound exceeded. A record is checked for duplicate names **before** it is
built; a caller cannot satisfy this rule with a pre-collapsed map. External
decoders (for example JSON) must also reject duplicate object keys before a
lossy map conversion; that is a consumer Need, not something this Piece can
detect after the fact.

Normalization: record fields are sorted by the UTF-8 byte order of their
names; lists keep their order; nothing else changes. Two values are equal
when their normalized forms are structurally equal. Integers, text, bytes and
booleans stay distinct (`1 != {:text, "1"} != true`).

### Finite bounds

Fixed Contract constants (not Config). Exceeding one is
`{:invalid_input, {:bound_exceeded, name}}`; values are never truncated.

| Bound | Value |
| --- | --- |
| value nesting depth | 16 |
| nodes in one value (every scalar, list, record and field counts) | 4096 |
| bytes of one text, bytes or field name | 4096 |
| integer magnitude | `abs(n) < 2^256` |
| writes in one proposal (before coalescing) | 256 |
| entries in one authority set (before coalescing) | 4096 |
| rules in one policy | 1024 |
| effect classes in one policy | 256 |

## Schemas

All identities (proposer, tenant, resource, action id, target, field, effect
class, rule id, policy id, requirement name) are nonempty valid UTF-8 text,
compared by exact byte equality without normalization. An identity proves
nothing about authenticity, uniqueness or authority.

**Write**: `%{target: text, field: text, value: value}`.

**Write set** (proposal writes and every authority set use the same rule):
validate each entry; coalesce structurally identical entries; two entries with
the same `(target, field)` and different values are a **conflict** and fail
closed with `{:invalid_input, {:conflicting_writes, target, field}}` (never
last-write-wins); sort by UTF-8 byte order of `(target, field)`. Input order
and identical duplication do not change the result.

An authority set is a finite set of exact permitted writes `(target, field,
value)`. There is no wildcard in authority. (A wildcard grant would make the
subset law depend on pattern semantics; a future ID may add it.)

**Proposal** (exact keys, all required):

```elixir
%{
  proposer: text, tenant: text, resource: text,
  action_id: text,          # stable action identity
  effect_class: text,       # must be one of the policy's declared classes
  payload: value,           # business data; never a control channel
  writes: [write]
}
```

A proposal map that carries any of the control keys `:policy`, `:authority`,
`:bounding_authority`, `:parent_authority`, `:approval`, `:approvals`,
`:evidence`, `:verifier` or `:decision` is **denied** as a proposal: the result
is a DENY decision with reason `{:control_field, key}` and no writes (issue:
"deny as a proposal any proposal that carries its own policy, bounding authority
or approval"). Any other unknown key is `{:invalid_input, {:unknown_field, key}}`.
Payload content is data only. A payload record named `"approved"`, or text
such as `"approved"` from a model, has no control meaning anywhere.

**Policy** (trusted configuration, never from a proposal):

```elixir
%{
  id: text, version: pos_integer, content_hash: <<_::256>>,  # host-supplied SHA-256
  effect_classes: [text],
  rules: [%{
    id: text,
    effect_class: text,                    # exact typed class
    target: :any | {:exact, text},
    field: :any | {:exact, text},
    verdict: :allow | :ask | :deny,
    requirement: nil | %{name: text, version: pos_integer, scope: :once | :run | :root}
  }]
}
```

`requirement` is required exactly when `verdict` is `:ask`. The host computes
`content_hash` over its immutable versioned policy artifact. This Piece
compares and carries the identity triple; it does not compute the digest,
authenticate the host or prove the digest's origin. No executable policy DSL,
no text pattern, no regular expression and no string denylist exists: rules
match only exact typed effect class and exact or `:any` target/field.

A malformed policy (bad shape, duplicate rule id, unknown effect class in a
rule, ASK without requirement, bound exceeded) is
`{:unavailable_context, {:invalid_policy, reason}}`.

## Decision algorithm

`decide(policy, proposal, authority_context)`:

1. Validate trusted context: policy, `own` authority and, for a child,
   `parent` effective authority. Missing or invalid context →
   `{:error, {:unavailable_context, reason}}`. Never an empty ALLOW.
2. Validate the proposal (control keys → DENY as above; other faults →
   `{:error, {:invalid_input, reason}}`). The effect class must be declared
   by the policy.
3. **Containment (B24.3).** The proposal's normalized write set must be a
   subset of `own`, and, for a child, also a subset of `parent`. Being a
   subset of both is exactly being a subset of their intersection, which is
   the child's effective authority. A violation rejects the **whole proposal**:
   DENY with reason `:authority_exceeded`, no permitted and no escrowed writes.
   The proposal is never trimmed to fit.
4. **Per-write verdict.** For each write, take every rule whose effect class
   equals the proposal's and whose target/field match. Join their verdicts.
   No matching rule → DENY for that write (reason `:no_matching_rule`;
   default deny).
5. **Action verdict** = join of all per-write verdicts with
   `deny > ask > allow`. An empty write set is ALLOW with no writes (a
   read-only or no-op action still passes containment trivially).
6. **Shape.** ALLOW → `permitted = writes`, `escrowed = []`. ASK →
   `permitted = []`, `escrowed = writes` (the whole action waits; no partial
   execution). DENY → both empty.
7. **Requirement.** For ASK, the requirement is the one carried by the
   matching ASK rules. If matching ASK rules name more than one distinct
   `(name, version, scope)`, the decision fails closed with
   `{:unavailable_context, {:ambiguous_requirement, list}}` (see open
   question Q1).

Result:

```elixir
{:ok, %{
  verdict: :allow | :ask | :deny,
  reason: :allowed | {:ask, requirement} | {:rule, rule_id} | :no_matching_rule
          | :authority_exceeded | {:control_field, key},
  policy: %{id: _, version: _, content_hash: _},   # on every decision
  action: normalized_proposal,                       # structural binding data
  permitted: [write], escrowed: [write],
  requirement: nil | requirement,
  rules: [rule_id]                                   # contributing rules, policy order
}}
| {:error, {:invalid_input, reason}}
| {:error, {:unavailable_context, reason}}
```

The three failure classes stay distinct: policy DENY (an `:ok` decision),
invalid input, unavailable context. A denial is a result for the proposer and
a retained record for the owner; retention is caller-owned and is not
telemetry.

`proposer_view(decision, disclosure)` with `disclosure :: :full | :verdict_only`
returns what the Assembly chooses to show the proposer (issue: a declared
Assembly setting). `:verdict_only` hides reasons, rule ids and requirement.

### Order of the policy list

The join is commutative, associative and idempotent, so the **verdict** does
not depend on rule order. Rule order fixes the presentation order of
`rules` and is part of the policy content (and so of its hash).

## Concrete API

Elixir boundary (`pieces/domain/authorization/lib/elzoo/authorization.ex`):

```elixir
Elzoo.Authorization.validate_policy(map) :: {:ok, policy} | {:error, {:unavailable_context, r}}
Elzoo.Authorization.validate_authority([write]) :: {:ok, authority} | {:error, {:unavailable_context, r}}
Elzoo.Authorization.validate_proposal(map) :: {:ok, proposal} | {:deny, reason} | {:error, {:invalid_input, r}}
Elzoo.Authorization.decide(policy_map, proposal_map, %{own: [write], parent: [write] | :none})
Elzoo.Authorization.proposer_view(decision, :full | :verdict_only)
Elzoo.Authorization.same_action?(normalized_a, normalized_b) :: boolean   # structural
```

The Elixir layer validates, normalizes and encodes; the decision itself runs
in Cure. Text and bytes enter Cure as tagged lists of byte integers (the
pinned kernel reduces integer equality but not `String` equality inside
proofs; this was probed on the pinned commit). Cure source
(`pieces/domain/authorization/cure/elzoo/authorization.cure`,
`mod Elzoo.Authorization`):

```cure
type Verdict = Allow | Ask | Deny
type Value = VNull | VBool(Bool) | VInt(Int) | VText(List(Int)) | VBytes(List(Int))
           | VList(List(Value)) | VRecord(List(Field))
type Field = FieldOf(List(Int), Value)
rec Write   target: List(Int), field: List(Int), value: Value
rec Rule    id, effect_class, target: Match, field: Match, verdict: Verdict, requirement: Option(Requirement)
rec Policy  identity: PolicyIdentity, rules: List(Rule)
rec Action  proposer, tenant, resource, action_id, effect_class, payload: Value, writes: List(Write)
rec Outcome verdict: Verdict, reason: Reason, permitted: List(Write), escrowed: List(Write), requirement: Option(Requirement)

fn join(a: Verdict, b: Verdict) -> Verdict
fn join_all(vs: List(Verdict)) -> Verdict
fn eq_value / eq_write / eq_action -> Bool        # total structural equality
fn subset(xs: List(Write), ys: List(Write)) -> Bool
fn decide(policy: Policy, action: Action, own: List(Write), parent: Option(List(Write))) -> Outcome
```

Module and fixture names may change during implementation; the semantics
above may not.

## Selected laws (Cure-checked)

Checked on the actual production `join`, `join_all`, `shape` and `decide`
functions by pinned Cure, with negative controls (a mutated production source
must be rejected) and a clean `Cure.Audit.Ledger` report:

| Law | Statement |
| --- | --- |
| `deny_absorbs_left/right` | `join(Deny, v) = Deny`, `join(v, Deny) = Deny` for all `v` |
| `ask_over_allow` | `join(Ask, Allow) = Ask = join(Allow, Ask)` |
| `join_comm`, `join_assoc`, `join_idem` | exhaustive over the 3 verdicts |
| `deny_anywhere` | for all lists `p`, `s`: `join_all(p ++ [Deny | s]) = Deny` (induction) |
| `reduced_dominates` | for all `p`, `v`, `s`: `join(join_all(p ++ [v | s]), v) = join_all(p ++ [v | s])` (induction): the action verdict is at least every per-write verdict |
| `ask_escrows`, `deny_empty`, `allow_no_escrow` | for all writes: ASK shape has `permitted = []`, `escrowed = writes`; DENY has both `[]`; ALLOW has `escrowed = []` |
| `permitted_within_own`, `escrowed_within_own` | for all policy, action, `own`, `parent`: `subset(permitted(decide(...)), own) = True`, likewise escrowed |
| `permitted_within_parent`, `escrowed_within_parent` | same with `parent` (child non-escalation) |

A feasibility probe of `deny_anywhere` and `permitted_within_parent` shapes
compiled on the pinned commit with a clean audit. That probe is not evidence
for this Piece; the laws must pass again on the production source.

## Finite tests (not proofs)

- Validation: every rejected value kind; duplicate record names in pair input;
  text vs bytes vs integer vs boolean distinct; no Unicode normalization;
  each bound at limit (accepted) and limit + 1 (rejected, no truncation).
- Write sets: reorder and identical duplicates give the same normalized set;
  conflicting values for one `(target, field)` fail closed.
- Elixir normalization agrees with Cure `eq_value` on listed cases.
- Containment: over-authority proposal rejected whole (no trimming); child
  within own but outside parent rejected.
- Control keys in a proposal → DENY; model text `"approved"` in payload has no
  effect; a static tool permission or route match passed as payload is data.
- Missing/invalid policy or authority → `unavailable_context`, distinct from
  DENY and from `invalid_input`.
- Ambiguous ASK requirement fails closed.
- `proposer_view` disclosure modes.

## Ash reuse division (ELZ-015)

The ELZ-015 spike (`spikes/ash_foundation`) shows Ash policies answering
direct allow/deny for resource actions (`authorize_if` on actor role and
tenant). When a consumer uses Ash, Ash keeps that job. Ash policies have no
ASK verdict, no escrowed write set, no exact-payload consent and no scoped
consent memory. This Piece authors only that remainder. A consumer may call
this Piece from an Ash action, or translate an Ash decision into an input, in
its own Adapter. No Ash dependency is added to this pure bundle, and this
Piece is not a second resource policy engine.

## Operational applicability

- **Telemetry:** `not_applicable`. Pure callable; the invoking Unit/Assembly
  owns instrumentation. Decisions are retained records owned by the caller,
  not telemetry.
- **Config:** `supported` (per call). Policy and authority are trusted
  per-call inputs; `proposer_view` disclosure is a per-call Assembly setting.
  No hot reconfiguration. Bounds are fixed Contract constants.
- **Control:** `not_applicable`. No lifecycle.

## Needs, assumptions and unspecified behavior

Needs of the consumer: authentication and identity mapping; a trusted host
that derives proposer/approver authority from its own state; the immutable
policy artifact and its SHA-256; a duplicate-rejecting decoder for external
data; serialization of decisions with any state it guards.

Unspecified: concurrency (pure; the caller serializes); durability;
clock behavior (no time input here); meaning of identities beyond equality;
which product writes a target/field denotes.

## Dependencies

Pieces: none at runtime. It consumes `core/envelope` and `core/port`
unchanged only where a consumer carries a decision in an Envelope payload
(opaque) behind its own schema id; no Envelope/Port field is extended.
Providers: pinned Cure `a004c335cc4e9f2203ba6f51fc31e8540b66378d`, Elixir
1.20.4, OTP 29.1.2.

## Open questions for review

- **Q1.** Multiple distinct ASK requirements in one decision fail closed.
  Alternative: request every requirement and release only when all are
  approved. Fail-closed is simpler; it may be too strict for C3.
- **Q2.** Control keys yield a DENY decision (issue wording) rather than
  `invalid_input`. Confirm.
- **Q3.** Authority is exact writes only (no `:any` value). Confirm this is
  enough for C6/C3 first callers.
