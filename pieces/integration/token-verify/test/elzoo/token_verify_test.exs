# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TokenVerifyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Elzoo.{Principal, Secrets, TokenVerify}

  @max 9_223_372_036_854_775_807
  @now 1_800_000_000
  @iat @now - 60
  @issuer "https://issuer.example"
  @audience "elzoo-api"
  @jwt_error "invalid Elzoo.TokenVerify JWT configuration"
  @api_key_error "invalid Elzoo.TokenVerify API key configuration"
  @fields %{
    kind: :human,
    id: "alice",
    tenant: "acme",
    allowed_scopes: ["read"],
    allowed_spaces: ["wiki"]
  }

  # Keys are generated with jose once per module; signing below uses OTP directly, so the tests
  # control every header and payload byte.
  setup_all do
    %{
      ed_a: JOSE.JWK.generate_key({:okp, :Ed25519}),
      ed_b: JOSE.JWK.generate_key({:okp, :Ed25519}),
      rsa: JOSE.JWK.generate_key({:rsa, 2048}),
      attacker: JOSE.JWK.generate_key({:okp, :Ed25519})
    }
  end

  setup context do
    keys = [
      %{kid: "ed-a", alg: "EdDSA", jwk: public(context.ed_a)},
      %{kid: "ed-b", alg: "EdDSA", jwk: public(context.ed_b)},
      %{kid: "rs-1", alg: "RS256", jwk: public(context.rsa)}
    ]

    Map.put(context, :keys, keys)
  end

  # Helpers.

  defp public(jwk), do: jwk |> JOSE.JWK.to_public_map() |> elem(1)
  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "sub" => "user-1",
        "aud" => @audience,
        "exp" => @now + 600,
        "iat" => @iat
      },
      overrides
    )
  end

  # A compact JWS over raw header and payload bytes, signed with the given key's own algorithm.
  defp token(jwk, header, payload) do
    header = if is_binary(header), do: header, else: Jason.encode!(header)
    payload = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    input = b64(header) <> "." <> b64(payload)
    input <> "." <> b64(sign(jwk, input))
  end

  defp sign(%JOSE.JWK{kty: {:jose_jwk_kty_okp_ed25519, <<seed::binary-32, _::binary-32>>}}, input),
    do: :crypto.sign(:eddsa, :none, input, [seed, :ed25519])

  defp sign(%JOSE.JWK{kty: {:jose_jwk_kty_rsa, private}}, input),
    do: :public_key.sign(input, :sha256, private)

  defp sign({:hmac, key}, input), do: :crypto.mac(:hmac, :sha256, key, input)
  defp sign(:none, _input), do: ""

  defp ed(ctx, payload \\ claims(), kid \\ "ed-a"),
    do: token(ctx.ed_a, %{"alg" => "EdDSA", "kid" => kid}, payload)

  defp subject(reply \\ {:ok, %{principal: @fields, current_epoch: @iat}}) do
    owner = self()

    fn arg ->
      send(owner, {:subject, arg})
      if is_function(reply, 0), do: reply.(), else: reply
    end
  end

  defp jwt_config(ctx, overrides \\ []) do
    TokenVerify.jwt_config(
      Keyword.merge(
        [
          issuer: @issuer,
          audience: @audience,
          keys: ctx.keys,
          leeway_s: 0,
          subject: subject()
        ],
        overrides
      )
    )
  end

  # Runs one verification and asserts that the result and any captured log hold none of the secrets.
  defp run(fun, secrets) do
    {result, log} = with_log(fun)
    raw = :erlang.term_to_binary(result)

    for secret <- secrets do
      assert not String.contains?(inspect(result) <> log, secret)
      assert :binary.match(raw, secret) == :nomatch
    end

    assert log == ""
    result
  end

  defp jwt(token, config, now \\ @now),
    do: run(fn -> TokenVerify.verify_jwt(token, config, now) end, secrets(token))

  defp secrets(token) when is_binary(token) and byte_size(token) > 0 do
    [token | token |> :binary.split(".", [:global]) |> Enum.filter(&(byte_size(&1) > 20))]
  end

  defp secrets(_), do: []

  defp refute_subject_called, do: refute_received({:subject, _})

  defp assert_principal({:ok, %Principal{} = principal}, epoch) do
    assert principal.auth_epoch == epoch
    assert {principal.kind, principal.id, principal.tenant} == {:human, "alice", "acme"}
    assert Principal.check(principal, %{current_epoch: epoch, revoked_ids: []}) == :ok
  end

  # API key helpers.

  @digest_key :binary.copy(<<7>>, 32)
  @key_id "Key0001abc"
  @secret_bytes :binary.copy(<<0xA5>>, 32)
  @secret Base.url_encode64(@secret_bytes, padding: false)
  @api_key "ek_" <> @key_id <> "_" <> @secret

  defp credential(value \\ @digest_key, expires_ms \\ (@now + 3600) * 1000),
    do: %Secrets.Credential{value: value, version: 1, expires_at_unix_ms: expires_ms}

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        digest: :crypto.mac(:hmac, :sha256, @digest_key, @secret_bytes),
        principal: Map.put(%{@fields | kind: :service, id: "svc-1"}, :auth_epoch, 5),
        current_epoch: 5,
        expires_at_unix_s: nil,
        revoked: false
      },
      overrides
    )
  end

  defp api_config(opts \\ []) do
    owner = self()
    digest = Keyword.get(opts, :digest, {:ok, credential()})
    reply = Keyword.get(opts, :lookup, {:ok, record()})

    TokenVerify.api_key_config(
      prefix: Keyword.get(opts, :prefix, "ek"),
      digest_key: fn ->
        send(owner, :digest_key)
        if is_function(digest, 0), do: digest.(), else: digest
      end,
      lookup: fn key_id ->
        send(owner, {:lookup, key_id})
        if is_function(reply, 0), do: reply.(), else: reply
      end
    )
  end

  defp api(key, config, now \\ @now) do
    secrets =
      [@digest_key, @secret, @secret_bytes] ++ if(is_binary(key) and key != "", do: [key], else: [])

    run(fn -> TokenVerify.verify_api_key(key, config, now) end, secrets)
  end

  # 1. Valid tokens and key.

  describe "valid credentials" do
    test "EdDSA and RS256 tokens give the principal with auth_epoch equal to iat", ctx do
      config = jwt_config(ctx)
      assert_principal(jwt(ed(ctx), config), @iat)
      assert_received {:subject, arg}
      assert arg == %{issuer: @issuer, subject: "user-1"}

      rs = token(ctx.rsa, %{"alg" => "RS256", "kid" => "rs-1"}, claims(%{"iat" => @iat - 5}))

      assert_principal(
        jwt(rs, jwt_config(ctx, subject: subject({:ok, %{principal: @fields, current_epoch: 0}}))),
        @iat - 5
      )

      second =
        token(ctx.ed_b, %{"alg" => "EdDSA", "kid" => "ed-b"}, claims(%{"aud" => ["x", @audience]}))

      assert_principal(jwt(second, config), @iat)
    end

    test "a valid API key gives the looked-up principal" do
      assert {:ok, %Principal{kind: :service, id: "svc-1", auth_epoch: 5}} =
               api(@api_key, api_config())

      assert_received {:lookup, @key_id}
    end

    test "a 64-byte digest key, a future expiry and a 32-byte key ID pass" do
      long_key = :binary.copy(<<9>>, 64)
      key_id = String.duplicate("Z", 32)

      config =
        api_config(
          digest: {:ok, credential(long_key)},
          lookup:
            {:ok,
             record(%{
               digest: :crypto.mac(:hmac, :sha256, long_key, @secret_bytes),
               expires_at_unix_s: @now + 1
             })}
        )

      assert {:ok, _} = api("ek_#{key_id}_#{@secret}", config)
    end
  end

  # 2. Algorithm and key selection.

  describe "algorithm and key confusion" do
    test "alg none and HS256 keyed with the RSA public PEM stop at the header", ctx do
      config = jwt_config(ctx)
      none = token(:none, %{"alg" => "none", "kid" => "rs-1"}, claims())
      assert jwt(none, config) == {:error, :malformed}
      assert jwt(none <> "AAAA", config) == {:error, :malformed}

      {_, pem} = ctx.rsa |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      hs = token({:hmac, pem}, %{"alg" => "HS256", "kid" => "rs-1"}, claims())
      assert jwt(hs, config) == {:error, :malformed}
      refute_subject_called()
    end

    test "drift: jose 1.11.13 verify_strict refuses alg none and the HS256 confusion token", ctx do
      assert Application.spec(:jose, :vsn) == ~c"1.11.13"
      rsa = JOSE.JWK.from_map(public(ctx.rsa))
      none = token(:none, %{"alg" => "none", "kid" => "rs-1"}, claims())
      {_, pem} = ctx.rsa |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      hs = token({:hmac, pem}, %{"alg" => "HS256", "kid" => "rs-1"}, claims())

      assert {false, _, _} = JOSE.JWS.verify_strict(rsa, ["RS256"], none)
      assert {false, _, _} = JOSE.JWS.verify_strict(rsa, ["RS256"], hs)
      # Even when the confused algorithm is allowed, the public key does not verify the HMAC.
      assert {false, _, _} = JOSE.JWS.verify_strict(rsa, ["HS256"], hs)

      # And it accepts each algorithm with its own key, returning the raw payload.
      payload = Jason.encode!(claims())
      ed = token(ctx.ed_a, %{"alg" => "EdDSA", "kid" => "ed-a"}, payload)
      rs = token(ctx.rsa, %{"alg" => "RS256", "kid" => "rs-1"}, payload)

      assert {true, ^payload, _} =
               JOSE.JWS.verify_strict(JOSE.JWK.from_map(public(ctx.ed_a)), ["EdDSA"], ed)

      assert {true, ^payload, _} = JOSE.JWS.verify_strict(rsa, ["RS256"], rs)

      assert {false, _, _} =
               JOSE.JWS.verify_strict(JOSE.JWK.from_map(public(ctx.ed_b)), ["EdDSA"], ed)

      # jose honours "b64": false without crit (RFC 7797 requires crit), so the Adapter refuses b64.
      # At 1.11.13 it signs over the header segment and the decoded payload bytes; with valid claims,
      # only the b64 refusal stops such a token.
      header = b64(~s({"alg":"EdDSA","kid":"ed-a","b64":false}))
      raw = Jason.encode!(claims())
      segment = b64(raw)
      unencoded = header <> "." <> segment <> "." <> b64(sign(ctx.ed_a, header <> "." <> raw))
      ed_a = JOSE.JWK.from_map(public(ctx.ed_a))
      assert {true, ^raw, _} = JOSE.JWS.verify_strict(ed_a, ["EdDSA"], unencoded)
      assert TokenVerify.verify_jwt(unencoded, jwt_config(ctx), @now) == {:error, :malformed}
    end

    test "a token whose alg differs from the named key's alg is invalid_signature", ctx do
      config = jwt_config(ctx)
      rs_names_ed = token(ctx.rsa, %{"alg" => "RS256", "kid" => "ed-a"}, claims())
      ed_names_rs = token(ctx.ed_a, %{"alg" => "EdDSA", "kid" => "rs-1"}, claims())
      assert jwt(rs_names_ed, config) == {:error, :invalid_signature}
      assert jwt(ed_names_rs, config) == {:error, :invalid_signature}
      refute_subject_called()
    end

    test "each forbidden header member is malformed, even with a valid signature", ctx do
      config = jwt_config(ctx)

      for {member, value} <- [
            {"jwk", public(ctx.ed_a)},
            {"jku", "https://keys.example/jwks"},
            {"x5u", "https://keys.example/cert"},
            {"x5c", ["MIIB"]},
            {"x5t", "abc"},
            {"x5t#S256", "abc"},
            {"crit", ["exp"]},
            {"b64", false},
            {"b64", true}
          ] do
        header = %{"alg" => "EdDSA", "kid" => "ed-a", member => value}
        assert jwt(token(ctx.ed_a, header, claims()), config) == {:error, :malformed}, member
      end

      refute_subject_called()
    end

    test "an attacker key carried in a jwk header is never used", ctx do
      header = %{"alg" => "EdDSA", "kid" => "ed-a", "jwk" => public(ctx.attacker)}
      forged = token(ctx.attacker, header, claims())
      assert jwt(forged, jwt_config(ctx)) == {:error, :malformed}
      # The attacker token without the jwk member names ed-a and fails its signature.
      forged = token(ctx.attacker, %{"alg" => "EdDSA", "kid" => "ed-a"}, claims())
      assert jwt(forged, jwt_config(ctx)) == {:error, :invalid_signature}
    end

    test "missing, non-string and unknown kid; a key removed from the set", ctx do
      config = jwt_config(ctx)
      assert jwt(token(ctx.ed_a, %{"alg" => "EdDSA"}, claims()), config) == {:error, :malformed}

      assert jwt(token(ctx.ed_a, %{"alg" => "EdDSA", "kid" => 1}, claims()), config) ==
               {:error, :malformed}

      assert jwt(ed(ctx, claims(), "ed-z"), config) == {:error, :unknown_kid}

      removed = jwt_config(ctx, keys: tl(ctx.keys))
      assert jwt(ed(ctx), removed) == {:error, :unknown_kid}
      refute_subject_called()
    end

    test "a token signed by configured key B that names key A's kid is invalid_signature", ctx do
      b_names_a = token(ctx.ed_b, %{"alg" => "EdDSA", "kid" => "ed-a"}, claims())
      assert jwt(b_names_a, jwt_config(ctx)) == {:error, :invalid_signature}
      refute_subject_called()
    end

    test "header shapes: not an object, duplicate keys, bad JSON", ctx do
      config = jwt_config(ctx)

      for header <- [
            ~s(["EdDSA"]),
            ~s({"alg":"EdDSA","kid":"ed-a","alg":"EdDSA"}),
            ~s({"alg":"EdDSA","kid":"ed-a"),
            ~s({"alg":"ES256","kid":"ed-a"}),
            ~s({"alg":"eddsa","kid":"ed-a"})
          ] do
        assert jwt(token(ctx.ed_a, header, claims()), config) == {:error, :malformed}, header
      end
    end
  end

  # 3. Token shape and claim types.

  describe "token shape and claims" do
    test "tampered payload and signature are invalid_signature", ctx do
      config = jwt_config(ctx)
      [h, p, s] = String.split(ed(ctx), ".")
      other = b64(Jason.encode!(claims(%{"sub" => "user-2"})))
      assert jwt(Enum.join([h, other, s], "."), config) == {:error, :invalid_signature}

      <<first, rest::binary>> = s
      flipped = if first == ?A, do: ?B, else: ?A

      assert jwt(Enum.join([h, p, <<flipped, rest::binary>>], "."), config) ==
               {:error, :invalid_signature}

      refute_subject_called()
    end

    test "truncated tokens and non-binary input are malformed", ctx do
      config = jwt_config(ctx)
      token = ed(ctx)
      [h, p, s] = String.split(token, ".")

      for bad <- [
            h <> "." <> p,
            h <> "." <> p <> ".",
            binary_part(token, 0, byte_size(token) - byte_size(s) - 2),
            h <> "." <> p <> "." <> binary_part(s, 0, 1),
            token <> ".x",
            "",
            "..",
            h <> ".." <> s,
            h <> "." <> p <> "." <> s <> "=",
            h <> "." <> p <> "+." <> s,
            nil,
            ~c"abc"
          ] do
        assert jwt(bad, config) == {:error, :malformed}, inspect(bad)
      end

      refute_subject_called()
    end

    test "now_unix_s outside 0..2^63-1 or not an integer is malformed", ctx do
      config = jwt_config(ctx)

      for now <- [-1, @max + 1, 1.0e9, "1800000000", nil] do
        assert jwt(ed(ctx), config, now) == {:error, :malformed}
      end

      refute_subject_called()
    end

    test "8,192 bytes pass and 8,193 bytes are malformed", ctx do
      config = jwt_config(ctx)
      at_limit = sized(ctx, 8192)
      assert byte_size(at_limit) == 8192
      assert {:ok, _} = jwt(at_limit, config)
      over = sized(ctx, 8193)
      assert byte_size(over) == 8193
      assert jwt(over, config) == {:error, :malformed}
    end

    test "validly signed non-JSON, non-object and duplicate-key claims are malformed; badly signed are invalid_signature",
         ctx do
      config = jwt_config(ctx)
      base = Jason.encode!(claims()) |> binary_part(1, byte_size(Jason.encode!(claims())) - 2)

      for payload <- [
            "not json",
            "{",
            "[1,2]",
            ~s("text"),
            "42",
            "null",
            "{" <> base <> ~s(,"sub":"user-2"}),
            "{" <> base <> ~s(,"extra":{"a":1,"a":2}}),
            "{" <> base <> ~s(,"extra":[{"b":1,"b":1}]})
          ] do
        assert jwt(ed(ctx, payload), config) == {:error, :malformed}, payload
        bad = token(ctx.ed_b, %{"alg" => "EdDSA", "kid" => "ed-a"}, payload)
        assert jwt(bad, config) == {:error, :invalid_signature}, payload
      end

      refute_subject_called()
    end

    test "time claims that are float, negative, string, out of range or missing are malformed",
         ctx do
      config = jwt_config(ctx)

      for claim <- ["exp", "iat", "nbf"],
          value <- [1.8e9, 1_800_000_000.0, -1, "1800000000", @max + 1, nil, true] do
        assert jwt(ed(ctx, claims(%{claim => value})), config) == {:error, :malformed},
               "#{claim} #{inspect(value)}"
      end

      for claim <- ["exp", "iat"] do
        assert jwt(ed(ctx, Map.delete(claims(), claim)), config) == {:error, :malformed}
      end

      refute_subject_called()
    end

    test "iss, sub and aud shapes are bounded", ctx do
      config = jwt_config(ctx)
      long = String.duplicate("a", 1025)

      for overrides <- [
            %{"iss" => ""},
            %{"iss" => 1},
            %{"sub" => ""},
            %{"sub" => long},
            %{"sub" => ["user-1"]},
            %{"aud" => []},
            %{"aud" => List.duplicate(@audience, 17)},
            %{"aud" => [@audience, 1]},
            %{"aud" => 1},
            %{"aud" => nil}
          ] do
        assert jwt(ed(ctx, claims(overrides)), config) == {:error, :malformed}, inspect(overrides)
      end

      for claim <- ["iss", "sub", "aud"] do
        assert jwt(ed(ctx, Map.delete(claims(), claim)), config) == {:error, :malformed}
      end

      assert {:ok, _} = jwt(ed(ctx, claims(%{"sub" => String.duplicate("a", 1024)})), config)
      assert {:ok, _} = jwt(ed(ctx, claims(%{"aud" => List.duplicate(@audience, 16)})), config)
    end
  end

  # A validly signed EdDSA token of exactly `size` bytes, padded with a filler claim.
  defp sized(ctx, size) do
    Enum.find_value(0..8192, fn n ->
      token = ed(ctx, claims(%{"pad" => String.duplicate("x", n)}))
      if byte_size(token) == size, do: token
    end) ||
      Enum.find_value(0..8192, fn n ->
        header = ~s({"alg":"EdDSA","kid":"ed-a" })
        token = token(ctx.ed_a, header, claims(%{"pad" => String.duplicate("x", n)}))
        if byte_size(token) == size, do: token
      end)
  end

  # 4. Time edges.

  describe "time edges" do
    for leeway <- [0, 300] do
      test "exp, iat and nbf at and beyond the edge with leeway #{leeway}", ctx do
        leeway = unquote(leeway)
        config = jwt_config(ctx, leeway_s: leeway)

        assert jwt(ed(ctx, claims(%{"exp" => @now - leeway})), config) == {:error, :expired}
        assert {:ok, _} = jwt(ed(ctx, claims(%{"exp" => @now - leeway + 1})), config)

        epoch = @now + leeway

        config =
          jwt_config(ctx,
            leeway_s: leeway,
            subject: subject({:ok, %{principal: @fields, current_epoch: 0}})
          )

        assert {:ok, %{auth_epoch: ^epoch}} = jwt(ed(ctx, claims(%{"iat" => epoch})), config)
        assert jwt(ed(ctx, claims(%{"iat" => epoch + 1})), config) == {:error, :not_yet_valid}
        assert {:ok, _} = jwt(ed(ctx, claims(%{"nbf" => epoch})), config)
        assert jwt(ed(ctx, claims(%{"nbf" => epoch + 1})), config) == {:error, :not_yet_valid}
        # Expiry is decided before not-yet-valid.
        early_and_late = claims(%{"exp" => 0, "iat" => epoch + 1, "nbf" => epoch + 1})
        assert jwt(ed(ctx, early_and_late), config) == {:error, :expired}
      end
    end

    test "now_unix_s 0 and 2^63-1 are accepted operands", ctx do
      config = jwt_config(ctx, subject: subject({:ok, %{principal: @fields, current_epoch: 0}}))
      assert {:ok, _} = jwt(ed(ctx, claims(%{"exp" => 1, "iat" => 0})), config, 0)
      assert jwt(ed(ctx), config, @max) == {:error, :expired}
      assert {:ok, _} = jwt(ed(ctx, claims(%{"exp" => @max})), config, @max - 1)
    end
  end

  # 5. Issuer and audience.

  describe "issuer and audience" do
    test "issuer differing by a trailing slash or case is bad_issuer", ctx do
      config = jwt_config(ctx)

      for iss <- [
            @issuer <> "/",
            "https://Issuer.example",
            "HTTPS://ISSUER.EXAMPLE",
            "https://issuer.example "
          ] do
        assert jwt(ed(ctx, claims(%{"iss" => iss})), config) == {:error, :bad_issuer}, iss
      end

      refute_subject_called()
    end

    test "audience string mismatch and lists without and with the configured value", ctx do
      config = jwt_config(ctx)
      assert jwt(ed(ctx, claims(%{"aud" => "elzoo-API"})), config) == {:error, :bad_audience}

      assert jwt(ed(ctx, claims(%{"aud" => ["other", "elzoo-api/"]})), config) ==
               {:error, :bad_audience}

      refute_subject_called()
      assert {:ok, _} = jwt(ed(ctx, claims(%{"aud" => ["other", @audience]})), config)
      assert {:ok, _} = jwt(ed(ctx, claims(%{"aud" => [@audience]})), config)
    end

    test "issuer is checked before audience and audience before time", ctx do
      config = jwt_config(ctx)
      bad = claims(%{"iss" => "x", "aud" => "y", "exp" => 1})
      assert jwt(ed(ctx, bad), config) == {:error, :bad_issuer}
      # Claim types are decided before the issuer.
      assert jwt(ed(ctx, %{bad | "exp" => 1.0}), config) == {:error, :malformed}
      assert jwt(ed(ctx, Map.put(bad, "iss", @issuer)), config) == {:error, :bad_audience}
    end
  end

  # 6. Revocation.

  describe "revocation" do
    test "subject revoked and unknown_subject pass through", ctx do
      assert jwt(ed(ctx), jwt_config(ctx, subject: subject({:error, :revoked}))) ==
               {:error, :revoked}

      assert jwt(ed(ctx), jwt_config(ctx, subject: subject({:error, :unknown_subject}))) ==
               {:error, :unknown_subject}
    end

    test "current_epoch above iat is revoked, equal passes", ctx do
      above =
        jwt_config(ctx, subject: subject({:ok, %{principal: @fields, current_epoch: @iat + 1}}))

      assert jwt(ed(ctx), above) == {:error, :revoked}
      equal = jwt_config(ctx, subject: subject({:ok, %{principal: @fields, current_epoch: @iat}}))
      assert {:ok, _} = jwt(ed(ctx), equal)
    end

    test "API key revoked, raised epoch, and past or equal expiry" do
      assert api(@api_key, api_config(lookup: {:ok, record(%{revoked: true})})) ==
               {:error, :revoked}

      assert api(@api_key, api_config(lookup: {:ok, record(%{current_epoch: 6})})) ==
               {:error, :revoked}

      assert {:ok, _} = api(@api_key, api_config(lookup: {:ok, record(%{current_epoch: 4})}))

      assert api(@api_key, api_config(lookup: {:ok, record(%{expires_at_unix_s: @now - 1})})) ==
               {:error, :expired}

      assert api(@api_key, api_config(lookup: {:ok, record(%{expires_at_unix_s: @now})})) ==
               {:error, :expired}

      # Revocation is decided before expiry.
      both = record(%{revoked: true, expires_at_unix_s: 0})
      assert api(@api_key, api_config(lookup: {:ok, both})) == {:error, :revoked}
    end

    test "refusals before the digest match do not reveal revocation or expiry" do
      wrong = "ek_" <> @key_id <> "_" <> Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

      for overrides <- [%{revoked: true}, %{expires_at_unix_s: 0}, %{current_epoch: @max}, %{}] do
        assert api(wrong, api_config(lookup: {:ok, record(overrides)})) ==
                 {:error, :invalid_signature}
      end

      wrong_digest = record(%{revoked: true, digest: :binary.copy(<<0>>, 32)})
      assert api(@api_key, api_config(lookup: {:ok, wrong_digest})) == {:error, :invalid_signature}
    end
  end

  # 7. Needs.

  describe "Needs" do
    test "subject raising, throwing, exiting or returning a malformed result is unavailable", ctx do
      token = ed(ctx)

      replies = [
        fn -> raise "boom #{token}" end,
        fn -> throw(token) end,
        fn -> exit(token) end,
        {:error, :unavailable},
        {:error, :other},
        {:error, token},
        :ok,
        {:ok, @fields},
        {:ok, %{principal: @fields}},
        {:ok, %{principal: @fields, current_epoch: 1, extra: 1}},
        {:ok, %{principal: Map.put(@fields, :auth_epoch, 1), current_epoch: 1}},
        {:ok, %{principal: %{@fields | id: ""}, current_epoch: 1}},
        {:ok, %{principal: %{@fields | kind: :agent}, current_epoch: 1}},
        {:ok, %{principal: Map.delete(@fields, :tenant), current_epoch: 1}},
        {:ok, %{principal: [], current_epoch: 1}},
        {:ok, %{principal: @fields, current_epoch: -1}},
        {:ok, %{principal: @fields, current_epoch: @max + 1}},
        {:ok, %{principal: @fields, current_epoch: "1"}}
      ]

      for reply <- replies do
        assert jwt(token, jwt_config(ctx, subject: subject(reply))) == {:error, :unavailable},
               inspect(reply)

        assert_received {:subject, _}
        refute_subject_called()
      end
    end

    test "subject is called exactly once on success and never when an earlier step fails", ctx do
      config = jwt_config(ctx)
      assert {:ok, _} = jwt(ed(ctx), config)
      assert_received {:subject, %{issuer: @issuer, subject: "user-1"}}
      refute_subject_called()

      for token <- [
            "x.y",
            ed(ctx, claims(), "nope"),
            token(ctx.ed_b, %{"alg" => "EdDSA", "kid" => "ed-a"}, claims()),
            ed(ctx, "[]"),
            ed(ctx, claims(%{"iss" => "x"})),
            ed(ctx, claims(%{"aud" => "x"})),
            ed(ctx, claims(%{"exp" => 0})),
            ed(ctx, claims(%{"nbf" => @now + 1}))
          ] do
        assert {:error, _} = jwt(token, config)
        refute_subject_called()
      end
    end

    test "digest_key failures are unavailable and lookup is never called" do
      digests = [
        fn -> raise "boom #{@digest_key}" end,
        fn -> throw(@digest_key) end,
        fn -> exit(:boom) end,
        {:error, :missing},
        {:error, :expired},
        :error,
        {:ok, @digest_key},
        {:ok, %{value: @digest_key}},
        {:ok, credential(:binary.copy(<<1>>, 31))},
        {:ok, credential(:binary.copy(<<1>>, 65))},
        {:ok, credential(:not_binary)},
        {:ok, credential(@digest_key, @now * 1000)},
        {:ok, credential(@digest_key, @now * 1000 - 1)},
        {:ok, credential(@digest_key, nil)}
      ]

      for digest <- digests do
        assert api(@api_key, api_config(digest: digest)) == {:error, :unavailable}, inspect(digest)
        assert_received :digest_key
        refute_received {:lookup, _}
      end

      assert {:ok, _} =
               api(@api_key, api_config(digest: {:ok, credential(@digest_key, @now * 1000 + 1)}))
    end

    test "lookup failures are unavailable; not_found is invalid_signature" do
      lookups = [
        fn -> raise "boom #{@key_id}" end,
        fn -> throw(:x) end,
        fn -> exit(:x) end,
        {:error, :unavailable},
        {:error, :other},
        :error,
        {:ok, Map.delete(record(), :revoked)},
        {:ok, Map.put(record(), :extra, 1)},
        {:ok, record(%{digest: :binary.copy(<<0>>, 31)})},
        {:ok, record(%{revoked: nil})},
        {:ok, record(%{expires_at_unix_s: "never"})},
        {:ok, record(%{principal: %{}})},
        {:ok, record(%{principal: Map.delete(record().principal, :auth_epoch)})},
        {:ok, record(%{current_epoch: -1})}
      ]

      for lookup <- lookups do
        assert api(@api_key, api_config(lookup: lookup)) == {:error, :unavailable}, inspect(lookup)
        assert_received {:lookup, @key_id}
      end

      assert api(@api_key, api_config(lookup: {:error, :not_found})) == {:error, :invalid_signature}
    end
  end

  # 8. API key shapes.

  describe "API key shapes" do
    test "wrong prefix, separators, bad base64url, non-canonical secret and part lengths are malformed" do
      config = api_config()

      # The last character carries 4 data bits and 2 zero bits; the next character sets a zero bit and
      # still decodes to the same bytes, so only the canonical-encoding check refuses it.
      <<head::binary-42, last>> = @secret
      noncanonical = head <> <<last + 1>>

      keys = [
        "ex_" <> @key_id <> "_" <> @secret,
        "EK_" <> @key_id <> "_" <> @secret,
        "ek" <> @key_id <> "_" <> @secret,
        "ek-" <> @key_id <> "-" <> @secret,
        "ek_" <> @key_id <> @secret,
        "ek__" <> @key_id <> "_" <> @secret,
        "ek_" <> @key_id <> "__" <> @secret,
        "_ek_" <> @key_id <> "_" <> @secret,
        "ek_" <> @key_id <> "_" <> @secret <> "_",
        "ek_" <> @key_id <> "_" <> head <> "=",
        "ek_" <> @key_id <> "_" <> head <> "+",
        "ek_" <> @key_id <> "_" <> head <> "/",
        "ek_" <> @key_id <> "_" <> head <> " ",
        "ek_" <> @key_id <> "_" <> noncanonical,
        "ek_" <> @key_id <> "_" <> head,
        "ek_" <> @key_id <> "_" <> @secret <> "A",
        "ek_" <> String.duplicate("a", 7) <> "_" <> @secret,
        "ek_" <> String.duplicate("a", 33) <> "_" <> @secret,
        "ek_" <> "Key0001-bc" <> "_" <> @secret,
        "ek_" <> "Key0001ébc" <> "_" <> @secret,
        "",
        nil,
        String.to_charlist(@api_key)
      ]

      assert Base.url_decode64(noncanonical, padding: false) == {:ok, @secret_bytes}

      for key <- keys do
        assert api(key, config) == {:error, :malformed}, inspect(key)
        refute_received :digest_key
      end

      for now <- [-1, @max + 1, 1.0, nil] do
        assert api(@api_key, config, now) == {:error, :malformed}
      end

      refute_received :digest_key
    end

    test "an expired digest-key credential is unavailable" do
      expired = api_config(digest: {:ok, credential(@digest_key, (@now - 1) * 1000)})
      assert api(@api_key, expired) == {:error, :unavailable}
      refute_received {:lookup, _}
    end

    test "an unknown key ID and a wrong secret give the same result" do
      unknown = api("ek_Unknown0001_" <> @secret, api_config(lookup: {:error, :not_found}))

      wrong =
        api(
          "ek_" <> @key_id <> "_" <> Base.url_encode64(:binary.copy(<<1>>, 32), padding: false),
          api_config()
        )

      assert unknown == wrong
      assert wrong == {:error, :invalid_signature}
    end
  end

  # 9. Secrecy: every refusal above runs through run/2, which asserts that no token, key, secret or
  # digest-key byte is in the result or captured log. These cases cover raised messages and Inspect.

  describe "secrecy" do
    test "configs, the digest key and raised configuration errors hold no secret", ctx do
      config = jwt_config(ctx)
      assert inspect(config) == "#Elzoo.TokenVerify.JwtConfig<redacted>"
      assert inspect(api_config()) == "#Elzoo.TokenVerify.ApiKeyConfig<redacted>"
      assert inspect(credential()) == "#Elzoo.Secrets.Credential<redacted>"

      secret_issuer = "issuer-" <> @secret

      error =
        assert_raise ArgumentError, fn -> jwt_config(ctx, issuer: secret_issuer, leeway_s: -1) end

      assert Exception.message(error) == @jwt_error

      error =
        assert_raise ArgumentError, fn ->
          TokenVerify.api_key_config(
            prefix: @secret,
            digest_key: fn -> @digest_key end,
            lookup: & &1
          )
        end

      assert Exception.message(error) == @api_key_error
    end

    test "a Need that raises with the token or secret leaks nothing", ctx do
      token = ed(ctx)

      for reply <- [fn -> raise ArgumentError, token end, fn -> exit({:shutdown, token}) end] do
        assert jwt(token, jwt_config(ctx, subject: subject(reply))) == {:error, :unavailable}
      end

      assert api(@api_key, api_config(digest: fn -> raise RuntimeError, @api_key end)) ==
               {:error, :unavailable}

      assert api(@api_key, api_config(lookup: fn -> raise RuntimeError, @digest_key end)) ==
               {:error, :unavailable}
    end

    test "a non-config argument raises the fixed message", ctx do
      token = ed(ctx)
      error = assert_raise ArgumentError, fn -> TokenVerify.verify_jwt(token, %{}, @now) end
      assert Exception.message(error) == @jwt_error
      error = assert_raise ArgumentError, fn -> TokenVerify.verify_api_key(@api_key, %{}, @now) end
      assert Exception.message(error) == @api_key_error
    end
  end

  # 10. Configuration.

  describe "configuration" do
    test "malformed JWT options raise the fixed ArgumentError", ctx do
      {_, ed_private} = JOSE.JWK.to_map(ctx.ed_a)
      {_, rsa_private} = JOSE.JWK.to_map(ctx.rsa)
      rsa_2047 = public(JOSE.JWK.generate_key({:rsa, 2047}))
      x25519 = public(JOSE.JWK.generate_key({:okp, :X25519}))

      rsa_8193 = %{
        "kty" => "RSA",
        "e" => "AQAB",
        "n" => b64(:binary.encode_unsigned(Integer.pow(2, 8192) + 1))
      }

      [a, b, c] = ctx.keys
      seventeen = for i <- 1..17, do: %{a | kid: "k#{i}"}

      bad = [
        keys: [%{a | jwk: ed_private}],
        keys: [%{c | jwk: rsa_private}],
        keys: [%{c | jwk: rsa_2047}],
        keys: [%{c | jwk: rsa_8193}],
        keys: [%{a | jwk: x25519}],
        keys: [%{a | jwk: c.jwk}],
        keys: [%{c | jwk: a.jwk}],
        keys: [%{a | alg: "ES256"}],
        keys: [%{a | alg: "HS256", jwk: %{"kty" => "oct", "k" => "AAAA"}}],
        keys: [Map.put(a.jwk, "use", "sig") |> then(&%{a | jwk: &1})],
        keys: [a, %{b | kid: "ed-a"}],
        keys: seventeen,
        keys: [],
        keys: a,
        keys: [Map.put(a, :use, "sig")],
        keys: [Map.delete(a, :alg)],
        keys: [%{a | kid: ""}],
        keys: [%{a | kid: String.duplicate("k", 129)}],
        keys: [%{a | kid: "k\n"}],
        keys: [%{a | kid: "ké"}],
        keys: [%{a | jwk: %{"kty" => "OKP", "crv" => "Ed25519", "x" => "AAAA"}}],
        keys: [%{c | jwk: %{c.jwk | "e" => "AQ"}}],
        keys: [%{c | jwk: %{c.jwk | "e" => "AQAA"}}],
        leeway_s: 301,
        leeway_s: -1,
        leeway_s: 1.0,
        issuer: "",
        issuer: String.duplicate("i", 1025),
        issuer: <<0xFF>>,
        audience: nil,
        subject: fn -> :ok end
      ]

      for {key, value} <- bad do
        error = assert_raise ArgumentError, fn -> jwt_config(ctx, [{key, value}]) end
        assert Exception.message(error) == @jwt_error, "#{key} #{inspect(value)}"
      end

      valid = [
        issuer: @issuer,
        audience: @audience,
        keys: ctx.keys,
        leeway_s: 0,
        subject: subject()
      ]

      for opts <- [
            Keyword.delete(valid, :subject),
            valid ++ [extra: 1],
            valid ++ [leeway_s: 0],
            Map.new(valid),
            nil
          ] do
        error = assert_raise ArgumentError, fn -> TokenVerify.jwt_config(opts) end
        assert Exception.message(error) == @jwt_error
      end

      sixteen = Enum.take(seventeen, 16)

      rsa_8192 = %{
        c
        | jwk: %{c.jwk | "n" => b64(:binary.encode_unsigned(Integer.pow(2, 8191) + 1))}
      }

      assert %TokenVerify.JwtConfig{} = jwt_config(ctx, keys: sixteen, leeway_s: 300)

      assert %TokenVerify.JwtConfig{} =
               jwt_config(ctx, keys: [rsa_8192], issuer: String.duplicate("i", 1024))
    end

    test "malformed API key options raise the fixed ArgumentError" do
      valid = [prefix: "ek", digest_key: fn -> :ok end, lookup: fn _ -> :ok end]

      for opts <- [
            Keyword.put(valid, :prefix, ""),
            Keyword.put(valid, :prefix, "Ek"),
            Keyword.put(valid, :prefix, "e_k"),
            Keyword.put(valid, :prefix, String.duplicate("a", 17)),
            Keyword.put(valid, :digest_key, fn _ -> :ok end),
            Keyword.put(valid, :lookup, fn -> :ok end),
            Keyword.delete(valid, :lookup),
            valid ++ [extra: 1],
            valid ++ [prefix: "ek"],
            Map.new(valid)
          ] do
        error = assert_raise ArgumentError, fn -> TokenVerify.api_key_config(opts) end
        assert Exception.message(error) == @api_key_error
      end

      assert %TokenVerify.ApiKeyConfig{} =
               TokenVerify.api_key_config(Keyword.put(valid, :prefix, "a1b2c3d4e5f6g7h8"))
    end
  end

  test "the checked example" do
    {result, _} = Code.eval_file(Path.expand("../../examples/token_verify.exs", __DIR__))

    assert [
             {:ok, %Principal{id: "alice", auth_epoch: 1_800_000_000}},
             {:error, :bad_audience},
             {:ok, %Principal{id: "svc-1"}},
             {:error, :invalid_signature}
           ] = result
  end
end
