#!/usr/bin/env python3
"""Controls for scripts/worker-services.py: a stateful fake Docker and Git, no Docker, no network, no Mix."""
import base64
import contextlib
import hashlib
import hmac
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import socket
import stat
import struct
import sys
import tarfile
import tempfile
import threading
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


REVISION = "208248063d64e621782cd26dd30698ee42850a89"


def checksums(version):
    return hashlib.sha256(b"inner" + version.encode()).hexdigest(), hashlib.sha256(b"outer" + version.encode()).hexdigest()


def lock_text(version):
    inner, outer = checksums(version)
    return ("%{\n"
            f'  "cure": {{:git, "https://example.invalid/cure.git", "{REVISION}", [ref: "{REVISION}", depth: 1]}},\n'
            f'  "jason": {{:hex, :jason, "{version}", "{inner}", [:mix], [], "hexpm", "{outer}"}},\n'
            "}\n")


def fetch_deps(project, version):
    """What `mix deps.get` leaves on disk for lock_text(version)."""
    inner, outer = checksums(version)
    (project / "deps" / "jason").mkdir(parents=True)
    (project / "deps" / "jason" / ".hex").write_bytes(b"\x83h\x02inner_checksumm\x00@" + inner.encode()
                                                      + b"outer_checksumm\x00@" + outer.encode())
    (project / "deps" / "cure" / ".git").mkdir(parents=True)
    (project / "deps" / "cure" / ".git" / "HEAD").write_text(REVISION + "\n")


