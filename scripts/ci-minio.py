#!/usr/bin/env python3
"""ELZ-066 (folds in ELZ-064): start a pinned, disposable S3 test server (MinIO) for the object-store tests.

The binary of release RELEASE.2025-09-07T16-13-09Z (the production release; upstream is archived, AGPL-3.0, no
security updates) is obtained from, in order: a cache directory that the workflow restored, the release-asset API with
the job token, the browser release URL. Every source is checked against the pinned size and SHA-256; any mismatch or
error stops the step (fail closed). The server runs loopback-only inside the disposable job, with random credentials
and one bucket, and is checked with a signed request before its connection is exported to later steps.

Environment: ELZOO_MINIO_DIR (work directory, default $RUNNER_TEMP/elzoo-minio), ELZOO_MINIO_CACHE (cache directory
that actions/cache restores and saves, default $RUNNER_TEMP/elzoo-minio-cache), GITHUB_TOKEN (optional, source 2),
GITHUB_ENV, GITHUB_OUTPUT (optional). Prints one summary line per step; never prints the credentials.
"""
import datetime
import hashlib
import hmac
import http.client
import os
import pathlib
import re
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

VERSION = "RELEASE.2025-09-07T16-13-09Z"
ASSET = f"minio.linux-amd64.{VERSION}"
ASSET_ID = 404655976
SIZE = 110_989_496
SHA256 = "7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"
API_URL = f"https://api.github.com/repos/minio/minio/releases/assets/{ASSET_ID}"
BROWSER_URL = f"https://github.com/minio/minio/releases/download/{VERSION}/{ASSET}"
BUCKET = "elzoo-test"
REGION = "us-east-1"
DEFAULT_PORT = 9000
ATTEMPTS = 3
RETRY_STATUS = {500, 502, 503, 504}
REDIRECT_STATUS = {301, 302, 303, 307, 308}
DOWNLOAD_SECONDS = 420          # total time for obtaining the binary, all sources and attempts
HEALTH_SECONDS = 60
USER_AGENT = "elzoo-ci-minio"
HOST = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")


class Stop(Exception):
    """The step cannot continue; the message names the reason (never a secret)."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_get(url, headers, timeout=60):
    """One GET without automatic redirects: (status, headers, body)."""
    request = urllib.request.Request(url, headers=headers)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.headers, error.read()
        finally:
            error.close()


def redirect_allowed(location):
    """HTTPS only, plain host, no user info, port 443 or none, GitHub-owned domain."""
    try:
        if not location.isascii() or any(c in location for c in "\\ \t\r\n"):
            return False
        parts = urllib.parse.urlsplit(location)
        host = parts.hostname or ""
        if ("%" in parts.netloc or parts.scheme != "https" or parts.username is not None
                or parts.password is not None or parts.port not in (None, 443) or not HOST.fullmatch(host)):
            return False
    except ValueError:
        return False
    return host == "github.com" or host.endswith(".github.com") or host.endswith(".githubusercontent.com")


def verified(data):
    return len(data) == SIZE and hashlib.sha256(data).hexdigest() == SHA256


def fetch(url, token, get, sleep, clock, deadline):
    """Download one source, following one redirect by hand without the token. Returns bytes or raises Stop."""
    headers = {"User-Agent": USER_AGENT, "Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    last = "no attempt"
    for attempt in range(1, ATTEMPTS + 1):
        if clock() >= deadline:
            raise Stop("download time budget used up")
        try:
            status, response_headers, body = get(url, headers)
            if status in REDIRECT_STATUS:
                location = response_headers.get("Location", "")
                if not redirect_allowed(location):
                    raise Stop("redirect to an unexpected host refused")
                status, response_headers, body = get(location, {"User-Agent": USER_AGENT})
        except (urllib.error.URLError, http.client.HTTPException, ValueError, TimeoutError, OSError) as error:
            last = f"{type(error).__name__}"
            status, body = None, b""
        else:
            last = f"HTTP {status}"
            if status == 200:
                return body
        # transport errors and 5xx are retried; anything else (401, 403, 404, 429...) ends this source
        if (status is None or status in RETRY_STATUS) and attempt < ATTEMPTS:
            sleep(2 ** attempt)
            continue
        break
    raise Stop(f"download failed ({last})")


def obtain(cache_dir, token, get=http_get, sleep=time.sleep, clock=time.monotonic):
    """Return (binary bytes, source name). Order: restored cache, release-asset API, browser URL."""
    cached = pathlib.Path(cache_dir) / "minio"
    reasons = []
    if cached.is_file():
        data = cached.read_bytes()
        if verified(data):
            return data, "cache"
        reasons.append("cache entry failed verification")
        cached.unlink()
    deadline = clock() + DOWNLOAD_SECONDS
    for name, url, source_token in (("release-asset API", API_URL, token), ("browser URL", BROWSER_URL, None)):
        try:
            data = fetch(url, source_token, get, sleep, clock, deadline)
        except Stop as error:
            reasons.append(f"{name}: {error}")
            continue
        if verified(data):
            return data, name
        reasons.append(f"{name}: size or SHA-256 mismatch")
    raise Stop("no source gave the pinned binary (" + "; ".join(reasons) + ")")


# --- SigV4 (stdlib), used only to prove that the credentials and the bucket work -----------------------------

def _hmac(key, text):
    return hmac.new(key, text.encode(), hashlib.sha256).digest()


def sigv4_headers(method, host, path, access, secret, now, region=REGION, service="s3", payload=b"", extra=None):
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    day = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(payload).hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date, **(extra or {})}
    signed = ";".join(sorted(headers))
    canonical = "\n".join([method, urllib.parse.quote(path, safe="/"), "",
                           "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload_hash])
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = _hmac(_hmac(_hmac(_hmac(("AWS4" + secret).encode(), day), region), service), "aws4_request")
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed}, "
                                f"Signature={signature}")
    return headers


def free_port(preferred=DEFAULT_PORT):
    for port in (preferred, 0):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
                return probe.getsockname()[1]
            except OSError:
                continue
    raise Stop("no free loopback port")


def wait_health(base, sleep, clock, alive=lambda: True, seconds=HEALTH_SECONDS, get=http_get):
    end = clock() + seconds
    pending = ["/minio/health/live", "/minio/health/ready"]
    while pending:
        if not alive():
            raise Stop("the server process ended before it was healthy")
        try:
            status, _headers, _body = get(base + pending[0], {"User-Agent": USER_AGENT}, 5)
            if status == 200:
                pending.pop(0)
                continue
        except (urllib.error.URLError, http.client.HTTPException, OSError):
            pass
        if clock() >= end:
            raise Stop(f"health check {pending[0]} did not answer 200 in {seconds} s")
        sleep(0.5)


def check_bucket(base, access, secret, now=None, urlopen=urllib.request.urlopen):
    """Signed HEAD of the bucket: 200 proves the credentials and the bucket (403 or 404 do not)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    host = urllib.parse.urlsplit(base).netloc
    headers = sigv4_headers("HEAD", host, f"/{BUCKET}", access, secret, now)
    request = urllib.request.Request(f"{base}/{BUCKET}", headers=headers, method="HEAD")
    try:
        with urlopen(request, timeout=10) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
    except (urllib.error.URLError, OSError) as error:
        raise Stop(f"signed HEAD of the bucket failed ({type(error).__name__})") from error
    if status != 200:
        raise Stop(f"signed HEAD of the bucket answered HTTP {status}")


