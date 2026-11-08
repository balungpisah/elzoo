# ELZ-060 — Install the pinned Gleam compiler through the release-asset API, with the job token

- Phase: P0 harness (CI; `.github/workflows/symbolic-gleam.yml`, `spikes/gleam_ui/scripts/setup_gleam.py`,
  `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: none (independent of ELZ-049, ELZ-057, ELZ-058, ELZ-059). Urgent.
- Review: independent review of the workflow and guard diff is required.

## Outcome

Since about 16:20 WIB on 2026-11-08 the browser download URL for release assets
(`https://github.com/gleam-lang/gleam/releases/download/v1.19.2/...`) answered HTTP 504 from the
job container (Gleam run 42467133717, job 128689127890: `spikes/gleam_ui/scripts/setup_gleam.py`,
`urllib.error.HTTPError: HTTP Error 504: Gateway Time-out`). That download is the first step of every
Gleam job, and the merge queue requires a green Gleam run, so no pull request can merge.
The release-asset API route answers: `GET /repos/gleam-lang/gleam/releases/assets/<id>` with
`Accept: application/octet-stream` returned the full 10,565,692-byte Linux x86_64 archive whose SHA-256
is the pinned `2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f`.

Correction to the first brief: `setup-beam` installs only OTP in this workflow; the Gleam compiler is
downloaded by `setup_gleam.py` (called by `scripts/setup.sh`), which already verifies a pinned SHA-256 per
platform. The change is therefore in that script plus a workflow step that passes the job token.

## Scope

- `spikes/gleam_ui/scripts/setup_gleam.py`: download each pinned asset through the API by asset ID
  (`https://api.github.com/repos/gleam-lang/gleam/releases/assets/<id>`, `Accept: application/octet-stream`,
  `Authorization` from `GITHUB_TOKEN` when set) instead of the browser URL. Follow the redirect to the
  storage host manually and send **no** `Authorization` header there; accept only HTTPS redirect hosts
  under `githubusercontent.com` or `github.com`. Keep the pinned per-platform SHA-256 (unchanged: the
  GitHub API digests equal the pins for all four platforms) and add the pinned size and asset ID. Fail
  closed on a checksum mismatch, size mismatch, unexpected redirect host, or any HTTP/network error
  (bounded retries only for HTTP 502, 503 and 504). Keep the archive handling and `.tools/gleam` result.
- `symbolic-gleam.yml`: the setup step becomes `Install the pinned Gleam compiler` with
  `env: GITHUB_TOKEN: ${{ github.token }}` and `run: ./scripts/setup.sh`. Identity of the job (name,
  fork-PR gate, `runs-on`, container digest, timeout) is untouched; `setup-beam` stays for OTP only.
- Guard: `scripts/check-ci-runners.py` pins that exact step in `symbolic-gleam.yml` and allows
  `github.token` only on that one line; `scripts/test-ci-runners.py` gets negative controls (token on
  another step, token in the job `env`, a changed run line, a missing step). Existing tests are not
  edited or weakened; forced edits, if any, are listed in the PR for the owner's approval.
- Tests for `setup_gleam.py` with a fake HTTP layer (success, checksum mismatch, size mismatch, 504 then
  success, three 504s, redirect to a foreign host, token not sent to the redirect target), run by the
  Gleam job's `check.sh` or by `scripts/test-*.py` in the backend job (decide in the PR; keep the guard
  shape of the backend workflow unchanged).
- Docs: `docs/development/10-symbolic-ci.md` records the pin (v1.19.2), the four hashes and asset IDs, the
  API route, and the outage of 2026-11-08 as the reason; `spikes/gleam_ui/README.md` setup paragraph.

## Acceptance

- [ ] The Gleam job of this PR passes using the new route (run and job IDs), on `symbolic-elzoo-gleam`.
- [ ] A wrong checksum in a test copy of the script fails closed (test, not CI).
- [ ] Guard and tests pass; independent review of the actual diff (separate agent session, reviewed SHA).
- [ ] The queue question `queue free for PR #N?` is asked before the merge.

## Limits

The API route depends on `api.github.com` and the storage host the redirect names; it is not proof that
the browser URL works again. The token is the job's read-only `github.token`; a public release needs no
extra scope. Platforms other than the four pinned ones stay unsupported.
