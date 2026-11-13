# ELZ-150 — Test the agent-loop rules that no test runs

- Dependencies: ELZ-142
- Allowed implementation path: `pieces/workflow/agent-loop/test/**`, the evidence text of `pieces/workflow/agent-loop/piece.json` and `README.md` where it counts the test groups, and the index/generated changes under AGENTS.md section 3.

The independent review of ELZ-142 (issue #316) found rules of the task body (#301) that are in `lib/elzoo/agent_loop.ex` and match the body by reading, but that no test runs. ELZ-142 named fourteen groups and asked for no more. This task adds the missing tests. It changes no behaviour.

Add one named test for each of these rules, through the public function of the Piece only, in the form of the existing groups:

1. Declaration rule 6: a declaration that would put the state over 65,536 bytes is refused with `state_over_bound`, and the state is unchanged by it.
2. A proposed call whose `id` repeats an earlier call of the same turn is left out with `repeated_id`.
3. A proposed call after 64 kept calls of one turn is left out with `over_call_bound`.
4. A kept call whose arguments the tool's validator answers with a disagreement gets the notice `[tool call not run: validator_disagreement]` and no action.
5. A kept call that does not resolve at execution time gets the notice `[tool call not run: not_resolved]` and no action.
6. A request that prompt assembly cannot build closes the loop with `stopped`, `request_not_built`.
7. The input `run_ended` closes an open loop without a request, in each phase that the README table names for it.

Contract: unchanged. No change of `lib/`, of an existing test or of a shape. If a rule cannot be reached through the public function, or the code differs from the README or from the body of #301, do not bend the test: stop that rule, write the exact point on issue #316, and deliver the others.

## Acceptance

- Each of the seven tests fails under a temporary mutation of its own rule in `lib/elzoo/agent_loop.ex` (for example the bound, the tag or the branch) and passes without it. Record the seven mutations and the failing test of each. Remove every mutation.
- `mix test pieces/workflow/agent-loop/test` exits 0 with the fourteen existing groups unchanged and passing.
- The evidence text of `piece.json` and the README states the groups that now exist; no other claim changes.
- Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6. The pull request closes issue #316 as well.
