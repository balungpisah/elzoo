# ELZ-401 — CI: ci-minio.py retries a transient bucket check after MinIO reports ready

- Dependencies: none

## Outcome and scope

Defect #969. The push run of `main` on `ce2adb70` (run 45560286330, job
`check-root-b`) failed in its MinIO step before any test ran:
`signed HEAD of the bucket answered HTTP 503`. `wait_health` in
`scripts/ci-minio.py` polls the live and ready endpoints until each answers
200, but `check_bucket` then makes one signed HEAD of the bucket and stops on
any status other than 200. MinIO can still answer 503 for a short time after
it reports ready.

After this task, `check_bucket` retries the signed HEAD on HTTP 500, 502, 503
and 504 and on connection errors, within one fixed bound that the script
already owns (for example the remainder of `HEALTH_SECONDS`), and then stops
with a message that names the last status or error. HTTP 403 and 404, and any
other status, still stop at once, because they show that the credentials or
the bucket are wrong. A 200 succeeds as before.

This is a CI-harness change: a coordinator-owned non-Piece change on the
one-PR path (`AGENTS.md` section 1). Publication and implementation share one
`task/ELZ-401` pull request. It takes the full/affected local gate and the
full hosted check, not the docs-only lane.

Owned paths:

- `scripts/ci-minio.py`
- `scripts/test-ci-minio.py`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. No Piece, manifest, catalogue entry,
dependency, pin, workflow file or runner label changes.

## Acceptance

- Guard cases in `scripts/test-ci-minio.py` against a local fake server: 503
  then 200 succeeds; repeated 503 until the bound stops with a message naming
  503; a connection error then 200 succeeds; 403 and 404 each stop on the
  first request with no retry (assert the request count); 200 at once makes
  one request.
- The bound is finite and is the script's own: no new environment variable,
  no unbounded loop, and the existing download retry path is unchanged.
- Negative control: temporarily restore the single HEAD; the 503-then-200
  case fails. Restore the fix before the final gate.
- `python3 scripts/test-ci-minio.py`, `mix check --affected origin/main` (it
  selects everything for a script change) and `git diff --check` exit 0, and
  the full hosted check passes on the exact head.
