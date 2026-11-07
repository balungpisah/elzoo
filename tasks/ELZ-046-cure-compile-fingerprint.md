# ELZ-046 — Skip the owned Cure compile when a content fingerprint matches

- Phase: P0 harness (`lib/mix/tasks/compile_cure.ex`, copied into Cure consumers by `lib/elzoo/export.ex`)
- Catalogue IDs: none
- Dependencies: ELZ-045 (#80) for the stage stamps that measure this. Not a merge dependency.
- Source: CI speed assessment 2026-11-08, item 2.

## Outcome

Today `mix setup` compiles all 25 owned `.cure` files, then `mix check` compiles them again
(about 110-137 s per CI job, measured). The custom compiler keeps only a module-name manifest, so
it cannot tell that nothing changed. After this task the compiler skips when, and only when, a
content fingerprint matches and every expected BEAM is present. Any mismatch or doubt recompiles.

## Scope

- `Mix.Tasks.Compile.Cure` writes a manifest with a sha256 fingerprint over: the path and
  content of every `.cure` source, the nearest `Cure.toml` of each source, the sorted source-root
  list, the whole `mix.lock`, every file in the loaded Cure `ebin`, the compiler module's own BEAM
  md5, and the Elixir, OTP and ERTS versions. It keeps the module list for stale removal. A
  mismatch, an old-format or malformed manifest, a missing BEAM, or `--force` recompiles.
- Consumers copy the same file. Their first build starts from an empty `_build` and compiles;
  a later build in the same consumer skips under the same rule.
- New negative controls in a new test file: unchanged inputs skip; one edited `.cure` source
  recompiles; a corrupted, wrong or old-format manifest recompiles; a deleted BEAM recompiles;
  `--force`, a changed source-root list, a new or edited `Cure.toml` and a new or edited
  `mix.lock` recompile; a manifest module line outside `Cure.<name>` is rejected. These run in an isolated
  temporary Mix project. Existing tests and assertions stay as they are.
- `docs/development/10-symbolic-ci.md`: what the skip means and what it does not.

## Acceptance

- [ ] Full `mix setup` and `mix check` pass locally; the `ELZOO STAGE compile` line (ELZ-045) shows
      the compile stage shortened on the same SHA, both runners, run and job IDs recorded.
- [ ] Listed negative controls pass.
- [ ] Independent review of the actual diff (compiler/evidence boundary).

## Limits

The fingerprint covers named inputs only. It is not a proof that no other input exists. The gain is
hypothetical until measured on CI.
