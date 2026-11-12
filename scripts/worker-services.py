#!/usr/bin/env python3
"""Disposable test services for one worktree on a developer host: `up`, `status`, `down`.

Developer host only. This command is never merge evidence: the hosted check (`symbolic-check.yml`) on the exact
pull request head is. It gives each worktree its own services, so that several workers on one host do not share a
database server, and it matches the services of the hosted job `check-root`:

- PostgreSQL: a container from the image and digest that `check-root` pins (read from the workflow at run time),
  with the role `elzoo_test`, the database `elzoo_test` and the extension `vector`, created by the superuser.
- S3 test server: the MinIO release that scripts/ci-minio.py pins, the asset for the architecture of the Docker
  server, checked against a pinned size and SHA-256 (fail closed), run in a container of the same pinned image,
  with the bucket and the region of scripts/ci-minio.py.
- Warm build: when `_build` and `deps` are missing, a copy-on-write clone from another worktree of the same
  repository with the same mix.exs, mix.lock and .tool-versions; else `mix setup`.

Both containers publish their port on 127.0.0.1 only, on a free port that Docker chooses. Names derive from the
worktree path; each container and volume carries the label of its worktree, and `down` removes only those.
Credentials are random for each worktree, are written only to the Git-ignored file .elzoo-services/env.sh (mode
0600) and are never printed. Load them with `. .elzoo-services/env.sh`.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True

SCRIPTS = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("ci_minio", SCRIPTS / "ci-minio.py")
ci_minio = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci_minio)

Stop = ci_minio.Stop

WORKFLOW = pathlib.Path(".github/workflows/symbolic-check.yml")
STATE_DIR = ".elzoo-services"
ENV_FILE = "env.sh"
LABEL = "io.elzoo.worker-services"
LABEL_ID = LABEL + ".id"
LABEL_ROLE = LABEL + ".role"
PG_ROLE = PG_DATABASE = "elzoo_test"
PG_PORT = 5432
S3_PORT = 9000
S3_BINARY = "/opt/elzoo-minio"
PG_READY_SECONDS = 180
VALUE = re.compile(r"[A-Za-z0-9_.:/@-]+")

# The MinIO release of scripts/ci-minio.py, one asset per Docker server architecture. The linux-amd64 values are
# those of ci-minio.py. The linux-arm64 values are the GitHub asset digest of the same release, which equals the
# release's own minio.linux-arm64.RELEASE.2025-09-07T16-13-09Z.sha256sum file.
MINIO_VERSION = "RELEASE.2025-09-07T16-13-09Z"
MINIO_ASSETS = {
    "amd64": (f"minio.linux-amd64.{MINIO_VERSION}", ci_minio.SIZE, ci_minio.SHA256),
    "arm64": (f"minio.linux-arm64.{MINIO_VERSION}", 105_251_000,
              "5c83cd2cf151717ba0243f73e1c7802ff36e272b67144bdd7f1f7d684fd6f03d"),
}
MINIO_SERVER_ENV = {"MINIO_BROWSER": "off", "MINIO_CI_CD": "1", "MINIO_UPDATE": "off", "MINIO_API_REQUESTS_MAX": "0"}

# Files that must be equal before a build is cloned from another worktree (the root project and the Ash spike).
BUILD_PAIRS = (
    (".", ("mix.exs", "mix.lock", ".tool-versions")),
    ("spikes/ash_foundation", ("mix.exs", "mix.lock", "../../.tool-versions")),
)


# --- process runner -----------------------------------------------------------------------------------------------

def run(argv, input=None, env=None, cwd=None, stream=False):
    """Run one command: (exit code, stdout text, stderr text). Never raises for a non-zero exit.

    With stream=True the output goes to the terminal and is not captured (used for `mix setup`)."""
    try:
        if stream:
            return subprocess.run(argv, env=env, cwd=cwd).returncode, "", ""
        done = subprocess.run(argv, input=input, capture_output=True, env=env, cwd=cwd)
    except FileNotFoundError:
        return 127, "", f"{argv[0]}: not found"
    return done.returncode, done.stdout.decode(errors="replace"), done.stderr.decode(errors="replace")


def must(runner, argv, what, **kw):
    code, out, err = runner(argv, **kw)
    if code != 0:
        first = (err.strip() or out.strip()).splitlines()[:1]
        raise Stop(f"{what} failed (exit {code}{': ' + first[0][:200] if first else ''})")
    return out


# --- identity ----------------------------------------------------------------------------------------------------

def identity(root):
    """(id, name prefix) of a worktree path: the id is a hash of the absolute path, the prefix is readable."""
    root = str(pathlib.Path(root).resolve())
    digest = hashlib.sha256(root.encode()).hexdigest()[:12]
    slug = re.sub(r"[^a-z0-9]+", "-", pathlib.Path(root).name.lower()).strip("-")[:24].strip("-") or "worktree"
    return digest, f"elzoo-ws-{slug}-{digest}"


def names(prefix):
    return {"pg": f"{prefix}-pg", "s3": f"{prefix}-s3", "pg_volume": f"{prefix}-pg-data",
            "s3_volume": f"{prefix}-s3-data"}


def worktree_root(path, runner=run):
    out = must(runner, ["git", "-C", str(path), "rev-parse", "--show-toplevel"], "git rev-parse")
    return pathlib.Path(out.strip()).resolve()


# --- pins --------------------------------------------------------------------------------------------------------

def postgres_image(workflow_text):
    """The PostgreSQL image of job `check-root`, which must be pinned by digest."""
    match = re.search(r"^  check-root:\n(.*?)(?=^  \S)", workflow_text + "\n  end:\n", re.M | re.S)
    if not match:
        raise Stop("job check-root not found in the workflow")
    images = re.findall(r"^\s+image:\s*(\S+)\s*$", match.group(1), re.M)
    if len(images) != 1:
        raise Stop(f"expected one service image in check-root, found {len(images)}")
    image = images[0]
    if not re.fullmatch(r"[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}", image):
        raise Stop("the check-root image is not pinned by tag and digest")
    return image


def minio_asset(arch):
    if ci_minio.VERSION != MINIO_VERSION:
        raise Stop("scripts/ci-minio.py pins another MinIO release; update MINIO_ASSETS first")
    if arch not in MINIO_ASSETS:
        raise Stop(f"no pinned MinIO asset for Docker server architecture {arch!r}")
    return MINIO_ASSETS[arch]


def cache_dir(env):
    base = env.get("XDG_CACHE_HOME") or str(pathlib.Path(env.get("HOME", "/tmp")) / ".cache")
    return pathlib.Path(base) / "elzoo-worker-services"


def obtain_minio(arch, cache, get=None, sleep=time.sleep, clock=time.monotonic):
    """The verified bytes of the pinned asset: a verified cache entry, else the release download. Fail closed."""
    asset, size, sha = minio_asset(arch)

    def ok(data):
        return len(data) == size and hashlib.sha256(data).hexdigest() == sha

    cached = pathlib.Path(cache) / asset
    if cached.is_file():
        data = cached.read_bytes()
        if ok(data):
            return data, "cache"
        cached.unlink()
    url = f"https://github.com/minio/minio/releases/download/{MINIO_VERSION}/{asset}"
    data = ci_minio.fetch(url, None, get or ci_minio.http_get, sleep, clock, clock() + ci_minio.DOWNLOAD_SECONDS)
    if not ok(data):
        raise Stop(f"{asset}: size or SHA-256 mismatch (expected {size} bytes, sha256 {sha})")
    cached.parent.mkdir(parents=True, exist_ok=True)
    partial = cached.with_name(f".{asset}.{os.getpid()}")
    partial.write_bytes(data)
    partial.replace(cached)
    return data, "download"


# --- environment file ---------------------------------------------------------------------------------------------

ENV_KEYS = ("ELZOO_TEST_DATABASE_URL", "ELZOO_TEST_S3_URL", "ELZOO_TEST_S3_BUCKET", "ELZOO_TEST_S3_ACCESS_KEY_ID",
            "ELZOO_TEST_S3_SECRET_ACCESS_KEY", "ELZOO_TEST_S3_REGION", "ELZOO_WORKER_SERVICES_ID")


def env_text(values):
    lines = ["# Written by scripts/worker-services.py. Developer host only; never merge evidence.",
             "# Load it with: . .elzoo-services/env.sh"]
    for key in ENV_KEYS:
        value = values[key]
        if not VALUE.fullmatch(value):
            raise Stop(f"refusing to write {key}: unexpected characters")
        lines.append(f"export {key}='{value}'")
    return "\n".join(lines) + "\n"


def read_env(path):
    """The exported values of an env file written by env_text, or {} when it is missing or not ours."""
    try:
        text = pathlib.Path(path).read_text(encoding="utf-8")
    except OSError:
        return {}
    values = dict(re.findall(r"^export ([A-Z0-9_]+)='([^']*)'$", text, re.M))
    return values if all(k in values for k in ENV_KEYS) else {}


def write_private(path, text):
    path = pathlib.Path(path)
    fd, partial = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(partial, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(partial)
        raise


def database_url(password, port):
    return f"ecto://{PG_ROLE}:{password}@127.0.0.1:{port}/{PG_DATABASE}"


def url_password(url):
    match = re.fullmatch(rf"ecto://{PG_ROLE}:([^@]+)@127\.0\.0\.1:\d+/{PG_DATABASE}", url or "")
    return match.group(1) if match else None


# --- Docker ------------------------------------------------------------------------------------------------------

class Docker:
    def __init__(self, runner=run):
        self.runner = runner

    def arch(self):
        out = must(self.runner, ["docker", "version", "--format", "{{.Server.Arch}}"], "docker version")
        return out.strip()

    def ensure_image(self, image):
        """Pull the image by digest when absent, then check that Docker records exactly that digest."""
        pulled = False
        if self.runner(["docker", "image", "inspect", image])[0] != 0:
            must(self.runner, ["docker", "pull", "--quiet", image], "docker pull")
            pulled = True
        out = must(self.runner, ["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", image],
                   "docker image inspect")
        repository, digest = image.split(":", 1)[0], image.rsplit("@", 1)[1]
        recorded = json.loads(out.strip() or "[]") or []
        if not any(entry.split("@", 1)[0].split("/")[-2:] == repository.split("/")[-2:]
                   and entry.endswith("@" + digest) for entry in recorded):
            raise Stop(f"the local image does not carry the pinned digest {digest}")
        return digest, pulled

    def inspect(self, name):
        code, out, _err = self.runner(["docker", "container", "inspect", name])
        if code != 0:
            return None
        found = json.loads(out)
        return found[0] if found else None

    def containers(self, ident):
        out = must(self.runner, ["docker", "ps", "-a", "--filter", f"label={LABEL_ID}={ident}",
                                 "--format", "{{.Names}}"], "docker ps")
        return sorted(line for line in out.split() if line)

    def volumes(self, ident):
        out = must(self.runner, ["docker", "volume", "ls", "--filter", f"label={LABEL_ID}={ident}",
                                 "--format", "{{.Name}}"], "docker volume ls")
        return sorted(line for line in out.split() if line)

    def all_containers(self):
        out = must(self.runner, ["docker", "ps", "-a", "--filter", f"label={LABEL}=1", "--format",
                                 '{{.Names}}\t{{.Label "' + LABEL_ID + '"}}\t{{.State}}\t{{.Ports}}'], "docker ps")
        return [line for line in out.splitlines() if line]

    def port(self, name, inner):
        out = must(self.runner, ["docker", "port", name, f"{inner}/tcp"], "docker port")
        for line in out.splitlines():
            match = re.fullmatch(r"127\.0\.0\.1:(\d+)", line.strip())
            if match:
                return int(match.group(1))
        raise Stop(f"{name} publishes no 127.0.0.1 port for {inner}")


def labels(ident, role):
    return ["--label", f"{LABEL}=1", "--label", f"{LABEL_ID}={ident}", "--label", f"{LABEL_ROLE}={role}"]


def with_env_file(state, values, body):
    """Run body(path) with a 0600 Docker env file that is deleted afterwards (values never enter argv)."""
    fd, path = tempfile.mkstemp(dir=state, prefix=".docker-env.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for key, value in values.items():
                if not VALUE.fullmatch(value):
                    raise Stop(f"refusing to pass {key}: unexpected characters")
                handle.write(f"{key}={value}\n")
        return body(path)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)


def tar_of(data, name):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        info = tarfile.TarInfo(name)
        info.size, info.mode, info.mtime = len(data), 0o755, int(time.time())
        archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


# --- services ----------------------------------------------------------------------------------------------------

class Services:
    def __init__(self, root, runner=run, env=None, out=print, sleep=time.sleep, clock=time.monotonic,
                 wait_s3=None, check_s3=None, obtain=None, reach=None):
        self.root = pathlib.Path(root)
        self.ident, self.prefix = identity(self.root)
        self.n = names(self.prefix)
        self.runner = runner
        self.docker = Docker(runner)
        self.env = os.environ if env is None else env
        self.out = out
        self.sleep, self.clock = sleep, clock
        self.state = self.root / STATE_DIR
        self.env_path = self.state / ENV_FILE
        self.wait_s3 = wait_s3 or (lambda base: ci_minio.wait_health(base, sleep, clock))
        self.check_s3 = check_s3 or ci_minio.check_bucket
        self.obtain = obtain or (lambda arch: obtain_minio(arch, cache_dir(self.env), sleep=sleep, clock=clock))
        self.reach = reach or tcp_reachable

    # -- up

    def up(self):
        started = self.clock()
        image = postgres_image((self.root / WORKFLOW).read_text(encoding="utf-8"))
        arch = self.docker.arch()
        minio_asset(arch)
        self.state.mkdir(mode=0o700, exist_ok=True)
        with lock(self.state / "lock"):
            values = read_env(self.env_path)
            reused = self._reusable(image, values)
            if reused:
                for role in ("pg", "s3"):
                    if not reused[role]["State"]["Running"]:
                        must(self.runner, ["docker", "start", self.n[role]], f"docker start {role}")
            else:
                self._remove_own()
                values = self._create(image, arch)
            values = self._ready(values)
            write_private(self.env_path, env_text(values))
        self.out(f"ELZOO SERVICES up: id={self.ident} mode={'reused' if reused else 'created'} "
                 f"seconds={self.clock() - started:.1f}")
        self.out(f"ELZOO SERVICES env: {STATE_DIR}/{ENV_FILE} (mode 0600, credentials not printed); "
                 f"load it with: . {STATE_DIR}/{ENV_FILE}")
        return 0

    def _reusable(self, image, values):
        """The inspected containers when both exist with our labels, the pinned image and known credentials."""
        if not values or values.get("ELZOO_WORKER_SERVICES_ID") != self.ident:
            return None
        found = {}
        for role in ("pg", "s3"):
            info = self.docker.inspect(self.n[role])
            if (not info or info["Config"]["Labels"].get(LABEL_ID) != self.ident
                    or info["Config"]["Image"] != image):
                return None
            found[role] = info
        return found

    def _remove_own(self):
        for name in self.docker.containers(self.ident):
            must(self.runner, ["docker", "rm", "-f", "-v", name], f"docker rm {name}")
        for volume in self.docker.volumes(self.ident):
            must(self.runner, ["docker", "volume", "rm", volume], f"docker volume rm {volume}")

    def _create(self, image, arch):
        digest, pulled = self.docker.ensure_image(image)
        self.out(f"ELZOO SERVICES image: {image} digest={digest} (verified{', pulled' if pulled else ''})")
        superuser, password = secrets.token_hex(16), secrets.token_hex(16)
        access, secret = "elzoo" + secrets.token_hex(8), secrets.token_urlsafe(30)
        for volume, role in ((self.n["pg_volume"], "pg"), (self.n["s3_volume"], "s3")):
            must(self.runner, ["docker", "volume", "create", *labels(self.ident, role), volume], "docker volume create")

        must_create = lambda argv: lambda path: must(self.runner, argv(path), "docker create")  # noqa: E731
        with_env_file(self.state, {"POSTGRES_PASSWORD": superuser}, must_create(lambda path: [
            "docker", "create", "--name", self.n["pg"], *labels(self.ident, "pg"), "--env-file", path,
            "--publish", f"127.0.0.1::{PG_PORT}", "--volume", f"{self.n['pg_volume']}:/var/lib/postgresql/data",
            image]))
        must(self.runner, ["docker", "start", self.n["pg"]], "docker start pg")

        data, source = self.obtain(arch)
        asset, size, sha = minio_asset(arch)
        self.out(f"ELZOO SERVICES minio: {asset} source={source} bytes={size} sha256={sha} (verified)")
        command = (f"mkdir -p /data/{ci_minio.BUCKET} && exec {S3_BINARY} server /data "
                   f"--address :{S3_PORT} --console-address 127.0.0.1:9001")
        with_env_file(self.state, {"MINIO_ROOT_USER": access, "MINIO_ROOT_PASSWORD": secret, **MINIO_SERVER_ENV},
                      must_create(lambda path: [
                          "docker", "create", "--name", self.n["s3"], *labels(self.ident, "s3"), "--env-file", path,
                          "--publish", f"127.0.0.1::{S3_PORT}", "--volume", f"{self.n['s3_volume']}:/data",
                          "--mount", "type=tmpfs,destination=/var/lib/postgresql/data",
                          "--entrypoint", "/bin/sh", image, "-c", command]))
        must(self.runner, ["docker", "cp", "-", f"{self.n['s3']}:{os.path.dirname(S3_BINARY)}"], "docker cp",
             input=tar_of(data, os.path.basename(S3_BINARY)))
        must(self.runner, ["docker", "start", self.n["s3"]], "docker start s3")

        self._wait_postgres()
        script = (f"\\set pw '{password}'\n"
                  f"CREATE ROLE {PG_ROLE} LOGIN PASSWORD :'pw';\n"
                  f"CREATE DATABASE {PG_DATABASE} OWNER {PG_ROLE};\n"
                  f"\\connect {PG_DATABASE}\n"
                  "CREATE EXTENSION vector;\n")
        must(self.runner, ["docker", "exec", "-i", self.n["pg"], "psql", "-U", "postgres", "-d", "postgres",
                           "-v", "ON_ERROR_STOP=1", "-qAt"], "database setup", input=script.encode())
        return {"ELZOO_TEST_DATABASE_URL": database_url(password, 0), "ELZOO_TEST_S3_URL": "",
                "ELZOO_TEST_S3_BUCKET": ci_minio.BUCKET, "ELZOO_TEST_S3_ACCESS_KEY_ID": access,
                "ELZOO_TEST_S3_SECRET_ACCESS_KEY": secret, "ELZOO_TEST_S3_REGION": ci_minio.REGION,
                "ELZOO_WORKER_SERVICES_ID": self.ident}

    def _wait_postgres(self):
        # The image's first start initializes on a Unix socket only; TCP answers after the final start.
        end = self.clock() + PG_READY_SECONDS
        while self.runner(["docker", "exec", self.n["pg"], "pg_isready", "-q", "-h", "127.0.0.1", "-U",
                           "postgres"])[0] != 0:
            if self.clock() >= end:
                raise Stop(f"PostgreSQL did not accept TCP connections in {PG_READY_SECONDS} s")
            self.sleep(1)

    def _ready(self, values):
        """Read the current ports, prove both services as the test clients will use them, return new values."""
        pg_port = self.docker.port(self.n["pg"], PG_PORT)
        s3_port = self.docker.port(self.n["s3"], S3_PORT)
        password = url_password(values["ELZOO_TEST_DATABASE_URL"])
        if not password:
            raise Stop("the database URL of the env file is not one that this command wrote")
        self._wait_postgres()
        if not self.reach("127.0.0.1", pg_port):
            raise Stop(f"PostgreSQL is not reachable on 127.0.0.1:{pg_port}")
        query = ("SELECT current_setting('server_version'), current_setting('max_connections'), "
                 "(SELECT extversion FROM pg_extension WHERE extname = 'vector')")
        out = must(self.runner, ["docker", "exec", "-e", "PGPASSWORD", self.n["pg"], "psql", "-h", "127.0.0.1",
                                 "-U", PG_ROLE, "-d", PG_DATABASE, "-v", "ON_ERROR_STOP=1", "-qAt", "-c", query],
                   "database check as the test role", env={**self.env, "PGPASSWORD": password})
        version, connections, vector = (out.strip().split("|") + ["", "", ""])[:3]
        if not vector:
            raise Stop("the vector extension is missing in the test database")
        self.out(f"ELZOO SERVICES postgres: 127.0.0.1:{pg_port} database={PG_DATABASE} role={PG_ROLE} "
                 f"server_version={version} max_connections={connections} vector={vector}")
        base = f"http://127.0.0.1:{s3_port}"
        self.wait_s3(base)
        self.check_s3(base, values["ELZOO_TEST_S3_ACCESS_KEY_ID"], values["ELZOO_TEST_S3_SECRET_ACCESS_KEY"])
        self.out(f"ELZOO SERVICES s3: {base} bucket={ci_minio.BUCKET} region={ci_minio.REGION} "
                 f"version={MINIO_VERSION} signed HEAD of the bucket: HTTP 200")
        return {**values, "ELZOO_TEST_DATABASE_URL": database_url(password, pg_port), "ELZOO_TEST_S3_URL": base}

    # -- status and down

    def status(self):
        healthy = True
        for role in ("pg", "s3"):
            info = self.docker.inspect(self.n[role])
            if not info or info["Config"]["Labels"].get(LABEL_ID) != self.ident:
                self.out(f"{self.n[role]}: absent")
                healthy = False
                continue
            running = info["State"]["Running"]
            port = self.docker.port(self.n[role], PG_PORT if role == "pg" else S3_PORT) if running else None
            self.out(f"{self.n[role]}: {'running' if running else 'stopped'} image={info['Config']['Image']} "
                     f"image_id={info.get('Image', '')} port={'127.0.0.1:' + str(port) if port else '-'}")
            healthy = healthy and running
        has_env = bool(read_env(self.env_path))
        self.out(f"{STATE_DIR}/{ENV_FILE}: {'present' if has_env else 'absent'}")
        self.out(f"volumes: {' '.join(self.docker.volumes(self.ident)) or '-'}")
        return 0 if healthy and has_env else 1

    def down(self):
        removed = []
        if self.state.is_dir():
            with lock(self.state / "lock"):
                removed = self._down()
        else:
            removed = self._down()
        self.out(f"ELZOO SERVICES down: id={self.ident} removed={' '.join(removed) or 'nothing'}")
        return 0

    def _down(self):
        removed = []
        for name in self.docker.containers(self.ident):
            must(self.runner, ["docker", "rm", "-f", "-v", name], f"docker rm {name}")
            removed.append(name)
        for volume in self.docker.volumes(self.ident):
            must(self.runner, ["docker", "volume", "rm", volume], f"docker volume rm {volume}")
            removed.append(volume)
        if self.state.is_dir():
            for child in self.state.iterdir():
                if child.name in (ENV_FILE, "lock") or child.name.startswith((".docker-env.", f".{ENV_FILE}.")):
                    child.unlink()
                    removed.append(f"{STATE_DIR}/{child.name}")
            with contextlib.suppress(OSError):
                self.state.rmdir()
        return removed


@contextlib.contextmanager
def lock(path):
    with open(path, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def tcp_reachable(host, port, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


# --- warm build --------------------------------------------------------------------------------------------------

def worktrees(root, runner=run):
    out = must(runner, ["git", "-C", str(root), "worktree", "list", "--porcelain"], "git worktree list")
    return [pathlib.Path(line[len("worktree "):]) for line in out.splitlines() if line.startswith("worktree ")]


def same_files(a, b, files):
    for name in files:
        try:
            if (a / name).read_bytes() != (b / name).read_bytes():
                return False
        except OSError:
            return False
    return True


LOCK_ENTRY = re.compile(r'^\s*"([^"]+)": \{', re.M)
LOCK_HEX = re.compile(r'^\s*"([^"]+)": \{:hex, :\w+, "[^"]+", "([0-9a-f]{64})", .*"([0-9a-f]{64})"\},?$', re.M)
LOCK_GIT = re.compile(r'^\s*"([^"]+)": \{:git, "[^"]+", "([0-9a-f]{40})", ', re.M)


def deps_match_lock(project):
    """True when `deps` holds every entry of mix.lock as locked: a Hex package with both locked checksums in its
    `.hex` file, a Git dependency checked out at the locked revision. An equal mix.lock file alone does not prove
    this: a checkout can hold an older `deps`."""
    project = pathlib.Path(project)
    try:
        lock_text = (project / "mix.lock").read_text(encoding="utf-8")
        entries = LOCK_ENTRY.findall(lock_text)
        hex_entries, git_entries = LOCK_HEX.findall(lock_text), LOCK_GIT.findall(lock_text)
        if not entries or len(entries) != len(hex_entries) + len(git_entries):
            return False
        for name, inner, outer in hex_entries:
            recorded = (project / "deps" / name / ".hex").read_bytes()
            if inner.encode() not in recorded or outer.encode() not in recorded:
                return False
        for name, revision in git_entries:
            if (project / "deps" / name / ".git" / "HEAD").read_text().strip() != revision:
                return False
    except (OSError, UnicodeDecodeError):
        return False
    return True


def build_plan(root, candidates):
    """For each build pair with neither `_build` nor `deps`: the first candidate with equal pins and a `deps` that
    matches its lock.

    Returns (pairs to clone as (subdir, source), pairs that are partly present or have no safe source).
    """
    clone, missing = [], []
    root = pathlib.Path(root).resolve()
    for subdir, files in BUILD_PAIRS:
        here = root / subdir
        present = [(here / d).exists() for d in ("_build", "deps")]
        if all(present):
            continue
        if any(present):
            missing.append(subdir)
            continue
        for candidate in candidates:
            if candidate.resolve() == root:
                continue
            there = candidate / subdir
            if ((there / "_build").is_dir() and (there / "deps").is_dir() and same_files(here, there, files)
                    and deps_match_lock(there)):
                clone.append((subdir, candidate))
                break
        else:
            missing.append(subdir)
    return clone, missing


def clone_dir(source, target, runner=run, system=platform.system):
    """Copy-on-write clone of a directory, through a temporary name so that a failure leaves no partial target."""
    partial = target.with_name(f".{target.name}.clone-{os.getpid()}")
    argv = ["cp", "-Rc", str(source), str(partial)] if system() == "Darwin" else \
        ["cp", "-a", "--reflink=auto", str(source), str(partial)]
    code, _out, err = runner(argv)
    if code != 0:
        shutil.rmtree(partial, ignore_errors=True)
        raise Stop(f"clone of {target.name} failed (exit {code}: {err.strip()[:200]})")
    partial.rename(target)


def warm_build(root, runner=run, out=print, system=platform.system, clock=time.monotonic):
    started = clock()
    clone, missing = build_plan(root, worktrees(root, runner))
    for subdir, source in clone:
        for directory in ("_build", "deps"):
            clone_dir(source / subdir / directory, pathlib.Path(root) / subdir / directory, runner, system)
        out(f"ELZOO SERVICES build: cloned {subdir}/_build and {subdir}/deps from another worktree "
            f"with equal pins")
    if missing:
        out(f"ELZOO SERVICES build: no safe clone for {', '.join(missing)}; running mix setup")
        code, _o, _e = runner(["mix", "setup"], cwd=str(root), stream=True)
        if code != 0:
            raise Stop(f"mix setup failed (exit {code})")
    if not clone and not missing:
        out("ELZOO SERVICES build: _build and deps present; left alone")
    out(f"ELZOO SERVICES build: seconds={clock() - started:.1f}")


# --- command line ------------------------------------------------------------------------------------------------

HELP_EPILOG = """\
Developer host only: these services are never merge evidence. The hosted check on the exact pull request head is.
After `up`, load the connection variables with:  . .elzoo-services/env.sh
Before `git worktree remove`, run `down` in the worktree (or `down --worktree PATH` from another checkout).
"""


def main(argv=None, runner=run, out=print, env=None):
    parser = argparse.ArgumentParser(
        prog="worker-services.py", description=__doc__.split("\n\n")[0], epilog=HELP_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("up", "status", "down", "list"),
                        help="up: start or reuse; status: this worktree; down: remove this worktree's services; "
                             "list: every worker-services container on this host")
    parser.add_argument("--worktree", default=".", help="worktree path (default: the current one)")
    parser.add_argument("--no-build", action="store_true", help="up: skip the warm build step")
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            for line in Docker(runner).all_containers():
                out(line)
            return 0
        if args.command == "down":
            # down also works for a path that is no longer a worktree: the identity is a hash of the path.
            path = pathlib.Path(args.worktree).resolve()
            root = worktree_root(path, runner) if path.is_dir() else path
        else:
            root = worktree_root(args.worktree, runner)
        services = Services(root, runner=runner, env=env, out=out)
        if args.command == "up":
            code = services.up()
            if not args.no_build:
                warm_build(root, runner, out)
            return code
        return services.status() if args.command == "status" else services.down()
    except Stop as error:
        out(f"ELZOO SERVICES {args.command} failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
