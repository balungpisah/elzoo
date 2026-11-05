# CI execution on symbolic

All Elzoo CI executes on the user-owned **symbolic** Linux machine. GitHub
stores the repository, schedules Actions and reports checks; it must not supply
the compute runner. Do not select `ubuntu-latest`, `ubuntu-24.04`, `macos-*`,
`windows-*` or a hosted fallback. If symbolic is offline, leave jobs queued and
restore the runner rather than consuming hosted minutes.

The workflows use explicit role selectors:

```yaml
# Backend
runs-on: [self-hosted, linux, x64, symbolic, elzoo, backend]
# Gleam
runs-on: [self-hosted, linux, x64, symbolic, elzoo, gleam]
```

The repository guard `python3 scripts/check-ci-runners.py` checks the canonical
selector syntax, requires one role and rejects ordinary selector/fallback changes. It is a source
convention guard, not GitHub account-level enforcement or a hostile-YAML parser.
Independent workflow review remains required. Do not bypass the user's runner
restriction when making a workflow or troubleshooting a queue.

## Machine and job environment

- SSH alias: `symbolic`; host Ubuntu 26.04.1, x86_64, Docker installed.
- Repository-scoped runners for `balungpisah/elzoo` only:
  `symbolic-elzoo` (backend) and `symbolic-elzoo-gleam` (Gleam).
- Dedicated local account: `elzoo-ci`, member of the Docker group.
- Installations: `/opt/actions-runner/elzoo` and `/opt/actions-runner/elzoo-gleam`;
  separate work and tool caches under each `_work/`.
- System services: `actions.runner.balungpisah-elzoo.symbolic-elzoo.service` and
  `actions.runner.balungpisah-elzoo.symbolic-elzoo-gleam.service`, enabled at boot.
  Each runner processes one job at a time. One backend and one Gleam job can run
  concurrently; jobs of the same role queue. Do not give either runner both
  roles or register more copies without measuring contention first.
- Initial runner installation: upstream `actions/runner` 2.338.2, archive SHA-256
  `baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40`.
  Standard runner self-updates remain enabled; this is an observed installation
  version, not a locked compiler version.
- Jobs run in Ubuntu 24.04 containers pinned by digest
  `sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`.
  `ImageOS: ubuntu24` explicitly tells setup-beam which container build to use;
  self-hosted runners do not supply that variable. The tag names the OS; the digest fixes the image. Container package preparation
  installs build prerequisites, then pinned Actions install OTP/Elixir/Node.
  Apt repository packages are not a bit-for-bit snapshot.
- After checkout, each job adds only GITHUB_WORKSPACE to Git's safe.directory
  list and confirms it is inside the repository. Host/container ownership differs;
  checkout's temporary Git trust does not apply to later shell commands. Never
  use a wildcard safe.directory setting. Lockfile checks compare against HEAD.
- Existing Cure, OTP, Elixir, Gleam and Node pins remain unchanged. The repository
  tests run inside the job container, not a developer checkout on the host.
- Backend dependency caches still use GitHub storage, under a new
  symbolic-ubuntu24-v1 key namespace. Do not restore legacy hosted-runner build
  artifacts with different workspace paths and numeric file ownership.
  This migration removes hosted-runner compute use; it is not a statement about
  every possible GitHub storage/account charge.

The runner account can use Docker and execute repository workflow code. Keep it
scoped to this private repository and trusted contributors; do not register it
as a general runner for arbitrary external repositories. Job containers are
execution environments, not a sandbox for hostile PR code. Credentials and the
runner's generated registration files stay on the machine, outside the repo.

## Resource use and measurement

Symbolic has four physical CPU cores/eight logical CPUs and approximately
30 GiB RAM. The runner service and job containers have no CPU or memory quota.
`ERL_FLAGS` limits schedulers **per BEAM VM**, not the entire job: the backend
check launches child Mix/BEAM processes, and Node or native tools have their own
parallelism. Each workflow reports its actual BEAM scheduler counts in the log.

