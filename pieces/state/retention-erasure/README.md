# state/retention-erasure

A per-subject personal-data vault in PostgreSQL 16 whose erasure makes the subject's data
unreadable (ELZ-279, [issue #643](https://github.com/balungpisah/elzoo/issues/643)). Personal
data lives in the vault, sealed under one key per subject; command, event and audit logs carry
only the vault's opaque references. Erasing a subject destroys its key and its entries in one
transaction, so a copy of an envelope taken earlier (an export, a cache or a row restored from
backup) has no key in the vault.

One Adapter over a consumer-owned Ecto Repo, in plain Elixir: no Ash, no Oban job and no
process. The Piece never reads, deletes or rewrites a row of `elzoo_log_records`, so
`assembly/checked-command` recovery and `state/audit-log` history stay intact; the root
acceptance (ELZ-286) proves that composition, and this Piece's tests do not use the Store.

## Copy and providers

`mix elzoo.take state/retention-erasure --to <consumer>` copies this Piece with
`integration/encryption` (every seal and open) and `integration/secrets`
(`%Elzoo.Secrets.Credential{}` for the KEK). Add `:crypto` to `extra_applications`. Providers:
`ecto_sql` 3.14.0 and `postgrex` 0.22.4, `elixir` 1.20.4 and `otp` 29.1.2
(`:crypto.strong_rand_bytes/1`). Source is Apache-2.0; see
[consuming](../../../docs/consuming.md). Grounding per claim is in [piece.json](piece.json).

## Tables

`Elzoo.RetentionErasure.Migration.install(prefix)`, called from the `up/0` of a consumer Ecto
migration, creates in the existing schema `prefix`:

- `elzoo_vault_subjects`: `subject text PRIMARY KEY`, `state text NOT NULL CHECK (state IN
  ('active','erased'))`, `erased_at bigint` (Unix seconds from the database clock);
- `elzoo_vault_keys`: `subject` referencing the subjects table, `version bigint`,
  `wrapped bytea NOT NULL`, `PRIMARY KEY (subject, version)`;
- `elzoo_vault_entries`: `ref text PRIMARY KEY`, `subject` referencing the subjects table,
  `key_version bigint NOT NULL`, `envelope bytea NOT NULL`, with an index on `subject`.

`prefix` follows the `state/tenant-isolation` identifier rule `^[a-z_][a-z0-9_]{0,62}$` and is
quoted; anything else raises `ArgumentError` with the fixed message
`"invalid retention erasure prefix or options"` before any DDL is queued. Nothing is reversible
by the Piece; a `down/0` is the consumer's.

## API

`Elzoo.RetentionErasure.vault(repo: repo, prefix: prefix, kek: kek)` takes exactly those three
keys and returns an opaque vault whose `Inspect` is `#Elzoo.RetentionErasure<redacted>`, or
raises the same fixed `ArgumentError`. `kek` is an arity-1 Need called as `kek.(:current)` (to
seal a new subject key) or `kek.(version)` (to unwrap one). It returns `{:ok, credential}` with
a 32-byte value whose `version` is the current or the requested one, or `{:error, _}`; a
destroyed version must answer `{:error, :not_found}`.

```elixir
kek = fn version ->
  case MyApp.Kms.vault_kek(version) do
    {:ok, bytes, v} -> {:ok, %Elzoo.Secrets.Credential{value: bytes, version: v, expires_at_unix_ms: 0}}
    :destroyed -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end
end

vault = Elzoo.RetentionErasure.vault(repo: MyApp.Repo, prefix: "vault", kek: kek)
{:ok, ref} = Elzoo.RetentionErasure.put(vault, "principal:42", "+62 812 3456 7890")
```

`MyApp.Kms` is consumer-owned.

- `put(vault, subject, plaintext)` returns `{:ok, ref}` or
  `{:error, :malformed | :in_transaction | :unavailable | :erased}`. `ref` is `"v1_"` and 22
  base64url characters of 16 random bytes (the `integration/pii-redaction` reference rule). In
  one transaction it inserts the subject as `active` if absent, locks the subject row
  `FOR SHARE` and gives `:erased` for an erased subject, takes the newest key version (or makes
  version 1 from 32 random bytes, sealed under the current KEK; two concurrent first puts store
  one version 1 by `ON CONFLICT DO NOTHING` and a re-read), and inserts the entry sealed under
  key ID `subject` with `aad` equal to `ref`. Any KEK or seal failure rolls back and is
  `:unavailable`.
- `fetch(vault, ref)` returns `{:ok, plaintext}` or
  `{:error, :malformed | :in_transaction | :not_found | :unavailable | :invalid}`. It reads the
  entry and its stored key version in one statement and opens it with `Elzoo.Encryption.open/3`
  and a keys Need that unwraps that subject's key version through the KEK. A missing entry,
  which includes every entry of an erased subject, is `:not_found`; `:invalid` from Encryption
  stays `:invalid`; anything else is `:unavailable`.
- `erase(vault, subject)` returns `:ok` or `{:error, :malformed | :in_transaction |
  :unavailable}`. In one transaction it upserts the subject as `erased` (taking the row lock
  that conflicts with `put`'s `FOR SHARE`; the first `erased_at` is kept) and deletes the
  subject's entry and key rows. An absent or already erased subject is `:ok`, and it stays
  erased: a later `put` is `:erased` and creates no key.
- `status(vault, subject)` returns `{:ok, :absent | :active | :erased}` or
  `{:error, :malformed | :in_transaction | :unavailable}`.

Order of refusals: shape (`:malformed`), then `repo.in_transaction?()` (`:in_transaction`),
both before any query or Need call, so the Piece keeps its own lock order. A `subject` follows
the `domain/principal` text rule, which is also the `integration/encryption` key-ID rule: 1..128
bytes of valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F). The
host namespaces subjects, for example `principal:<id>` or `tenant:<id>`; per-tenant erasure is
erasure of a tenant subject. `plaintext` is a binary of 0..65,536 bytes. A Repo, database or
driver failure is `:unavailable`; nothing raised reaches the caller.

## Storage format

- Entry envelope: `Elzoo.Encryption.seal(plaintext, ref, subject, subject_key)`, so the header
  names the subject and key version and the `aad` binds the ref. An envelope moved to another
  ref is `:invalid`; one moved to another subject's ref names the wrong key and is
  `:unavailable`.
- Wrapped key: `Elzoo.Encryption.seal(key, <<version::64, subject::binary>>,
  "elzoo-vault-kek", kek_credential)`. A wrapped key moved to another subject or version fails
  its `aad` and is `:unavailable`; it never opens another subject's plaintext.

## Limits

- Dead tuples, WAL and backups keep wrapped keys until the database reclaims them. A restored
  backup can open old envelopes only while its KEK version still exists (a wrapped key's key ID
  is `"elzoo-vault-kek"`, not the subject), so destroying an old KEK version after the backup
  retention period finishes the erasure. That is the host's duty.
- No subject-key rotation (one key version should seal fewer than 2^32 envelopes, as
  `integration/encryption` states), no KEK re-wrap, no artifact or object tombstones, no
  retention schedule and no tenant column or row-level security on the vault tables.
- The Piece emits no telemetry and no log; errors are fixed atoms that never echo a subject,
  plaintext, key or envelope. But `log: false` only silences the Logger: the consumer Repo's
  query telemetry event receives subjects, refs, envelopes and wrapped keys as parameters.
- The KEK Need runs synchronously inside `put`'s transaction while the subject row is locked;
  the host bounds it. No memory erasure of keys or plaintext.

Telemetry, Config and Control are `not_applicable`: no events, fixed bounds, the Repo, prefix
and KEK Need are vault operands, and there is no process.

## Evidence

[test/elzoo/retention_erasure_test.exs](test/elzoo/retention_erasure_test.exs) runs on the
worker's own disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) behind a fail-closed
target guard, in random schemas dropped afterwards, one `describe` per acceptance group:

1. Round trip of 0-, 1- and 65,536-byte plaintexts for 1- and 128-byte subjects and two
   subjects; many entries share key version 1; the raw `envelope` and `wrapped` columns hold no
   plaintext, subject key or KEK bytes.
2. Erasure: every ref of A `:not_found`, B still opens, `status` `:erased`, a later put
   `:erased` with no key and no Need call; a pre-erase envelope copy opened over the current
   key rows gives `:no_key`; the limit case: the copied wrapped key unwraps under KEK version 1
   until the test's KEK Need answers `{:error, :not_found}`, then `:no_key`; erase of an absent
   subject blocks a later put.
3. Swaps by direct SQL: envelope to another ref, to another subject, wrapped key to another
   subject and to another version: `:invalid` or `:unavailable`, never another plaintext.
4. Barrier-controlled races: two first puts of one new subject (one waiting on the other's
   subject row, and both past the lock with the `ON CONFLICT` re-read) store one key row; a put
   holding `FOR SHARE` makes the erase wait, so the put commits first and its entry is gone; an
   erase holding its row lock makes the put `:erased`; 30 free races leave no key or entry.
5. KEK Need: raise, throw, exit, `{:error, :not_found}`, `{:ok, "raw"}`, a 31-byte value and a
   wrong version each `:unavailable` with no row written; counted calls, none for `:malformed`
   or `:in_transaction`.
6. Shape and bounds: subjects of 0 and 129 bytes, invalid UTF-8, NUL, DEL, U+001F and U+0085;
   a 65,537-byte plaintext; malformed refs, all before any query (on a Repo that was never
   started); every call inside `repo.transact/2`; an unreachable Repo; bad prefixes and options.
7. Secrecy: no plaintext, subject, subject key or KEK byte in results, raised messages,
   `Inspect` or a debug-level logging Repo's captured log.

Negative controls (temporary edits, reverted): skipping the `erased` check in `put` fails
groups 2 and 4; erasing keys but not the subject state fails groups 2 and 4; a fixed entry
`aad` fails groups 1–3; reading the subject state without `FOR SHARE` fails group 4. Finite
scenarios, not proofs; row locks, `ON CONFLICT` and transactions are PostgreSQL's, AES-GCM is
OTP's via `integration/encryption`. No Cure law is selected.
