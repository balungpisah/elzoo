# ELZ-029 — proposed Contract amendments (exact before/after text, revision 2)

Status: **approved wording (A1–A7), not yet applied in this form; A7″ and A8 proposed in revision 4, A7′ withdrawn.** The main
coordinator approved A2 and A3 as written in revision 1 and the **reworded**
A1, A4, A5, A6 and A7 below (byte-exact before-texts from the focused re-review
[ELZ-029-early-rereview.md](ELZ-029-early-rereview.md), section "Exact
suggested wording"; A7 in the reviewer's sentence form naming
`integration/agent-runner`). The reworded texts replace the revision-1 wording.

**Current live state (important):** issue #46 and
`tasks/ELZ-029-os-process-adapter.md` currently carry the **revision-1
wording**, applied at commit `8dd1038` on the pieces coordinator's earlier
instruction before the re-review arrived (issue comment
[6723359800](https://github.com/balungpisah/elzoo/issues/46#issuecomment-6723359800);
plan hash `dd6d715b…`). Nothing is reverted. When the pieces coordinator gives
the go, the second edit is computed as: original body (git `64acad7`, sha256
`f844ecc1…`) → apply the exact replacements below in order (A1, A4, A5, A2, A3,
A6, A7) → set as live body → resync the task copy bytewise and the plan hash in
one commit. The before-texts below are substrings of the **original** body, as
the reviewer wrote them.

All replacements apply to section **2. Interface and invariant**.

## A1 — rejected set (reviewer wording)

Replace this exact issue substring:

```text
`rejected{queue_full |
   queue_timeout}` (not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

## A4 — deadline expiry before dispatch (reviewer wording), after A1

Replace this exact substring:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched), `expired{deadline}` when the declared deadline passed before dispatch (not dispatched)
```

And replace this exact substring:

```text
`rejected{…}` → `rejected/not_dispatched`,
```

with:

```text
`rejected{…}` → `rejected/not_dispatched`, `expired` → `timed_out/not_dispatched`,
```

## A5 — stage `none` (reviewer wording)

Replace this exact issue substring:

```text
`terminated{stage: term | kill,
   deadline}`
```

with:

```text
`terminated{stage: none | term | kill, deadline}` (`none` only when a reliable observation establishes that the original group is empty before any termination signal; `none` does not claim signal delivery)
```

## A2 — stage travels in the paired Adapter result (approved as written)

Replace:

```text
`terminated` on deadline → `timed_out/dispatched` carrying the stage
```

with:

```text
`terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field
```

## A3 — cancellation and owner death (approved as written)

Add directly after the A2 text (before the `, liveness-check failure` that
follows it in the original):

```text
; `terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage; only report definitive termination when it is observed, and partial external Effects remain possible
```

## A6 — `unknown` after a surviving group (reviewer wording)

Replace this exact issue substring:

```text
`unknown` when the liveness check itself fails
```

with:

```text
`unknown` when the liveness check itself fails or the group is still observed alive after the kill stage and the bounded reap wait; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria
```

Also replace:

```text
liveness-check failure → `unknown/dispatched`
```

with:

```text
`unknown` → `unknown/dispatched`
```

## A7 — Needs (reviewer sentence form; `integration/agent-runner` named per main)

Insert after the exact issue anchor:

```text
   confinement (domain/authorization).
```

this text (as a continuation of the same list item):

```text
   Needs: an executable path and declared executable version, a working directory, an explicit environment allowlist (names inherited from the host plus names set per call; everything else is unset for the child), and declared host `kill` and `pgrep` utilities for signalling and group observation. The `integration/agent-runner` task records the exact Claude Code CLI and Codex CLI versions.
```

## A7′ — WITHDRAWN (revision 4)

The `/bin/sh` wrapper of revision 3 is withdrawn: the main coordinator ruled
that a library is exercised first, and the probe
([ELZ-029-provider-probe.md](ELZ-029-provider-probe.md)) found erlexec 2.6.0
fit. No `/bin/sh` or `setsid` Need.

## A7″ — proposed replacement of the A7 Needs sentence (author, revision 4; NOT yet approved)

With erlexec as the provider, the Adapter sends no signal itself, so `kill`
is no longer a Need; the provider's port program and `pgrep` are. Proposed:
in the approved A7 text replace

```text
and declared host `kill` and `pgrep` utilities for signalling and group observation.
```

with

```text
the erlexec 2.6.0 port program (`exec-port`, built from the pinned Hex package with the host C++ toolchain) for spawning, group creation, deadline escalation and owner-death cleanup, and the declared host `pgrep` utility for group observation.
```

## A8 — proposed addition (author, revision 4; NOT yet approved)

erlexec masks the exit status of a termination it performed on request
(`exec:stop`, and the stop it performs when a linked owner dies). The ending
signal is then not reported, while the group's emptiness is still observed.
Proposed: in the A5 text replace

```text
`terminated{stage: none | term | kill, deadline}`
```

with

```text
`terminated{stage: none | term | kill | unobserved, deadline}`
```

and append to the A5 parenthesis, before its closing `)`:

```text
; `unobserved` only when the provider performed the staged termination on the Adapter's or the owner-death request and does not report the ending signal, while the group was observed empty afterwards
```

Reason: the only alternatives are to infer the stage from timing (rejected by
review) or to send group signals from the BEAM (refused by erlexec, and the
identity race the review rejected). `unobserved` is a truthful label; it does
not claim `term` or `kill`.
