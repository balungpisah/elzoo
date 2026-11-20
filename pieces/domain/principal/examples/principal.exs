# SPDX-License-Identifier: Apache-2.0
alias Elzoo.Principal

# The host builds a principal only after its own authentication, for example ELZ-268 token verification.
{:ok, alice} =
  Principal.new(%{
    kind: :human,
    id: "alice",
    tenant: "acme",
    auth_epoch: 3,
    allowed_scopes: ["read", "write"],
    allowed_spaces: ["docs"]
  })

# An agent acts for alice with part of her authority.
{:ok, bot} =
  Principal.delegate(alice, %{id: "alice-bot", allowed_scopes: ["read"], allowed_spaces: ["docs"]})

# The host supplies the parent's current epoch and the revoked IDs it holds.
ok = Principal.check(bot, %{current_epoch: 3, revoked_ids: []})

# A request beyond the parent is refused whole; an agent cannot delegate again.
escalation =
  Principal.delegate(alice, %{
    id: "alice-bot",
    allowed_scopes: ["read", "admin"],
    allowed_spaces: ["docs"]
  })

nested = Principal.delegate(bot, %{id: "bot-2", allowed_scopes: [], allowed_spaces: []})

# Revoking alice revokes her agent; an agent is not a human.
revoked = Principal.check(bot, %{current_epoch: 3, revoked_ids: ["alice"]})
not_human = Principal.require_human(bot)

[ok, escalation, nested, revoked, not_human]
