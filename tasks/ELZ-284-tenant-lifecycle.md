# ELZ-284 — Move a tenant through its lifecycle and consume one-use invitations as checked commands

- Phase: Wave 5 Level 3 (sub-level 3b)
- Dependencies: ELZ-033, ELZ-024, ELZ-249, ELZ-281
- Release: V1B
- Output: new `workflow/tenant-lifecycle` Piece
- Change class: Piece-only
- Owned paths: `pieces/workflow/tenant-lifecycle/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`domain/kill-switch`, `assembly/checked-command`, `domain/membership`, `state/retention-erasure`), `mix.exs`, `mix.lock` or CI.

## Why a Piece, not a composition

The wave plan made tenant lifecycle a composition with no kernel Piece. The owner then moved one-use invitations here as a durable checked command. Single use needs a durable compare-and-set, which `domain/membership` (ELZ-269) could not hold. Ready `assembly/checked-command` (ELZ-249) already has that compare-and-set: one append per command under the expected resource revision, retained results and replay. What is missing is reusable policy: the transition table, the invitation states, code-digest matching, the inviter's rights and the kill-switch coupling. Each needs adversarial tests and must be copyable into an application. That makes it a pure preparer Piece, like `state/conversation` (ELZ-250): no store, process or I/O of its own. The Wave 5 root acceptance (ELZ-286) remains the end-to-end composition with PostgreSQL, RunEngine and retention erasure.

## Outcome and boundary

One pure Piece in plain Elixir (Cure for the transition table where it fits; no new provider). `Elzoo.TenantLifecycle.prepare/3` is a CheckedCommand preparer over the tenant control resource that `domain/kill-switch` (ELZ-281) also uses. It reads and writes the `"lifecycle"` and `"invitations"` fields. On a transition that suspends or reactivates the tenant it also writes `"switches"`, through the public `Elzoo.KillSwitch.engage/2` and `release/2` with the reserved reason `lifecycle`. So the status and the switch that every gate checks change in one append. Other fields are kept by CheckedCommand's per-field writes.

Not in this Piece: storing memberships (the host applies an accepted invitation from the response or from the descriptor's outbox notice), erasing data (the host calls `state/retention-erasure` and reports it as a fact), sending invitation codes, and Oban jobs.

## Lifecycle

States: `provisioned`, `active`, `suspended`, `closing`, `erased`. An absent field is the state `none`.

| Command (`"op"`) | From | To | Switch with reason `lifecycle` |
| --- | --- | --- | --- |
| `provision` | `none` | `provisioned` | engaged (no work before activation) |
| `activate` | `provisioned`, `suspended` | `active` | released |
| `suspend` | `active` | `suspended` | engaged |
| `close` | `active`, `suspended` | `closing` | engaged (kept if already engaged); every pending invitation is removed |
| `erase` | `closing` | `erased` | kept |

`erase` also requires the trusted fact `vault_erased: true`. The host sets it only after `state/retention-erasure` reported every subject of the tenant `erased`. `erased` is terminal, and every command there is refused `terminal`. Another kill-switch reason (an operator's `incident` switch) is independent: `activate` does not release it.

## Invitations

The `"invitations"` field holds 0..32 pending invitations, sorted by ID. Each one is a portable record with `id`, `space`, `role`, `invitee` (`nil` or a principal ID), `code_digest` (`{:bytes, <<_::256>>}`), `expires_at` (Unix seconds) and `issued_by`.

- `invite` (status `active` only): the payload carries `id`, `space`, `role`, `invitee` and `expires_at`. The trusted facts carry `code_digest`, the SHA-256 of a random code that the host made and sends out of band, so the code never enters command history. They also carry `known_target: true` (the host checked that the space and role exist in the tenant) and `inviter_may_grant: true` (the host resolved, for example with `domain/membership`, that the inviter holds the permission it hands out). An existing ID is `duplicate`; a 33rd is `too_many`; `expires_at <= now` is `invalid_request`.
- `accept` (status `active` only): the payload carries `id`. The facts carry `presented_digest`, the SHA-256 of the code the accepter presented, and `now`. The accepter is the trusted `facts.actor`. The order of refusals:
  1. an absent ID is `unknown_invitation`, which covers a used, revoked or removed one;
  2. `now >= expires_at` is `expired`;
  3. a non-matching digest (compared with `:crypto.hash_equals/2`) is `bad_code`;
  4. an `invitee` other than the actor is `wrong_invitee`.

  On success the invitation is removed and the response is the membership record `%{principal: actor, space, role, valid_from: now, valid_to: nil}` in portable form.
- `revoke` (any status with invitations): it removes a pending invitation; an absent ID is `unknown_invitation`.

Single use follows from removal plus CheckedCommand's revision fencing. Two accepts with distinct operation IDs at one revision commit at most once; the other is retained as stale. A replay of the committed operation returns its first result. A digest mismatch commits nothing, and a refused accept leaves the invitation pending.

## Interface and bounds

`prepare(snapshot, request, facts)` follows the CheckedCommand preparer contract: it returns `{:ok, writes, response}` with 1..3 writes on `request.resource`, or `{:refused, code}`. The payload is a string-keyed map with `"op"` and that command's fields. `facts.data` is an exact portable record per command:

- `now` for every command;
- `vault_erased` for `erase`;
- `code_digest`, `known_target` and `inviter_may_grant` for `invite`;
- `presented_digest` for `accept`.

Refusal codes are fixed `[a-z0-9_]` texts, in this order: `invalid_request` (shape, including a malformed stored field), `terminal`, `invalid_transition`, `not_active`, `not_erased` (for `vault_erased` other than `true`), `not_permitted` (for `known_target` or `inviter_may_grant` other than `true`), then the invitation codes above. IDs, spaces, roles and principals follow the `domain/principal` text rule. Times are integers `0..2^63-1`, and digests are exactly 32 bytes. `Elzoo.TenantLifecycle.status(read)` returns `{:ok, state}` or `{:error, :unavailable}` from a `CheckedCommand.resource/3` result, for host checks such as "issue tokens only for an `active` tenant". The Piece emits no telemetry and no log.

## Acceptance

1. Transition table: every listed transition passes and writes the listed switch change through `Elzoo.KillSwitch`. Every other `(state, op)` pair is `invalid_transition` or `terminal`, enumerated exhaustively. `erase` without `vault_erased: true` is `not_erased`. After `suspend` and after `provision`, `Elzoo.KillSwitch.check/2` over the resulting fields denies `tenant_suspended`; after `activate` it allows. An `incident` switch engaged beside it survives `activate`, and its target stays denied.
2. Invitations, pure: invite and accept; each refusal in its order (an expired invitation with a bad code is `expired`; a bad code for another invitee is `bad_code`); `expires_at == now` is `expired` and `now + 1` passes; a 33rd invite is `too_many`; `close` removes every pending invitation; `revoke` then `accept` is `unknown_invitation`; no command history field holds a code (the code bytes appear in no request, write or response).
3. Composition on the Memory Store with a real CheckedCommand descriptor: provision, activate, invite and accept commit. Replay of the accept operation returns the same membership response. A second accept with a new operation ID at the new revision is `unknown_invitation`. Two accepts with distinct operation IDs prepared at one revision: one commits and the other has the retained stale result, with one membership response in total. A policy answering ASK for `suspend` mutates nothing until a distinct reviewer's once-evidence is released.
4. Shape: payloads with missing, extra or wrong-typed keys; texts at 0, 1, 128 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085; digests of 31 and 33 bytes; times at −1 and 2^63; stored fields that are unsorted, duplicate, oversized or use an unknown state. Each is `invalid_request`.
5. Negative controls, one at a time: keep an accepted invitation pending; skip the expiry check; let `activate` release every switch of the tenant rather than the `lifecycle` one; allow `erase` without `vault_erased`. Each must make a case of groups 1–3 fail. Restore before the final gates.

Limits to state: the host vouches for actor, inviter rights, target existence, erasure completion and time. A code's secrecy is the host's: SHA-256 without a key is enough only for a high-entropy random code, which the README requires to be at least 128 bits. There is no membership store, and the host applies the response or outbox notice at most once per command identity. No reminder, resend or expiry sweep: expired invitations stay until revoked or until `close`. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