def export(variables, env):
    """Write NAME=value lines to $GITHUB_ENV (values are single-line and contain no newline)."""
    target = env.get("GITHUB_ENV")
    for key, value in variables.items():
        if "\n" in value or "\r" in value:
            raise Stop(f"refusing to export {key}")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            for key, value in variables.items():
                handle.write(f"{key}={value}\n")


def main(env=None, out=print, get=http_get, sleep=time.sleep, clock=time.monotonic, popen=subprocess.Popen,
         check=None):
    env = os.environ if env is None else env
    started = clock()
    temp = env.get("RUNNER_TEMP") or env.get("TMPDIR") or "/tmp"
    work = pathlib.Path(env.get("ELZOO_MINIO_DIR") or pathlib.Path(temp) / "elzoo-minio")
    cache_dir = pathlib.Path(env.get("ELZOO_MINIO_CACHE") or pathlib.Path(temp) / "elzoo-minio-cache")
    try:
        data, source = obtain(cache_dir, env.get("GITHUB_TOKEN"), get, sleep, clock)
        out(f"ELZOO MINIO binary: source={source} bytes={len(data)} sha256={SHA256} (verified)")
        work.mkdir(mode=0o700, parents=True, exist_ok=True)
        binary = work / "minio"
        binary.write_bytes(data)
        binary.chmod(0o700)
        if source != "cache":
            cache_dir.mkdir(parents=True, exist_ok=True)
            (cache_dir / "minio").write_bytes(data)
        (work / "data" / BUCKET).mkdir(parents=True, exist_ok=True)
        access, secret = "elzoo" + secrets.token_hex(8), secrets.token_urlsafe(30)
        out(f"::add-mask::{access}")
        out(f"::add-mask::{secret}")
        port = free_port()
        console = free_port(0)
        base = f"http://127.0.0.1:{port}"
        log = open(work / "server.log", "ab")
        server_env = {"PATH": env.get("PATH", "/usr/bin:/bin"), "HOME": str(work), "MINIO_ROOT_USER": access,
                      "MINIO_ROOT_PASSWORD": secret, "MINIO_BROWSER": "off", "MINIO_CI_CD": "1",
                      "MINIO_UPDATE": "off", "MINIO_API_REQUESTS_MAX": "0"}
        process = popen([str(binary), "server", str(work / "data"), "--address", f"127.0.0.1:{port}",
                         "--console-address", f"127.0.0.1:{console}"],
                        env=server_env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                        start_new_session=True)
        log.close()   # the child holds its own copy of the descriptor
        wait_health(base, sleep, clock, alive=lambda: process.poll() is None, get=get)
        (check or check_bucket)(base, access, secret)
        export({"ELZOO_TEST_S3_URL": base, "ELZOO_TEST_S3_BUCKET": BUCKET, "ELZOO_TEST_S3_ACCESS_KEY_ID": access,
                "ELZOO_TEST_S3_SECRET_ACCESS_KEY": secret, "ELZOO_TEST_S3_REGION": REGION}, env)
        target = env.get("GITHUB_OUTPUT")
        if target:
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(f"source={source}\n")
        out(f"ELZOO MINIO ready: url={base} bucket={BUCKET} region={REGION} version={VERSION} "
            f"pid={process.pid} seconds={clock() - started:.1f}")
        return 0
    except Stop as error:
        out(f"::error::ELZOO MINIO step failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
