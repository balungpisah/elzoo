# domain/authorization

> **Stage 1 Contract draft, revision 2 (ELZ-024, issue #38).** No
> implementation exists yet. Revision 2 resolves early review findings 1–11
> ([review](https://github.com/balungpisah/elzoo/issues/38#issuecomment-6694306514)).
> Nothing here is executed evidence. `piece.json` and the ledger row are added
> only with the implementation.

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
| **B24.3** current authority outside proposals | Proposer identity, effect class, own authority and parent effective authority are trusted inputs outside the proposal; child bound is the intersection; whole-proposal rejection on containment failure; three distinct failure classes; re-evaluation at release/restore (Cure `release` calls Cure `decide`). |
| **B24.2** evidence/time/scope | Owned by `workflow/approval`. This Piece supplies the Cure `decide` function that B24.2 release and restore call. |

## Portable value domain (B24.1)

Values cross the Elixir boundary as **tagged** terms, so no type is guessed or
coerced:

| Input term | Meaning |
| --- | --- |
| `nil` | null |
| `true`, `false` | boolean |
| integer | integer (inside the magnitude bound) |
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
`{:invalid_input, {:bound_exceeded, name}}` for proposal data and
`{:unavailable_context, {:bound_exceeded, name}}` for trusted context. Values
are never truncated.

| Bound | Value |
| --- | --- |
| value nesting depth | 16 |
| nodes in one value (every scalar, list, record and field counts) | 4096 |
| bytes of one text, bytes value or record field name | 4096 |
| bytes of one identity text (proposer, tenant, resource, action id, target, field, effect class, rule id, policy id, requirement name) | 1024 |
| integer magnitude in a value | `abs(n) < 2^256` |
| writes in one proposal (before coalescing) | 256 |
| entries in one authority set (before coalescing) | 4096 |
| rules in one policy | 1024 |
| effect classes in one policy | 256 |
| policy `version`, requirement `version` | integer `1..2^31-1` |
| policy `content_hash` | exactly 32 bytes |

## Schemas

All identities (proposer, tenant, resource, action id, target, field, effect
class, rule id, policy id, requirement name) are nonempty valid UTF-8 text,
compared by exact byte equality without normalization. An identity proves
nothing about authenticity, uniqueness or authority.

**Write**: `%{target: text, field: text, value: value}`.

**Write set** (proposal writes and every authority set use the same rule):
validate each entry; coalesce structurally identical entries; two entries with
the same `(target, field)` and different values are a **conflict** and fail
closed (`{:invalid_input, {:conflicting_writes, target, field}}` in a proposal,
`{:unavailable_context, {:conflicting_authority, target, field}}` in an
authority set); never last-write-wins. Sort by UTF-8 byte order of
`(target, field)`. Input order and identical duplication do not change the
result.

An authority set is a finite set of exact permitted writes `(target, field,
value)`. Because the conflict rule applies to authority sets, an authority
set holds **at most one value per `(target, field)`**. There is no wildcard in
authority. The host therefore builds exact-value authority for each action
(for example the exact refund amount). This is a recorded limit (see
"Interface deltas"); a wildcard or range authority needs a new Piece ID.

**Authority context** (trusted; supplied by the owning caller from its own
state, never from the proposal):

```elixir
%{
  proposer: text,         # trusted principal identity of the proposer (F1)
  effect_class: text,     # derived by the host, e.g. from tool/route identity (F2)
  own: [write],           # proposer's current authority
  parent: [write] | :none # current parent effective authority, for a child Run
}
```

**Proposal** (exact keys):

```elixir
%{
  tenant: text, resource: text,      # required
  action_id: text,                   # required, stable action identity
  payload: value,                    # required; business data, never a control channel
  writes: [write],                   # required
  proposer: text,                    # optional, binding copy only
  effect_class: text                 # optional, binding copy only
}
```

`proposer` and `effect_class` in a proposal are never trusted. If present,
each must equal the trusted value exactly; otherwise the **whole proposal** is
rejected with `{:invalid_input, :proposer_mismatch}` or
`{:invalid_input, :effect_class_mismatch}`. The normalized action always
carries the **trusted** proposer and effect class. The trusted effect class
must be declared by the policy, else
`{:unavailable_context, :undeclared_effect_class}`.

Control keys. A proposal map with an atom key `:policy`, `:authority`,
`:bounding_authority`, `:parent_authority`, `:approval`, `:approvals`,
`:evidence`, `:verifier` or `:decision` is **denied** as a proposal (issue:
"deny as a proposal any proposal that carries its own policy, bounding
authority or approval"). This check runs only after the trusted context is
valid, and the DENY carries the current policy identity, reason
`{:control_field, key}` and no writes. A **string** key such as `"policy"` (or
any other key that is not an atom of the schema) is
`{:invalid_input, {:unknown_field, key}}`. Both fail closed with no writes; only
the reason class differs. Payload content is data only. A payload record named
`"approved"`, or text such as `"approved"` from a model, has no control meaning.

**Policy** (trusted configuration, never from a proposal):

```elixir
%{
  id: text, version: 1..2^31-1, content_hash: <<_::256>>,  # host-supplied SHA-256
  effect_classes: [text],
  rules: [%{
    id: text,
    effect_class: text,                  # exact typed class (required)
    principal: :any | {:exact, text},    # trusted proposer identity (F9)
    tenant: :any | {:exact, text},       # F9
    resource: :any | {:exact, text},     # F9
    payload: :any | {:exact, value},     # F9, structural equality
    target: :any | {:exact, text},
    field: :any | {:exact, text},
    value: :any | {:exact, value},       # F9, write value, structural equality
    verdict: :allow | :ask | :deny,
    requirement: nil | %{name: text, version: 1..2^31-1, scope: :once | :run | :root}
  }]
}
```

Omitted condition keys mean `:any`. `requirement` is required exactly when
`verdict` is `:ask`. The host computes `content_hash` over its immutable
versioned policy artifact. This Piece compares and carries the identity
triple; it does not compute the digest, authenticate the host or prove the
digest's origin. No executable policy DSL, text pattern, regular expression,
string denylist, range or comparison operator exists: every condition is an
exact typed match or `:any`.

A malformed policy (bad shape, duplicate rule id, rule effect class not
declared, ASK without requirement, requirement on a non-ASK rule, bound
exceeded) is `{:unavailable_context, {:invalid_policy, reason}}`.

## Decision algorithm

`decide(policy, proposal, authority_context)`:

1. Validate trusted context: policy, proposer identity, effect class, `own`
   and, for a child, `parent`. Missing or invalid context →
   `{:error, {:unavailable_context, reason}}`. Never an empty ALLOW.
2. Validate the proposal: control atom keys → DENY (above); other faults,
   including proposer/effect-class mismatch → `{:error, {:invalid_input,
   reason}}`.
3. **Containment (B24.3).** The proposal's normalized write set must be a
   subset of `own` and, for a child, also of `parent` (subset with respect to
   `eq_write`). Being a subset of both is exactly being a subset of their
   intersection, the child's effective authority. A violation rejects the
   **whole proposal**: DENY, reason `:authority_exceeded`, no permitted and no
   escrowed writes. The proposal is never trimmed to fit.
4. **Per-write verdict.** For each write, take every rule whose effect class
   equals the trusted class and whose principal, tenant, resource, payload,
   target, field and value conditions match. Join their verdicts. No matching
   rule → DENY for that write (reason `:no_matching_rule`; default deny).
5. **Action verdict** = join of all per-write verdicts with
   `deny > ask > allow`. An empty write set is ALLOW with no writes.
6. **Shape.** ALLOW → `permitted = writes`, `escrowed = []`. ASK →
   `permitted = []`, `escrowed = writes` (the whole action waits; no partial
   execution). DENY → both empty.
7. **Requirement.** For ASK, the requirement is the one carried by the
   matching ASK rules. More than one distinct `(name, version, scope)` fails
   closed with `{:unavailable_context, {:ambiguous_requirement, list}}`.

Result:

```elixir
{:ok, %{
  verdict: :allow | :ask | :deny,
  reason: :allowed | {:ask, requirement} | {:rule, rule_id} | :no_matching_rule
          | :authority_exceeded | {:control_field, key},
  policy: %{id: _, version: _, content_hash: _},   # on every decision
  action: normalized_action,                         # trusted proposer + class; binding data
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

The join is commutative, associative and idempotent, so the **verdict** does
not depend on rule order. Rule order fixes the presentation order of `rules`
and is part of the policy content (and so of its hash).

## Cure/Elixir split (F3)

| Function | Runs in | Grounding |
| --- | --- | --- |
| Value/write/authority/policy/proposal validation, duplicate-pair check, bounds, UTF-8 check | Elixir `Elzoo.Authorization` | finite tests |
| Normalization (field sort, coalesce, conflict detection, `(target, field)` sort) | Elixir | finite tests |
| Encoding to Cure terms (text/bytes → tagged byte-integer lists) and decoding of results | Elixir | finite tests, incl. named Elixir↔Cure agreement test |
| Proposer/effect-class mismatch, control-key DENY, undeclared class | Elixir (before Cure) | finite tests |
| `eq_value`, `eq_write`, `eq_action`, `member`, `subset` | Cure | constructor-distinctness laws; agreement test |
| rule matching, per-write verdict, `join`, `join_all`, containment, `shape`, requirement selection, `decide` | Cure | selected laws below |
| `proposer_view` | Elixir | finite tests |

Elixir `decide/3` only validates, encodes, calls Cure `decide` and decodes.
It does not compute any verdict, containment or write set itself.

Cure source `pieces/domain/authorization/cure/elzoo/authorization.cure`
(`mod Elzoo.Authorization`). Text and bytes enter Cure as tagged lists of byte
integers: the pinned kernel reduces `Int` equality inside proofs but not
`String` or derived `==`, so all Cure equality is hand-written and total.

```cure
type Verdict = Allow | Ask | Deny
type Value = VNull | VBool(Bool) | VInt(Int) | VText(List(Int)) | VBytes(List(Int))
           | VList(List(Value)) | VRecord(List(Field))
type Field = FieldOf(List(Int), Value)
type Match(t) = Any | Exact(t)
rec Write   target: List(Int), field: List(Int), value: Value
rec Rule    id, effect_class, principal, tenant, resource, payload, target, field, value, verdict, requirement
rec Policy  identity: PolicyIdentity, rules: List(Rule)
rec Action  proposer, tenant, resource, action_id, effect_class, payload: Value, writes: List(Write)
rec Outcome verdict: Verdict, reason: Reason, permitted: List(Write), escrowed: List(Write), requirement: Option(Requirement)
type FailureClass = InvalidInput | UnavailableContext
type DecideResult = Decided(Outcome) | DecideFailed(FailureClass, FailureCode)

fn decide(policy: Policy, action: Action, own: List(Write), parent: Option(List(Write))) -> DecideResult
fn permitted_of(r: DecideResult) -> List(Write)   # [] for DecideFailed
fn escrowed_of(r: DecideResult) -> List(Write)    # [] for DecideFailed
```

Cure `decide` reports only failures it can detect on already validated input
(today: `DecideFailed(UnavailableContext, AmbiguousRequirement)`); Elixir maps
`DecideFailed` to the matching `{:error, {class, reason}}`. Module and fixture
names may change; the semantics above may not.

## Selected laws (Cure-checked)

Checked on the production Cure functions by pinned Cure, with negative
controls (a mutated production source must be rejected) and a clean
`Cure.Audit.Ledger` report. **Every subset law is with respect to Cure
`eq_write`.** If `eq_write` were too loose, a law could pass while escalating;
the constructor-distinctness laws and the named agreement test bound that
risk; they do not prove `eq_write` is exactly structural equality.

| Law | Cure function | Statement |
| --- | --- | --- |
| `deny_absorbs_left/right` | `join` | `join(Deny, v) = Deny`, `join(v, Deny) = Deny` for all `v` |
| `ask_over_allow_left/right` | `join` | `join(Ask, Allow) = Ask = join(Allow, Ask)` |
| `join_comm`, `join_assoc`, `join_idem` | `join` | exhaustive over the 3 verdicts |
| `deny_anywhere` | `join_all` | for all `p`, `s`: `join_all(p ++ [Deny \| s]) = Deny` (induction) |
| `reduced_dominates` | `join_all` | for all `p`, `v`, `s`: `join(join_all(p ++ [v \| s]), v) = join_all(p ++ [v \| s])` (induction) |
| `ask_escrows`, `deny_empty`, `allow_no_escrow` | `shape` | for all writes: ASK → `permitted = []`, `escrowed = writes`; DENY → both `[]`; ALLOW → `escrowed = []` |
| `permitted_within_own`, `escrowed_within_own` | `decide` | for all policy, action, `own`, `parent`: `subset(permitted_of(decide(...)), own) = True`, likewise escrowed |
| `permitted_within_parent`, `escrowed_within_parent` | `decide` | for all policy, action, `own`, `p`: `subset(permitted_of(decide(policy, action, own, Some(p))), p) = True`, likewise escrowed |
| `text_ne_bytes`, `bytes_ne_text`, `int_ne_text`, `text_ne_int`, `int_ne_bool`, `bool_ne_int`, `bool_ne_text`, `null_ne_*`, `list_ne_record`, `record_ne_list` | `eq_value` | e.g. `eq_value(VText(x), VBytes(y)) = False` for all `x`, `y` (by reduction) |

`deny_anywhere` and `reduced_dominates` are about `join_all` over any verdict
list; `decide` applies `join_all` to its per-write verdict list. That
composition is by construction of the production source, reviewed, and
covered by tests; no separate law states "decide's verdict equals join_all of
its rule verdicts". A feasibility probe of these law shapes compiled on the
pinned commit with a clean audit; that probe is not evidence for this Piece.

## Finite tests (not proofs)

- Validation: every rejected value kind; duplicate record names in pair input;
  text vs bytes vs integer vs boolean distinct; no Unicode normalization;
  each bound at limit (accepted) and limit + 1 (rejected, no truncation).
- Write sets: reorder and identical duplicates give the same normalized set;
  conflicting values for one `(target, field)` fail closed in a proposal and
  in an authority set.
- **Elixir↔Cure agreement** (named test): Elixir structural equality of
  normalized values agrees with Cure `eq_value` on a listed corpus, including
  text/bytes with equal bytes and records with reordered input.
- Containment: over-authority proposal rejected whole (no trimming); child
  within own but outside parent rejected.
- **Forged proposer**: a proposal whose `proposer` differs from the trusted
  identity is rejected as `:proposer_mismatch`; the decision always binds the
  trusted proposer.
- **Mislabelled effect class**: policy `publish → ASK`, `read any/any →
  ALLOW`; host derives `publish`; a proposal labelled `read` is rejected as
  `:effect_class_mismatch`, and a proposal without a label is ASK, never ALLOW.
- Rule conditions on principal, tenant, resource, payload and write value
  change the verdict as declared (for example `value: {:exact, 500}` → ASK,
  other amounts unmatched → default DENY).
- Control atom keys → DENY with policy identity; string `"policy"` →
  `invalid_input`; model text `"approved"` in payload has no effect; a static
  tool permission or route match passed as payload is data.
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
- **Config:** `supported`, per call, no default, no hot reconfiguration:
  - `policy` — the schema above, with its bounds; immutable per
    `(id, version, content_hash)`;
  - `disclosure` — `:full | :verdict_only`, for `proposer_view/2`.
  Bounds are fixed Contract constants, not Config.
- **Data, not Config:** the proposal, the authority context (proposer,
  effect class, own, parent).
- **Control:** `not_applicable`. No lifecycle.

## Needs, assumptions and unspecified behavior

Needs of the consumer: authentication and identity mapping that yield the
trusted proposer identity; a host that derives the effect class from tool or
route identity and derives authority from its own state; the immutable
policy artifact and its SHA-256; a duplicate-rejecting decoder for external
data; serialization of decisions with any state they guard.

Unspecified: concurrency (pure; the caller serializes); durability; clock
behavior (no time input here); meaning of identities beyond equality; which
product writes a target/field denotes.

## Dependencies

Pieces: none at runtime. It consumes `core/envelope` and `core/port`
unchanged only where a consumer carries a decision in an Envelope payload
(opaque) behind its own schema id; no Envelope/Port field is extended.
Providers: pinned Cure `a004c335cc4e9f2203ba6f51fc31e8540b66378d`, Elixir
1.20.4, OTP 29.1.2.

## Limits

- **Single requirement (Q1).** An ASK with more than one distinct requirement
  fails closed. Multi-approver flows (for example some C3 refunds) need a new
  Piece ID.
- **Exact-value authority (Q3).** Authority holds one exact value per
  `(target, field)`; the host builds exact-value authority per action.
- Subset laws hold with respect to `eq_write`; agreement with Elixir
  structural equality is a finite test.
- No security certification, identity guarantee or authentication.

## Interface deltas vs #38

Each item refines or makes concrete an #38 statement; none removes an #38
input, output or acceptance item.

| # | #38 text | This Contract | Reason |
| --- | --- | --- | --- |
| D1 | inputs include "principal" | proposer identity is trusted context; proposal copy must match or is rejected (`:proposer_mismatch`) | F1: self-approval bypass via forged proposer |
| D2 | "gate on typed effect class, not text" | effect class is host-derived trusted context; proposal copy must match (`:effect_class_mismatch`) | F2: mislabelled class could turn ASK into ALLOW |
| D3 | "decide, from principal, tenant, resource, action payload and policy version" | rules match exact principal, tenant, resource, payload and write value, plus effect class, target and field; policy version is in the identity triple bound and rechecked | F9: verdict can depend on every listed input |
| D4 | "bounding authority (the permitted-write set …)" | exact writes, one value per `(target, field)`, no wildcard | B24.3 + conflict rule; Q3 limit |
| D5 | "ASK holding proposed writes in escrow" | whole-action escrow: ASK permits nothing until release | no partial execution of one action |
| D6 | ASK requirement | one requirement per ASK; several distinct → fail closed | Q1 limit; multi-approver needs new ID |
| D7 | "deny as a proposal any proposal that carries its own policy, bounding authority or approval" | atom control keys → DENY with policy identity; string keys → `invalid_input` | F11/Q2: both fail closed; the reason class differs |
| D8 | DENY reasons / ASK prompts shown "is a declared Assembly setting" | `proposer_view/2` with per-call `disclosure` | makes the setting concrete |
| D9 | "implement the pure reducer … in Cure" | validation/normalization/encoding in Elixir; all decisions in Cure; text as byte-integer lists; laws relative to `eq_write` | F3/F8; pinned Cure cannot reduce `String` equality in proofs |
| D10 | approval scope "once, run, root" | scope comes from the ASK rule's requirement; evidence scope must equal it (approval Piece) | Q4 |
| D11 | release / restore | approval adds `revalidate/3` for restored released records and returns the current decision's escrow at release | F7 and restore (approval Piece) |