class FakeDocker:
    """Interprets the docker and git command lines that the script runs, and keeps their state."""

    def __init__(self, arch="arm64", vector="0.8.7", repo_digests=None, worktree_list=""):
        self.arch = arch
        self.vector = vector
        self.repo_digests = repo_digests if repo_digests is not None else [f"pgvector/pgvector@{DIGEST}"]
        self.images = set()
        self.containers = {}
        self.volumes = {}
        self.networks = {}
        self.calls = []
        self.queries = []
        self.next_port = 41000
        self.worktree_list = worktree_list
        self.toplevel = None
        self.otp = "29.1.2"
        self.elixir = "Erlang/OTP 29 [erts-16.1]\n\nElixir 1.20.4 (compiled with Erlang/OTP 29)\n"
        self.fail = {}

    def pg_query(self, host, port, user, password, database, sql):
        """The test role over TCP: refused unless the password is the one that the setup script gave the role."""
        self.queries.append((host, port, user, database))
        found = [c for c in self.containers.values() if c.get("running") and c.get("port") == port]
        if not found or host != "127.0.0.1":
            raise ConnectionRefusedError(61, "Connection refused")
        if user != "elzoo_test" or password != found[0].get("role_password"):
            raise ws.Stop('PostgreSQL refused the test role (28P01 password authentication failed for user '
                          '"elzoo_test")')
        return [["16.15", "100", self.vector or None]]

    def add_foreign(self, name, labels=None, running=True):
        self.containers[name] = {"labels": labels or {}, "image": "postgres:18", "running": running, "ports": {}}

    def __call__(self, argv, input=None, env=None, cwd=None, stream=False):
        self.calls.append({"argv": list(argv), "input": input, "env": dict(env) if env else None, "cwd": cwd})
        key = tuple(argv[:2])
        if key in self.fail:
            return self.fail[key]
        if argv[0] == "git":
            if "rev-parse" in argv:
                return 0, (self.toplevel or argv[2]) + "\n", ""
            return 0, self.worktree_list, ""
        if argv[0] == "mix":
            return 0, "", ""
        if argv[0] == "erl":
            return (0, self.otp, "") if self.otp else (127, "", "erl: not found")
        if argv[0] == "elixir":
            return 0, self.elixir, ""
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
                                   "State": {"Running": c["running"]}, "Image": DIGEST,
                                   "HostConfig": {"NetworkMode": c.get("network", "default")}}]), ""
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
        if command == "network":
            sub = argv[2]
            if sub == "ls":
                k, v = argv[argv.index("--filter") + 1][len("label="):].split("=", 1)
                return 0, "".join(n + "\n" for n, l in self.networks.items() if l.get(k) == v), ""
            if sub == "create":
                self.networks[argv[-1]] = self.labels(argv)
                return 0, "", ""
            if sub == "rm":
                if any(c.get("network") == argv[-1] for c in self.containers.values()):
                    return 1, "", "network has active endpoints"
                del self.networks[argv[-1]]
                return 0, "", ""
        if command == "create":
            name = argv[argv.index("--name") + 1]
            publish = argv[argv.index("--publish") + 1]
            env_file = pathlib.Path(argv[argv.index("--env-file") + 1])
            image = IMAGE if IMAGE in argv else None
            network = argv[argv.index("--network") + 1] if "--network" in argv else "default"
            if network != "default" and network not in self.networks:
                return 1, "", "network not found"
            self.containers[name] = {"labels": self.labels(argv), "image": image, "running": False,
                                     "publish": publish, "env": env_file.read_text(), "network": network,
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
            name, destination = argv[-1].split(":", 1)
            self.containers[name]["copied" if destination == "/opt" else "secrets"] = input
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
            if input:
                match = re.search(r"\\set pw '([^']+)'", input.decode())
                if match:
                    self.containers[argv[argv.index("-i") + 1]]["role_password"] = match.group(1)
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
                           obtain=lambda arch: (BINARY, "cache"), query=self.docker.pg_query, **kw)

    @staticmethod
    def secret_files(container):
        with tarfile.open(fileobj=io.BytesIO(container["secrets"])) as archive:
            return {m.name: archive.extractfile(m).read().decode() for m in archive.getmembers() if m.isfile()}

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
        n = ws.names(ws.identity(root)[1])
        superuser = self.secret_files(self.docker.containers[n["pg"]])["elzoo-secrets/postgres-password"]
        secrets = self.secrets_of(root) + [superuser]
        for secret in secrets:
            self.assertGreaterEqual(len(secret), 16)
            for call in self.docker.calls:
                self.assertFalse(any(secret in a for a in call["argv"]), call["argv"])
            self.assertFalse(any(secret in line for line in self.lines))
            # `docker inspect` shows the container environment: no credential is in it
            for c in self.docker.containers.values():
                self.assertNotIn(secret, c["env"])
        # the test role is checked from the host, through the published port
        self.assertEqual([("127.0.0.1", self.docker.containers[n["pg"]]["port"], "elzoo_test", "elzoo_test")],
                         self.docker.queries)

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

    def test_a_worktree_without_the_workflow_stops_before_docker(self):
        root = self.tmp / "no-workflow"
        root.mkdir()
        with self.assertRaisesRegex(ws.Stop, "cannot read"):
            self.services(root).up()
        self.assertEqual([], self.docker.calls)

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


class Password(ServicesCase):
    """BLOCKER of review 1: the password must be proved as the tests use it."""

    def test_the_server_has_no_tcp_rule_without_a_password(self):
        root = self.worktree()
        self.services(root).up()
        pg = self.docker.containers[ws.names(ws.identity(root)[1])["pg"]]
        self.assertIn("POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256", pg["env"].splitlines())
        self.assertIn("POSTGRES_PASSWORD_FILE=/run/elzoo-secrets/postgres-password", pg["env"].splitlines())
        self.assertNotIn("POSTGRES_PASSWORD=", pg["env"])

    def test_a_wrong_password_in_the_env_file_makes_up_fail(self):
        root = self.worktree()
        self.services(root).up()
        env_path = root / ws.STATE_DIR / ws.ENV_FILE
        values = ws.read_env(env_path)
        good = ws.url_password(values["ELZOO_TEST_DATABASE_URL"])
        values["ELZOO_TEST_DATABASE_URL"] = values["ELZOO_TEST_DATABASE_URL"].replace(good, "0" * 32)
        ws.write_private(env_path, ws.env_text(values))
        with self.assertRaisesRegex(ws.Stop, "refused the test role .*28P01"):
            self.services(root).up()
        self.assertFalse(any(good in line for line in self.lines))

    def test_a_role_created_with_another_password_makes_up_fail_without_an_env_file(self):
        root = self.worktree()
        original = self.docker.__call__

        def runner(argv, input=None, **kw):
            if input and b"\\set pw" in input:
                input = re.sub(rb"\\set pw '[^']+'", lambda _m: b"\\set pw 'not-the-written-one'", input)
            return original(argv, input=input, **kw)
        services = self.services(root)
        services.runner = services.docker.runner = runner
        with self.assertRaisesRegex(ws.Stop, "28P01"):
            services.up()
        self.assertFalse((root / ws.STATE_DIR / ws.ENV_FILE).exists())


