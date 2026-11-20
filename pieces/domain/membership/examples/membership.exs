# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{Membership, Principal}

# The host builds the principal from its own authenticated state and has already
# called Principal.check/2 with the real epoch and revoked IDs.
{:ok, alice} =
  Principal.new(%{
    kind: :human,
    id: "alice",
    tenant: "acme",
    auth_epoch: 3,
    allowed_scopes: ["read"],
    allowed_spaces: ["finance"]
  })

{:ok, bot} =
  Principal.delegate(alice, %{
    id: "alice-bot",
    allowed_scopes: ["read"],
    allowed_spaces: ["finance"]
  })

# Facts the host read from its own storage; revoked rows stay with revoked_at set.
facts = %{
  spaces: [
    %{id: "acme", tenant: "acme", parent: nil, block_inheritance: false},
    %{id: "finance", tenant: "acme", parent: "acme", block_inheritance: false},
    %{id: "finance/eu", tenant: "acme", parent: "finance", block_inheritance: false},
    %{id: "lab", tenant: "acme", parent: "acme", block_inheritance: true},
    %{id: "globex", tenant: "globex", parent: nil, block_inheritance: false}
  ],
  roles: [
    %{id: "member", permissions: ["read"]},
    %{id: "approver", permissions: ["approve", "money.pay"]}
  ],
  memberships: [
    %{
      principal: "alice",
      space: "acme",
      role: "member",
      valid_from: 0,
      valid_to: nil,
      revoked_at: nil
    },
    %{
      principal: "alice",
      space: "finance",
      role: "approver",
      valid_from: 0,
      valid_to: nil,
      revoked_at: nil
    },
    %{
      principal: "alice",
      space: "globex",
      role: "approver",
      valid_from: 0,
      valid_to: nil,
      revoked_at: 500
    }
  ],
  non_inheriting: ["money."]
}

now = 1_000

[
  # Inherited "read" from acme plus the approver role held at finance.
  Membership.permissions(alice, "finance", facts, now),
  # "money.pay" stays at finance; "approve" and "read" flow down.
  Membership.permissions(alice, "finance/eu", facts, now),
  # lab blocks inheritance from acme.
  Membership.permissions(alice, "lab", facts, now),
  # The agent holds its parent's permissions within its own scopes.
  Membership.permissions(bot, "finance", facts, now),
  # Where alice may approve, for a tenant-isolation space list.
  Membership.spaces(alice, "approve", facts, now),
  # Another tenant's space is refused, never resolved.
  Membership.permissions(alice, "globex", facts, now)
]
