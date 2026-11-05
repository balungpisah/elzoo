# Gates: runtime

Scope: Pinned, runnable Mix/Cure foundation and a small genuine composition.

- [x] R1: mix setup installs pinned Cure and dependencies reproducibly without a Zoo checkout.
  EVIDENCE: `mix.exs` and `mix.lock` pin Cure to git commit
  `a004c335cc4e9f2203ba6f51fc31e8540b66378d`; `mix setup` completed from the
  Elzoo root using only the network, Git, Hex and the pinned Mix toolchain. No
  path dependency or Zoo checkout is referenced.
- [x] R2: mix check compiles Cure through its proof kernel, runs runtime tests and rejects a false proof and incompatible typed connection.
  CHECK: mix check
  EXPECT: ELZOO CHECK PASSED
  EVIDENCE: `mix check` passed 8 ExUnit tests and printed the expected marker.
  The tests compile the actual `cure/*.cure` sources through
  `Cure.Compiler.compile_file/2`, audit the selected pure proofs, and assert
  compiler rejection of a false proof, incompatible typed connection, and an
  unfinished proof. `mix check` accepts no targeting arguments; use `mix test`
  for targeted diagnostics.
- [x] R3: The same pure transition runs fused and behind OTP; an external Elixir library is exercised with explicit trust.
  EVIDENCE: `Elzoo.Runtime.fused/1` and `Elzoo.Runtime.hopped/1` share the
  compiled Cure operator; deterministic seeded traces agree with an independent
  set/sum model. `Elzoo.Unit` and a Supervisor exercise OTP placement and its
  volatile-restart limit. The Cure adapter calls Jason through `@extern`, while
  `Elzoo.JsonBoundary` validates inputs and translates library failures.
- [x] R4: Dependencies, source layout and failure behavior are documented for the coordinator; no hidden local path is required.
  EVIDENCE: `cure/`, `lib/elzoo/`, `lib/mix/tasks/`, `config/`, and `test/` are
  wired by normal Mix. The custom compiler stages Cure BEAMs, removes stale
  manifest entries, and publishes them into the application ebin before `:app`
  generation. Production compile and `mix release` both listed and loaded all
  four `Cure.Elzoo.*` BEAMs; no Zoo checkout was on the runtime path.
