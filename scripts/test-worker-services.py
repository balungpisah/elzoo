#!/usr/bin/env python3
"""Controls for scripts/worker-services.py: a stateful fake Docker and Git, no Docker, no network, no Mix."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import sys
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("worker_services", ROOT / "scripts" / "worker-services.py")
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

IMAGE = ("pgvector/pgvector:0.8.7-pg16-bookworm@sha256:"
         "0dd3149a06e4579a0d70d8fef9945636cd514005e7237deb27f9b67886f8dc4f")
DIGEST = IMAGE.rsplit("@", 1)[1]
BINARY = b"\x7fELF fake minio\n" * 64


class FakeDocker:
    """Interprets the docker and git command lines that the script runs, and keeps their state."""

    def __init__(self, arch="arm64", vector="0.8.7", repo_digests=None, worktree_list=""):
        self.arch = arch
        self.vector = vector
        self.repo_digests = repo_digests if repo_digests is not None else [f"pgvector/pgvector@{DIGEST}"]
        self.images = set()
        self.containers = {}
        self.volumes = {}
        self.calls = []
        self.next_port = 41000
        self.worktree_list = worktree_list
        self.fail = {}

    def add_foreign(self, name, labels=None, running=True):
        self.containers[name] = {"labels": labels or {}, "image": "postgres:18", "running": running, "ports": {}}

    def __call__(self, argv, input=None, env=None, cwd=None, stream=False):
        self.calls.append({"argv": list(argv), "input": input, "env": dict(env) if env else None, "cwd": cwd})
        key = tuple(argv[:2])
        if key in self.fail:
            return self.fail[key]
        if argv[0] == "git":
            if "rev-parse" in argv:
                return 0, argv[2] + "\n", ""
            return 0, self.worktree_list, ""
        if argv[0] == "mix":
            return 0, "", ""
        if argv[0] == "cp":
            shutil.copytree(argv[-2], argv[-1])
            return 0, "", ""
        command = argv[1]
        if command == "version":
            return 0, self.arch + "\n", ""
        if command == "pull":
            self.images.add(argv[-1])
            return 0, "", ""
        if command == "image":
            if argv[-1] not in self.images:
                return 1, "", "No such image"
            if "--format" in argv:
                return 0, json.dumps(self.repo_digests) + "\n", ""
            return 0, "[]", ""
        if command == "container":
            c = self.containers.get(argv[-1])
            if not c:
                return 1, "[]", "No such container"
            return 0, json.dumps([{"Config": {"Labels": c["labels"], "Image": c["image"]},
                                   "State": {"Running": c["running"]}, "Image": DIGEST}]), ""
        if command == "ps":
            k, v = argv[argv.index("--filter") + 1][len("label="):].split("=", 1)
            found = [n for n, c in self.containers.items() if c["labels"].get(k) == v]
            return 0, "".join(n + "\n" for n in found), ""
        if command == "volume":
            sub = argv[2]
            if sub == "ls":
                k, v = argv[argv.index("--filter") + 1][len("label="):].split("=", 1)
                return 0, "".join(n + "\n" for n, l in self.volumes.items() if l.get(k) == v), ""
            if sub == "create":
                self.volumes[argv[-1]] = self.labels(argv)
                return 0, argv[-1] + "\n", ""
            if sub == "rm":
                del self.volumes[argv[-1]]
                return 0, "", ""
        if command == "create":
            name = argv[argv.index("--name") + 1]
            publish = argv[argv.index("--publish") + 1]
            env_file = pathlib.Path(argv[argv.index("--env-file") + 1])
            image = IMAGE if IMAGE in argv else None
            self.containers[name] = {"labels": self.labels(argv), "image": image, "running": False,
                                     "publish": publish, "env": env_file.read_text(),
                                     "env_mode": stat.S_IMODE(env_file.stat().st_mode), "argv": list(argv)}
            return 0, "", ""
        if command == "start":
            c = self.containers[argv[-1]]
            if not c["running"]:
                c["running"] = True
                self.next_port += 1
                c["port"] = self.next_port
            return 0, "", ""
        if command == "rm":
            del self.containers[argv[-1]]
            return 0, "", ""
        if command == "cp":
            self.containers[argv[-1].split(":")[0]]["copied"] = input
            return 0, "", ""
        if command == "port":
            c = self.containers[argv[2]]
            if not c["running"]:
                return 1, "", "not running"
            return 0, f"127.0.0.1:{c['port']}\n", ""
        if command == "exec":
            if "pg_isready" in argv:
                return 0, "", ""
            if "-c" in argv:
                return 0, f"16.15|100|{self.vector}\n", ""
            return 0, "", ""
        raise AssertionError(f"unexpected command {argv}")

    @staticmethod
    def labels(argv):
        return dict(argv[i + 1].split("=", 1) for i, a in enumerate(argv) if a == "--label")

    def argv_of(self, *prefix):
        return [c["argv"] for c in self.calls if tuple(c["argv"][:len(prefix)]) == prefix]


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ServicesCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.docker = FakeDocker()
        self.lines = []
        self.s3_checks = []

    def worktree(self, name="elzoo-ELZ-123"):
        root = self.tmp / name
        (root / ".github" / "workflows").mkdir(parents=True)
        shutil.copy(ROOT / ws.WORKFLOW, root / ws.WORKFLOW)
        return root

    def services(self, root, **kw):
        clock = Clock()
        return ws.Services(root, runner=self.docker, env={"HOME": str(self.tmp)}, out=self.lines.append,
                           sleep=clock.sleep, clock=clock, wait_s3=lambda base: None,
                           check_s3=lambda base, a, s: self.s3_checks.append((base, a, s)),
                           obtain=lambda arch: (BINARY, "cache"), reach=lambda host, port: True, **kw)

    def secrets_of(self, root):
        values = ws.read_env(root / ws.STATE_DIR / ws.ENV_FILE)
        return [ws.url_password(values["ELZOO_TEST_DATABASE_URL"]), values["ELZOO_TEST_S3_ACCESS_KEY_ID"],
                values["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]]


class IdentityAndPins(unittest.TestCase):
    def test_identity_is_stable_distinct_and_a_valid_docker_name(self):
        a1, p1 = ws.identity("/w/elzoo-ELZ-123")
        a2, p2 = ws.identity("/w/elzoo-ELZ-123")
        b, q = ws.identity("/other/elzoo-ELZ-123")
        self.assertEqual((a1, p1), (a2, p2))
        self.assertNotEqual(a1, b)
        self.assertNotEqual(p1, q)
        self.assertRegex(p1, r"^elzoo-ws-elzoo-elz-123-[0-9a-f]{12}$")
        for name in ws.names(p1).values():
            self.assertRegex(name, r"^[a-z0-9][a-z0-9_.-]+$")

    def test_the_postgres_image_is_the_check_root_pin_of_the_workflow(self):
        text = (ROOT / ws.WORKFLOW).read_text()
        self.assertEqual(IMAGE, ws.postgres_image(text))

    def test_an_unpinned_missing_or_ambiguous_image_fails_closed(self):
        job = "jobs:\n  check-root:\n    services:\n      postgres:\n        image: {}\n  check-next:\n    x: 1\n"
        for text in (job.format("pgvector/pgvector:0.8.7-pg16-bookworm"),
                     job.format("pgvector/pgvector@sha256:" + "a" * 64),
                     "jobs:\n  check-other:\n    services: {}\n",
                     job.format(IMAGE) .replace("    services:", "    services:\n      a:\n        image: x:1@sha256:"
                                                + "b" * 64)):
            with self.subTest(text=text[:60]):
                with self.assertRaises(ws.Stop):
                    ws.postgres_image(text)

    def test_the_minio_release_is_the_one_of_ci_minio(self):
        self.assertEqual(ws.ci_minio.VERSION, ws.MINIO_VERSION)
        self.assertEqual((f"minio.linux-amd64.{ws.MINIO_VERSION}", ws.ci_minio.SIZE, ws.ci_minio.SHA256),
                         ws.MINIO_ASSETS["amd64"])
        self.assertEqual((f"minio.linux-arm64.{ws.MINIO_VERSION}", 105_251_000,
                          "5c83cd2cf151717ba0243f73e1c7802ff36e272b67144bdd7f1f7d684fd6f03d"),
                         ws.MINIO_ASSETS["arm64"])
        self.assertEqual("elzoo-test", ws.ci_minio.BUCKET)
        with self.assertRaisesRegex(ws.Stop, "architecture"):
            ws.minio_asset("s390x")

    def test_a_changed_ci_minio_release_stops_until_the_pins_follow(self):
        saved = ws.ci_minio.VERSION
        ws.ci_minio.VERSION = "RELEASE.2099-01-01T00-00-00Z"
        try:
            with self.assertRaisesRegex(ws.Stop, "another MinIO release"):
                ws.minio_asset("arm64")
        finally:
            ws.ci_minio.VERSION = saved


class ObtainMinio(unittest.TestCase):
    def setUp(self):
        self.cache = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-cache-"))
        self.addCleanup(shutil.rmtree, self.cache, True)
        self.saved = dict(ws.MINIO_ASSETS)
        self.addCleanup(lambda: ws.MINIO_ASSETS.update(self.saved))
        ws.MINIO_ASSETS["arm64"] = ("asset", len(BINARY), hashlib.sha256(BINARY).hexdigest())
        self.urls = []

    def get(self, body):
        def get(url, headers, timeout=60):
            self.urls.append(url)
            return 200, {}, body
        return get

    def test_a_verified_cache_entry_is_used_without_a_request(self):
        (self.cache / "asset").write_bytes(BINARY)
        self.assertEqual((BINARY, "cache"), ws.obtain_minio("arm64", self.cache, get=self.get(b"")))
        self.assertEqual([], self.urls)

    def test_a_corrupt_cache_entry_is_replaced_by_a_verified_download(self):
        (self.cache / "asset").write_bytes(BINARY[:-1] + b"x")
        self.assertEqual((BINARY, "download"), ws.obtain_minio("arm64", self.cache, get=self.get(BINARY)))
        self.assertEqual([f"https://github.com/minio/minio/releases/download/{ws.MINIO_VERSION}/asset"], self.urls)
        self.assertEqual(BINARY, (self.cache / "asset").read_bytes())

    def test_a_download_with_another_hash_or_size_fails_closed_and_is_not_cached(self):
        for body in (BINARY[:-1] + b"y", BINARY + b"y", b""):
            with self.subTest(size=len(body)):
                with self.assertRaisesRegex(ws.Stop, "mismatch"):
                    ws.obtain_minio("arm64", self.cache, get=self.get(body))
                self.assertEqual([], list(self.cache.iterdir()))


class Up(ServicesCase):
    def test_up_creates_two_labelled_loopback_services_and_a_private_env_file(self):
        root = self.worktree()
        self.assertEqual(0, self.services(root).up())
        ident, prefix = ws.identity(root)
        n = ws.names(prefix)
        self.assertEqual({n["pg"], n["s3"]}, set(self.docker.containers))
        self.assertEqual({n["pg_volume"], n["s3_volume"]}, set(self.docker.volumes))
        for c in self.docker.containers.values():
            self.assertEqual({ws.LABEL: "1", ws.LABEL_ID: ident}, {k: c["labels"][k] for k in (ws.LABEL, ws.LABEL_ID)})
            self.assertEqual(IMAGE, c["image"])
            self.assertTrue(c["running"])
            self.assertEqual(0o600, c["env_mode"])
        self.assertEqual("127.0.0.1::5432", self.docker.containers[n["pg"]]["publish"])
        self.assertEqual("127.0.0.1::9000", self.docker.containers[n["s3"]]["publish"])
        for labels in self.docker.volumes.values():
            self.assertEqual(ident, labels[ws.LABEL_ID])
        env_path = root / ws.STATE_DIR / ws.ENV_FILE
        self.assertEqual(0o600, stat.S_IMODE(env_path.stat().st_mode))
        values = ws.read_env(env_path)
        self.assertRegex(values["ELZOO_TEST_DATABASE_URL"], r"^ecto://elzoo_test:[0-9a-f]{32}@127\.0\.0\.1:\d+/elzoo_test$")
        self.assertRegex(values["ELZOO_TEST_S3_URL"], r"^http://127\.0\.0\.1:\d+$")
        self.assertEqual(("elzoo-test", "us-east-1"), (values["ELZOO_TEST_S3_BUCKET"], values["ELZOO_TEST_S3_REGION"]))
        self.assertEqual([(values["ELZOO_TEST_S3_URL"], values["ELZOO_TEST_S3_ACCESS_KEY_ID"],
                           values["ELZOO_TEST_S3_SECRET_ACCESS_KEY"])], self.s3_checks)
        # the temporary Docker env files are gone; only the env file and the lock stay
        self.assertEqual({"env.sh", "lock"}, {p.name for p in (root / ws.STATE_DIR).iterdir()})

    def test_the_credentials_never_appear_in_argv_or_in_the_output(self):
        root = self.worktree()
        self.services(root).up()
        superuser = [c["env"] for c in self.docker.containers.values() if "POSTGRES_PASSWORD" in c["env"]][0]
        secrets = self.secrets_of(root) + [superuser.split("=", 1)[1].strip()]
        for secret in secrets:
            self.assertGreaterEqual(len(secret), 16)
            for call in self.docker.calls:
                self.assertFalse(any(secret in a for a in call["argv"]), call["argv"])
            self.assertFalse(any(secret in line for line in self.lines))
        check = [c for c in self.docker.calls if c["argv"][:2] == ["docker", "exec"] and "-c" in c["argv"]][0]
        self.assertIn("PGPASSWORD", check["argv"])
        self.assertEqual(secrets[0], check["env"]["PGPASSWORD"])

    def test_the_superuser_creates_the_role_the_database_and_the_vector_extension(self):
        root = self.worktree()
        self.services(root).up()
        setup = [c for c in self.docker.calls if c["input"] and c["argv"][:2] == ["docker", "exec"]][0]
        self.assertIn("-U", setup["argv"])
        self.assertEqual("postgres", setup["argv"][setup["argv"].index("-U") + 1])
        script = setup["input"].decode()
        for statement in ("CREATE ROLE elzoo_test LOGIN PASSWORD :'pw';", "CREATE DATABASE elzoo_test OWNER elzoo_test;",
                          "\\connect elzoo_test", "CREATE EXTENSION vector;"):
            self.assertIn(statement, script)
        self.assertTrue(any("vector=0.8.7" in line for line in self.lines))

    def test_the_pinned_binary_is_copied_with_the_server_settings_of_ci_minio(self):
        root = self.worktree()
        self.services(root).up()
        s3 = self.docker.containers[ws.names(ws.identity(root)[1])["s3"]]
        with tarfile.open(fileobj=io.BytesIO(s3["copied"])) as archive:
            member = archive.getmember("elzoo-minio")
            self.assertEqual(0o755, member.mode)
            self.assertEqual(BINARY, archive.extractfile(member).read())
        for setting in ("MINIO_BROWSER=off", "MINIO_CI_CD=1", "MINIO_UPDATE=off", "MINIO_API_REQUESTS_MAX=0"):
            self.assertIn(setting, s3["env"])
        self.assertIn("mkdir -p /data/elzoo-test && exec /opt/elzoo-minio server /data", s3["argv"][-1])
        self.assertIn("type=tmpfs,destination=/var/lib/postgresql/data", s3["argv"])

    def test_a_second_up_reuses_everything_and_follows_a_new_port(self):
        root = self.worktree()
        self.services(root).up()
        before = self.secrets_of(root)
        n = ws.names(ws.identity(root)[1])
        self.docker.containers[n["pg"]]["running"] = False     # e.g. Docker restarted
        self.docker.calls.clear()
        self.assertEqual(0, self.services(root).up())
        self.assertEqual([], self.docker.argv_of("docker", "create"))
        self.assertEqual([], self.docker.argv_of("docker", "volume", "create"))
        self.assertEqual([["docker", "start", n["pg"]]], self.docker.argv_of("docker", "start"))
        self.assertEqual(before, self.secrets_of(root))
        values = ws.read_env(root / ws.STATE_DIR / ws.ENV_FILE)
        self.assertTrue(values["ELZOO_TEST_DATABASE_URL"].endswith(f":{self.docker.containers[n['pg']]['port']}/elzoo_test"))
        self.assertTrue(any("mode=reused" in line for line in self.lines))

    def test_without_the_env_file_up_recreates_only_its_own_services(self):
        a, b = self.worktree("a"), self.worktree("b")
        self.services(a).up()
        self.services(b).up()
        self.docker.add_foreign("someone-else-db")
        b_containers = {k: v["labels"][ws.LABEL_ID] for k, v in self.docker.containers.items() if ws.LABEL_ID in v["labels"]}
        old = self.secrets_of(a)
        (a / ws.STATE_DIR / ws.ENV_FILE).unlink()
        self.services(a).up()
        self.assertNotEqual(old, self.secrets_of(a))
        self.assertIn("someone-else-db", self.docker.containers)
        for name, ident in b_containers.items():
            if ident == ws.identity(b)[0]:
                self.assertIn(name, self.docker.containers)
        removed = [argv[-1] for argv in self.docker.argv_of("docker", "rm")]
        self.assertTrue(removed and all(r.startswith(ws.identity(a)[1]) for r in removed))

    def test_a_container_from_another_image_is_recreated(self):
        root = self.worktree()
        self.services(root).up()
        n = ws.names(ws.identity(root)[1])
        self.docker.containers[n["pg"]]["image"] = "pgvector/pgvector:old@sha256:" + "c" * 64
        self.docker.calls.clear()
        self.services(root).up()
        self.assertEqual(2, len(self.docker.argv_of("docker", "create")))

    def test_an_image_without_the_pinned_digest_stops_before_any_container(self):
        self.docker.repo_digests = ["pgvector/pgvector@sha256:" + "d" * 64]
        root = self.worktree()
        with self.assertRaisesRegex(ws.Stop, "pinned digest"):
            self.services(root).up()
        self.assertEqual({}, self.docker.containers)
        self.assertEqual([[ "docker", "pull", "--quiet", IMAGE]], self.docker.argv_of("docker", "pull"))

    def test_a_missing_vector_extension_fails_closed_without_an_env_file(self):
        self.docker.vector = ""
        root = self.worktree()
        with self.assertRaisesRegex(ws.Stop, "vector"):
            self.services(root).up()
        self.assertFalse((root / ws.STATE_DIR / ws.ENV_FILE).exists())

    def test_a_failed_signed_request_fails_closed_without_an_env_file(self):
        root = self.worktree()
        services = self.services(root)

        def refuse(base, access, secret):
            raise ws.Stop("signed HEAD of the bucket answered HTTP 403")
        services.check_s3 = refuse
        with self.assertRaisesRegex(ws.Stop, "403"):
            services.up()
        self.assertFalse((root / ws.STATE_DIR / ws.ENV_FILE).exists())

    def test_a_port_published_beyond_loopback_is_refused(self):
        docker = FakeDocker()
        docker.containers["x"] = {"running": True, "port": 1}
        original = docker.__call__

        def runner(argv, **kw):
            if argv[1] == "port":
                return 0, "0.0.0.0:5432\n", ""
            return original(argv, **kw)
        with self.assertRaisesRegex(ws.Stop, "127.0.0.1"):
            ws.Docker(runner).port("x", 5432)


class Down(ServicesCase):
    def test_down_removes_only_this_worktree_and_twice_is_harmless(self):
        a, b = self.worktree("a"), self.worktree("b")
        self.services(a).up()
        self.services(b).up()
        self.docker.add_foreign("someone-else-db", labels={"com.example": "1"})
        self.docker.volumes["someone-else-volume"] = {}
        self.assertEqual(0, self.services(a).down())
        ident_a, ident_b = ws.identity(a)[0], ws.identity(b)[0]
        self.assertFalse(any(c["labels"].get(ws.LABEL_ID) == ident_a for c in self.docker.containers.values()))
        self.assertEqual(2, sum(c["labels"].get(ws.LABEL_ID) == ident_b for c in self.docker.containers.values()))
        self.assertIn("someone-else-db", self.docker.containers)
        self.assertIn("someone-else-volume", self.docker.volumes)
        self.assertEqual(2, sum(l.get(ws.LABEL_ID) == ident_b for l in self.docker.volumes.values()))
        self.assertFalse((a / ws.STATE_DIR).exists())
        self.assertTrue((b / ws.STATE_DIR / ws.ENV_FILE).exists())
        self.assertEqual(0, self.services(a).down())
        self.assertTrue(any("removed=nothing" in line for line in self.lines))

    def test_down_keeps_files_it_did_not_write(self):
        root = self.worktree()
        self.services(root).up()
        (root / ws.STATE_DIR / "notes.txt").write_text("keep")
        self.services(root).down()
        self.assertEqual(["notes.txt"], [p.name for p in (root / ws.STATE_DIR).iterdir()])

    def test_two_worktrees_get_two_servers_on_two_ports(self):
        a, b = self.worktree("a"), self.worktree("b")
        self.services(a).up()
        self.services(b).up()
        urls = [ws.read_env(r / ws.STATE_DIR / ws.ENV_FILE)["ELZOO_TEST_DATABASE_URL"] for r in (a, b)]
        self.assertNotEqual(urls[0].rsplit(":", 1)[1], urls[1].rsplit(":", 1)[1])
        self.assertEqual(4, len(self.docker.containers))

    def test_status_reports_without_secrets_and_exits_1_when_down(self):
        root = self.worktree()
        self.assertEqual(1, self.services(root).status())
        self.services(root).up()
        self.lines.clear()
        self.assertEqual(0, self.services(root).status())
        for secret in self.secrets_of(root):
            self.assertFalse(any(secret in line for line in self.lines))


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-build-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def checkout(self, name, lock="lock-1", tools="elixir 1.20.4\n", built=True, spike=True):
        root = self.tmp / name
        spike_dir = root / "spikes" / "ash_foundation"
        spike_dir.mkdir(parents=True)
        for directory, files in ((root, {"mix.exs": "exs", "mix.lock": lock, ".tool-versions": tools}),
                                 (spike_dir, {"mix.exs": "spike", "mix.lock": "spike-lock"})):
            for file, text in files.items():
                (directory / file).write_text(text)
        if built:
            for directory in ("_build", "deps"):
                (root / directory / "x").mkdir(parents=True)
                if spike:
                    (spike_dir / directory / "y").mkdir(parents=True)
        return root

    def test_a_worktree_with_both_directories_is_left_alone(self):
        here = self.checkout("here")
        self.assertEqual(([], []), ws.build_plan(here, [self.checkout("main")]))

    def test_the_first_candidate_with_equal_pins_is_chosen(self):
        here = self.checkout("here", built=False)
        other_lock = self.checkout("a", lock="lock-2")
        other_tools = self.checkout("b", tools="elixir 1.19.0\n")
        unbuilt = self.checkout("c", built=False)
        good = self.checkout("d")
        clone, missing = ws.build_plan(here, [here, other_tools, unbuilt, other_lock, good])
        # The spike is its own Mix project: its pins are its mix files and the toolchain, not the root lock.
        self.assertEqual([(".", good), ("spikes/ash_foundation", other_lock)], clone)
        self.assertEqual([], missing)

    def test_no_safe_source_or_a_partial_build_falls_back(self):
        here = self.checkout("here", built=False)
        self.assertEqual(([], [".", "spikes/ash_foundation"]),
                         ws.build_plan(here, [self.checkout("a", lock="x", tools="elixir 1.19.0\n")]))
        partial = self.checkout("partial")
        shutil.rmtree(partial / "deps")
        clone, missing = ws.build_plan(partial, [self.checkout("main")])
        self.assertEqual(["."], missing)
        self.assertEqual([], clone)

    def test_warm_build_clones_then_mix_runs_only_when_needed(self):
        here = self.checkout("here", built=False)
        main = self.checkout("main")
        docker = FakeDocker(worktree_list=f"worktree {main}\nHEAD x\n\nworktree {here}\n")
        lines = []
        ws.warm_build(here, docker, lines.append, system=lambda: "Darwin")
        cps = [c["argv"] for c in docker.calls if c["argv"][0] == "cp"]
        self.assertEqual(4, len(cps))
        self.assertTrue(all(argv[:2] == ["cp", "-Rc"] for argv in cps))
        self.assertTrue((here / "_build" / "x").is_dir() and (here / "spikes/ash_foundation/deps/y").is_dir())
        self.assertFalse([c for c in docker.calls if c["argv"][0] == "mix"])
        other = self.checkout("other", built=False, lock="different")
        docker = FakeDocker(worktree_list=f"worktree {main}\n")
        ws.warm_build(other, docker, lines.append, system=lambda: "Linux")
        self.assertEqual([["mix", "setup"]], [c["argv"] for c in docker.calls if c["argv"][0] == "mix"])

    def test_clone_uses_reflink_on_linux_and_leaves_no_partial_target_on_failure(self):
        source = self.tmp / "src"
        (source / "a").mkdir(parents=True)
        seen = []

        def failing(argv, **kw):
            seen.append(argv)
            pathlib.Path(argv[-1]).mkdir()
            return 1, "", "no space"
        with self.assertRaisesRegex(ws.Stop, "clone of _build failed"):
            ws.clone_dir(source, self.tmp / "_build", failing, system=lambda: "Linux")
        self.assertEqual(["cp", "-a", "--reflink=auto"], seen[0][:3])
        self.assertEqual(["src"], [p.name for p in self.tmp.iterdir()])


class CommandLine(unittest.TestCase):
    def test_help_says_developer_host_only_and_never_merge_evidence(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            ws.main(["--help"])
        self.assertIn("Developer host only", out.getvalue())
        self.assertIn("never merge evidence", out.getvalue())

    def test_a_stop_is_reported_with_exit_1(self):
        lines = []
        docker = FakeDocker()
        docker.fail[("docker", "version")] = (1, "", "Cannot connect to the Docker daemon")
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-cli-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / ".github" / "workflows").mkdir(parents=True)
        shutil.copy(ROOT / ws.WORKFLOW, tmp / ws.WORKFLOW)
        self.assertEqual(1, ws.main(["up", "--worktree", str(tmp)], runner=docker, out=lines.append, env={}))
        self.assertEqual(["ELZOO SERVICES up failed: docker version failed (exit 1: Cannot connect to the Docker daemon)"],
                         lines)

    def test_down_of_a_removed_worktree_path_uses_the_same_identity(self):
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-cli-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        gone = tmp / "removed-worktree"
        docker = FakeDocker()
        ident = ws.identity(gone.resolve())[0]
        docker.containers["left"] = {"labels": {ws.LABEL_ID: ident}, "image": IMAGE, "running": True}
        lines = []
        self.assertEqual(0, ws.main(["down", "--worktree", str(gone)], runner=docker, out=lines.append, env={}))
        self.assertEqual({}, docker.containers)


if __name__ == "__main__":
    unittest.main()
