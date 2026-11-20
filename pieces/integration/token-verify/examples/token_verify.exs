# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{Secrets, TokenVerify}

now = 1_800_000_000

# JWT: the host pins its issuer's public keys; the private key below stands in for the issuer.
issuer_key = JOSE.JWK.generate_key({:okp, :Ed25519})
{_, public_jwk} = JOSE.JWK.to_public_map(issuer_key)

fields = %{kind: :human, id: "alice", tenant: "acme", allowed_scopes: ["read"], allowed_spaces: []}

jwt_config =
  TokenVerify.jwt_config(
    issuer: "https://issuer.example",
    audience: "elzoo-api",
    keys: [%{kid: "2026-11", alg: "EdDSA", jwk: public_jwk}],
    leeway_s: 30,
    # Account linking: the host maps (issuer, subject) to its own principal and revocation mark.
    subject: fn %{issuer: "https://issuer.example", subject: "user-1"} ->
      {:ok, %{principal: fields, current_epoch: 0}}
    end
  )

sign = fn claims ->
  issuer_key
  |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "EdDSA", "kid" => "2026-11"})
  |> JOSE.JWS.compact()
  |> elem(1)
end

claims = %{
  "iss" => "https://issuer.example",
  "sub" => "user-1",
  "aud" => "elzoo-api",
  "exp" => now + 300,
  "iat" => now
}

valid_jwt = TokenVerify.verify_jwt(sign.(claims), jwt_config, now)
other_audience = TokenVerify.verify_jwt(sign.(%{claims | "aud" => "other-api"}), jwt_config, now)

# API key: the host stores only HMAC-SHA-256(digest key, secret) for each key ID.
digest_key = :crypto.strong_rand_bytes(32)
secret = :crypto.strong_rand_bytes(32)

api_config =
  TokenVerify.api_key_config(
    prefix: "ek",
    digest_key: fn ->
      {:ok,
       %Secrets.Credential{value: digest_key, version: 1, expires_at_unix_ms: (now + 3600) * 1000}}
    end,
    lookup: fn
      "svc0001key" ->
        {:ok,
         %{
           digest: :crypto.mac(:hmac, :sha256, digest_key, secret),
           principal: %{fields | kind: :service, id: "svc-1"} |> Map.put(:auth_epoch, 1),
           current_epoch: 1,
           expires_at_unix_s: nil,
           revoked: false
         }}

      _ ->
        {:error, :not_found}
    end
  )

key = "ek_svc0001key_" <> Base.url_encode64(secret, padding: false)
wrong = "ek_svc0001key_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

[
  valid_jwt,
  other_audience,
  TokenVerify.verify_api_key(key, api_config, now),
  TokenVerify.verify_api_key(wrong, api_config, now)
]
