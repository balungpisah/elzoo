# ELZ-279 — Keep personal data in a per-subject vault that erasure makes unreadable

- Phase: Wave 5 Level 3 (sub-level 3a)
- Dependencies: ELZ-033, ELZ-105, ELZ-273
- Release: V1B
- Output: new `state/retention-erasure` Piece
- Change class: Piece-only
- Owned paths: `pieces/state/retention-erasure/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`integration/encryption`, `integration/secrets`, `state/artifact`, `assembly/checked-command`, `state/audit-log`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One Adapter over a consumer-owned Ecto Repo on PostgreSQL 16. It implements the erasure posture of the owner decision of 2026-11-20: personal data lives in a vault, sealed under one key per subject, and command, event and audit logs carry only opaque references. Erasing a subject destroys its key and its entries in one transaction. A copy of an envelope taken earlier (an export, a cache or a row restored from backup) then has no key in the vault. The Piece never deletes or rewrites a row of `elzoo_log_records`, so `assembly/checked-command` recovery (`low_water == 0`) and Carbonite `state/audit-log` history stay intact. The root acceptance (ELZ-286) proves that composition: this Piece's tests do not use the Store.

Reuse, without new providers: ready `integration/encryption` (ELZ-273) for every seal and open, ready `integration/secrets` (ELZ-105) `%Elzoo.Secrets.Credential{}` for the key-encryption key (KEK), OTP `:crypto.strong_rand_bytes/1`, and locked `ecto_sql 3.14.0` and `postgrex 0.22.4`. Plain Elixir; no Ash, no Oban job, no background process.

Not in this task: tombstones or expiry for `state/artifact` and `integration/search-data` objects, retention schedules, subject-key rotation, KEK re-wrapping, or a tenant column or row-level security on the vault tables.

## Interface

- `Elzoo.RetentionErasure.Migration.install(prefix)`, inside a consumer Ecto migration, creates three tables in schema `prefix`:
  - `elzoo_vault_subjects`: `subject text PRIMARY KEY`, `state text NOT NULL CHECK (state IN ('active','erased'))`, `erased_at bigint`;
  - `elzoo_vault_keys`: `subject` referencing the subjects table, `version bigint`, `wrapped bytea NOT NULL`, `PRIMARY KEY (subject, version)`;
  - `elzoo_vault_entries`: `ref text PRIMARY KEY`, `subject` referencing the subjects table, `key_version bigint NOT NULL`, `envelope bytea NOT NULL`.

  `prefix` follows the `state/tenant-isolation` identifier rule `^[a-z_][a-z0-9_]{0,62}$`, else `ArgumentError` with a fixed message.
- `Elzoo.RetentionErasure.vault(opts)` takes a keyword list with exactly `repo`, `prefix` and `kek`, and returns an opaque vault with a redacted `Inspect`, or raises the fixed `ArgumentError`. `kek` is an arity-1 Need called as `kek.(:current)` or `kek.(version)`. It returns `{:ok, credential}` with a 32-byte value whose `version` equals the requested one (or is the current one), or `{:error, _}`. KEK envelopes use the fixed key ID `"elzoo-vault-kek"`.
- `put(vault, subject, plaintext)` returns `{:ok, ref}` or `{:error, :malformed | :in_transaction | :unavailable | :erased}`. `ref` is `"v1_"` followed by 22 base64url characters of 16 random bytes, so it fits the `integration/pii-redaction` (ELZ-278) reference rule. Inside one transaction it:
  1. inserts the subject as `active` if it is absent;
  2. locks the subject row `FOR SHARE` and gives `:erased` if its state is `erased`;
  3. takes the newest key version. With none, it generates 32 random bytes as version 1 and stores them sealed with `Elzoo.Encryption.seal/4` under the current KEK, with an AAD that binds the subject and the version. Two concurrent first puts store exactly one version 1 (`ON CONFLICT DO NOTHING`, then re-read);
  4. seals `plaintext` with `Elzoo.Encryption.seal/4` under key ID `subject` and the subject key, with `aad` equal to `ref`, and inserts the entry.
- `fetch(vault, ref)` returns `{:ok, plaintext}` or `{:error, :malformed | :in_transaction | :not_found | :unavailable | :invalid}`. It opens the entry with `Elzoo.Encryption.open/3` and a keys Need that unwraps that subject's stored key version through the KEK. A missing entry, which includes every entry of an erased subject, is `:not_found`. An `:invalid` result of Encryption stays `:invalid`; any other failure is `:unavailable`.
- `erase(vault, subject)` returns `:ok` or `{:error, :malformed | :in_transaction | :unavailable}`. In one transaction it upserts the subject as `erased` with `erased_at` (Unix seconds from the database clock), taking the row lock, and deletes the subject's key rows and entry rows. Erasing an absent or already erased subject is `:ok`, and it stays erased: a later `put` is `:erased`.
- `status(vault, subject)` returns `{:ok, :absent | :active | :erased}` or `{:error, :malformed | :unavailable}`.

Every entry point refuses inside the caller's open transaction on the Repo (`repo.in_transaction?()`, giving `:in_transaction`) before any query. This keeps the lock order its own. A `subject` follows the `domain/principal` text rule (1..128 bytes, valid UTF-8, no C0 or C1 control character), which is also the `integration/encryption` key-ID rule. The host namespaces subjects, for example `principal:<id>` or `tenant:<id>`; per-tenant erasure is erasure of a tenant subject. `plaintext` is a binary of 0..65,536 bytes. Errors are fixed atoms and never echo a subject, plaintext, key or envelope. The Piece's own queries pass `log: false` and it emits no telemetry and no log.

## Acceptance

All database cases run on the worker's own disposable database behind a fail-closed target guard (the pattern of `state/tenant-isolation` tests), in random schemas dropped afterwards.

1. Round trip: put and fetch for 0-, 1- and 65,536-byte plaintexts and for 1- and 128-byte subjects; two subjects; many entries of one subject share key version 1. The stored `envelope` and `wrapped` columns hold no plaintext or raw key bytes (search the raw rows).
2. Erasure: after `erase(A)`, every ref of A is `:not_found`, every ref of B still opens, and `status(A)` is `:erased`. A later `put(A, _)` is `:erased` and creates no key. Crypto-shredding: an envelope and a wrapped key copied out of the tables before the erase (the stand-in for a backup) are opened with `Elzoo.Encryption.open/3` and a keys Need that reads only what the vault still stores, and that gives `:no_key`. `erase` of an absent subject is `:ok` and blocks a later put.
3. Swaps: an entry envelope moved to another ref, and a wrapped key moved to another subject or version (direct SQL), give `:invalid` or `:unavailable` and never another subject's plaintext.
4. Concurrency, with a controlled barrier on real PostgreSQL: two first puts of one new subject give exactly one key row. A put and an erase of one subject race. The result is either the put committing first, so its entry is gone after the erase, or `:erased`. Afterwards no key or entry of the subject exists, whatever the order.
5. KEK Need: a raise, throw, exit, `{:ok, "raw"}`, a 31-byte value and a wrong version are each `:unavailable` with no row written. The Need is not called for `:malformed` or `:in_transaction` (count the calls).
6. Shape and bounds: subjects of 0, 1, 128 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085; a plaintext of 65,537 bytes; refs that are not `v1_` plus 22 base64url characters are `:malformed` before any query; each call inside an open `repo.transact/2` is `:in_transaction`; an unreachable Repo is `:unavailable`; a bad `prefix` raises the fixed `ArgumentError` in `install/1` and `vault/1`.
7. Secrecy: no plaintext, key or KEK byte appears in a result, a raised message or captured logs.
8. Negative controls, one at a time: skip the `erased` check in `put`; erase keys but not the subject state; use a fixed AAD for entries; read the subject state in `put` without `FOR SHARE`. Each must make a case of groups 2–4 fail. Restore before the final gates.

Limits to state: dead tuples, WAL and backups keep wrapped keys until the database reclaims them. A restored backup can open old envelopes only while its KEK version still exists, so destroying an old KEK version after the backup retention period finishes the erasure, and that is the host's duty. No subject-key rotation (one key version should seal fewer than 2^32 envelopes, as ELZ-273 states), no KEK re-wrap, no artifact or object tombstones, no retention schedule and no tenant scoping of the vault tables. The consumer Repo's query telemetry receives subjects and envelopes as parameters. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