Backend uses `+S 4:4 +SDcpu 1 +SDio 1`; Gleam keeps
`+S 2:2 +SDcpu 1 +SDio 1`. Dedicated roles avoid two heavy backend builds
competing while allowing the short Gleam job to proceed during backend work
and cache transport. These are scheduler choices, not hard CPU reservations.

Choose scheduler and runner counts from elapsed time and contention measurements,
not from a goal of keeping every CPU busy. Serial work, network downloads and
cache transport may not benefit from more schedulers. Additional runners can
reduce queue time without making an individual job faster. Keep independent
runner installations/work directories and per-job containers; never point two
runner services at the same `_work` directory.

See [ELZ-020's measurement method and evidence](../work/ELZ-020.md) and
`scripts/benchmark-ci.py`. Measurements run in a disposable, prepared Linux
container, on an idle host, with full checks and explicit source/tool versions.
Do not benchmark against the live runner checkout or present a warmed compile
probe as clean-download or end-to-end Actions performance.

## Operations and replacement

From a machine with the established SSH alias:

```sh
ssh symbolic 'sudo systemctl status actions.runner.balungpisah-elzoo.symbolic-elzoo.service --no-pager'
ssh symbolic 'sudo systemctl status actions.runner.balungpisah-elzoo.symbolic-elzoo-gleam.service --no-pager'
gh api repos/balungpisah/elzoo/actions/runners \
  --jq '.runners[] | {name,status,busy,labels: [.labels[].name]}'
```

Restart with `sudo systemctl restart` for the affected service. Inspect its journal
and free disk before changing tool versions or expanding capacity. Do not
remove `_work/` or restart the service while a job is busy. For planned
maintenance, disable the two symbolic workflows and wait for active jobs to
finish. Re-enable only those symbolic workflows when the service is healthy.

To replace the host/runner:

1. Prepare Linux x86_64 with Docker, the dedicated account and separate directories above.
2. Download the appropriate upstream Actions runner archive; verify its published
   SHA-256 before extraction. Record a new version/checksum if upgrading.
3. Obtain a short-lived **repository runner registration token** with authorized
   GitHub admin access. Send it directly to `config.sh` without printing it,
   committing it or storing it in task/issue text. No broad GitHub token is
   needed on symbolic.
4. For each runner, as `elzoo-ci`, run `config.sh --unattended` with the repository URL,
   its distinct name and registration token, `--work _work`, and exactly one role:
   `--labels symbolic,elzoo,backend` or `--labels symbolic,elzoo,gleam`.
   Resolve an existing runner deliberately; do not silently replace a busy one.
5. In the install directory, run `sudo ./svc.sh install elzoo-ci` and
   `sudo ./svc.sh start`. Check GitHub reports the expected runner online.
6. Run both symbolic workflows and inspect the job API's `runner_name` and
   `labels`, in addition to passing test results. A green job alone does not
   identify the machine that ran it. Expect `symbolic-elzoo` for backend and
   `symbolic-elzoo-gleam` for Gleam. A stuck role queues rather than falling back
   to the other role or a hosted runner. To roll back role separation, stop the
   idle Gleam service and deliberately revert the selectors/guard/docs together;
   never add a hosted fallback.

## Migration record

ELZ-019 disables the old `check.yml` and `gleam.yml` workflows before changing
routing. Their earlier runs used GitHub-hosted Ubuntu; they are not symbolic
validation. The replacement paths are `symbolic-check.yml` and
`symbolic-gleam.yml`, allowing the PR to validate new self-hosted jobs while the
old hosted definitions stay disabled. Never re-enable those legacy workflows.
Their files were removed from main by the migration PR. ELZ-019's PR and
merged-main jobs both reported `runner_name: symbolic-elzoo`. With ELZ-020's
role separation, PR and merged-main acceptance require backend jobs to report
`symbolic-elzoo` and Gleam jobs to report `symbolic-elzoo-gleam`, with the
matching exclusive role labels.
