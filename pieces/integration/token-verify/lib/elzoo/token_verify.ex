# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TokenVerify do
  @moduledoc """
  Offline verification of a compact JWS bearer token (EdDSA or RS256 against pinned public keys)
  or a prefixed API key (keyed HMAC-SHA-256 digest) into an `Elzoo.Principal`, or one fixed
  failure atom. No network, clock read, key fetch, log or telemetry. See the bundle README.
  """

  alias Elzoo.{Principal, Secrets}

  @max_int 9_223_372_036_854_775_807
  @max_token 8192
  @algs ["EdDSA", "RS256"]
  @forbidden ["jwk", "jku", "x5u", "x5c", "x5t", "x5t#S256", "crit"]
  @members %{"EdDSA" => ["crv", "kty", "x"], "RS256" => ["e", "kty", "n"]}
  @min_modulus Integer.pow(2, 2047)
  @max_modulus Integer.pow(2, 8192)
  @jwt_options [:audience, :issuer, :keys, :leeway_s, :subject]
  @api_key_options [:digest_key, :lookup, :prefix]
  @jwt_error "invalid Elzoo.TokenVerify JWT configuration"
  @api_key_error "invalid Elzoo.TokenVerify API key configuration"

  defmodule JwtConfig do
    @moduledoc false
    defstruct [:issuer, :audience, :keys, :leeway_s, :subject]

    defimpl Inspect do
      def inspect(_, _), do: "#Elzoo.TokenVerify.JwtConfig<redacted>"
    end
  end

  defmodule ApiKeyConfig do
    @moduledoc false
    defstruct [:prefix, :digest_key, :lookup]

    defimpl Inspect do
      def inspect(_, _), do: "#Elzoo.TokenVerify.ApiKeyConfig<redacted>"
    end
  end

  @doc "Validates JWT options (exactly issuer, audience, keys, leeway_s, subject) into an opaque config."
  def jwt_config(opts) do
    with true <- options?(opts, @jwt_options),
         true <- text?(opts[:issuer], 1024) and text?(opts[:audience], 1024),
         {:ok, keys} <- keys(opts[:keys]),
         leeway = opts[:leeway_s],
         true <- is_integer(leeway) and leeway >= 0 and leeway <= 300,
         true <- is_function(opts[:subject], 1) do
      %JwtConfig{
        issuer: opts[:issuer],
        audience: opts[:audience],
        keys: keys,
        leeway_s: leeway,
        subject: opts[:subject]
      }
    else
      _ -> raise ArgumentError, @jwt_error
    end
  end

  @doc "Validates API key options (exactly prefix, digest_key, lookup) into an opaque config."
  def api_key_config(opts) do
    if options?(opts, @api_key_options) and byte_size_in?(opts[:prefix], 1, 16) and
         chars?(opts[:prefix], &lower_alnum?/1) and is_function(opts[:digest_key], 0) and
         is_function(opts[:lookup], 1) do
      %ApiKeyConfig{prefix: opts[:prefix], digest_key: opts[:digest_key], lookup: opts[:lookup]}
    else
      raise ArgumentError, @api_key_error
    end
  end

  @doc "Verifies a compact JWS bearer token at the caller-supplied Unix second."
  def verify_jwt(token, %JwtConfig{} = config, now_unix_s) do
    with :ok <- jwt_shape(token, now_unix_s),
         {:ok, alg, kid} <- header(token),
         {:ok, payload} <- signature(token, alg, kid, config.keys),
         {:ok, claims} <- claims(payload),
         :ok <- registered(claims, config, now_unix_s) do
      jwt_principal(config.subject, claims)
    end
  end

  def verify_jwt(_, _, _), do: raise(ArgumentError, @jwt_error)

  @doc "Verifies a `<prefix>_<key_id>_<secret>` API key at the caller-supplied Unix second."
  def verify_api_key(key, %ApiKeyConfig{} = config, now_unix_s) do
    with {:ok, key_id, secret} <- api_key(key, config.prefix, now_unix_s),
         {:ok, digest_key} <- digest_key(config.digest_key, now_unix_s),
         {:ok, record} <- lookup(config.lookup, key_id),
         true <-
           :crypto.hash_equals(:crypto.mac(:hmac, :sha256, digest_key, secret), record.digest) ||
             {:error, :invalid_signature} do
      cond do
        record.revoked ->
          {:error, :revoked}

        record.expires_at_unix_s != nil and record.expires_at_unix_s <= now_unix_s ->
          {:error, :expired}

        true ->
          principal(record.principal, record.current_epoch)
      end
    end
  end

  def verify_api_key(_, _, _), do: raise(ArgumentError, @api_key_error)

  # Configuration.

  defp options?(opts, names),
    do: Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == names

  defp keys([_ | _] = list) do
    with true <- bounded?(list, 16),
         keys = Enum.map(list, &key/1),
         false <- :error in keys,
         kids = Enum.map(keys, & &1.kid),
         true <- Enum.uniq(kids) == kids do
      {:ok, keys}
    end
  end

  defp keys(_), do: :error

  defp key(%{kid: kid, alg: alg, jwk: jwk} = key)
       when map_size(key) == 3 and alg in @algs and is_map(jwk) and not is_struct(jwk) do
    with true <- byte_size_in?(kid, 1, 128) and chars?(kid, &(&1 in 0x20..0x7E)),
         true <- Enum.sort(Map.keys(jwk)) == @members[alg],
         true <- Enum.all?(Map.values(jwk), &is_binary/1),
         %JOSE.JWK{kty: kty} = parsed <- from_map(jwk),
         true <- public?(alg, kty) do
      %{kid: kid, alg: alg, jwk: parsed}
    else
      _ -> :error
    end
  end

  defp key(_), do: :error

  defp from_map(jwk) do
    JOSE.JWK.from_map(jwk)
  catch
    _, _ -> :error
  end

  # The parsed key is a public key of the type its alg names: Ed25519, or RSA with a 2048..8192-bit modulus.
  defp public?("EdDSA", {:jose_jwk_kty_okp_ed25519, <<_::256>>}), do: true

  defp public?("RS256", {:jose_jwk_kty_rsa, {:RSAPublicKey, n, e}}),
    do: is_integer(n) and n >= @min_modulus and n < @max_modulus and is_integer(e) and e > 0

  defp public?(_, _), do: false

  # JWT steps 1 to 5.

  defp jwt_shape(token, now) do
    with true <- int?(now) and is_binary(token) and byte_size(token) <= @max_token,
         [_, _, _] = segments <- :binary.split(token, ".", [:global]),
         true <- Enum.all?(segments, &(&1 != "" and base64url?(&1))) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp header(token) do
    with {:ok, json} <- peek(token),
         {:ok, %Jason.OrderedObject{values: pairs} = object} <-
           Jason.decode(json, objects: :ordered_objects),
         true <- unique_keys?(object),
         header = Map.new(pairs),
         true <- header["alg"] in @algs,
         true <- is_binary(header["kid"]),
         false <- Enum.any?(@forbidden, &Map.has_key?(header, &1)) do
      {:ok, header["alg"], header["kid"]}
    else
      _ -> {:error, :malformed}
    end
  end

  defp peek(token) do
    {:ok, JOSE.JWS.peek_protected(token)}
  catch
    _, _ -> :error
  end

  # Only the key that the header's kid names, and only with that key's own algorithm.
  defp signature(token, alg, kid, keys) do
    case Enum.find(keys, &(&1.kid == kid)) do
      nil -> {:error, :unknown_kid}
      %{alg: ^alg} = key -> verified(key, token)
      _ -> {:error, :invalid_signature}
    end
  end

  defp verified(key, token) do
    case JOSE.JWS.verify_strict(key.jwk, [key.alg], token) do
      {true, payload, _} when is_binary(payload) -> {:ok, payload}
      _ -> {:error, :invalid_signature}
    end
  catch
    _, _ -> {:error, :invalid_signature}
  end

  defp claims(payload) do
    with {:ok, %Jason.OrderedObject{values: pairs} = object} <-
           Jason.decode(payload, objects: :ordered_objects),
         true <- unique_keys?(object),
         claims = Map.new(pairs),
         true <- text?(claims["iss"], 1024) and text?(claims["sub"], 1024),
         true <- audience?(claims["aud"]),
         true <- int?(claims["exp"]) and int?(claims["iat"]),
         true <- not Map.has_key?(claims, "nbf") or int?(claims["nbf"]) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp audience?(aud) when is_binary(aud), do: true
  defp audience?([_ | _] = list), do: bounded?(list, 16) and Enum.all?(list, &is_binary/1)
  defp audience?(_), do: false

  defp registered(claims, config, now) do
    latest = now + config.leeway_s

    cond do
      claims["iss"] != config.issuer -> {:error, :bad_issuer}
      config.audience not in List.wrap(claims["aud"]) -> {:error, :bad_audience}
      claims["exp"] + config.leeway_s <= now -> {:error, :expired}
      claims["iat"] > latest -> {:error, :not_yet_valid}
      Map.get(claims, "nbf", 0) > latest -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp jwt_principal(subject, claims) do
    with {:ok, %{principal: fields, current_epoch: epoch} = result} when map_size(result) == 2 <-
           call(fn -> subject.(%{issuer: claims["iss"], subject: claims["sub"]}) end),
         true <- is_map(fields) and not Map.has_key?(fields, :auth_epoch) do
      principal(Map.put(fields, :auth_epoch, claims["iat"]), epoch)
    else
      {:error, reason} when reason in [:revoked, :unknown_subject, :unavailable] -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  # API key steps.

  defp api_key(key, prefix, now) do
    with true <- int?(now) and is_binary(key),
         [^prefix, rest] <- :binary.split(key, "_"),
         [key_id, secret] <- :binary.split(rest, "_"),
         true <- byte_size_in?(key_id, 8, 32) and chars?(key_id, &alnum?/1),
         true <- byte_size(secret) == 43 and base64url?(secret),
         {:ok, <<_::256>> = bytes} <- Base.url_decode64(secret, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == secret do
      {:ok, key_id, bytes}
    else
      _ -> {:error, :malformed}
    end
  end

  defp digest_key(need, now) do
    after_ms = now * 1000

    with {:ok, %Secrets.Credential{expires_at_unix_ms: expires} = credential}
         when is_integer(expires) and expires > after_ms <- call(need),
         value = Secrets.reveal(credential),
         true <- byte_size_in?(value, 32, 64) do
      {:ok, value}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp lookup(need, key_id) do
    case call(fn -> need.(key_id) end) do
      {:ok,
       %{
         digest: <<_::256>>,
         principal: _,
         current_epoch: _,
         expires_at_unix_s: expires,
         revoked: revoked
       } = record}
      when map_size(record) == 5 and is_boolean(revoked) and
             (is_integer(expires) or is_nil(expires)) ->
        {:ok, record}

      {:error, :not_found} ->
        {:error, :invalid_signature}

      _ ->
        {:error, :unavailable}
    end
  end

  # Shared.

  defp principal(fields, current_epoch) do
    with {:ok, principal} <- Principal.new(fields) do
      case Principal.check(principal, %{current_epoch: current_epoch, revoked_ids: []}) do
        :ok -> {:ok, principal}
        {:error, :stale} -> {:error, :revoked}
        _ -> {:error, :unavailable}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  # A raising, throwing or exiting Need is a failed Need; nothing it raised is kept.
  defp call(fun) do
    fun.()
  catch
    _, _ -> :raised
  end

  defp unique_keys?(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    Enum.uniq(keys) == keys and Enum.all?(pairs, fn {_, value} -> unique_keys?(value) end)
  end

  defp unique_keys?(list) when is_list(list), do: Enum.all?(list, &unique_keys?/1)
  defp unique_keys?(_), do: true

  defp int?(n), do: is_integer(n) and n >= 0 and n <= @max_int

  defp text?(t, max), do: byte_size_in?(t, 1, max) and String.valid?(t)

  defp byte_size_in?(t, min, max), do: is_binary(t) and byte_size(t) >= min and byte_size(t) <= max

  # A proper list of at most n entries.
  defp bounded?([], _), do: true
  defp bounded?([_ | rest], n) when n > 0, do: bounded?(rest, n - 1)
  defp bounded?(_, _), do: false

  defp chars?(binary, allowed),
    do: for(<<c <- binary>>, reduce: true, do: (ok -> ok and allowed.(c)))

  # The unpadded base64url alphabet; Base.url_decode64/2 alone would also take "=" padding.
  defp base64url?(segment),
    do:
      chars?(segment, &(alnum?(&1) or &1 in [?-, ?_])) and
        Base.url_decode64(segment, padding: false) != :error

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
  defp lower_alnum?(c), do: c in ?a..?z or c in ?0..?9
end
