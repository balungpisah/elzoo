#!/usr/bin/env python3
"""ELZ-071: is a change documentation only?

One allowlist, used by the workflow (step `Classify the change`) and by the merge queue
(scripts/merge-queue.py loads this file), so that both read the same rule.

A change is documentation only when it has at least one changed path and every changed path is a
regular file under `docs/` or `tasks/`, or one of the root files README.md, GOAL.md, PLAN.md and AGENTS.md,
except `docs/consuming.md`, which `Elzoo.Export` copies into every export (so the export tests and the
copied consumers read it). Everything else is code or configuration for this purpose: `.github/`,
`scripts/`, `lib/`, `test/`, `pieces/`, `config/`, `registry/`, `mix.*` and the generated
`LEDGER.md` (the root test `registry_test.exs` reads it). Renames count both paths (git is asked with --no-renames), and a
symlink or submodule entry on either side is never documentation. Any doubt (empty list, failed Git
command, malformed output, an odd path) means "not documentation only".

Small gate: is a change Piece-only?

A change is Piece-only when it has at least one changed path below `pieces/<family>/<name>/` and every changed path
is one of: a regular file below `pieces/<family>/<name>/` (family and name in lower case letters, digits and dashes);
an index or generated file (INDEX_FILES); or a path that the documentation allowlist above accepts. Everything else
means "not Piece-only": `pieces/test_helper.exs`, a file directly below `pieces/` or `pieces/<family>/`, `lib/`,
`test/`, `config/`, `scripts/`, `.github/`, `mix.*`, `docs/consuming.md`. The same rules as above apply: renames count
both paths (a rename out of or into the class is not Piece-only; a raw rename or copy entry is refused), a symlink or
submodule entry is never Piece-only, and any doubt means "not Piece-only". A Piece-only change also names the set of
changed Piece IDs (`<family>/<name>`). A Piece-only pull request gets the small gate (`mix check --piece`) instead of
the full check; the full check runs on main after the merge.

Commands:
  ci-change-class.py github                 for the workflow: writes docs_only=true|false to $GITHUB_OUTPUT
  ci-change-class.py github-piece           for the workflow: writes piece_only=true|false to $GITHUB_OUTPUT
  ci-change-class.py range <base> <head>    prints true or false for `git diff base...head`
  ci-change-class.py piece-paths <path>...  for `mix check --piece`: prints one JSON object
                                            {"piece_only": bool, "pieces": [...], "refused": path or null}
"""
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

DOC_DIRS = ("docs/", "tasks/")
# ELZ-073 scope addition (owner, 2026-11-09): AGENTS.md is documentation. No test or code reads it (the scan in
# test-ci-change-class.py looks for it too); scripts/check-roadmap.py reads it and runs in the short check.
DOC_ROOT_FILES = {"README.md", "GOAL.md", "PLAN.md", "AGENTS.md"}
# Files below docs/ or tasks/ that code reads (checked by test-ci-change-class.py against lib/, test/, pieces/).
READ_BY_CODE = {"docs/consuming.md"}
# Git's raw format: ":<old mode> <new mode> <old sha> <new sha> <status>", then the path, NUL separated.
RAW = re.compile(r"^:([0-7]{6}) ([0-7]{6}) [0-9a-f]{40} [0-9a-f]{40} ([A-Z])$")
SPECIAL_MODES = {"120000", "160000"}  # symlink, submodule
# Small gate: the index and generated files that a Piece task changes in its last commit (AGENTS.md section 3).
# scripts/check-roadmap.py (plan job) and the root tests that read the index (mix check --piece) check them.
INDEX_FILES = {"registry/catalogue.json", "docs/plans/release-plan.json", "LEDGER.md", "docs/plans/views.md",
               "docs/plans/dependencies.mmd"}
PIECE_SEGMENT = re.compile(r"[a-z0-9][a-z0-9-]*")


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


def piece_id(path):
    """The Piece ID `<family>/<name>` of a path below `pieces/<family>/<name>/`, or None."""
    if not doc_path_shape(path):
        return None
    parts = path.split("/")
    if len(parts) < 4 or parts[0] != "pieces":
        return None
    if not (PIECE_SEGMENT.fullmatch(parts[1]) and PIECE_SEGMENT.fullmatch(parts[2])):
        return None
    return f"{parts[1]}/{parts[2]}"


