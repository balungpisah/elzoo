# ADR-0003: Use OTP lifecycle isolation, not a home-grown engine

*Status:* accepted for bootstrap

*Date:* 2026-11-05

## Context

Zoo's engine concept is useful as a boundary, but rebuilding a scheduler,
supervisor and mailbox on top of Cure would duplicate mature OTP behavior.
The Cure spike showed that a pure transition can run unchanged behind a
generic `GenServer` and `Supervisor`. It also showed that a BEAM restart loses
volatile state.

## Decision

Use ordinary OTP `Application`, `Supervisor`, `GenServer` and, when needed,
`DynamicSupervisor`/`Registry` as the host and lifecycle shell. Keep decisions
in Cure and keep adapters thin. Treat a hop as a message crossing a unit
boundary, with its delivery class stated separately from process placement.
Use an OS process/port or an external service when native code, hostile input
or resource isolation requires a boundary that a BEAM process does not supply.

## Consequences

The first runtime is small and benefits from OTP's maintained failure
semantics. A synchronous `GenServer.call` is useful bootstrap evidence but is
not an asynchronous durable hop. Volatile units must disclose restart data
loss; durable units need an explicit log/checkpoint/outbox contract and
recovery tests. We do not claim exactly-once delivery or OS-level isolation
without a later assembly and evidence.
