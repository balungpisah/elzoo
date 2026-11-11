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
               "tasks/ELZ-071-docs-only-fast-path.md", "tasks/x", "README.md", "GOAL.md", "PLAN.md", "AGENTS.md",
               "docs/consuming.md.bak", "docs/Consuming.md"]
    DENIED = [
        # code and configuration of every kind
        ".github/workflows/symbolic-check.yml", ".github/CODEOWNERS", "scripts/ci-change-class.py",
        "scripts/x.md", "lib/elzoo/export.ex", "lib/x.md", "test/registry_test.exs", "test/x.md",
        "pieces/core/selection/README.md", "pieces/core/selection/piece.json", "pieces/x/y/docs/a.md",
        "config/config.exs", "registry/catalogue.json", "mix.exs", "mix.lock", "LEDGER.md",
        "LICENSE", "NOTICE", ".gitignore", ".formatter.exs", "spikes/gleam_ui/README.md", "CLAUDE.md",
        # files that code reads
        "docs/consuming.md",
        # look-alikes
        "docs-x/a.md", "tasks-x/a.md", "docs", "tasks", "docs/", "tasks/", "doc/a.md", "Docs/a.md", "TASKS/a.md",
        "readme.md", "Readme.md", "README.md/x", "README.markdown", "GOAL.md.x", "PLAN.mdx", "xdocs/a.md",
        "agents.md", "Agents.md", "AGENTS.md/x", "AGENTS.mdx", "AGENTS.md.x", "docs/AGENTS.md/../x", "a/AGENTS.md",
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
        for code in ("scripts/x.py", "lib/x.ex", "LEDGER.md", ".github/workflows/symbolic-check.yml",
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
        self.assertEqual([["git", "diff", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none",
                           "--no-relative", "main...task/ELZ-071", "--"]], run.calls)
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


    def test_the_hosts_git_configuration_cannot_hide_a_change(self):
        # Real Git with the settings that would change the raw output: a gitlink hidden by diff.ignoreSubmodules,
        # and paths made relative to the working directory by diff.relative.
        self.assertIn("--ignore-submodules=none", cc.diff_argv("main", "head"))
        self.assertIn("--no-relative", cc.diff_argv("main", "head"))

    def test_the_hosts_git_configuration_cannot_hide_a_change_in_a_real_repository(self):
        repo = GitRepository("test_a_submodule_entry_is_never_documentation")
        repo.setUp()
        self.addCleanup(repo.doCleanups)
        repo.git("config", "diff.ignoreSubmodules", "all")
        repo.git("config", "diff.relative", "true")
        repo.branch(lambda: (repo.write("docs/b.md", "b\n"), repo.gitlink("docs/sub")))
        # With the host setting, a plain diff does not list the gitlink; the queue's command does.
        plain = subprocess.run(["git", "-C", repo.dir, "diff", "--raw", "HEAD^1...HEAD^2"], capture_output=True, text=True).stdout
        self.assertNotIn("160000", plain)
        self.assertFalse(repo.github())
        repo.git("switch", "-q", "main")
        repo.git("reset", "-q", "--hard", "HEAD~1")
        repo.git("branch", "-qD", "pr")
        repo.branch(lambda: (repo.write("scripts/outside.py", "x\n"), Path(repo.dir, "docs").mkdir(exist_ok=True),
                             repo.write("docs/c.md", "c\n")))
        cwd = os.getcwd()
        os.chdir(Path(repo.dir) / "docs")   # diff.relative would limit a plain diff to this directory
        try:
            self.assertFalse(cc.classify_github({"GITHUB_EVENT_NAME": "pull_request"}))
        finally:
            os.chdir(cwd)

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

    def gitlink(self, relative):
        """A real gitlink (mode 160000): an embedded repository, which `git add` stores as a submodule entry.
        (`update-index --cacheinfo` is not enough: `git add -A` drops an entry that has no directory.)"""
        path = Path(self.dir) / relative
        path.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "-C", str(path), "init", "-q"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(path), "-c", "user.email=t@example.invalid", "-c", "user.name=t",
                        "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "inner"],
                       check=True, capture_output=True)

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

    def test_the_generated_ledger_is_code(self):
        self.write("LEDGER.md", "l\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "root files")
        self.branch(lambda: self.write("LEDGER.md", "changed\n"))
        self.assertFalse(self.github())

    def test_agents_md_is_documentation_alone_and_code_next_to_code(self):
        # ELZ-073 scope addition (owner, 2026-11-09). Negative control: the same change with one code path is code.
        self.write("AGENTS.md", "a\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "agents")
        self.branch(lambda: self.write("AGENTS.md", "changed\n"))
        self.assertTrue(self.github())
        self.git("reset", "-q", "--hard", "HEAD~1")
        self.git("branch", "-qD", "pr")
        self.branch(lambda: (self.write("AGENTS.md", "changed\n"), self.write("scripts/x.py", "x\n")))
        self.assertFalse(self.github())

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
        self.branch(lambda: (self.write("docs/b.md", "b\n"), self.gitlink("docs/sub")))
        # The merge really contains a gitlink: the test must not pass on an empty change.
        self.assertIn("160000", self.git("diff", "--raw", "HEAD^1...HEAD^2"))
        self.assertFalse(self.github())

    def test_a_merge_without_the_gitlink_would_have_been_documentation(self):
        # The control of the test above: the same merge without the gitlink is documentation only.
        self.branch(lambda: self.write("docs/b.md", "b\n"))
        self.assertTrue(self.github())

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
# every source file of the repository that `mix check` (or the Gleam check) can run: Elixir, Cure, Gleam, Erlang,
# templates and shell, wherever they are (lib, test, config, pieces including examples and support files, spikes,
# mix.exs, helpers). A literal is allowed only when it appears in the reviewed list below, with the reason; the file
# that code does read (docs/consuming.md) is not in the allowlist, which a second test checks. The scan is a net, not
# a proof: a path built from parts that the patterns cannot see (a computed name, a wildcard that reaches the root)
# is not found.
SCANNED_SUFFIXES = {".ex", ".exs", ".gleam", ".sh", ".erl", ".hrl", ".cure", ".eex", ".heex", ".leex", ".mjs", ".js"}
SKIPPED_DIRS = {".git", "deps", "_build", "node_modules", "build", ".elixir_ls", ".claims", ".github"}
ROOT_ONLY_SKIPPED = {"docs", "tasks"}   # the documentation itself; a nested lib/mix/tasks is source and is scanned
# Comments are scanned too: no language rule decides here what is a comment (in Elixir a line that starts with `%{` is
# a map and a heredoc line that starts with `#{` is code); the six comment lines that mention a path are reviewed.
LITERALS = [
    # docs/x, tasks/x, also after a slash or an interpolation: "../../docs/x", "#{root}/docs/x"
    re.compile(r"""(?<![A-Za-z0-9_.@-])((?:docs|tasks)/[^\s"'`)\]]*)"""),
    # the word as a path part: "docs", 'tasks', "../../docs", "/docs/", also on its own line of a Path.join list
    re.compile(r"""["'/]((?:docs|tasks))(?=["'/]|$)"""),
    re.compile(r"""~w[(\[{<|/][^)\]}>|/]*\b(docs|tasks)\b"""),   # ~w(docs x.md)
    re.compile(r"""(?<![A-Za-z0-9_.-])((?:GOAL|PLAN|AGENTS)\.md)"""),
    re.compile(r"""(?<![A-Za-z0-9_.-])(README\.md)"""),      # also "#{dir}/README.md" and ~s(README.md)
    re.compile(r"""(?i)(\*\.\{?[a-z,]*md)"""),              # a markdown glob such as Path.wildcard("*.{md,json}")
    re.compile(r"""Path\.wildcard\(\s*["'](\*[^"']*)"""),    # a wildcard that starts at the working directory
    # a wildcard or a listing over the project root, the working directory or a root variable
    re.compile(r"""(Path\.wildcard\(\s*Path\.join\(\s*\[?\s*(?:@?root\b|File\.cwd!\(\)|["']\.["']|\.\s*,))"""),
    re.compile(r"""(File\.ls!?\()"""),
]
# The README of a piece, as an explicit path of exactly two directories: not the root README.md. Removed from a line
# before the patterns run ("pieces/../README.md" and other odd forms are not removed, so they are reported).
PIECE_README_PATH = re.compile(r"""pieces[/\\](?:[A-Za-z0-9_-]+[/\\]){2}README\.md""")
# (file, the stripped line) -> why it is not a read of a documentation file that the allowlist accepts. The key is the
# line itself, so a new read in a file that already has a reviewed line is still new and fails the test.
PIECE_README = "README.md of a piece directory (pieces/**), not the root README.md"
MIX_TASK = "path of a Mix task source file (lib/mix/tasks/), not a read of tasks/"
FIXTURE = "string in a selection or export fixture, not a read"
REVIEWED = {
    ("pieces/delivery/data-stream/test/elzoo/data_stream_copy_test.exs", 'compiler = "lib/mix/tasks/compile_cure.ex"'): MIX_TASK,
    ("lib/elzoo/export.ex", '{".elzoo/docs/consuming.md", "docs/consuming.md"}'):
        "READ: the export copies it into every bundle; docs/consuming.md is not in the allowlist (READ_BY_CODE)",
    ("lib/elzoo/export.ex", '{".elzoo/#{piece["directory"]}/README.md", "#{piece["directory"]}/README.md"},'): PIECE_README,
    ("lib/elzoo/export.ex", 'do: [{"lib/mix/tasks/compile_cure.ex", "lib/mix/tasks/compile_cure.ex"}],'): MIX_TASK,
    ("lib/elzoo/registry.ex", 'source!(root, "#{directory}/README.md")'): PIECE_README,
    ("lib/elzoo/registry.ex", '"| [#{entry["id"]}](#{entry["directory"]}/README.md) | ready (subset) | #{entry["kind"]} | #{providers} | #{evidence} | #{operations} | #{cell(entry["contract"])} |"'): PIECE_README,
    ("lib/elzoo/registry.ex", "guarantees beyond the declared Contract. See docs/operational-contracts.md."): "text of a message, not a read",
    ("pieces/assembly/durable-job/lib/elzoo/durable_job.ex", "2.24.2. See docs/work/ELZ-010.md for the Contract, result tables and limits."): "text of a doc string, not a read",
    ("test/check_selection_test.exs", 'for relative <- ["piece.json", "README.md", "test/new_test.exs", "lib/deleted.ex"] do'):
        PIECE_README + " (selection fixture)",
    ("test/check_selection_test.exs", '"docs/unknown.md"'): FIXTURE,
    ("test/check_selection_test.exs", '["pieces/runtime/host//README.md"],'): "invalid piece path in a selection fixture",
    ("test/check_selection_test.exs", '["pieces\\\\runtime\\\\host\\\\README.md"],'): "invalid piece path in a selection fixture",
    ("test/check_selection_test.exs", '"lib/mix/tasks/check.ex",'): MIX_TASK,
    ("test/export_test.exs", 'refute Map.has_key?(plan.files, "lib/mix/tasks/compile_cure.ex")'): MIX_TASK,
    ("test/registry_test.exs", '{&put_in(&1, ["operations", "config", "evidence"], ["README.md"]),'):
        PIECE_README + " (manifest fixture)",
    ("spikes/ash_foundation/test/elz010_job_provider_test.exs", "# docs/work/ELZ-010.md; not a shipped adapter."): "comment",
    ("spikes/ash_foundation/test/support/elz010_job_provider.ex",
     "# ELZ-010 job-provider comparison (exploration evidence for docs/work/ELZ-010.md)."): "comment",
    ("test/elz010_cure_probe_test.exs", "# Exploration evidence for docs/work/ELZ-010.md; not a ready Piece."): "comment",
    ("test/elz010_provider_probe_test.exs", "# aborted it ({:error, :rollback}, no job; recorded in docs/work/ELZ-010.md)."): "comment",
    ("test/elz010_provider_probe_test.exs", "# docs/work/ELZ-010.md, re-run by mix check. Not acceptance evidence for a Piece."): "comment",
    ("test/support/elz010_probe_test_helper.exs", "# Contract proposal in docs/work/ELZ-010.md). Not a Piece and not shipped."): "comment",
    ("lib/elzoo/registry.ex", 'Path.wildcard(Path.join([root, directory, role, "**", "*"]), match_dot: true)'):
        "files of one piece directory (pieces/<family>/<name>/<role>), not the project root",
    ("test/support/cure_consumer_case_test_helper.exs", 'Path.wildcard(Path.join([@root, "_build", "test", "lib", "*", "ebin"]))'):
        "compiled beams below _build, not documentation",
    ("test/export_test.exs", 'assert File.ls!(ctx.destination) == ["mix.exs"]'): "lists the temporary export destination, not the root",
    ("test/elz099_streaming_provider_test.exs", 'for entry <- File.ls!(source), entry not in ["_build", "ebin", ".git"] do'):
        "lists the two installed provider source directories from Mix.Project.deps_paths(), not repository documentation",
}
# Reviewed lines that are real reads: the literal must not be in the allowlist.
READS = {("lib/elzoo/export.ex", '{".elzoo/docs/consuming.md", "docs/consuming.md"}'): "docs/consuming.md"}


def source_files(root):
    found = []
    for directory, subdirectories, names in os.walk(root):
        skipped = SKIPPED_DIRS | (ROOT_ONLY_SKIPPED if Path(directory) == Path(root) else set())
        subdirectories[:] = sorted(d for d in subdirectories if d not in skipped)
        found.extend(Path(directory) / name for name in sorted(names) if Path(name).suffix in SCANNED_SUFFIXES)
    return found


def documentation_literals(root):
    """{(relative file, stripped line): [(literal, line number)]} for every line with a path literal of a
    documentation file, comment-only lines excepted."""
    hits = {}
    for path in source_files(root):
        relative = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            text = line.strip()
            line = PIECE_README_PATH.sub("", line)
            for pattern in LITERALS:
                for match in pattern.finditer(line):
                    hits.setdefault((relative, text), []).append((match.group(1).rstrip(".,;:"), number))
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
        hits = documentation_literals(ROOT)
        self.assertEqual({"docs/consuming.md"}, set(READS.values()))
        for key, literal in READS.items():
            with self.subTest(literal=literal):
                self.assertIn(key, REVIEWED)
                self.assertIn(literal, [found for found, _number in hits[key]])
                self.assertFalse(cc.doc_path(literal))
                self.assertIn(literal, cc.READ_BY_CODE)
        self.assertEqual(sorted(key for key, why in REVIEWED.items() if why.startswith("READ:")), sorted(READS))

    def test_the_scan_sees_the_sources_of_everything_that_mix_check_runs(self):
        files = {path.relative_to(ROOT).as_posix() for path in source_files(ROOT)}
        for expected in ("lib/elzoo/export.ex", "lib/mix/tasks/check.ex", "test/registry_test.exs",
                         "test/support/cure_consumer_case_test_helper.exs", "mix.exs",
                         "pieces/assembly/durable-job/test/elzoo/durable_job_test.exs",
                         "pieces/assembly/durable-job/lib/elzoo/durable_job.ex",
                         "pieces/delivery/effect-intent/examples/effect_intent.exs",
                         "spikes/ash_foundation/test/elz010_job_provider_test.exs",
                         "scripts/check.sh"):
            with self.subTest(expected=expected):
                self.assertIn(expected, files)
        self.assertTrue([f for f in files if f.endswith(".cure")])
        self.assertTrue([f for f in files if f.endswith(".gleam")])
        self.assertGreater(len(files), 200)
        # The scan stays out of the documentation itself and the build output.
        self.assertFalse([f for f in files if f.startswith(("docs/", "tasks/", "deps/", "_build/"))])

    def test_a_scratch_source_that_reads_a_documentation_file_fails_the_scan(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        reads = {
            "test/a_test.exs": 'File.read!("docs/plans/release-plan.json")\n',
            "pieces/a/b/test/b_test.exs": "File.read!('tasks/ELZ-071-docs-only-fast-path.md')\n",
            "lib/c.ex": 'File.read!(Path.join(["docs", "x.md"]))\n',
            "test/d_test.exs": 'File.read!("GOAL.md")\n',
            "config/e.exs": 'File.read!("PLAN.md")\n',
            "test/ac_test.exs": 'File.read!("AGENTS.md")\n',            # ELZ-073: AGENTS.md joins the allowlist
            "lib/ad.ex": 'File.read!(Path.join(root, "AGENTS.md"))\n',
            "mix.exs": 'File.read!("README.md")\n',
            # the forms of this repository's own tests (relative to __DIR__) and interpolation
            "pieces/x/y/test/f_test.exs": 'File.read!(Path.expand("../../../../docs/x.json", __DIR__))\n',
            "test/g_test.exs": 'File.read!("#{root}/docs/x.md")\n',
            "test/h_test.exs": "File.read!(Path.join(~w(docs x.md)))\n",
            "test/i_test.exs": "File.read!(~s(README.md))\n",
            "test/j_test.exs": 'File.read!("#{root}/README.md")\n',
            "test/k_test.exs": 'Path.wildcard("*.md")\n',
            # sources outside lib and test that mix check runs or loads
            "spikes/ash_foundation/test/l_test.exs": 'File.read!("docs/x.md")\n',
            "pieces/a/b/examples/m.exs": 'File.read!("tasks/x.md")\n',
            "pieces/test_helper.exs": 'File.read!("GOAL.md")\n',
            "pieces/a/b/cure/n.cure": 'read_file("docs/x.md")\n',
            "spikes/gleam_ui/src/o.gleam": 'read("docs/x.md")\n',
            "scripts/p.sh": "cat docs/x.md\n",
            # the styles that the first version of the scan missed (second independent review)
            "pieces/x/y/test/r_test.exs": 'File.read!(Path.join(Path.expand("../../../../docs", __DIR__), "x.json"))\n',
            "test/s_test.exs": 'Path.join([root,\n "docs",\n "x.md"])\n',
            "test/t_test.exs": '@doc_dir "docs"\n',
            "test/u_test.exs": 'Path.wildcard("*.{md,json}")\n',
            "test/v_test.exs": 'Path.wildcard("**/*")\n',
            "test/aa_test.exs": 'Path.wildcard(dir <> "/*.md")\n',      # only the markdown glob sees these two
            "test/ab_test.exs": 'Path.wildcard(dir <> "/*.MD")\n',
            "test/w_test.exs": "Path.join(~w(tasks x.md))\n",
            "test/x_test.exs": 'File.read!("pieces/../README.md")\n',
            "test/y_test.exs": 'File.read!("pieces/a/b/c/README.md")\n',
            "spikes/gleam_ui/browser/z.mjs": "readFileSync('docs/x.md')\n",
            "lib/q.erl": '-include("docs/x.hrl").\n',
        }
        for relative, text in reads.items():
            path = scratch / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        found = {file for file, _line in documentation_literals(scratch)}
        self.assertEqual(set(reads), found)
        # ELZ-073 (review note): the literal itself is reported, not only the file.
        literals = {file: [lit for _key, found_literals in documentation_literals(scratch).items() if _key[0] == file
                           for lit, _number in found_literals] for file in ("test/ac_test.exs", "lib/ad.ex")}
        self.assertEqual({"test/ac_test.exs": ["AGENTS.md"], "lib/ad.ex": ["AGENTS.md"]}, literals)

    def test_a_new_read_in_a_file_with_a_reviewed_line_is_still_new(self):
        # The reviewed list is keyed by the line itself, so a root README read added next to a piece README line
        # (the five files of the first version) fails the scan.
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        reviewed_file, reviewed_line = next(key for key in REVIEWED if key[0] == "lib/elzoo/export.ex" and "README" in key[1])
        path = scratch / reviewed_file
        path.parent.mkdir(parents=True)
        path.write_text(reviewed_line + '\nFile.read!("README.md")\nFile.read!(Path.join(root, "GOAL.md"))\n')
        unreviewed = {key for key in documentation_literals(scratch) if key not in REVIEWED}
        self.assertEqual({(reviewed_file, 'File.read!("README.md")'), (reviewed_file, 'File.read!(Path.join(root, "GOAL.md"))')},
                         unreviewed)

    def test_explicit_piece_readme_paths_are_not_reported(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        (scratch / "test").mkdir()
        (scratch / "test/a_test.exs").write_text('select(["pieces/core/port/README.md", "pieces/runtime/host/README.md"])\n')
        self.assertEqual({}, documentation_literals(scratch))

    def test_lines_that_start_like_a_comment_but_are_code_are_scanned(self):
        # In Elixir `%{` starts a map and `#{` inside a heredoc is interpolation; JS has `#field`; Erlang has `#record{}`.
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        forms = {
            "lib/a.ex": 'config =\n  %{readme: File.read!("README.md")}\n',
            "lib/b.ex": '  %Plan{file: File.read!(Path.join(root, "docs/x.md"))}\n',
            "lib/c.ex": 'text = """\n#{File.read!("docs/x.md")}\n"""\n',
            "lib/d.ex": 'x = """\n#{File.read!(Path.join(root, "GOAL.md"))}\n"""\n',
            "spikes/gleam_ui/browser/e.mjs": "class A {\n  #text = readFileSync('docs/x.md');\n}\n",
            "lib/f.erl": '#plan{file = file:read_file("docs/x.md")}.\n',
            "scripts/g.sh": "# cat docs/x.md\n",
            "lib/h.ex": '# File.read!("docs/x.md")\n',
            "lib/i.ex": '%% docs/x.md\n',
        }
        for relative, text in forms.items():
            path = scratch / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.assertEqual(set(forms), {file for file, _line in documentation_literals(scratch)})

    def test_roots_wildcards_and_listings_are_reported(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        forms = {
            "test/a_test.exs": 'Path.wildcard(Path.join(root, "**/*"))\n',
            "test/b_test.exs": 'Path.wildcard(Path.join([@root, "**", "*"]))\n',
            "test/c_test.exs": 'Path.wildcard(Path.join(File.cwd!(), "*"))\n',
            "test/d_test.exs": 'File.ls!(root)\n',
            "test/e_test.exs": 'File.ls(".")\n',
            "test/f_test.exs": 'Path.wildcard("*.MD")\n',
            "test/g_test.exs": 'Path.wildcard(Path.join(".", "*"))\n',
        }
        for relative, text in forms.items():
            path = scratch / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.assertEqual(set(forms), {file for file, _line in documentation_literals(scratch)})

    def test_a_clean_scratch_tree_and_look_alikes_are_not_reported(self):
        scratch = Path(tempfile.mkdtemp(prefix="elzoo-class-scratch-"))
        self.addCleanup(shutil.rmtree, scratch, True)
        (scratch / "lib").mkdir()
        (scratch / "lib/a.ex").write_text('x = "mydocs/a"\ny = "lib/foo"\nz = %{tasks: 1, docs: 2}\nw = "undocs"\n')
        (scratch / "docs").mkdir()
        (scratch / "docs/b.ex").write_text('File.read!("docs/x.md")\n')      # inside docs/: not scanned
        (scratch / "deps").mkdir()
        (scratch / "deps/c.ex").write_text('File.read!("docs/x.md")\n')      # build output and dependencies
        self.assertEqual({}, documentation_literals(scratch))


if __name__ == "__main__":
    unittest.main()