class FakePostgres(threading.Thread):
    """One connection of a PostgreSQL server on 127.0.0.1 with the server side of SCRAM-SHA-256, written apart
    from ws.Scram: it checks the client proof against the stored key, as PostgreSQL does."""

    def __init__(self, password, mode="scram"):
        super().__init__(daemon=True)
        self.password, self.mode = password.encode(), mode
        self.server = socket.create_server(("127.0.0.1", 0))
        self.port = self.server.getsockname()[1]
        self.query = None

    def run(self):
        try:
            self.serve()
        except (OSError, struct.error):
            pass                                # the client closed the connection
        finally:
            self.server.close()

    def serve(self):
        connection, _ = self.server.accept()
        with connection, connection.makefile("rwb") as f:
            def send(kind, payload):
                f.write(kind + struct.pack("!I", len(payload) + 4) + payload)
                f.flush()

            def recv():
                head = f.read(5)
                return head[:1], f.read(struct.unpack("!I", head[1:])[0] - 4)
            f.read(struct.unpack("!I", f.read(4))[0] - 4)
            if self.mode == "trust":
                send(b"R", struct.pack("!I", 0))
            elif self.mode == "md5":
                send(b"R", struct.pack("!I", 5) + b"salt")
                return
            else:
                send(b"R", struct.pack("!I", 10) + b"SCRAM-SHA-256\0\0")
                _, body = recv()
                first = body[body.index(b"\0") + 5:].decode()
                bare = first[3:]
                nonce = dict(item.split("=", 1) for item in bare.split(","))["r"] + "srv"
                salt, rounds = b"salt-of-the-role", 4096
                server_first = f"r={nonce},s={base64.b64encode(salt).decode()},i={rounds}"
                send(b"R", struct.pack("!I", 11) + server_first.encode())
                _, final = recv()
                without_proof, proof = final.decode().rsplit(",p=", 1)
                salted = hashlib.pbkdf2_hmac("sha256", self.password, salt, rounds)
                stored = hashlib.sha256(hmac.new(salted, b"Client Key", hashlib.sha256).digest()).digest()
                auth = f"{bare},{server_first},{without_proof}".encode()
                signature = hmac.new(stored, auth, hashlib.sha256).digest()
                client_key = bytes(a ^ b for a, b in zip(base64.b64decode(proof), signature))
                if hashlib.sha256(client_key).digest() != stored:
                    send(b"E", b'SFATAL\0C28P01\0Mpassword authentication failed for user "elzoo_test"\0\0')
                    return
                server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
                verifier = hmac.new(server_key, auth, hashlib.sha256).digest() if self.mode == "scram" else b"x" * 32
                send(b"R", struct.pack("!I", 12) + b"v=" + base64.b64encode(verifier))
                send(b"R", struct.pack("!I", 0))
            send(b"S", b"server_version\x0016.15\x00")
            send(b"Z", b"I")
            _, self.query = recv()
            field = lambda text: struct.pack("!i", len(text)) + text  # noqa: E731
            send(b"D", struct.pack("!H", 3) + field(b"16.15") + field(b"100") + struct.pack("!i", -1))
            send(b"C", b"SELECT 1\0")
            send(b"Z", b"I")
            recv()


