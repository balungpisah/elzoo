# Independent Gleam / Lustre experiment

This is an optional library evaluation, not a ready Piece or a required backend
runtime. It has no Ash dependency and no Telemetry / Config / Control API.
The [research decision](../../docs/research/gleam-libraries.md) records adoption
limits and the other candidates.

## Reproduce

Prerequisites: Node **24.16.0**, Python **3.11+**, OTP **29.1.2** (the repository's
BEAM pin), network access and a supported browser host. From this directory:

```sh
./scripts/setup.sh
./scripts/check.sh
```

Setup installs Gleam **1.19.2** under `.tools/`, downloads the release archive
through the GitHub release-asset API by asset ID (set `GITHUB_TOKEN` to avoid the
unauthenticated rate limit; CI passes the job token), checks the archive's pinned
size and SHA-256, resolves the committed Hex manifest, runs `npm ci`, and installs
Playwright's pinned Chromium. macOS arm64/x86_64 and Linux arm64/x86_64 compiler
assets are mapped; only macOS arm64 local and Ubuntu x86_64 CI are acceptance
environments. On minimal Linux, also run
`npx --no-install playwright install-deps chromium` after setup.
Windows and other browsers/platforms are not checked.

Check runs format validation, three model tests on each target, JavaScript
compilation with owned warnings treated as errors, packages `dist/`, then runs
one multi-scenario Chromium host check against only that copied distribution.
The separate **Gleam experiment** workflow reproduces this on Linux. Root
`mix setup` / `mix check` remain independent and require no Gleam or Node.

## What the example promises

`quantity.gleam` owns a pure opaque integer model in the inclusive range 0–100.
Increment/decrement saturate at the bounds. Host strings are parsed with
`gleam/int.parse` and range checked; rejected changes preserve current state.
The selected finite tests run unchanged on JavaScript and BEAM. These are
**tests and compiler type checks, not a Cure proof** or a demonstration of all
cross-target numeric behavior. The small range avoids JS integer precision
limits; it is not a money/token-accounting model.

`elzoo_gleam_ui.gleam` registers the browser-only `elzoo-quantity` custom element.
Call `main()` once per browser custom-element registry. Each instance starts at
0, accepts its own `value` attribute and renders in its own shadow DOM. The
initial attribute can be present before registration. Host updates replace the
value without emitting a user event. Invalid or removed attributes leave the
previous value intact. User changes emit a `quantity-change` CustomEvent whose
`detail` is plain `{value: integer}`; listen on the element itself. The attribute
is input only: user clicks do not reflect current state back into the attribute.
Buttons are disabled at the bounds and do not submit an enclosing form.

The host check exercises initial attributes, two independent instances, both
bounds, six invalid attributes, host updates without event echoes, event payloads,
Enter/Space activation, form isolation and absence of page/module-load errors.
It is not a full accessibility audit or browser-compatibility certification.

## Copying the experiment

`dist/index.html` is a plain HTML consumer of the generated ES module tree:

```html
<elzoo-quantity value="2"></elzoo-quantity>
<script type="module">
  import { main } from './modules/elzoo_gleam_ui/elzoo_gleam_ui.mjs';
  main();
</script>
```

Copy **all of `dist/`**, keeping relative paths and license/notice files. Serve
`.mjs` as JavaScript over HTTP(S); this is not a `file://` distribution. Hosts
need browser modules/custom elements/shadow DOM, but no BEAM/Elzoo runtime or
Gleam compiler. Developers modifying source need the pinned tools. The check
uses Playwright request interception instead of starting a development server.

Packaging deliberately copies all runtime dependencies' `.mjs` files, including
unused modules: it is **not** tree-shaken, minified or a single-file bundle. The
local package is roughly 1 MB uncompressed; this is directory size, not measured
network transfer or application performance. Test modules and gleeunit are not
included. `provenance.json` records source/content hashes and resolved packages;
`third-party/` preserves license texts and package metadata. Houdini 1.2.1 ships
no standalone license file; its Apache-2.0 declaration is retained with the
standard license text and source reference. No upstream source is modified.

This is not yet supported by `mix elzoo.take`. Ready export would need a real
consumer use case, a versioned DOM contract, export/provenance integration,
accessibility/theme/remount requirements and relevant browser/host checks. No
framework integration, server rendering/hydration or Cure/Elixir FFI is claimed.
