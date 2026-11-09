#!/usr/bin/env python3
"""ELZ-071: offline controls for scripts/ci-change-class.py (the documentation-only allowlist).

The classifier tests use real Git repositories in temporary directories; the allowlist guard test scans the
repository sources.
"""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ci_change_class", ROOT / "scripts/ci-change-class.py")
cc = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(cc)

Z = "0" * 40
H = "a" * 40


def raw(*entries):
    """Git's `--raw -z` output for (old_mode, new_mode, status, path) entries."""
    return "".join(f":{old} {new} {H} {H} {status}\x00{path}\x00" for old, new, status, path in entries)


def file_entry(path, status="M"):
    return ("100644", "100644", status, path)


class Allowlist(unittest.TestCase):
    ALLOWED = ["docs/a.md", "docs/work/ELZ-010.md", "docs/plans/release-plan.json", "docs/deep/a/b/c/d.md",
               "tasks/ELZ-071-docs-only-fast-path.md", "tasks/x", "README.md", "GOAL.md", "PLAN.md",
               "docs/consuming.md.bak", "docs/Consuming.md"]
    DENIED = [
        # code and configuration of every kind
        ".github/workflows/symbolic-check.yml", ".github/CODEOWNERS", "scripts/ci-change-class.py",
        "scripts/x.md", "lib/elzoo/export.ex", "lib/x.md", "test/registry_test.exs", "test/x.md",
        "pieces/core/selection/README.md", "pieces/core/selection/piece.json", "pieces/x/y/docs/a.md",
        "config/config.exs", "registry/catalogue.json", "mix.exs", "mix.lock", "AGENTS.md", "LEDGER.md",
        "LICENSE", "NOTICE", ".gitignore", ".formatter.exs", "spikes/gleam_ui/README.md", "CLAUDE.md",
        # files that code reads
        "docs/consuming.md",
        # look-alikes
        "docs-x/a.md", "tasks-x/a.md", "docs", "tasks", "docs/", "tasks/", "doc/a.md", "Docs/a.md", "TASKS/a.md",
        "readme.md", "Readme.md", "README.md/x", "README.markdown", "GOAL.md.x", "PLAN.mdx", "xdocs/a.md",
        "a/docs/b.md", "a/tasks/b.md", "scripts/docs/a.md",
        # traversal and odd forms
        "docs/../scripts/x.py", "docs/..", "../docs/a.md", "docs/./a.md", "./docs/a.md", "docs//a.md",
        "/docs/a.md", "docs\\a.md", "docs/a.md\nscripts/x.py", "docs/a.md\x00", " docs/a.md", "docs/a.md ",
        "\tdocs/a.md", "", " ", None, 5, b"docs/a.md",
    ]

    def test_each_allowed_path(self):
        for path in self.ALLOWED:
            with self.subTest(path=path):
                self.assertTrue(cc.doc_path(path))

    def test_each_denied_path(self):
        for path in self.DENIED:
            with self.subTest(path=path):
                self.assertFalse(cc.doc_path(path))

    def test_the_files_that_code_reads_are_not_documentation(self):
        self.assertEqual({"docs/consuming.md"}, set(cc.READ_BY_CODE))
        for path in cc.READ_BY_CODE:
            self.assertFalse(cc.doc_path(path))

    def test_a_change_is_documentation_only_when_every_entry_is(self):
        self.assertTrue(cc.docs_only([file_entry("docs/a.md"), file_entry("tasks/b.md"), file_entry("README.md")]))
        self.assertTrue(cc.docs_only([("000000", "100644", "A", "docs/new.md")]))   # added
        self.assertTrue(cc.docs_only([("100644", "000000", "D", "docs/old.md")]))   # deleted
        self.assertTrue(cc.docs_only([("100644", "100755", "M", "docs/x.sh")]))     # mode change of a doc file

    def test_one_code_path_makes_the_whole_change_code(self):
        for code in ("scripts/x.py", "lib/x.ex", "AGENTS.md", "LEDGER.md", ".github/workflows/symbolic-check.yml",
                     "docs/consuming.md", "scripts/ci-change-class.py"):
            with self.subTest(code=code):
                self.assertFalse(cc.docs_only([file_entry("docs/a.md"), file_entry(code), file_entry("tasks/b.md")]))
                self.assertFalse(cc.docs_only([file_entry(code), file_entry("docs/a.md")]))

    def test_an_empty_list_is_not_documentation(self):
        self.assertFalse(cc.docs_only([]))

    def test_symlink_and_submodule_entries_are_never_documentation(self):
        for old, new in (("120000", "120000"), ("000000", "120000"), ("120000", "000000"), ("100644", "120000"),
                         ("120000", "100644"), ("160000", "160000"), ("000000", "160000"), ("160000", "000000")):
            with self.subTest(old=old, new=new):
                self.assertFalse(cc.docs_only([(old, new, "M", "docs/link")]))
                self.assertFalse(cc.docs_only([file_entry("docs/a.md"), (old, new, "M", "docs/link")]))


