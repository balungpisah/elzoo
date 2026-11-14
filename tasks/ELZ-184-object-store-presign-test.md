# ELZ-184 — The presign test of `integration/object-store` reads its URL before it can expire

- Dependencies: ELZ-033
- Output: none. A repair of one test of the ready Piece `integration/object-store`; the Contract of the Piece does not change.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/integration/object-store/test/**` only, and its index/generated changes under AGENTS.md section 3 if a listed file hash changes.

Issue #381 holds the evidence. In the push run 43567597423 of `main` (job
`check-aggregate`, first attempt) the test `S9 presign: works before expiry,
refused after; put presign; no I/O, redacted inspect`
(`test/elzoo/object_store_test.exs`) failed at its first read: the S3 test
server answered 403, `AccessDenied`, "Request has expired". The rerun of all
jobs passed. The change under test could not affect the Piece.

Fact checked on main: the test makes one URL with `expires_s: 1`, reads it in
the next statement and expects 200, then sleeps 2,100 ms and expects 403. In
the aggregate consumer, which runs many suites together, more than one second
can pass between the two statements. The one URL serves two claims with
opposite needs: "works before expiry" needs a long life, "refused after"
needs a short one.

## Change

Use two URLs for the same object in that test:

1. "Works before expiry": a URL with `expires_s: 60`. Read it at once and
   expect 200 with the body. The assertions on the URL text (it holds the
   access key, it holds no secret) and on `inspect/1` stay, on this URL.
2. "Refused after": a second URL with `expires_s: 1`. Do not read it before
   it expires. Wait as today and expect 403.

Change nothing else: no other test, no file under `lib/`, no limit and no
timeout of a suite. The test stays one test with its name.

## Acceptance

- The test passes 50 times in a row locally with the S3 test server of the
  worker (`mix test pieces/integration/object-store/test --only
  "test:<the test name>"` or the form that the Piece's suite needs; record
  the command and the count).
- A negative control: with the first URL back at `expires_s: 1` and a
  `Process.sleep(1_500)` before its read, the test fails with the 403 of the
  issue; restore it.
- The local gate: `mix test pieces/integration/object-store/test`, then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check`. One independent review.
- The pull request closes #381.

## Not in scope

The presign implementation, clock skew between the runner and the test
server, any other flaky test.
