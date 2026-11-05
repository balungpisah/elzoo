# Upstream first; maintained forks when needed

Use upstream releases by default. MIT licensing permits a fork; it does not
make a fork necessary. Elzoo does not mirror or fork every dependency. The
owner explicitly authorizes maintained MIT-library forks under `balungpisah`
when a concrete modification is needed. A dependency that needs no changes
stays upstream. Prefer configuration, public extension points or an upstream
fix when they satisfy the Contract without a permanent divergent version.

## When a fork earns its maintenance cost

Before creating one, record an issue with the failing scenario or missing
Contract, why existing extension points cannot satisfy it, the intended
change and acceptance checks. A fork may be justified by a required bug fix,
incompatible upstream direction or a maintenance gap that affects a real
consumer. A possible future feature or the license alone is not a trigger.
This rule authorizes the needed development; it adds no per-fork owner
approval step. Follow normal task claim, independent review and integration.

Use a real GitHub fork in `balungpisah` when available. Preserve Git ancestry,
an `upstream` remote and the exact upstream base SHA/tag. GitHub public forks
are public: keep Elzoo-private configuration and application code out of them.
If a private derivative is necessary, use a separately created repository
with preserved provenance rather than assuming a public fork can be private.

## License and ownership

Verify the license of the exact version and affected files, including bundled
code and assets. Keep upstream copyright notices and MIT permission/license
text in copies and distributions. Do not relabel upstream source as
Elzoo-owned Apache-2.0. For a maintained MIT fork, retain MIT for the fork and
record our modifications distinctly; original Elzoo Pieces remain Apache-2.0.
Other licenses need their own applicable terms; this MIT policy is not a
blanket permission to handle every dependency identically.

The upstream contract still grounds unchanged behavior where its assumptions
hold. Modified behavior is now our responsibility: attach regression tests,
selected proofs when useful, and changed assumptions to the exact fork
revision. Do not inherit an upstream evidence claim for code we changed
without checking whether that evidence still applies.

## Required fork record

Keep `docs/dependencies/forks/<package>.md` with:

- problem/issue and named maintaining team or maintainer;
- upstream URL, exact base revision, license and preserved notice locations;
- `balungpisah` fork URL, immutable consumed revision and patch summary;
- consuming Pieces/Assemblies and lockfile/provider records;
- tests, known incompatibilities and responsibility for modified behavior;
- upstream release/security monitoring owner and integration cadence;
- conditions for returning upstream or retiring the fork.

Preserve package/application/module identities unless a concrete coexistence
requirement calls for renaming. Pin consumed Git dependencies by commit and
run their integration checks; do not follow a moving branch silently. Update
the dependency register and relevant Piece Ledger records when consumption
changes. Merely creating a fork is not adoption.

Keep the patch set small. Reconcile upstream fixes deliberately and re-run
affected checks. Contributing a fix upstream is encouraged, but external
messages or PRs still require session authorization. If upstream incorporates
what we need, evaluate returning to a supported upstream release and retire
the divergence. No fork is created by ELZ-015; its Ash packages are upstream.
