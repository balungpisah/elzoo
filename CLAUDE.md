# CLAUDE.md

@AGENTS.md

`AGENTS.md` is the one source of the workflow. This file only imports it and
adds notes for Claude Code. Put a workflow rule in `AGENTS.md`, not here.

## Claude Code only

- Claim from the main checkout. Then start the build session inside the task
  worktree.
- A subagent that edits files gets its own task and its own worktree. Do not
  let a subagent write in the worktree of the lead while the lead also writes.
- For the one independent review in `AGENTS.md` section 6, start a strong reasoning reviewer agent. Give it
  the issue number and frozen diff range. Do not give it your conclusions.
- Run the reviewer in the foreground and wait for its final message. A
  background reviewer can stop with no report when the session ends.
- Put no project memory, local path or session identifier in a committed file.
- Follow the standing rules in `AGENTS.md` sections 3–8: acceptance-only scope, the model-role split, separate defect tasks, one independent review with re-review only after code changes, ready-before-merge and stop-and-report on permission or policy refusals.
