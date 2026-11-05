#!/usr/bin/env python3
"""Package the pinned runtime module tree; deliberately no bundling/tree shaking."""
import hashlib
import json
import pathlib
import shutil
import tomllib

root = pathlib.Path(__file__).resolve().parents[1]
compiled = root / "build/dev/javascript"
destination = root / "dist"
shutil.rmtree(destination, ignore_errors=True)
destination.mkdir()
manifest = tomllib.loads((root / "manifest.toml").read_text())
config = tomllib.loads((root / "gleam.toml").read_text())
packages = {package["name"]: package for package in manifest["packages"]}
runtime = set()

def include(name):
    if name not in runtime:
        runtime.add(name)
        for dependency in packages[name]["requirements"]:
            include(dependency)

for name in config["dependencies"]:
    include(name)

# Keep module paths and upstream FFI source intact. Copy every runtime module,
# including unused modules, but no test runner or compiler cache/build metadata.
for name in sorted(runtime):
    for source in (compiled / name).rglob("*.mjs"):
        target = destination / "modules" / source.relative_to(compiled)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
for name in ["elzoo_gleam_ui.mjs", "quantity.mjs", "gleam.mjs"]:
    target = destination / "modules/elzoo_gleam_ui" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(compiled / "elzoo_gleam_ui" / name, target)
shutil.copyfile(compiled / "prelude.mjs", destination / "modules/prelude.mjs")
shutil.copyfile(root / "browser/host.html", destination / "index.html")
shutil.copyfile(root.parents[1] / "LICENSE", destination / "LICENSE")
(destination / "NOTICE").write_text(
    "Elzoo quantity component experiment\nCopyright 2026 Elzoo contributors\n"
    "Elzoo-owned code: Apache-2.0. Upstream modules retain their licenses.\n"
    "Gleam 1.19.2 generated runtime/prelude: Apache-2.0, Gleam contributors.\n"
    "See third-party/ for package licenses and provenance.json for pins.\n"
)
for name in sorted(runtime):
    package = root / "build/packages" / name
    target = destination / "third-party" / name
    target.mkdir(parents=True)
    shutil.copyfile(package / "gleam.toml", target / "gleam.toml")
    notices = [p for p in package.iterdir()
               if p.is_file() and p.name.upper().split(".")[0] in {"LICENSE", "LICENCE", "NOTICE", "COPYING"}]
    for notice in notices:
        shutil.copyfile(notice, target / notice.name)
    if not notices:
        # houdini 1.2.1 declares Apache-2.0 in package metadata but ships no
        # standalone license/notice. Preserve metadata and the standard text.
        if name != "houdini" or packages[name]["version"] != "1.2.1":
            raise SystemExit(f"Review missing license text for {name}")
        shutil.copyfile(root.parents[1] / "LICENSE", target / "LICENSE")
        (target / "SOURCE.txt").write_text(
            "houdini 1.2.1, giacomocavalieri/houdini, commit "
            "8d2c5188235e433c7a4d29aa39b064d6e91d8687.\n"
            "Apache-2.0 declared in upstream gleam.toml. No standalone license "
            "or NOTICE shipped; LICENSE is the standard Apache-2.0 text.\n"
        )
receipt = {
    "compiler": "gleam 1.19.2",
    "packages": [packages[name] for name in sorted(runtime)],
    "owned_sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted((root / "src").glob("*.gleam"))},
    "files": {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(destination.rglob("*")) if p.is_file()},
}
(destination / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(f"Packaged {len(receipt['files'])} files ({sum(p.stat().st_size for p in destination.rglob('*') if p.is_file())} bytes); unoptimized module tree")
