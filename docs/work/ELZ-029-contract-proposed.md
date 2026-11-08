# ELZ-029 — proposed Contract amendments (exact before/after text)

Status: **proposed**, not applied. The main coordinator decides; the worker does
not edit the live issue #46 body or `tasks/ELZ-029-os-process-adapter.md`.
Source of the wording: the independent early review
([ELZ-029-early-review.md](ELZ-029-early-review.md), finding 4) where it gave
text; the author adds A4–A7 with the stated reasons. Every amendment adds
specificity; none weakens an invariant, acceptance item or the ready
`core/envelope` Contract.

All amendments apply to section **2. Interface and invariant** of the
Admission record unless stated otherwise.

## A1 — rejected set (reviewer wording)

Before:

```
`rejected{queue_full | queue_timeout}` (not dispatched)
```

After:

```
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

Reason: `Port.open` fails for a missing or non-executable file after
admission, and a queued request can be cancelled before dispatch; both dispatch
nothing and need a distinct, non-`terminated` label so a caller cannot confuse
them with a termination.

## A2 — stage travels in the paired Adapter result (reviewer wording)

Before:

```
`terminated` on deadline → `timed_out/dispatched` carrying the stage
```

After:

```
`terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field
```

Reason: ready `core/envelope` rejects extra keys on error results; the stage
is carried by the Adapter result returned alongside the delivery result.

## A3 — cancellation and owner death (reviewer wording, extended)

Add after the mapping of A2:

```
`terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage; only report definitive termination when it is observed, and partial external Effects remain possible
```

Reason: the reviewer proposed the cancellation and caller-death text; the
author adds "death of the collecting BEAM process" because the reaper's
cleanup after a collector death produces the same observed `terminated`
outcome and the command's own result is lost (the Port is closed), which is a
definitive boundary failure, not a timeout and not a loss of observation.

## A4 — deadline expiry before dispatch (author)

Before:

```
Outputs: `completed{exit_code, output}` (a non-zero exit is a completed result, not an Adapter error), `rejected{…}`
```

(The `rejected{…}` text is as amended by A1.) After — insert a new output
between `rejected{…}` and `terminated{…}`:

```
`expired{deadline}` when the declared deadline passed before dispatch (while queued or at dispatch; not dispatched)
```

and add to the mapping list:

```
`expired` → `timed_out/not_dispatched`
```

Reason: review finding 6. The deadline is absolute and is converted at
admission; queue residence must not extend it. The shared result matrix already
defines `timed_out/not_dispatched` as "timeout reported before dispatch".

## A5 — stage `none` (author)

Before:

```
`terminated{stage: term | kill, deadline}`
```

After:

```
`terminated{stage: none | term | kill, deadline}` (`none` only when the first group observation at termination time already found no member, so no signal was sent)
```

Reason: review finding 3 ("never report no-process on an ambiguous failure",
stage from observation). When the leader has exited but a process that left
the group still holds the output pipe, the deadline arrives with an empty
group; reporting `term` would assume a signal that was never sent.

## A6 — `unknown` after a surviving group (author)

Before:

```
`unknown` when the liveness check itself fails
```

After:

```
`unknown` when the liveness check itself fails, or when the group is still observed alive after the kill stage within the Adapter's bounded reap wait (cleanup not established)
```

Reason: review finding 2 ("do not present an unverified residual as
Contract-compliant"). A `terminated` result then always means the group was
observed empty; a group that survives KILL (uninterruptible sleep, zombie under
a non-reaping init) is reported as `unknown`, never as `terminated`.

## A7 — environment allowlist and signal tools as Needs (author; record alignment)

Add to the end of section 2 (after "Non-goals: …"):

```
Needs: the executable path (and its version, recorded by the composing task), the working directory, an explicit environment allowlist (names inherited from the host plus names set per call; everything else is unset for the child), and the host `kill` and `pgrep` utilities used for signalling and group observation. Executable versions for the Claude Code CLI and the Codex CLI are recorded by the task that composes them (`integration/agent-runner`), not by this Adapter.
```

Reason: review finding 5 and the ELZ-050 record ("working directory and
environment allowlist"; "OS executables and their versions as declared
Needs"). The default inherits nothing. The owner's open question on exact CLI
versions is routed to the composing task; the coordinator confirms this
disposition (G1).