class PostgresClient(unittest.TestCase):
    def query(self, mode, password):
        server = FakePostgres("right-password", mode)
        server.start()
        try:
            return ws.pg_query("127.0.0.1", server.port, "elzoo_test", password, "elzoo_test", "SELECT 1"), server
        finally:
            server.join(5)

    def test_scram_matches_the_rfc_7677_example(self):
        scram = ws.Scram("pencil", nonce="rOprNGfwEbeRWgbNEkqO", user="user")
        self.assertEqual(b"n,,n=user,r=rOprNGfwEbeRWgbNEkqO", scram.client_first())
        final = scram.client_final(b"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                                   b"s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        self.assertEqual(b"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                         b"p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final)
        scram.check_server_final(b"v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        self.assertTrue(scram.verified)

    def test_the_right_password_returns_the_rows(self):
        rows, server = self.query("scram", "right-password")
        self.assertEqual([["16.15", "100", None]], rows)
        self.assertEqual(b"SELECT 1\0", server.query)

    def test_a_wrong_password_is_refused(self):
        with self.assertRaisesRegex(ws.Stop, "28P01"):
            self.query("scram", "wrong-password")

    def test_a_server_without_a_password_check_or_with_another_method_is_refused(self):
        for mode, message in (("trust", "without SCRAM-SHA-256"), ("md5", "method 5"),
                              ("bad-signature", "server signature")):
            with self.subTest(mode=mode), self.assertRaisesRegex(ws.Stop, message):
                self.query(mode, "right-password")


class Hardening(ServicesCase):
    def test_each_worktree_gets_its_own_labelled_network_and_down_removes_it(self):
        a, b = self.worktree("a"), self.worktree("b")
        self.services(a).up()
        self.services(b).up()
        self.docker.networks["someone-else-net"] = {}
        na, nb = ws.names(ws.identity(a)[1]), ws.names(ws.identity(b)[1])
        self.assertEqual({na["network"], nb["network"], "someone-else-net"}, set(self.docker.networks))
        self.assertEqual(ws.identity(a)[0], self.docker.networks[na["network"]][ws.LABEL_ID])
        for role in ("pg", "s3"):
            self.assertEqual(na["network"], self.docker.containers[na[role]]["network"])
            self.assertEqual("127.0.0.1::" + ("5432" if role == "pg" else "9000"),
                             self.docker.containers[na[role]]["publish"])
        self.services(a).down()
        self.assertEqual({nb["network"], "someone-else-net"}, set(self.docker.networks))

    def test_a_container_on_another_network_is_recreated(self):
        root = self.worktree()
        self.services(root).up()
        n = ws.names(ws.identity(root)[1])
        self.docker.containers[n["s3"]]["network"] = "default"
        self.docker.calls.clear()
        self.services(root).up()
        self.assertEqual(2, len(self.docker.argv_of("docker", "create")))

    def test_an_image_of_another_repository_with_the_pinned_digest_is_refused(self):
        self.docker.repo_digests = [f"someone/pgvector@{DIGEST}"]
        root = self.worktree()
        with self.assertRaisesRegex(ws.Stop, "pinned digest"):
            self.services(root).up()
        self.assertEqual({}, self.docker.containers)
        self.docker.repo_digests = [f"docker.io/pgvector/pgvector@{DIGEST}"]
        self.assertEqual(0, self.services(root).up())

    def test_status_fails_on_a_port_that_docker_no_longer_publishes_and_up_rewrites_it(self):
        root = self.worktree()
        self.services(root).up()
        n = ws.names(ws.identity(root)[1])
        self.docker.containers[n["pg"]]["running"] = False       # e.g. `docker restart` gave a new port
        self.docker(["docker", "start", n["pg"]])
        self.lines.clear()
        self.assertEqual(1, self.services(root).status())
        self.assertTrue(any("pg port" in line and "differs" in line for line in self.lines), self.lines)
        self.assertEqual(0, self.services(root).up())
        self.lines.clear()
        self.assertEqual(0, self.services(root).status())
        self.assertFalse(any("differs" in line for line in self.lines))

    def racing_lock(self, rounds):
        """ws.lock, but a parallel `down` removes the state directory while the first `rounds` callers wait."""
        real, calls = ws.lock, []

        @contextlib.contextmanager
        def racing(path):
            with real(path) as handle:
                calls.append(path)
                if len(calls) <= rounds:
                    for child in path.parent.iterdir():
                        child.unlink()
                    path.parent.rmdir()
                yield handle
        ws.lock = racing
        self.addCleanup(setattr, ws, "lock", real)
        return calls

    def test_up_takes_the_lock_again_when_down_removed_the_directory_meanwhile(self):
        root = self.worktree()
        calls = self.racing_lock(1)
        self.assertEqual(0, self.services(root).up())
        self.assertEqual(2, len(calls))
        self.assertTrue(ws.read_env(root / ws.STATE_DIR / ws.ENV_FILE))

    def test_up_stops_with_a_clear_message_when_the_directory_keeps_changing(self):
        root = self.worktree()
        self.racing_lock(99)
        with self.assertRaisesRegex(ws.Stop, "removed or replaced while this command waited"):
            self.services(root).up()

    def test_a_state_directory_that_is_a_symbolic_link_is_refused_by_up_and_down(self):
        root = self.worktree()
        self.services(root).up()
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        for name in ("env.sh", "lock"):
            (elsewhere / name).write_text("keep")
        shutil.rmtree(root / ws.STATE_DIR)
        (root / ws.STATE_DIR).symlink_to(elsewhere)
        before = dict(self.docker.containers)
        for command in ("up", "down"):
            with self.subTest(command=command), self.assertRaisesRegex(ws.Stop, "symbolic link"):
                getattr(self.services(root), command)()
        self.assertEqual(before.keys(), self.docker.containers.keys())
        self.assertEqual({"env.sh": "keep", "lock": "keep"}, {p.name: p.read_text() for p in elsewhere.iterdir()})


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

    def checkout(self, name, lock="1.4.5", tools="elixir 1.20.4-otp-29\nerlang 29.1.2\n", built=True, spike=True,
                 fetched=True):
        """A checkout whose mix.lock has one Hex and one Git entry; `lock` is the Hex version (it changes the lock)."""
        root = self.tmp / name
        spike_dir = root / "spikes" / "ash_foundation"
        spike_dir.mkdir(parents=True)
        for directory, version, files in ((root, lock, {"mix.exs": "app: :elzoo,", ".tool-versions": tools}),
                                          (spike_dir, "3.0.0", {"mix.exs": "app: :elzoo_ash_spike,"})):
            files["mix.lock"] = lock_text(version)
            for file, text in files.items():
                (directory / file).write_text(text)
            if built and (spike or directory == root):
                app = "elzoo" if directory == root else "elzoo_ash_spike"
                for own in ("lib/jason/ebin", f"lib/{app}/ebin", "consolidated"):
                    (directory / "_build" / "test" / own).mkdir(parents=True)
                    (directory / "_build" / "test" / own / "x.beam").write_bytes(b"beam")
                fetch_deps(directory, version if fetched else "0.0.0")
        return root

    def test_deps_match_lock_needs_each_locked_checksum_and_revision(self):
        good = self.checkout("good")
        self.assertTrue(ws.deps_match_lock(good))
        self.assertTrue(ws.deps_match_lock(good / "spikes" / "ash_foundation"))
        self.assertFalse(ws.deps_match_lock(self.checkout("stale", fetched=False)))
        for damage in ("hex", "git", "missing", "unknown-entry"):
            with self.subTest(damage=damage):
                root = self.checkout(damage)
                if damage == "hex":
                    (root / "deps" / "jason" / ".hex").write_bytes(b"other")
                elif damage == "git":
                    (root / "deps" / "cure" / ".git" / "HEAD").write_text("f" * 40 + "\n")
                elif damage == "missing":
                    shutil.rmtree(root / "deps" / "jason")
                else:
                    text = (root / "mix.lock").read_text().replace("%{\n", '%{\n  "odd": {:path, "x"},\n')
                    (root / "mix.lock").write_text(text)
                self.assertFalse(ws.deps_match_lock(root))

    def test_a_candidate_with_stale_deps_is_skipped(self):
        here = self.checkout("here", built=False)
        stale = self.checkout("stale", fetched=False)
        good = self.checkout("good")
        clone, missing = ws.build_plan(here, [stale, good])
        self.assertEqual([(".", good), ("spikes/ash_foundation", good)], clone)
        self.assertEqual(([], [".", "spikes/ash_foundation"]), ws.build_plan(here, [stale]))

    def test_a_worktree_with_both_directories_is_left_alone(self):
        here = self.checkout("here")
        self.assertEqual(([], []), ws.build_plan(here, [self.checkout("main")]))

    def test_the_first_candidate_with_equal_pins_is_chosen(self):
        here = self.checkout("here", built=False)
        other_lock = self.checkout("a", lock="1.4.6")
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
                         ws.build_plan(here, [self.checkout("a", lock="9.9.9", tools="elixir 1.19.0\n")]))
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
        self.assertTrue((here / "_build" / "test").is_dir() and ws.deps_match_lock(here / "spikes/ash_foundation"))
        self.assertFalse([c for c in docker.calls if c["argv"][0] == "mix"])
        other = self.checkout("other", built=False, lock="2.0.0")
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


class BuildSafety(unittest.TestCase):
    setUp, checkout = Build.setUp, Build.checkout

    def clone_into_here(self, docker=None, runner=None):
        here = self.checkout("here", built=False)
        main = self.checkout("main")
        docker = docker or FakeDocker()
        docker.worktree_list = f"worktree {main}\n"
        lines = []
        ws.warm_build(here, runner or docker, lines.append, system=lambda: "Darwin")
        return here, docker, lines

    def test_the_compiled_project_itself_is_not_cloned(self):
        here, _docker, _lines = self.clone_into_here()
        for project, app in ((here, "elzoo"), (here / "spikes" / "ash_foundation", "elzoo_ash_spike")):
            self.assertTrue((project / "_build" / "test" / "lib" / "jason" / "ebin" / "x.beam").is_file())
            self.assertFalse((project / "_build" / "test" / "lib" / app).exists())
            self.assertFalse((project / "_build" / "test" / "consolidated").exists())

    def test_deps_that_change_during_the_copy_discard_the_clone(self):
        docker = FakeDocker()
        original = docker.__call__

        def runner(argv, **kw):
            result = original(argv, **kw)
            if argv[0] == "cp" and pathlib.Path(argv[-1]).name.startswith(".deps.clone-") \
                    and "spikes" not in argv[-1]:
                (pathlib.Path(argv[-1]) / "jason" / ".hex").write_bytes(b"changed by a deps.get in the source")
            return result
        here, _docker, lines = self.clone_into_here(docker, runner)
        self.assertFalse((here / "_build").exists() or (here / "deps").exists())
        self.assertTrue(ws.deps_match_lock(here / "spikes" / "ash_foundation"))
        self.assertTrue(any("no clone of .: the cloned deps do not match" in line for line in lines), lines)
        self.assertEqual([["mix", "setup"]], [c["argv"] for c in docker.calls if c["argv"][0] == "mix"])

    def test_a_build_that_holds_the_absolute_path_of_a_worktree_is_not_cloned(self):
        # A real Mix build holds the path of the worktree that compiled it (in beams of `_build`, and in `deps`).
        for where in ("_build/test/lib/jason/ebin/x.beam", "deps/cure/_build/stage/.cure_manifest"):
            with self.subTest(where=where):
                shutil.rmtree(self.tmp)
                self.tmp.mkdir()
                here = self.checkout("here", built=False)
                main = self.checkout("main")
                target = main / where
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"\x00" + str(main).encode() + b"/deps/cure/lib/std/option.cure\x00")
                docker = FakeDocker(worktree_list=f"worktree {main}\nworktree {here}\n")
                lines = []
                ws.warm_build(here, docker, lines.append, system=lambda: "Darwin")
                self.assertFalse((here / "_build").exists() or (here / "deps").exists())
                self.assertTrue(any("no clone of .: the build of the source holds" in line for line in lines), lines)
                self.assertEqual([["mix", "setup"]], [c["argv"] for c in docker.calls if c["argv"][0] == "mix"])

    def test_a_build_that_gains_a_worktree_path_during_the_copy_is_discarded(self):
        docker = FakeDocker()
        original = docker.__call__

        def runner(argv, **kw):
            result = original(argv, **kw)
            if argv[0] == "cp" and pathlib.Path(argv[-1]).name.startswith("._build.clone-") \
                    and "spikes" not in argv[-1]:
                (pathlib.Path(argv[-1]) / "test" / "lib" / "jason" / "ebin" / "x.beam").write_bytes(
                    str(pathlib.Path(argv[-2]).parent).encode() + b"/deps/x")
            return result
        here, _docker, lines = self.clone_into_here(docker, runner)
        self.assertFalse((here / "_build").exists() or (here / "deps").exists())
        self.assertTrue(any("no clone of .: the cloned build holds" in line for line in lines), lines)

    def test_a_toolchain_on_path_other_than_tool_versions_refuses_the_clone(self):
        for otp, elixir in (("28.0", None), (None, None),
                            ("29.1.2", "Elixir 1.20.4 (compiled with Erlang/OTP 28)\n"),
                            ("29.1.2", "Elixir 1.19.0 (compiled with Erlang/OTP 29)\n")):
            with self.subTest(otp=otp, elixir=elixir):
                shutil.rmtree(self.tmp)
                self.tmp.mkdir()
                docker = FakeDocker()
                docker.otp = otp
                docker.elixir = elixir or docker.elixir
                here, _docker, lines = self.clone_into_here(docker)
                self.assertEqual([], [c for c in docker.calls if c["argv"][0] == "cp"])
                self.assertEqual([["mix", "setup"]], [c["argv"] for c in docker.calls if c["argv"][0] == "mix"])
                self.assertTrue(any("no clone:" in line for line in lines), lines)

    def test_an_interrupted_clone_leaves_no_temporary_directory_and_git_ignores_its_name(self):
        source = self.tmp / "src"
        (source / "a").mkdir(parents=True)

        def interrupted(argv, **kw):
            shutil.copytree(argv[-2], argv[-1])
            raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            ws.clone_dir(source, self.tmp / "_build", interrupted, system=lambda: "Darwin")
        self.assertEqual(["src"], [p.name for p in self.tmp.iterdir()])
        for name in ("._build.clone-123", ".deps.clone-123", "spikes/ash_foundation/._build.clone-1",
                     "spikes/ash_foundation/.deps.clone-1"):
            with self.subTest(name=name):
                self.assertEqual(0, ws.run(["git", "-C", str(ROOT), "check-ignore", "-q", "--no-index", name])[0])


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

    def test_down_of_a_path_inside_a_worktree_never_resolves_to_the_enclosing_checkout(self):
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-cli-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        top, inner = tmp / "checkout", tmp / "checkout" / "pieces"
        inner.mkdir(parents=True)
        docker = FakeDocker()
        docker.toplevel = str(top)
        docker.containers["enclosing"] = {"labels": {ws.LABEL_ID: ws.identity(top)[0]}, "image": IMAGE,
                                          "running": True}
        lines = []
        self.assertEqual(1, ws.main(["down", "--worktree", str(inner)], runner=docker, out=lines.append, env={}))
        self.assertIn("enclosing", docker.containers)
        self.assertIn("not its top level", lines[-1])
        self.assertEqual(0, ws.main(["down", "--worktree", str(top)], runner=docker, out=lines.append, env={}))
        self.assertEqual({}, docker.containers)

    def test_an_os_error_is_reported_with_exit_1_and_no_traceback(self):
        def runner(argv, **kw):
            raise PermissionError(13, "Permission denied")
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-ws-cli-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / ".github" / "workflows").mkdir(parents=True)
        shutil.copy(ROOT / ws.WORKFLOW, tmp / ws.WORKFLOW)
        lines = []
        self.assertEqual(1, ws.main(["up", "--worktree", str(tmp)], runner=lambda argv, **kw: (0, str(tmp), "")
                                    if argv[0] == "git" else runner(argv), out=lines.append, env={}))
        self.assertEqual(["ELZOO SERVICES up failed: PermissionError: Permission denied"], lines)


if __name__ == "__main__":
    unittest.main()
