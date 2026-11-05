# Authored metadata, generated ledger

`catalogue.json` accounts for every stable capability ID. A ready entry names
`pieces/<id>/piece.json`; a planned/deferred entry names its reason and has no
installable implementation. `providers.json` records direct provider
identities, upstream references, licenses and baseline pins. Transitive
package resolution belongs to Mix and the consuming project's lockfile.

A ready `piece.json` has schema_version 1 and these fields:

- `id`, `status: ready`, `coverage: subset`, `license: Apache-2.0`;
- `kind`: owned (handwritten), adapter (local translation), or recipe (direct
  upstream usage without a mandatory production wrapper);
- `contract` and nonempty `limits`, stating the usable subset precisely;
- `dependencies`: other ready piece IDs; cycles or planned dependencies fail;
- `providers`: direct entries in providers.json; dependencies add their own;
- optional `applications`: OTP application names the consumer must enable;
- `files`: every file under the bundle's lib/, cure/, test/ and examples/;
- `grounding`: individual claims, each with `kind` and `claim`. Proof/type/test/
  monitor references name a bundled file; proof also names its equality-law
  function. Upstream claims name a declared provider and HTTPS reference.
  Assumptions are explicit statements, not evidence of correctness.

Every ready bundle includes a README and executable test evidence. The root
Mix harness compiles each bundle's lib/ and cure/ sources and discovers tests
under pieces/. Copied files retain conventional paths in the consumer.

Author metadata alongside the change, then run:

```sh
mix elzoo.ledger
mix check
```

The check rejects missing/unlisted files, evidence references, false provider
pins, duplicate/invalid IDs, source symlinks, dependency cycles and stale
LEDGER.md. It does not prove English claims, infer correct library selection,
or certify modified consumer code. Independent review must inspect the claim
scope and the executable evidence; path existence is not a semantic proof.

Provider pins are baselines, not instructions to silently replace a consumer's
lockfile. Source copying produces a reviewable dependency list and provenance
receipt; ordinary Mix resolves packages after the developer merges that list.
