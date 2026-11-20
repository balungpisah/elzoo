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

ELZ-277: a strictly planned-only publication (AGENTS.md section 5) is documentation only too. Its paths are
documentation plus `registry/catalogue.json` and `LEDGER.md`, both modified regular files; the catalogue keeps every
other field and every existing entry unchanged and in order and only adds planned rows (exactly id, summary,
disposition, phase, status `planned` and reason; so no manifest), and LEDGER.md only gains the rows that
`mix elzoo.ledger` writes for them. The classifier reads both blobs of each file by the object names of the raw diff
(`docs_only_output`); every other shape keeps its class.

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
import bisect
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
RAW = re.compile(r"^:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([A-Z])$")
SPECIAL_MODES = {"120000", "160000"}  # symlink, submodule
# Small gate: the index and generated files that a Piece task changes in its last commit (AGENTS.md section 3).
# scripts/check-roadmap.py (plan job) and the root tests that read the index (mix check --piece) check them.
INDEX_FILES = {"registry/catalogue.json", "docs/plans/release-plan.json", "LEDGER.md", "docs/plans/views.md",
               "docs/plans/dependencies.mmd"}
PIECE_SEGMENT = re.compile(r"[a-z0-9][a-z0-9-]*")
# ELZ-277: a strictly planned-only publication also changes these two files: the catalogue gains planned rows (read by
# the Registry, checked against the plan by scripts/check-roadmap.py in the short check) and the generated ledger gains
# their rows. The shape of an added row is the planned row of the coordinator guide; the ID form is the Registry's.
PLANNED_FILES = ("registry/catalogue.json", "LEDGER.md")
PLANNED_FIELDS = {"id", "summary", "disposition", "phase", "status", "reason"}
PLANNED_ID = re.compile(r"[a-z][a-z0-9-]*/[a-z][a-z0-9-]*")
LEDGER_TABLE = "| --- | --- | --- | --- | --- | --- | --- |\n"
LEDGER_ROW = re.compile(r"\| (?:`([a-z][a-z0-9-]*/[a-z][a-z0-9-]*)` \||\[([a-z][a-z0-9-]*/[a-z][a-z0-9-]*)\]\()")


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


def docs_only_output(output, run=subprocess.run):
    """The documentation-only verdict for `git diff --raw` output, as the workflow, the queue and the push-run skip
    decision ask it: documentation paths only, or a strictly planned-only publication. Raises Unclear on output that
    `raw_records` does not know."""
    records = raw_records(output)
    return docs_only([(o, n, s, p) for o, n, _a, _b, s, p in records]) or planned_publication(records, run)


def planned_publication(records, run=subprocess.run):
    """ELZ-277: True only for a strictly planned-only publication (AGENTS.md section 5). Every path is documentation
    or one of PLANNED_FILES; both of those are modified regular files; the catalogue only adds planned entries
    without a manifest (added_planned_entries); and LEDGER.md only gains their generated rows (ledger_with). Reads
    the two blobs of each file by the object names of the raw diff. Any doubt means False."""
    blobs = {}
    for old_mode, new_mode, old_blob, new_blob, status, path in records:
        if path in PLANNED_FILES:
            if (old_mode, new_mode, status) != ("100644", "100644", "M") or path in blobs:
                return False
            blobs[path] = (old_blob, new_blob)
        elif old_mode in SPECIAL_MODES or new_mode in SPECIAL_MODES or not doc_path(path):
            return False
    if set(blobs) != set(PLANNED_FILES):
        return False
    try:
        base, head = (strict_json(read_blob(blob, run)) for blob in blobs["registry/catalogue.json"])
        added = added_planned_entries(base, head)
        ledger_base, ledger_head = (read_blob(blob, run) for blob in blobs["LEDGER.md"])
        return ledger_head == ledger_with(ledger_base, added)
    except (Unclear, ValueError, KeyError, TypeError, AttributeError, RecursionError, OSError,
            subprocess.TimeoutExpired):
        return False


def read_blob(blob, run=subprocess.run):
    """The exact bytes of one blob (no text decoding, no newline translation)."""
    result = run(["git", "cat-file", "blob", blob], capture_output=True, timeout=60)
    if result.returncode != 0 or not isinstance(result.stdout, bytes):
        raise Unclear("git cat-file failed")
    return result.stdout


def strict_json(data):
    """JSON from UTF-8 bytes; a duplicate key or a non-standard constant (NaN, Infinity) is refused, so that this
    reading cannot differ from the one of the Registry (Jason)."""
    def pairs(items):
        if len({key for key, _ in items}) != len(items):
            raise Unclear("duplicate JSON key")
        return dict(items)

    def constant(name):
        raise Unclear(f"non-standard JSON constant {name}")

    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)


