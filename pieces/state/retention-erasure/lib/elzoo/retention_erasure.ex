# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetentionErasure do
  @moduledoc """
  A per-subject personal-data vault over a consumer-owned Ecto Repo (PostgreSQL 16).

  Each entry is sealed with `Elzoo.Encryption` under its subject's key (key ID = subject, `aad` =
  the entry's ref). The subject key is stored only sealed under the host's key-encryption key
  (KEK, key ID `"elzoo-vault-kek"`, `aad` = `<<version::64, subject::binary>>`). `erase/2`
  marks the subject erased and deletes its key and entry rows in one transaction, so a copy of
  an entry envelope taken earlier has no key in the vault.

  Errors are fixed atoms and never echo a subject, plaintext, key or envelope. The Piece emits
  no telemetry and no log; its own queries run with `log: false` (the Repo's query telemetry
  still receives their parameters, see the README).
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.Encryption
  alias Elzoo.RetentionErasure.Migration
  alias Elzoo.Secrets.Credential

  @enforce_keys [:repo, :prefix, :kek]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{repo: module(), prefix: String.t(), kek: (term() -> term())}

  @kek_id "elzoo-vault-kek"
  @max_plaintext 65_536

  @doc """
  Build a vault from exactly `repo:`, `prefix:` and `kek:` (an arity-1 Need called as
  `kek.(:current)` or `kek.(version)`). Raises `ArgumentError` with a fixed message otherwise.
  """
  def vault(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:kek, :prefix, :repo] and
         is_atom(opts[:repo]) and is_function(opts[:kek], 1) do
      %__MODULE__{repo: opts[:repo], prefix: Migration.prefix!(opts[:prefix]), kek: opts[:kek]}
    else
      raise ArgumentError, Migration.message()
    end
  end

  @doc """
  Seal `plaintext` (0..65,536 bytes) for `subject` and return `{:ok, ref}`, or
  `{:error, :malformed | :in_transaction | :unavailable | :erased}`.
  """
  def put(vault, subject, plaintext) do
    call(vault, subject?(subject) and plaintext?(plaintext), fn v ->
      ref = "v1_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      v.repo.transact(fn ->
        q!(
          v,
          "INSERT INTO #{v.prefix}.elzoo_vault_subjects (subject, state) VALUES ($1, 'active') ON CONFLICT (subject) DO NOTHING",
          [subject]
        )

        case q!(
               v,
               "SELECT state FROM #{v.prefix}.elzoo_vault_subjects WHERE subject = $1 FOR SHARE",
               [subject]
             ) do
          [["active"]] -> seal_entry(v, subject, ref, plaintext)
          [["erased"]] -> {:error, :erased}
        end
      end)
    end)
  end

  @doc """
  Open the entry `ref` and return `{:ok, plaintext}`, or
  `{:error, :malformed | :in_transaction | :not_found | :unavailable | :invalid}`.
  """
  def fetch(vault, ref) do
    call(vault, ref?(ref), fn v ->
      # One statement, one snapshot: the entry and its stored key version together.
      case q!(
             v,
             """
             SELECT e.subject, e.key_version, e.envelope, k.wrapped
             FROM #{v.prefix}.elzoo_vault_entries e
             LEFT JOIN #{v.prefix}.elzoo_vault_keys k
               ON k.subject = e.subject AND k.version = e.key_version
             WHERE e.ref = $1
             """,
             [ref]
           ) do
        [] ->
          {:error, :not_found}

        [[subject, version, envelope, wrapped]] ->
          keys = fn
            ^subject, ^version when is_binary(wrapped) ->
              unwrap(v, subject, version, wrapped)

            ^subject, ^version ->
              {:error, :not_found}

            _, _ ->
              {:error, :unavailable}
          end

          case Encryption.open(envelope, ref, keys) do
            {:ok, plaintext} -> {:ok, plaintext}
            {:error, :invalid} -> {:error, :invalid}
            {:error, _} -> {:error, :unavailable}
          end
      end
    end)
  end

  @doc """
  Mark `subject` erased and delete its key and entry rows in one transaction: `:ok` or
  `{:error, :malformed | :in_transaction | :unavailable}`.
  """
  def erase(vault, subject) do
    call(vault, subject?(subject), fn v ->
      result =
        v.repo.transact(fn ->
          # The upsert takes the subject row lock that put/3 holds FOR SHARE. The first
          # erasure time is kept.
          q!(
            v,
            """
            INSERT INTO #{v.prefix}.elzoo_vault_subjects AS s (subject, state, erased_at)
            VALUES ($1, 'erased', floor(extract(epoch FROM clock_timestamp()))::bigint)
            ON CONFLICT (subject) DO UPDATE
              SET state = 'erased', erased_at = COALESCE(s.erased_at, EXCLUDED.erased_at)
            """,
            [subject]
          )

          q!(v, "DELETE FROM #{v.prefix}.elzoo_vault_entries WHERE subject = $1", [subject])
          q!(v, "DELETE FROM #{v.prefix}.elzoo_vault_keys WHERE subject = $1", [subject])
          {:ok, :ok}
        end)

      with {:ok, :ok} <- result, do: :ok
    end)
  end

  @doc "`{:ok, :absent | :active | :erased}` or `{:error, :malformed | :in_transaction | :unavailable}`."
  def status(vault, subject) do
    call(vault, subject?(subject), fn v ->
      case q!(v, "SELECT state FROM #{v.prefix}.elzoo_vault_subjects WHERE subject = $1", [
             subject
           ]) do
        [] -> {:ok, :absent}
        [["active"]] -> {:ok, :active}
        [["erased"]] -> {:ok, :erased}
      end
    end)
  end

  # Shape first, then the caller's transaction, both before any query or Need call. Any failure
  # of the Repo, the database or the driver is :unavailable; nothing raised reaches the caller,
  # so no driver message (which can quote parameters) does either.
  defp call(%__MODULE__{} = v, true, fun) do
    if v.repo.in_transaction?(), do: {:error, :in_transaction}, else: fun.(v)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp call(_, _, _), do: {:error, :malformed}

  # Inside put/3's transaction under the subject row's FOR SHARE lock; an error rolls back.
  defp seal_entry(v, subject, ref, plaintext) do
    with {:ok, key} <- subject_key(v, subject),
         {:ok, envelope} <- Encryption.seal(plaintext, ref, subject, key) do
      q!(
        v,
        "INSERT INTO #{v.prefix}.elzoo_vault_entries (ref, subject, key_version, envelope) VALUES ($1, $2, $3, $4)",
        [ref, subject, key.version, envelope]
      )

      {:ok, ref}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp subject_key(v, subject) do
    case newest_key(v, subject) do
      [[version, wrapped]] -> unwrap(v, subject, version, wrapped)
      [] -> create_key(v, subject)
    end
  end

  defp newest_key(v, subject),
    do:
      q!(
        v,
        "SELECT version, wrapped FROM #{v.prefix}.elzoo_vault_keys WHERE subject = $1 ORDER BY version DESC LIMIT 1",
        [subject]
      )

  # Version 1 from 32 random bytes sealed under the current KEK. A concurrent first put that
  # stored version 1 first wins: this insert does nothing and the stored key is read back.
  defp create_key(v, subject) do
    key = :crypto.strong_rand_bytes(32)

    with {:ok, kek} <- current_kek(v),
         {:ok, wrapped} <- Encryption.seal(key, wrap_aad(subject, 1), @kek_id, kek) do
      case q!(
             v,
             "INSERT INTO #{v.prefix}.elzoo_vault_keys (subject, version, wrapped) VALUES ($1, 1, $2) ON CONFLICT (subject, version) DO NOTHING RETURNING version",
             [subject, wrapped]
           ) do
        [[1]] ->
          {:ok, credential(key, 1)}

        [] ->
          case newest_key(v, subject) do
            [[version, stored]] -> unwrap(v, subject, version, stored)
            [] -> {:error, :unavailable}
          end
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp current_kek(v) do
    result =
      try do
        v.kek.(:current)
      catch
        _, _ -> :error
      end

    case result do
      {:ok, %Credential{} = kek} -> {:ok, kek}
      _ -> {:error, :unavailable}
    end
  end

  # Encryption.open/3 catches the Need's raise, throw or exit and checks its credential's size
  # and version; the KEK Need is asked only for the version in the wrapped key's header.
  defp unwrap(v, subject, version, wrapped) do
    keks = fn
      @kek_id, kek_version -> v.kek.(kek_version)
      _, _ -> {:error, :unavailable}
    end

    case Encryption.open(wrapped, wrap_aad(subject, version), keks) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, credential(key, version)}
      _ -> {:error, :unavailable}
    end
  end

  defp wrap_aad(subject, version), do: <<version::64, subject::binary>>

  defp credential(key, version),
    do: %Credential{value: key, version: version, expires_at_unix_ms: 0}

  defp q!(v, sql, params), do: SQL.query!(v.repo, sql, params, log: false).rows

  defp plaintext?(plaintext), do: is_binary(plaintext) and byte_size(plaintext) <= @max_plaintext

  defp ref?(<<"v1_", rest::binary-size(22)>>), do: rest =~ ~r/\A[A-Za-z0-9_-]{22}\z/
  defp ref?(_), do: false

  # The domain/principal text rule, also the integration/encryption key-ID rule: 1..128 bytes of
  # valid UTF-8 with no C0 (U+0000..U+001F) or C1 (U+007F..U+009F) character.
  defp subject?(subject) when is_binary(subject) and byte_size(subject) in 1..128,
    do: String.valid?(subject) and no_control?(subject)

  defp subject?(_), do: false

  defp no_control?(<<>>), do: true

  defp no_control?(<<char::utf8, rest::binary>>)
       when char >= 0x20 and (char < 0x7F or char > 0x9F),
       do: no_control?(rest)

  defp no_control?(_), do: false

  defimpl Inspect do
    def inspect(_, _), do: "#Elzoo.RetentionErasure<redacted>"
  end
end
