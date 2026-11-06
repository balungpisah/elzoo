# CI on user-owned machines

Elzoo uses only the user-owned Linux machines `symbolic` and `macbook-ubuntu`.
GitHub provides scheduling and check reporting; it does not supply compute.
Never select a GitHub-hosted image or add a hosted fallback. If a runner is
offline, diagnose it or let work queue on the other approved runner.

## Roles and routing

- `symbolic-elzoo`: backend; labels `self-hosted`, `linux`, `x64`, `elzoo`,
  `backend`, `symbolic`.
- `macbook-ubuntu-elzoo-candidate`: backend after ELZ-034 acceptance; labels
  `self-hosted`, `linux`, `x64`, `elzoo`, `backend`, `macbook-ubuntu`,
  `ci-candidate`. Before acceptance it carries no `backend` label, so the
  existing symbolic workflow cannot send it normal jobs.
- `symbolic-elzoo-gleam`: Gleam only; labels `self-hosted`, `linux`, `x64`,
  `symbolic`, `elzoo`, `gleam`.

The backend workflow uses `[self-hosted, linux, x64, elzoo, backend]`. A
one-time ELZ-034 PR selector targets the candidate by its `macbook-ubuntu` and
`ci-candidate` labels only when the PR head is in this same repository and its
branch is `task/ELZ-034`, so a fork cannot select the candidate by spoofing
the branch name. Both backend and Gleam jobs skip fork PRs before runner
selection; a skipped job is not validation and must not be treated as evidence
for merging a fork. This does not make arbitrary same-repository code trustworthy.
The first container step refuses any backend `RUNNER_NAME` other than the two
names above. The Gleam selector stays symbolic-only. Before adding `backend`
to the candidate, a full task-branch check and independent review must pass.
Registration is repository-scoped; administrators must assign these labels only
to the named trusted machines. GitHub label selection is not cryptographic host
identity, and a runner name check happens after the host starts the container.

`scripts/check-ci-runners.py` checks exact selector conventions, the fork-PR and identity
gate, known workflow files and disallows reusable workflows without a policy.
`python3 scripts/test-ci-runners.py` exercises positive routing and negative
controls. This is a source convention guard, not protection against hostile YAML
or an account-level runner admission policy. Workflow and trust-model changes
require independent review. Inspect the actual GitHub job `runner_name` and
labels, not just the check name, when verifying a machine.

## Machine and container setup

Both machines use repository-scoped runner installations and dedicated
`elzoo-ci` accounts. The account can access Docker, which is root-equivalent;
job containers are not a sandbox for hostile PR code. Run only trusted code in
this private repository. Never store runner registration tokens in the repo or
logs. Use a short-lived registration token directly for `config.sh`.

`symbolic` is Ubuntu 26.04.1 x86_64, four physical/eight logical CPUs and
about 30 GiB RAM. Its backend and Gleam services are
`actions.runner.balungpisah-elzoo.symbolic-elzoo.service` and
`actions.runner.balungpisah-elzoo.symbolic-elzoo-gleam.service`, with separate
installations and `_work` directories.

`macbook-ubuntu` is Ubuntu 26.04.1 x86_64, two physical/four logical CPUs,
7.1 GiB usable RAM and 4 GiB swap, also running other user workloads. Docker
29.1.3 was installed from Ubuntu packages. Its candidate runner is version
2.338.2, verified against SHA-256
`baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40`, installed
at `/opt/actions-runner/elzoo-backend` and served by
`actions.runner.balungpisah-elzoo.macbook-ubuntu-elzoo-candidate.service`.
It has a separate `_work` directory. Docker startup and a pull/run of the pinned
CI image passed during provisioning; those are not a full CI validation.

Each role runs at most one job per runner. The candidate has no hard container
memory or CPU quota. The backend workflow keeps `+S 4:4 +SDcpu 1 +SDio 1` on
symbolic and selects `+S 2:2 +SDcpu 1 +SDio 1` on macbook-ubuntu, per BEAM VM;
child VMs and other processes are additional. The host is smaller, so check the
actual run's duration and cgroup peak, inspect host memory and user workload
contention, and keep it candidate-only if the full workload is unreliable.

Jobs run inside Ubuntu 24.04 pinned to
`sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`.
`ImageOS: ubuntu24` selects setup-beam's container build. Packages are installed
from apt repositories and are not a bit-for-bit package snapshot. Exact Cure,
Elixir, OTP, Node and Gleam pins remain in the repository. Backend jobs create a
per-container disposable PostgreSQL role and database and export
`ELZOO_TEST_DATABASE_URL`; required tests fail closed without it. Do not use a
personal or production database. Cache keys include the runner name as well as
toolchain/dependency pins: compiled Cure and Mix artifacts are not restored from
another machine's checkout. GitHub's cache service remains in use; no claim is
made about other GitHub account costs.

## Operation and rollback

```sh
ssh symbolic 'sudo systemctl status actions.runner.balungpisah-elzoo.symbolic-elzoo.service --no-pager'
ssh macbook-ubuntu 'systemctl status actions.runner.balungpisah-elzoo.macbook-ubuntu-elzoo-candidate.service --no-pager'
gh api repos/balungpisah/elzoo/actions/runners --jq '.runners[] | {name,status,busy,labels: [.labels[].name]}'
```

Do not restart or remove a busy runner or its `_work` directory. If the candidate
is unavailable, remove its `backend` label after the current job is finished;
symbolic continues to accept backend jobs. If it is the cause of failures,
record the exact run, environment and failure; preserve failed evidence and
route only to the healthy named machine. Never change to hosted CI.

To replace a runner, verify the published release archive checksum, provision a
separate service account and work directory, configure a short-lived repository
registration token without printing it, assign only the documented role labels,
and verify runner identity and the full job on a reviewed change. Do not point
two runners at one `_work` directory or blindly register more runners to reduce
queue time.

## Historical evidence

ELZ-019 moved CI from hosted machines to symbolic. ELZ-020 measured BEAM
scheduler settings and split backend and Gleam roles. Earlier hosted runs are
historical evidence and do not satisfy the user-owned machine policy. ELZ-034
adds the second backend candidate; its actual full-run evidence and final
admission decision belong in that task's PR and merge acceptance.
