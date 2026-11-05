#!/usr/bin/env python3
"""Install the pinned upstream compiler locally, verifying the release archive."""
import hashlib
import io
import pathlib
import platform
import subprocess
import tarfile
import urllib.request

VERSION = "1.19.2"
ASSETS = {
    ("Darwin", "arm64"): ("aarch64-apple-darwin", "fa7c6113e162ab1d979f72e7dde3e907b87e4b30c518af178768e577d180324d"),
    ("Darwin", "x86_64"): ("x86_64-apple-darwin", "c578192530507b868c4a6c8cb7ad5d2ab0830890257f41036f17c82853f19d05"),
    ("Linux", "x86_64"): ("x86_64-unknown-linux-musl", "2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f"),
    ("Linux", "aarch64"): ("aarch64-unknown-linux-musl", "d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1"),
}

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / ".tools" / "gleam"
if binary.exists() and subprocess.check_output([binary, "--version"], text=True).strip() == f"gleam {VERSION}":
    print(binary)
else:
    key = (platform.system(), platform.machine())
    if key not in ASSETS:
        raise SystemExit(f"Unsupported spike toolchain platform: {key}")
    target, checksum = ASSETS[key]
    url = f"https://github.com/gleam-lang/gleam/releases/download/v{VERSION}/gleam-v{VERSION}-{target}.tar.gz"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise SystemExit("Gleam release archive checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = [m for m in archive.getmembers() if m.isfile() and pathlib.PurePosixPath(m.name).name == "gleam"]
        if len(members) != 1:
            raise SystemExit("Expected exactly one compiler executable")
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(archive.extractfile(members[0]).read())
        binary.chmod(0o755)
    subprocess.run([binary, "--version"], check=True)
    print(binary)
