# Elzoo

A catalogue of composable building blocks for assembling reliable systems.

## Language

**Piece**: One reusable catalogue entry with an explicit interface, contract and evidence.

**Operator**: A pure state transition from state and input to new state and outputs.

**Unit**: A collection of operators behind ports, managed as one lifecycle boundary.

**Port**: A unit's named input or output, with a defined message contract.

**Edge**: A connection between ports. A fused edge stays within a unit; a hop crosses units.

**Wiring**: The declaration of units and their edges.

**Assembly**: Pieces composed behind an interface that permits further composition.

**Product**: Domain-specific behavior combined with the pieces and assemblies it uses.

**Effect**: An explicit request to interact with the outside world.

**Adapter**: The boundary that performs an effect and translates the external result.

**Host**: The operating-system process that contains running units.

**Needs**: The external capabilities a unit declares that it uses.

**Grounding**: The evidence supporting a particular behavioral claim, including proofs,
types, executable checks, monitoring and an upstream contract.

**Law**: A quantified or exhaustive behavioral statement checked by a proof mechanism.

**Contract**: What a piece promises, what it assumes, and what it leaves unspecified.

**Dependency**: An external implementation relied on through an explicit contract.

**Envelope**: Delivery metadata and payload passed across a message boundary.
