# Disagreements between the ranking, the canonical plan and the owner order.
# Each: (title, observation, decision owner, next action). Rendered as a section; no automatic reorder.
NOTES = [
("Owner priority versus the deferred `integration/secrets` prerequisite",
 "The owner's batch puts `integration/object-store` second and `integration/notification` third, yet both records (and the ranking rows R18/R20) depend on `integration/secrets`, which is deferred and has no task. The owner's priority is kept; the executable prerequisite is not satisfied.",
 "main coordinator",
 "when drafting ELZ-053 and ELZ-054, either admit a narrow secrets slice first or let each task take its credential as an explicit injected Need reviewed in that Contract; record the choice there."),
("Audit log before `domain/principal` exists",
 "`state/audit-log` is fourth in the owner's batch but depends on deferred `domain/principal` for attribution; the first audited mutation (ELZ-023 decision record) carries no actor field.",
 "main coordinator with the pieces coordinator",
 "treat `domain/principal` as a conditional prerequisite; the ELZ-055 Contract draft states the attribution source or records that attribution waits."),
("`domain/quota` edge to `domain/metering`",
 "The ranking (R31) makes quota depend on metering (V2) while the canonical plan's RC-08 does not depend on RC-21 and quota is a V1 job. The record now lists metering as a conditional input for C9 only; the canonical graph is unchanged and the roadmap release-order check validates that graph, not the record edges.",
 "pieces coordinator",
 "no change to the manifest; if a C9 task is admitted, add the dependency there with review."),
("`integration/sdk` scope: MCP client versus one foreign consumer protocol",
 "The owner names an MCP client (ExMCP) as the first tool boundary; the canonical RC-30 ('One foreign consumer protocol') scopes `integration/sdk` as one actual foreign language consuming versioned messages and results, TypeScript a candidate and not an adoption, with no four-language promise, MCP only when the named consumer needs it, and RC-17 (agent runner) among its prerequisites. The record follows the owner; the manifest scope is not edited here.",
 "main coordinator",
 "reconcile the RC-30 scope and prerequisite when the MCP-client task is drafted; a split into a separate protocol-client entry is a possible outcome."),
("Build order versus dependency order in general",
 "Owner answer 1 is a priority order, not a proof that each task's prerequisites are ready. Records mark every dependency ready, planned or deferred so a builder sees the gap before claiming.",
 "pieces coordinator",
 "each build-task draft names its unsatisfied prerequisites and how it handles them."),
]
