# ELZ-435 — CI: the runtime-library fallback reads only the official Ubuntu archive

- Dependencies: none

## Outcome and scope

`scripts/ci-install-runtime.py` installs `libncurses6`, `libsctp1` and
`libssl3` on the hosted runners. When the first `apt-get update` and install
fail, it rewrites the Ubuntu 24.04 source to `archive.ubuntu.com` and runs
`apt-get -o APT::Update::Error-Mode=any update` (line 65). That update reads
every configured apt source, including third-party sources on the hosted
image. On 2026-11-27, `packages.microsoft.com` answered 403 in Gleam run
45948960181 (pull request #1054, the "Install runtime libraries" step). The
fallback then failed although the Ubuntu archive was reachable, and the job
failed before its tests. A run a few minutes later passed.

- The fallback's update and the install after it read only the official
  Ubuntu stanzas that the fallback rewrites to `archive.ubuntu.com`. They do
  not read other stanzas of `ubuntu.sources`, and they do not read other
  source files. Apt reads every enabled stanza of a `.sources` file, so the
  fallback writes those stanzas to a separate temporary `.sources` file. It
  points `Dir::Etc::sourcelist` at that file and sets `Dir::Etc::sourceparts`
  to `-` (`apt.conf(5)`; apt hands a `.sources` main list to its deb822
  parser). The update keeps `Error-Mode=any`. The script names the options it
  relies on in a comment.
- The first attempt is unchanged.
- No new external dependency. The pinned package list is unchanged.

Paths: `scripts/ci-install-runtime.py` and its tests, if any exist (for
example in `scripts/test-*.py` or `test/`). This is a CI change (`AGENTS.md`
section 1).

## Acceptance

- A test runs the fallback with a stubbed `apt-get` and asserts the exact
  argument lists. The update and the install name only the temporary source
  file, and the update keeps `Error-Mode=any`. A second test uses an
  `ubuntu.sources` fixture that also contains a third-party stanza: the
  temporary file contains only the rewritten archive stanzas.
- A negative control, a temporary edit that drops the source restriction,
  makes that test fail. The edit is reverted.
- `python3 scripts/check-ci-runners.py`, `python3 scripts/test-ci-runners.py`,
  `python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py` and
  `git diff --check origin/main...HEAD` exit 0. `mix check --affected
  origin/main` exits 0, or the pull request records each command that cannot
  run and the exact reason.
- The full hosted check is green on the exact head.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