class ParseRaw(unittest.TestCase):
    def test_valid_output(self):
        entries = cc.parse_raw(raw(file_entry("docs/a.md"), ("000000", "100644", "A", "tasks/b.md")))
        self.assertEqual([("100644", "100644", "M", "docs/a.md"), ("000000", "100644", "A", "tasks/b.md")], entries)

    def test_empty_output_is_an_empty_list(self):
        self.assertEqual([], cc.parse_raw(""))

    def test_paths_with_spaces_and_unusual_characters_are_kept_whole(self):
        entries = cc.parse_raw(raw(file_entry("docs/a b.md"), file_entry("docs/éè.md"), file_entry("docs/a\nb.md")))
        self.assertEqual(["docs/a b.md", "docs/éè.md", "docs/a\nb.md"], [e[3] for e in entries])
        self.assertFalse(cc.docs_only(entries))  # a newline in a path is odd and refused

    def test_unknown_shapes_raise(self):
        bad = {
            "odd number of fields": raw(file_entry("docs/a.md")) + ":100644 100644 " + H + " " + H + " M\x00",
            "rename status": raw(("100644", "100644", "R", "docs/a.md")),
            "copy status": raw(("100644", "100644", "C", "docs/a.md")),
            "lowercase status": raw(("100644", "100644", "m", "docs/a.md")),
            "short sha": f":100644 100644 {'a' * 39} {H} M\x00docs/a.md\x00",
            "no colon": f"100644 100644 {H} {H} M\x00docs/a.md\x00",
            "bad mode": f":10064 100644 {H} {H} M\x00docs/a.md\x00",
            "combined diff": f"::100644 100644 100644 {H} {H} {H} MM\x00docs/a.md\x00",
            "plain text": "docs/a.md\n",
            "header only": f":100644 100644 {H} {H} M\x00",
            "newline separated": f":100644 100644 {H} {H} M\ndocs/a.md\n",
        }
        for label, output in bad.items():
            with self.subTest(label=label):
                with self.assertRaises(cc.Unclear):
                    cc.parse_raw(output)


class FakeRun:
    """A stand-in for subprocess.run that answers with fixed output."""

    def __init__(self, stdout="", returncode=0, error=None):
        self.stdout, self.returncode, self.error, self.calls = stdout, returncode, error, []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        if self.error:
            raise self.error
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, "")


