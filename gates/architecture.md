# Gates: architecture

Scope: An implementable Cure/OTP architecture and a catalogue rebuilt around reuse.

- [x] A1: Architecture covers composition, effects, delivery, state/durability, isolation and evidence, separating present behavior from targets.
  EVIDENCE: `docs/architecture.md` defines operators/units/ports/edges/assemblies, fused versus hop delivery, volatile/durable/external state, adapter boundaries, OTP isolation, phase assemblies, and a claim ledger linked to `cure/`, `lib/` and `test/` in this repository. The bootstrap's synchronous `GenServer.call` boundary and its limits are called out explicitly.
- [x] A2: Catalogue maps original Zoo capability families to owned pieces, direct reuse, thin integration or deferred work, with phases and rationale.
  EVIDENCE: `docs/catalogue.md` has stable IDs, dispositions, P0*–P4 assembly-driven phases, an old-family coverage table, alias normalization, and explicit drops/out-of-scope rationale. It prefers OTP/Enum/Stream/storage reuse and keeps Elzoo ownership at contracts/policies.
- [x] A3: External library candidates have authoritative source links, contract limits and an explicit adopted/candidate status; only tested dependencies are called adopted.
  EVIDENCE: `docs/dependencies.md` records exact Cure/Elixir/OTP/Jason bootstrap baselines, prior exercised behavior, official API/source links for Req/Finch/Ecto/Postgrex/Oban/Telemetry/OpenTelemetry/Plug, observed API names, candidate status and required negative/integration tests. Unexercised candidates are not adopted.
- [x] A4: A small decision record explains fresh start, mixed grounding and OTP/runtime isolation; Cure pitfalls from the executed spike are carried forward.
  EVIDENCE: `docs/adr/0001-fresh-start.md`, `docs/adr/0002-mixed-grounding.md`, `docs/adr/0003-otp-isolation.md`, and `docs/cure-notes.md` record the three choices, measured record ABI/authoring pitfalls, foreign-boundary limits, and upgrade checklist. Historical spike evidence is linked separately; production evidence is self-contained.
