# CI execution on symbolic

All Elzoo CI executes on the user-owned **symbolic** Linux machine. GitHub
stores the repository, schedules Actions and reports checks; it must not supply
the compute runner. Do not select `ubuntu-latest`, `ubuntu-24.04`, `macos-*`,
`windows-*` or a hosted fallback. If symbolic is offline, leave jobs queued and
restore the runner rather than consuming hosted minutes.

Both workflows use the exact selector:

```yaml
runs-on: [self-hosted, linux, x64, symbolic, elzoo]
```

The repository guard `python3 scripts/check-ci-runners.py` checks the canonical
selector syntax and rejects ordinary selector/fallback changes. It is a source
convention guard, not GitHub account-level enforcement or a hostile-YAML parser.
Independent workflow review remains required. Do not bypass the user's runner
restriction when making a workflow or troubleshooting a queue.

## Machine and job environment

- SSH alias: `symbolic`; host Ubuntu 26.04.1, x86_64, Docker installed.
- Repository-scoped runner: `symbolic-elzoo` for `balungpisah/elzoo` only.
- Dedicated local account: `elzoo-ci`, member of the Docker group.
- Installation: `/opt/actions-runner/elzoo`; work and tool cache under `_work/`.
- System service: `actions.runner.balungpisah-elzoo.symbolic-elzoo.service`,
  enabled at boot. One runner processes one job at a time; the other queues.
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
- Existing Cure, OTP, Elixir, Gleam and Node pins remain unchanged. The repository
  tests run inside the job container, not a developer checkout on the host.
- GitHub cache storage for the existing backend dependency cache is unchanged.
  This migration removes hosted-runner compute use; it is not a statement about
  every possible GitHub storage/account charge.

The runner account can use Docker and execute repository workflow code. Keep it
scoped to this private repository and trusted contributors; do not register it
as a general runner for arbitrary external repositories. Job containers are
execution environments, not a sandbox for hostile PR code. Credentials and the
runner's generated registration files stay on the machine, outside the repo.

## Operations and replacement

From a machine with the established SSH alias:

```sh
ssh symbolic 'sudo systemctl status actions.runner.balungpisah-elzoo.symbolic-elzoo.service --no-pager'
gh api repos/balungpisah/elzoo/actions/runners \
  --jq '.runners[] | {name,status,busy,labels: [.labels[].name]}'
```

Restart with `sudo systemctl restart` for the same service. Inspect its journal
and free disk before changing tool versions or expanding capacity. Do not
remove `_work/` or restart the service while a job is busy. For planned
maintenance, disable the two symbolic workflows and wait for active jobs to
finish. Re-enable only those symbolic workflows when the service is healthy.

To replace the host/runner:

1. Prepare Linux x86_64 with Docker, the dedicated account and directory above.
2. Download the appropriate upstream Actions runner archive; verify its published
   SHA-256 before extraction. Record a new version/checksum if upgrading.
3. Obtain a short-lived **repository runner registration token** with authorized
   GitHub admin access. Send it directly to `config.sh` without printing it,
   committing it or storing it in task/issue text. No broad GitHub token is
   needed on symbolic.
4. As `elzoo-ci`, run `config.sh --unattended` with the repository URL, runner
   name, registration token, `--labels symbolic,elzoo` and `--work _work`.
   Resolve an existing runner deliberately; do not silently replace a busy one.
5. In the install directory, run `sudo ./svc.sh install elzoo-ci` and
   `sudo ./svc.sh start`. Check GitHub reports the expected runner online.
6. Run both symbolic workflows and inspect the job API's `runner_name` and
   `labels`, in addition to passing test results. A green job alone does not
   identify the machine that ran it.

## Migration record

ELZ-019 disables the old `check.yml` and `gleam.yml` workflows before changing
routing. Their earlier runs used GitHub-hosted Ubuntu; they are not symbolic
validation. The replacement paths are `symbolic-check.yml` and
`symbolic-gleam.yml`, allowing the PR to validate new self-hosted jobs while the
old hosted definitions stay disabled. Never re-enable those legacy workflows.
Their files are removed from main by the migration PR. Acceptance requires the
new PR and merged-main jobs to report `runner_name: symbolic-elzoo`.
