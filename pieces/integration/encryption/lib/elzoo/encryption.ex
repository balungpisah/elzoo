# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Encryption do
  @moduledoc """
  AES-256-GCM envelopes under a caller-held, versioned 32-byte key.

  Envelope layout, integers big-endian:

      "EZE1" | id_len::8 | key_id | version::64 | nonce (12) | ciphertext | tag (16)

  The AEAD associated data is the header (`"EZE1"` through `version`) followed
  by the caller's `aad`. Keys are `Elzoo.Secrets.Credential` values read only
  through `Elzoo.Secrets.reveal/1`; their `version` is the key version.
  Destroying a key makes every envelope under it unreadable. This module owns
  no key store, key destruction, clock, telemetry or log. See the README.
  """

  alias Elzoo.Secrets
  alias Elzoo.Secrets.Credential

  @magic "EZE1"
  @max_version 9_007_199_254_740_991
  @max_plaintext 1_048_576
  @max_aad 1_024
  @nonce_size 12
  @tag_size 16
  @key_size 32

  @doc "Seal `plaintext` with `aad` under `key_id` and the credential's key and version."
  def seal(plaintext, aad, key_id, credential) do
    with :ok <- seal_input(plaintext, aad, key_id),
         {:ok, key, version} <- seal_key(credential) do
      header = header(key_id, version)
      nonce = :crypto.strong_rand_bytes(@nonce_size)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          header <> aad,
          @tag_size,
          true
        )

      {:ok, header <> nonce <> ciphertext <> tag}
    end
  end

  @doc "Open `envelope` with `aad`, calling `keys.(key_id, version)` exactly once when well-formed."
  def open(envelope, aad, keys) do
    with {:ok,
          %{
            header: header,
            key_id: key_id,
            version: version,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
          }} <- parse(envelope),
         :ok <- aad(aad),
         {:ok, key} <- fetch(keys, key_id, version) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             header <> aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :invalid}
      end
    end
  end

  @doc "Return the key ID and version of a well-formed envelope, without a key."
  def key_ref(envelope) do
    case parse(envelope) do
      {:ok, %{key_id: key_id, version: version}} -> {:ok, %{key_id: key_id, version: version}}
      error -> error
    end
  end

  defp seal_input(plaintext, aad, key_id) do
    if is_binary(plaintext) and byte_size(plaintext) <= @max_plaintext and aad(aad) == :ok and
         key_id?(key_id),
       do: :ok,
       else: {:error, :malformed}
  end

  defp seal_key(%Credential{value: _, version: version} = credential)
       when is_integer(version) and version in 1..@max_version do
    case Secrets.reveal(credential) do
      key when is_binary(key) and byte_size(key) == @key_size -> {:ok, key, version}
      _ -> {:error, :key}
    end
  end

  defp seal_key(_), do: {:error, :key}

  defp aad(aad) when is_binary(aad) and byte_size(aad) <= @max_aad, do: :ok
  defp aad(_), do: {:error, :malformed}

  defp header(key_id, version),
    do: <<@magic::binary, byte_size(key_id)::8, key_id::binary, version::64>>

  defp parse(<<@magic, id_len::8, key_id::binary-size(id_len), version::64, rest::binary>>)
       when id_len in 1..128 and version in 1..@max_version and
              byte_size(rest) >= @nonce_size + @tag_size and
              byte_size(rest) <= @nonce_size + @max_plaintext + @tag_size do
    if key_id?(key_id) do
      ciphertext_size = byte_size(rest) - @nonce_size - @tag_size

      <<nonce::binary-size(@nonce_size), ciphertext::binary-size(^ciphertext_size),
        tag::binary-size(@tag_size)>> = rest

      {:ok,
       %{
         header: header(key_id, version),
         key_id: key_id,
         version: version,
         nonce: nonce,
         ciphertext: ciphertext,
         tag: tag
       }}
    else
      {:error, :malformed}
    end
  end

  defp parse(_), do: {:error, :malformed}

  defp fetch(keys, key_id, version) when is_function(keys, 2) do
    result =
      try do
        keys.(key_id, version)
      catch
        _, _ -> {:error, :unavailable}
      end

    case result do
      {:ok, %Credential{value: _, version: ^version} = credential} ->
        case Secrets.reveal(credential) do
          key when is_binary(key) and byte_size(key) == @key_size -> {:ok, key}
          _ -> {:error, :unavailable}
        end

      {:error, :not_found} ->
        {:error, :no_key}

      _ ->
        {:error, :unavailable}
    end
  end

  defp fetch(_, _, _), do: {:error, :unavailable}

  # 1..128 bytes of valid UTF-8 with no C0 (U+0000..U+001F) or C1 (U+007F..U+009F) character.
  defp key_id?(key_id) when is_binary(key_id) and byte_size(key_id) in 1..128,
    do: String.valid?(key_id) and no_control?(key_id)

  defp key_id?(_), do: false

  defp no_control?(<<>>), do: true

  defp no_control?(<<char::utf8, rest::binary>>)
       when char >= 0x20 and (char < 0x7F or char > 0x9F),
       do: no_control?(rest)

  defp no_control?(_), do: false
end