def canonical(value):
    """A type-strict comparison key: 1, 1.0 and true differ, as they do for the Registry."""
    return json.dumps(value, sort_keys=True, allow_nan=False)


def added_planned_entries(base, head):
    """The entries that the head catalogue adds when that is its whole change: every other top-level field is
    unchanged, the base entries appear unchanged and in order, and each added entry is a planned row with exactly
    PLANNED_FIELDS (so no manifest). Raises Unclear (or a lookup error) otherwise."""
    if not (isinstance(base, dict) and isinstance(head, dict)):
        raise Unclear("the catalogue is not an object")
    old, new = base["entries"], head["entries"]
    if not (isinstance(old, list) and isinstance(new, list)):
        raise Unclear("the catalogue entries are not a list")
    if canonical({k: v for k, v in base.items() if k != "entries"}) != \
            canonical({k: v for k, v in head.items() if k != "entries"}):
        raise Unclear("a top-level catalogue field changed")
    kept, added, position = [canonical(entry) for entry in old], [], 0
    for entry in new:
        if position < len(kept) and canonical(entry) == kept[position]:
            position += 1
        else:
            added.append(entry)
    if position != len(kept) or not added:
        raise Unclear("an existing catalogue entry changed, moved or went away")
    for entry in added:
        if not (isinstance(entry, dict) and set(entry) == PLANNED_FIELDS and entry["status"] == "planned" and
                all(plain_text(value) for value in entry.values()) and PLANNED_ID.fullmatch(entry["id"])):
            raise Unclear("an added catalogue entry is not a planned row")
    ids = [entry["id"] for entry in new]
    if len(set(ids)) != len(ids):
        raise Unclear("duplicate catalogue ID")
    return added


def plain_text(value):
    """A string with a letter or digit and no control character (C0, DEL or C1) or lone surrogate."""
    return (isinstance(value, str) and any(char.isalnum() for char in value) and
            not any(ord(char) < 0x20 or 0x7F <= ord(char) <= 0x9F or 0xD800 <= ord(char) <= 0xDFFF for char in value))


def ledger_with(ledger, added):
    """LEDGER.md bytes with the row that `Elzoo.Registry.ledger/1` writes for each added planned entry, in ID order.
    Raises Unclear when the base ledger does not have that generated shape."""
    head, table, body = ledger.decode("utf-8").partition(LEDGER_TABLE)
    if not table or LEDGER_TABLE in body or not body.endswith("\n"):
        raise Unclear("unexpected ledger shape")
    rows = body[:-1].split("\n")
    ids = []
    for row in rows:
        match = LEDGER_ROW.match(row)
        if not match:
            raise Unclear("unexpected ledger row")
        ids.append(match.group(1) or match.group(2))
    if ids != sorted(set(ids)):
        raise Unclear("the ledger rows are not in ID order")
    for entry in added:
        if entry["id"] in ids:
            raise Unclear("the ledger already has a row for an added ID")
        at = bisect.bisect(ids, entry["id"])
        reason = entry["reason"].replace("|", "\\|")
        ids.insert(at, entry["id"])
        rows.insert(at, f"| `{entry['id']}` | {entry['status']} | {entry['disposition']} (planned) | — | none claimed | "
                        f"unassessed | {reason} |")
    return (head + table + "\n".join(rows) + "\n").encode("utf-8")


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


def raw_records(output):
    """Parse `git diff --raw -z --no-renames --no-abbrev` into (old mode, new mode, old blob, new blob, status, path)
    records. Raises Unclear on any shape it does not know."""
    fields = output.split("\x00")
    if fields and fields[-1] == "":
        fields.pop()
    if len(fields) % 2:
        raise Unclear("odd number of fields in the Git output")
    records = []
    for header, path in zip(fields[0::2], fields[1::2]):
        match = RAW.match(header)
        if not match or match.group(5) in "RC":
            raise Unclear("unexpected Git output line")
        records.append((*match.groups(), path))
    return records


def parse_raw(output):
    """The (old_mode, new_mode, status, path) entries of `raw_records`."""
    return [(old, new, status, path) for old, new, _old_blob, _new_blob, status, path in raw_records(output)]


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


def diff_output(base, head, run=subprocess.run):
    """The raw output of `git diff base...head` (the changes of the head since the merge base)."""
    result = run(diff_argv(base, head), capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise Unclear("git diff failed")
    return result.stdout


def changed(base, head, run=subprocess.run):
    """The changed entries of `git diff base...head`."""
    return parse_raw(diff_output(base, head, run))


def classify_range(base, head, run=subprocess.run):
    try:
        return docs_only_output(diff_output(base, head, run), run)
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
