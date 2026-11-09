#!/usr/bin/env python3
"""ELZ-071: is a change documentation only?

One allowlist, used by the workflow (step `Classify the change`) and by the merge queue
(scripts/merge-queue.py loads this file), so that both read the same rule.

A change is documentation only when it has at least one changed path and every changed path is a
regular file under `docs/` or `tasks/`, or one of the root files README.md, GOAL.md and PLAN.md,
except `docs/consuming.md`, which `Elzoo.Export` copies into every export (so the export tests and the
copied consumers read it). Everything else is code or configuration for this purpose: `.github/`,
`scripts/`, `lib/`, `test/`, `pieces/`, `config/`, `registry/`, `mix.*`, `AGENTS.md` and the generated
`LEDGER.md` (the root test `registry_test.exs` reads it). Renames count both paths (git is asked with --no-renames), and a
symlink or submodule entry on either side is never documentation. Any doubt (empty list, failed Git
command, malformed output, an odd path) means "not documentation only".

Commands:
  ci-change-class.py github                 for the workflow: writes docs_only=true|false to $GITHUB_OUTPUT
  ci-change-class.py range <base> <head>    prints true or false for `git diff base...head`
"""
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

DOC_DIRS = ("docs/", "tasks/")
DOC_ROOT_FILES = {"README.md", "GOAL.md", "PLAN.md"}
# Files below docs/ or tasks/ that code reads (checked by test-ci-change-class.py against lib/, test/, pieces/).
READ_BY_CODE = {"docs/consuming.md"}
# Git's raw format: ":<old mode> <new mode> <old sha> <new sha> <status>", then the path, NUL separated.
RAW = re.compile(r"^:([0-7]{6}) ([0-7]{6}) [0-9a-f]{40} [0-9a-f]{40} ([A-Z])$")
SPECIAL_MODES = {"120000", "160000"}  # symlink, submodule


class Unclear(Exception):
    """A reason to answer "not documentation only". Never an error of this script."""


def doc_path(path):
    """True for one path that the allowlist accepts."""
    if not isinstance(path, str) or not path or path != path.strip():
        return False
    if path.startswith("/") or "\\" in path or "\x00" in path or "\n" in path:
        return False
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    if len(parts) == 1:
        return path in DOC_ROOT_FILES
    return path.startswith(DOC_DIRS) and path not in READ_BY_CODE


def docs_only(entries):
    """entries: (old_mode, new_mode, status, path) tuples. True only when every entry is documentation."""
    if not entries:
        return False
    for old_mode, new_mode, status, path in entries:
        if old_mode in SPECIAL_MODES or new_mode in SPECIAL_MODES:
            return False
        if not doc_path(path):
            return False
    return True


def parse_raw(output):
    """Parse `git diff --raw -z --no-renames`. Raises Unclear on any shape it does not know."""
    fields = output.split("\x00")
    if fields and fields[-1] == "":
        fields.pop()
    if len(fields) % 2:
        raise Unclear("odd number of fields in the Git output")
    entries = []
    for header, path in zip(fields[0::2], fields[1::2]):
        match = RAW.match(header)
        if not match or match.group(3) in "RC":
            raise Unclear("unexpected Git output line")
        entries.append((match.group(1), match.group(2), match.group(3), path))
    return entries


def diff_argv(base, head):
    """The one Git command that both the workflow and the queue run: the changes of the head since the merge
    base. Object names are written in full (--no-abbrev); a revision may not start with a dash."""
    for value in (base, head):
        if not re.fullmatch(r"[0-9a-f]{40}|[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}", value or ""):
            raise Unclear("unsafe revision argument")
    # --ignore-submodules=none and --no-relative: a diff.ignoreSubmodules or diff.relative setting of the host
    # (the queue runs on a person's machine) must not hide a gitlink or a path outside the working directory.
    return ["git", "diff", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none", "--no-relative",
            f"{base}...{head}", "--"]


def changed(base, head, run=subprocess.run):
    """The changed entries of `git diff base...head` (the changes of the head since the merge base)."""
    result = run(diff_argv(base, head), capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise Unclear("git diff failed")
    return parse_raw(result.stdout)


def classify_range(base, head, run=subprocess.run):
    try:
        return docs_only(changed(base, head, run))
    except (Unclear, OSError, subprocess.TimeoutExpired, ValueError):
        return False


def classify_github(env, run=subprocess.run):
    """For the workflow. A pull_request run checks out the merge of the head into the base: HEAD^1 is the
    base, HEAD^2 is the head. Any other event, or a HEAD that is not such a merge, is not documentation."""
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return False
    try:
        parents = run(["git", "rev-list", "--parents", "-n1", "HEAD"], capture_output=True, text=True,
                      timeout=60).stdout.split()
        if len(parents) != 3 or not all(re.fullmatch(r"[0-9a-f]{40}", p) for p in parents):
            return False
        return classify_range(parents[1], parents[2], run)
    except (OSError, subprocess.TimeoutExpired):
        return False


def main(argv, env=None, out=print):
    env = os.environ if env is None else env
    if len(argv) == 1 and argv[0] == "github":
        verdict = classify_github(env)
        out(f"ELZOO CHANGE CLASS: docs_only={'true' if verdict else 'false'}")
        target = env.get("GITHUB_OUTPUT")
        if target:
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(f"docs_only={'true' if verdict else 'false'}\n")
        return 0
    if len(argv) == 3 and argv[0] == "range":
        out("true" if classify_range(argv[1], argv[2]) else "false")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
