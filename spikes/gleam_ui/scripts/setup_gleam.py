#!/usr/bin/env python3
"""Install the pinned upstream compiler locally, verifying the release archive.

ELZ-060: the archive is fetched through the release-asset API by asset ID, not through the browser
download URL (which answered HTTP 504 from CI on 2026-11-08). The pinned asset ID, size and SHA-256 of
every supported platform are checked; any mismatch or error stops the script (fail closed).
"""
import hashlib
import http.client
import io
import os
import pathlib
import platform
import re
import subprocess
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "1.19.2"
API = "https://api.github.com/repos/gleam-lang/gleam/releases/assets/"
# (target, API asset id, size in bytes, SHA-256) per platform; equal to the GitHub API digests of v1.19.2.
ASSETS = {
    ("Darwin", "arm64"): ("aarch64-apple-darwin", 633423162, 9234148,
                          "fa7c6113e162ab1d979f72e7dde3e907b87e4b30c518af178768e577d180324d"),
    ("Darwin", "x86_64"): ("x86_64-apple-darwin", 633423317, 9702221,
                           "c578192530507b868c4a6c8cb7ad5d2ab0830890257f41036f17c82853f19d05"),
    ("Linux", "x86_64"): ("x86_64-unknown-linux-musl", 633423401, 10565692,
                          "2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f"),
    ("Linux", "aarch64"): ("aarch64-unknown-linux-musl", 633423257, 10126116,
                           "d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1"),
}
RETRY_STATUS = {502, 503, 504}
ATTEMPTS = 3
REDIRECT_STATUS = {301, 302, 303, 307, 308}
USER_AGENT = "elzoo-setup-gleam"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect automatically: the token must not travel to the storage host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_get(url, headers, timeout=60):
    """One GET without following redirects. Returns (status, headers, body)."""
    request = urllib.request.Request(url, headers=headers)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:  # includes the 3xx answers, as redirects are not followed
        try:
            return error.code, error.headers, error.read()
        finally:
            error.close()


HOST_PATTERN = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")


def redirect_target_allowed(location):
    """HTTPS only, plain host name, no user info, default port, and a GitHub-owned domain."""
    try:
        # Percent-encoding is normal in the signed query string; it is refused only in the host part.
        if not location.isascii() or any(c in location for c in "\\ \t\r\n"):
            return False
        parts = urllib.parse.urlsplit(location)
        if "%" in parts.netloc:
            return False
        host = parts.hostname or ""
        if (parts.scheme != "https" or parts.username is not None or parts.password is not None
                or parts.port not in (None, 443) or not HOST_PATTERN.fullmatch(host)):
            return False
    except ValueError:
        return False
    return host == "github.com" or host.endswith(".github.com") or host.endswith(".githubusercontent.com")


def fetch_asset(asset_id, token, get=http_get, sleep=time.sleep):
    """Download one release asset through the API. Raises SystemExit on any failure."""
    headers = {"Accept": "application/octet-stream", "User-Agent": USER_AGENT,
               "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    last = None
    for attempt in range(1, ATTEMPTS + 1):
        try:
            status, response_headers, body = get(API + str(asset_id), headers)
            if status in REDIRECT_STATUS:
                location = response_headers.get("Location", "")
                if not redirect_target_allowed(location):
                    raise SystemExit("Gleam asset redirect to an unexpected host refused")
                # Signed storage URL: no Authorization header goes to this host.
                status, response_headers, body = get(location, {"User-Agent": USER_AGENT})
        except (urllib.error.URLError, http.client.HTTPException, ValueError, TimeoutError, OSError) as error:
            raise SystemExit(f"Gleam asset download failed: {type(error).__name__}: {error}") from error
        if status == 200:
            return body
        last = status
        if status in RETRY_STATUS and attempt < ATTEMPTS:
            sleep(2 ** attempt)
            continue
        break
    raise SystemExit(f"Gleam asset download failed: HTTP {last}")


def install(root, system, machine, token, get=http_get, sleep=time.sleep, run=subprocess.run):
    binary = root / ".tools" / "gleam"
    key = (system, machine)
    if key not in ASSETS:
        raise SystemExit(f"Unsupported spike toolchain platform: {key}")
    _target, asset_id, size, checksum = ASSETS[key]
    data = fetch_asset(asset_id, token, get=get, sleep=sleep)
    if len(data) != size:
        raise SystemExit("Gleam release archive size mismatch")
    if hashlib.sha256(data).hexdigest() != checksum:
        raise SystemExit("Gleam release archive checksum mismatch")
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            members = [m for m in archive.getmembers() if m.isfile() and pathlib.PurePosixPath(m.name).name == "gleam"]
            if len(members) != 1:
                raise SystemExit("Expected exactly one compiler executable")
            compiler = archive.extractfile(members[0]).read()
    except (tarfile.TarError, EOFError, OSError) as error:
        raise SystemExit(f"Gleam release archive could not be read: {type(error).__name__}") from error
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(compiler)
    binary.chmod(0o755)
    run([binary, "--version"], check=True)
    return binary


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    binary = root / ".tools" / "gleam"
    if binary.exists() and subprocess.check_output([binary, "--version"], text=True).strip() == f"gleam {VERSION}":
        print(binary)
        return
    print(install(root, platform.system(), platform.machine(), os.environ.get("GITHUB_TOKEN")))


if __name__ == "__main__":
    main()