def doc_path_shape(path):
    """The shape rules of doc_path without the allowlist: a plain relative path with no odd part."""
    if not isinstance(path, str) or not path or path != path.strip():
        return False
    if path.startswith("/") or "\\" in path or any(ord(char) < 0x20 or ord(char) == 0x7F for char in path):
        return False
    return not any(part in ("", ".", "..") for part in path.split("/"))


def piece_paths(paths):
    """(piece_only, sorted Piece IDs, first refused path or None) for a list of paths, without modes."""
    if not isinstance(paths, list) or not paths:
        return False, [], None
    ids = set()
    for path in paths:
        found = piece_id(path)
        if found:
            ids.add(found)
        elif not (doc_path_shape(path) and (path in INDEX_FILES or doc_path(path))):
            return False, [], path
    return bool(ids), sorted(ids), None


def piece_only(entries):
    """entries: (old_mode, new_mode, status, path) tuples. (True, IDs) only when the change is Piece-only."""
    if not entries:
        return False, []
    for old_mode, new_mode, status, path in entries:
        if old_mode in SPECIAL_MODES or new_mode in SPECIAL_MODES:
            return False, []
    verdict, ids, _refused = piece_paths([path for _o, _n, _s, path in entries])
    return (True, ids) if verdict else (False, [])


SPIKE_PREFIXES = ("spikes/ash_foundation/", "spikes/gleam_ui/")
SPIKE_INDEX = {"docs/plans/release-plan.json", "docs/plans/views.md", "docs/plans/dependencies.mmd"}


def spike_only(entries):
    """(spike-only, Ash changed) for regular spike files plus permitted documentation."""
    found = ash = False
    for old, new, status, path in entries:
        if old not in {"000000", "100644", "100755"} or new not in {"000000", "100644", "100755"}:
            return False, False
        if not doc_path_shape(path):
            return False, False
        if path.startswith(SPIKE_PREFIXES):
            found = True
            ash = ash or path.startswith(SPIKE_PREFIXES[0])
        elif not (doc_path(path) or path in SPIKE_INDEX):
            return False, False
    return found, ash if found else False


def classify_spike_github(env, run=subprocess.run):
    pair = merge_parents(env, run)
    if pair is None:
        return False, False
    try:
        return spike_only(changed(*pair, run=run))
    except (Unclear, OSError, subprocess.TimeoutExpired, ValueError):
        return False, False


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


def classify_piece_range(base, head, run=subprocess.run):
    try:
        return piece_only(changed(base, head, run))
    except (Unclear, OSError, subprocess.TimeoutExpired, ValueError):
        return False, []


def merge_parents(env, run):
    """(base, head) of a pull_request merge checkout, or None for any other event or shape."""
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return None
    try:
        parents = run(["git", "rev-list", "--parents", "-n1", "HEAD"], capture_output=True, text=True,
                      timeout=60).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return None
    if len(parents) != 3 or not all(re.fullmatch(r"[0-9a-f]{40}", p) for p in parents):
        return None
    return parents[1], parents[2]


def classify_piece_github(env, run=subprocess.run):
    """For the workflow: only a pull_request run can be Piece-only. A push, a dispatch or any other event, and a HEAD
    that is not a two-parent merge, are never Piece-only."""
    pair = merge_parents(env, run)
    if pair is None:
        return False, []
    return classify_piece_range(pair[0], pair[1], run)


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
    if len(argv) == 1 and argv[0] == "github-spike":
        verdict, ash = classify_spike_github(env)
        out(f"ELZOO CHANGE CLASS: spike_only={str(verdict).lower()} ash={str(ash).lower()}")
        target = env.get("GITHUB_OUTPUT")
        if target:
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(f"spike_only={str(verdict).lower()}\nash={str(ash).lower()}\n")
        return 0
    if len(argv) == 1 and argv[0] == "github-piece":
        verdict, ids = classify_piece_github(env)
        out(f"ELZOO CHANGE CLASS: piece_only={'true' if verdict else 'false'} pieces={','.join(ids) or 'none'}")
        target = env.get("GITHUB_OUTPUT")
        if target:
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(f"piece_only={'true' if verdict else 'false'}\n")
        return 0
    if len(argv) >= 2 and argv[0] == "piece-paths":
        verdict, ids, refused = piece_paths(argv[1:])
        out(json.dumps({"piece_only": verdict, "pieces": ids, "refused": refused}))
        return 0
    if len(argv) == 3 and argv[0] == "range":
        out("true" if classify_range(argv[1], argv[2]) else "false")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