class RangeClassification(unittest.TestCase):
    def test_documentation_range(self):
        run = FakeRun(raw(file_entry("docs/a.md")))
        self.assertTrue(cc.classify_range("main", "task/ELZ-071", run))
        self.assertEqual([["git", "diff", "--raw", "-z", "--no-renames", "--no-abbrev", "main...task/ELZ-071", "--"]],
                         run.calls)
        self.assertEqual(run.calls[0], cc.diff_argv("main", "task/ELZ-071"))

    def test_code_range(self):
        self.assertFalse(cc.classify_range(H, "b" * 40, FakeRun(raw(file_entry("docs/a.md"), file_entry("lib/x.ex")))))

    def test_every_failure_means_not_documentation(self):
        cases = {
            "git failed": FakeRun(raw(file_entry("docs/a.md")), returncode=128),
            "empty list": FakeRun(""),
            "malformed": FakeRun("garbage"),
            "rename": FakeRun(raw(("100644", "100644", "R", "docs/a.md"))),
            "timeout": FakeRun(error=subprocess.TimeoutExpired(["git"], 60)),
            "git missing": FakeRun(error=FileNotFoundError("git")),
            "undecodable output": FakeRun(error=UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")),
            "value error": FakeRun(error=ValueError("x")),
        }
        for label, run in cases.items():
            with self.subTest(label=label):
                self.assertFalse(cc.classify_range("main", "head", run))

    def test_unsafe_revision_arguments_are_refused_before_git_runs(self):
        for value in ("", None, "--output=x", "a b", "a;b", "$(x)", "a\nb", "-x", "-", "--", "x" * 201, "a`b`",
                      "a\x00b", "a\tb", "a'b", 'a"b', "a|b", "a&b", "a>b"):
            with self.subTest(value=value):
                run = FakeRun(raw(file_entry("docs/a.md")))
                self.assertFalse(cc.classify_range(value, "head", run))
                self.assertFalse(cc.classify_range("main", value, run))
                self.assertEqual([], run.calls)


    def test_git_prints_full_object_names_so_that_the_parser_can_read_the_real_output(self):
        # Without --no-abbrev Git shortens the names to 7 characters and every real change would be "unclear".
        self.assertIn("--no-abbrev", cc.diff_argv("main", "head"))
        self.assertIsNotNone(cc.RAW.match(f":000000 100644 {Z} {H} A"))
        self.assertIsNone(cc.RAW.match(":000000 100644 0000000 6178079 A"))


class GitRepository(unittest.TestCase):
    """Real Git: the same commands that the workflow and the queue run."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="elzoo-class-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        self.write("docs/a.md", "a\n")
        self.write("scripts/tool.py", "print(1)\n")
        self.write("README.md", "r\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")

    def git(self, *argv):
        result = subprocess.run(["git", "-C", self.dir, *argv], capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def write(self, relative, text):
        path = Path(self.dir) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def branch(self, change):
        """Commit `change()` on a branch, merge it into main with a merge commit and return the merge commit."""
        self.git("switch", "-qc", "pr")
        change()
        self.git("add", "-A")
        self.git("commit", "-qm", "pr", "--allow-empty")
        self.git("switch", "-q", "main")
        self.git("merge", "-q", "--no-ff", "pr", "-m", "merge")
        return self.git("rev-parse", "HEAD")

    def github(self, event="pull_request"):
        env = {"GITHUB_EVENT_NAME": event}
        cwd = os.getcwd()
        os.chdir(self.dir)
        try:
            return cc.classify_github(env)
        finally:
            os.chdir(cwd)

    def range(self, base, head):
        cwd = os.getcwd()
        os.chdir(self.dir)
        try:
            return cc.classify_range(base, head)
        finally:
            os.chdir(cwd)

    def test_a_documentation_merge_is_documentation_only(self):
        self.branch(lambda: (self.write("docs/b.md", "b\n"), self.write("tasks/ELZ-1.md", "t\n")))
        self.assertTrue(self.github())

    def test_one_code_path_in_the_merge_is_code(self):
        self.branch(lambda: (self.write("docs/b.md", "b\n"), self.write("scripts/tool.py", "print(2)\n")))
        self.assertFalse(self.github())

    def test_a_pull_request_that_edits_the_classifier_is_never_documentation_only(self):
        self.write("scripts/ci-change-class.py", "x = 1\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "classifier")
        self.branch(lambda: (self.write("scripts/ci-change-class.py", "x = 2\n"), self.write("docs/b.md", "b\n")))
        self.assertFalse(self.github())

    def test_the_file_that_the_export_copies_is_code(self):
        self.write("docs/consuming.md", "c\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "consuming")
        self.branch(lambda: self.write("docs/consuming.md", "changed\n"))
        self.assertFalse(self.github())

    def test_the_generated_ledger_and_agents_are_code(self):
        self.write("LEDGER.md", "l\n")
        self.write("AGENTS.md", "a\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "root files")
        for name in ("LEDGER.md", "AGENTS.md"):
            with self.subTest(name=name):
                self.branch(lambda: self.write(name, "changed\n"))
                self.assertFalse(self.github())
                self.git("reset", "-q", "--hard", "HEAD~1")
                self.git("branch", "-qD", "pr")

    def test_a_rename_counts_both_paths(self):
        for source, target in (("docs/a.md", "scripts/a.md"), ("scripts/tool.py", "docs/tool.py")):
            with self.subTest(source=source):
                self.setUp()
                self.branch(lambda: (Path(self.dir, target).parent.mkdir(parents=True, exist_ok=True),
                                     self.git("mv", source, target)))
                self.assertFalse(self.github())

    def test_a_rename_inside_the_documentation_is_documentation_only(self):
        self.branch(lambda: (Path(self.dir, "tasks").mkdir(exist_ok=True), self.git("mv", "docs/a.md", "tasks/a.md")))
        self.assertTrue(self.github())

    def test_a_symlink_in_docs_is_never_documentation(self):
        self.branch(lambda: os.symlink("../scripts/tool.py", Path(self.dir, "docs/link.md")))
        self.assertFalse(self.github())

    def test_replacing_a_documentation_file_by_a_symlink_is_never_documentation(self):
        def change():
            Path(self.dir, "docs/a.md").unlink()
            os.symlink("../scripts/tool.py", Path(self.dir, "docs/a.md"))
        self.branch(change)
        self.assertFalse(self.github())

    def test_a_submodule_entry_is_never_documentation(self):
        self.branch(lambda: self.git("update-index", "--add", "--cacheinfo", f"160000,{H},docs/sub"))
        self.assertFalse(self.github())

    def test_a_deleted_documentation_file_is_documentation_only(self):
        self.branch(lambda: self.git("rm", "-q", "docs/a.md"))
        self.assertTrue(self.github())

    def test_an_empty_change_is_not_documentation(self):
        self.branch(lambda: None)
        self.assertFalse(self.github())

    def test_other_events_are_never_documentation(self):
        self.branch(lambda: self.write("docs/b.md", "b\n"))
        for event in ("push", "workflow_dispatch", "pull_request_target", "schedule", "", None):
            with self.subTest(event=event):
                self.assertFalse(self.github(event))

    def test_a_head_that_is_not_a_merge_commit_is_not_documentation(self):
        self.write("docs/b.md", "b\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "docs only, no merge")
        self.assertFalse(self.github())

    def test_an_octopus_merge_is_not_documentation(self):
        for name in ("one", "two"):
            self.git("switch", "-qc", name, "main")
            self.write(f"docs/{name}.md", name)
            self.git("add", "-A")
            self.git("commit", "-qm", name)
        self.git("switch", "-q", "main")
        self.git("merge", "-q", "--no-ff", "one", "two", "-m", "octopus")
        self.assertFalse(self.github())

    def test_the_range_form_is_the_three_dot_diff(self):
        base = self.git("rev-parse", "HEAD")
        self.git("switch", "-qc", "task")
        self.write("docs/b.md", "b\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "docs")
        head = self.git("rev-parse", "HEAD")
        self.git("switch", "-q", "main")
        self.write("scripts/tool.py", "print(3)\n")   # a code change on main only: not part of the change of the head
        self.git("add", "-A")
        self.git("commit", "-qm", "code on main")
        self.assertTrue(self.range(self.git("rev-parse", "main"), head))
        self.assertTrue(self.range(base, head))

    def test_a_missing_revision_is_not_documentation(self):
        self.assertFalse(self.range("0" * 40, "1" * 40))

    def test_a_directory_that_is_not_a_repository_is_not_documentation(self):
        empty = tempfile.mkdtemp(prefix="elzoo-class-empty-")
        self.addCleanup(shutil.rmtree, empty, True)
        cwd = os.getcwd()
        os.chdir(empty)
        try:
            self.assertFalse(cc.classify_github({"GITHUB_EVENT_NAME": "pull_request"}))
        finally:
            os.chdir(cwd)


class CommandLine(unittest.TestCase):
    def test_github_writes_the_output_file_and_a_log_line(self):
        out, lines = Path(tempfile.mkdtemp(prefix="elzoo-class-out-")), []
        self.addCleanup(shutil.rmtree, out, True)
        target = out / "output"
        self.assertEqual(0, cc.main(["github"], env={"GITHUB_EVENT_NAME": "push", "GITHUB_OUTPUT": str(target)},
                                    out=lines.append))
        self.assertEqual("docs_only=false\n", target.read_text())
        self.assertEqual(["ELZOO CHANGE CLASS: docs_only=false"], lines)

    def test_github_without_an_output_file_still_succeeds(self):
        lines = []
        self.assertEqual(0, cc.main(["github"], env={"GITHUB_EVENT_NAME": "push"}, out=lines.append))
        self.assertEqual(["ELZOO CHANGE CLASS: docs_only=false"], lines)

    def test_range_prints_the_verdict(self):
        lines = []
        self.assertEqual(0, cc.main(["range", "0" * 40, "1" * 40], out=lines.append))
        self.assertEqual(["false"], lines)

    def test_other_arguments_print_the_usage_and_fail(self):
        for argv in ([], ["range"], ["range", "a"], ["github", "x"], ["other"], ["range", "a", "b", "c"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(2, cc.main(argv, env={}))


# --- the allowlist guard: no test or code may read a documentation file unseen -------------------------------
# A documentation-only pull request is not tested by `mix test`, so code and tests must not read a file that the
# allowlist accepts. This scan lists every path literal of `docs/`, `tasks/` and the root documentation files in
# the Elixir sources. A literal is allowed only when it appears in the reviewed list below, with the reason; the
# file that code does read (docs/consuming.md) is not in the allowlist, which a second test checks.
SCANNED = ("lib/**/*.ex", "lib/**/*.exs", "test/**/*.ex", "test/**/*.exs", "config/**/*.ex", "config/**/*.exs",
           "pieces/*/*/lib/**/*.ex", "pieces/*/*/lib/**/*.exs", "pieces/*/*/test/**/*.ex",
           "pieces/*/*/test/**/*.exs", "mix.exs", ".formatter.exs")
LITERALS = [
    re.compile(r"""(?<![A-Za-z0-9_.@/-])((?:docs|tasks)/[^\s"'`)\]]*)"""),
    re.compile(r"""(["'](?:docs|tasks)["'])"""),
    re.compile(r"""(?<![A-Za-z0-9_.-])((?:GOAL|PLAN)\.md)"""),
    re.compile(r"""(["']README\.md["'])"""),
]
# (file, literal) -> why it is not a read of a documentation file that the allowlist accepts.
REVIEWED = {
    ("lib/elzoo/export.ex", "docs/consuming.md"):
        "READ: the export copies it into every bundle; docs/consuming.md is not in the allowlist (READ_BY_CODE)",
    ("lib/elzoo/registry.ex", "docs/operational-contracts.md"): "text of a message, not a read",
    ("pieces/assembly/durable-job/lib/elzoo/durable_job.ex", "docs/work/ELZ-010.md"): "comment, not a read",
    ("test/check_selection_test.exs", '"README.md"'): "name of a file in a selection fixture (piece README), not a read",
    ("test/check_selection_test.exs", "docs/unknown.md"): "string in a selection fixture, not a read",
    ("test/elz010_cure_probe_test.exs", "docs/work/ELZ-010.md"): "comment, not a read",
    ("test/elz010_provider_probe_test.exs", "docs/work/ELZ-010.md"): "comment, not a read",
    ("test/registry_test.exs", '"README.md"'): "evidence name in a piece manifest fixture, not a read",
    ("test/support/elz010_probe_test_helper.exs", "docs/work/ELZ-010.md"): "comment, not a read",
}


def source_files(root):
    found = set()
    for pattern in SCANNED:
        found.update(path for path in Path(root).glob(pattern) if path.is_file())
    return sorted(found)


def documentation_literals(root):
    """{(relative file, literal): [line numbers]} for every path literal of a documentation file."""
    hits = {}
    for path in source_files(root):
        relative = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for pattern in LITERALS:
                for match in pattern.finditer(line):
                    hits.setdefault((relative, match.group(1).rstrip(".,;:")), []).append(number)
    return hits


class AllowlistGuard(unittest.TestCase):
    def test_no_source_reads_a_documentation_file_unreviewed(self):
        unreviewed = {key: lines for key, lines in documentation_literals(ROOT).items() if key not in REVIEWED}
        self.assertEqual({}, unreviewed, "A source mentions a documentation path. If it reads that file, take the "
                         "file out of the allowlist (READ_BY_CODE in scripts/ci-change-class.py); if it is only a "
                         "comment, message or fixture, add it to REVIEWED with the reason.")

    def test_the_reviewed_list_has_no_stale_entry(self):
        hits = documentation_literals(ROOT)
        self.assertEqual([], sorted(key for key in REVIEWED if key not in hits))

    def test_a_file_that_code_reads_is_not_in_the_allowlist(self):
        for (relative, literal), why in REVIEWED.items():
            if why.startswith("READ:"):
                with self.subTest(literal=literal):
                    self.assertFalse(cc.doc_path(literal))
                    self.assertIn(literal, cc.READ_BY_CODE)

    def test_the_scan_sees_the_sources(self):
        files = [path.relative_to(ROOT).as_posix() for path in source_files(ROOT)]
        for expected in ("lib/elzoo/export.ex", "test/registry_test.exs", "mix.exs",
                         "pieces/assembly/durable-job/test/elzoo/durable_job_test.exs"):
            with self.subTest(expected=expected):
                self.assertIn(expected, files)
        self.assertGreater(len(files), 100)

    def test_a_scratch_test_that_reads_a_documentation_file_fails_the_scan(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        reads = {
            "test/scratch_test.exs": 'File.read!("docs/plans/release-plan.json")\n',
            "pieces/a/b/test/scratch_test.exs": "File.read!('tasks/ELZ-071-docs-only-fast-path.md')\n",
            "lib/scratch.ex": 'File.read!(Path.join(["docs", "x.md"]))\n',
            "test/scratch2_test.exs": 'File.read!("GOAL.md")\n',
            "config/scratch.exs": 'File.read!("PLAN.md")\n',
            "mix.exs": 'File.read!("README.md")\n',
        }
        for relative, text in reads.items():
            path = scratch / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        found = {key for key in documentation_literals(scratch) if key not in REVIEWED}
        self.assertEqual({"test/scratch_test.exs", "pieces/a/b/test/scratch_test.exs", "lib/scratch.ex",
                          "test/scratch2_test.exs", "config/scratch.exs", "mix.exs"}, {file for file, _ in found})

    def test_comments_and_look_alikes_in_a_scratch_tree_are_found_or_ignored_as_designed(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        (scratch / "lib").mkdir()
        (scratch / "lib/a.ex").write_text('x = "lib/mix/tasks/compile_cure.ex"\ny = "scripts/docs/x.md"\nz = "mydocs/a"\n')
        self.assertEqual({}, documentation_literals(scratch))


if __name__ == "__main__":
    unittest.main()
