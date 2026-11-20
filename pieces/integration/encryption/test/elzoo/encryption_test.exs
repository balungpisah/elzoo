# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EncryptionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Bitwise
  alias Elzoo.Encryption
  alias Elzoo.Secrets.Credential

  @max_version 9_007_199_254_740_991
  @max_plaintext 1_048_576
  @key :binary.copy(<<0x5A>>, 32)
  @other_key :binary.copy(<<0xA5>>, 32)
  @plaintext "SECRET-PLAINTEXT-273"
  @aad "AAD-273-context"
  @key_id "subject-a"

  defp cred(value, version), do: %Credential{value: value, version: version, expires_at_unix_ms: 0}

  defp sealed(plaintext \\ @plaintext, aad \\ @aad, key_id \\ @key_id, key \\ @key, version \\ 1) do
    assert {:ok, envelope} = Encryption.seal(plaintext, aad, key_id, cred(key, version))
    envelope
  end

  # A Need that records each call in the mailbox, then answers.
  defp need(answer) do
    owner = self()

    fn key_id, version ->
      send(owner, {:need, key_id, version})
      answer.(key_id, version)
    end
  end

  # The original key for every reference, echoing the requested version.
  defp echo(key \\ @key), do: need(fn _, version -> {:ok, cred(key, version)} end)

  defp from_map(keys) do
    need(fn key_id, version ->
      case Map.fetch(keys, {key_id, version}) do
        {:ok, key} -> {:ok, cred(key, version)}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp calls(count \\ 0) do
    receive do
      {:need, _, _} -> calls(count + 1)
    after
      0 -> count
    end
  end

  # Group 7 for every refusal: the exact fixed result, no raise, no log, and no
  # plaintext, key or AAD bytes in the result or the captured log.
  defp refuse(expected, fun, secrets \\ []) do
    log = capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    assert result == {:error, expected}
    assert log == ""
    haystack = :erlang.term_to_binary(result) <> log

    for secret <- [@plaintext, @key, @other_key, @aad | secrets], secret != "" do
      assert :binary.match(haystack, secret) == :nomatch
    end
  end

  defp header(key_id, version),
    do: <<"EZE1", byte_size(key_id)::8, key_id::binary, version::64>>

  defp split(envelope) do
    <<"EZE1", id_len::8, key_id::binary-size(id_len), version::64, nonce::binary-size(12),
      rest::binary>> = envelope

    ct_size = byte_size(rest) - 16
    <<ciphertext::binary-size(^ct_size), tag::binary-size(16)>> = rest
    %{key_id: key_id, version: version, nonce: nonce, ciphertext: ciphertext, tag: tag}
  end

  defp flip(envelope, offset, bit \\ 0) do
    <<before::binary-size(^offset), byte, rest::binary>> = envelope
    <<before::binary, bxor(byte, 1 <<< bit), rest::binary>>
  end

  describe "1 round trip and format pin" do
    test "boundary plaintexts, aads, key IDs and versions open, key_ref and the layout agree" do
      long_id = String.duplicate("é", 64)
      assert byte_size(long_id) == 128

      for plaintext <- ["", "x", :binary.copy(<<7>>, @max_plaintext)],
          aad <- ["", :binary.copy("a", 1_024)],
          key_id <- ["a", long_id],
          version <- [1, @max_version] do
        envelope = sealed(plaintext, aad, key_id, @key, version)
        assert byte_size(envelope) == 4 + 1 + byte_size(key_id) + 8 + 12 + byte_size(plaintext) + 16

        assert Encryption.open(envelope, aad, echo()) == {:ok, plaintext}
        assert_received {:need, ^key_id, ^version}
        assert calls() == 0
        assert Encryption.key_ref(envelope) == {:ok, %{key_id: key_id, version: version}}

        parts = split(envelope)
        assert {parts.key_id, parts.version} == {key_id, version}

        assert :crypto.crypto_one_time_aead(
                 :aes_256_gcm,
                 @key,
                 parts.nonce,
                 parts.ciphertext,
                 header(key_id, version) <> aad,
                 parts.tag,
                 false
               ) == plaintext
      end
    end

    test "a credential released by Elzoo.Secrets.resolve/2 seals and opens" do
      request = %{ref: "pii-key/subject-a", scope: "tenant-a/pii"}

      context = %{
        grant: request,
        resolver: fn ref, scope ->
          {:ok, %{ref: ref, scope: scope, value: @key, version: 3, expires_at_unix_ms: 100}}
        end,
        clock: fn -> 0 end
      }

      assert {:ok, credential} = Elzoo.Secrets.resolve(request, context)
      assert {:ok, envelope} = Encryption.seal(@plaintext, @aad, @key_id, credential)
      keys = need(fn @key_id, 3 -> Elzoo.Secrets.resolve(request, context) end)
      assert Encryption.open(envelope, @aad, keys) == {:ok, @plaintext}
      assert Encryption.key_ref(envelope) == {:ok, %{key_id: @key_id, version: 3}}
    end
  end

  describe "2 integrity" do
    setup do
      assert String.ends_with?(@key_id, "a")
      envelope = sealed()
      assert Encryption.open(envelope, @aad, echo()) == {:ok, @plaintext}
      assert calls() == 1
      %{envelope: envelope}
    end

    test "each listed tamper is invalid after exactly one Need call", %{envelope: envelope} do
      id_end = 5 + byte_size(@key_id) - 1
      version_end = 5 + byte_size(@key_id) + 7
      nonce_at = version_end + 1
      ciphertext_at = nonce_at + 12
      tag_at = byte_size(envelope) - 16

      key_b =
        binary_part(envelope, 0, id_end) <>
          "b" <> binary_part(envelope, id_end + 1, byte_size(envelope) - id_end - 1)

      assert Encryption.key_ref(key_b) == {:ok, %{key_id: "subject-b", version: 1}}
      version_2 = flip(flip(envelope, version_end, 0), version_end, 1)
      assert Encryption.key_ref(version_2) == {:ok, %{key_id: @key_id, version: 2}}

      cases = [
        {key_b, @aad, echo()},
        {version_2, @aad, echo()},
        {flip(envelope, nonce_at), @aad, echo()},
        {flip(envelope, ciphertext_at), @aad, echo()},
        {flip(envelope, tag_at + 15, 7), @aad, echo()},
        {envelope, "another aad", echo()},
        {envelope, @aad, echo(@other_key)},
        {binary_part(envelope, 0, byte_size(envelope) - 1), @aad, echo()}
      ]

      for {candidate, aad, keys} <- cases do
        refuse(:invalid, fn -> Encryption.open(candidate, aad, keys) end)
        assert calls() == 1
      end
    end

    test "every single-bit flip of the envelope is refused", %{envelope: envelope} do
      for offset <- 0..(byte_size(envelope) - 1), bit <- 0..7 do
        assert {:error, reason} = Encryption.open(flip(envelope, offset, bit), @aad, echo())
        assert reason in [:invalid, :malformed]
      end
    end
  end

  describe "3 OTP drift" do
    test "NIST GCM test case 13 tag" do
      assert {"", tag} =
               :crypto.crypto_one_time_aead(:aes_256_gcm, <<0::256>>, <<0::96>>, "", "", 16, true)

      assert Base.encode16(tag, case: :lower) == "530f8afbc74536b9a963b4f1c4cb738b"
    end

    test "decryption accepts a tag truncated to 15 bytes, so the layout fixes 16" do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, @key, <<1::96>>, @plaintext, "a", 16, true)

      assert :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               @key,
               <<1::96>>,
               ciphertext,
               "a",
               binary_part(tag, 0, 15),
               false
             ) == @plaintext
    end

    test "decryption with a wrong AAD gives :error" do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, @key, <<1::96>>, @plaintext, "a", 16, true)

      assert :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               @key,
               <<1::96>>,
               ciphertext,
               "b",
               tag,
               false
             ) ==
               :error
    end

    test "an 8-byte IV is accepted and a 31-byte key raises, so both are fixed before :crypto" do
      assert {<<_>>, <<_::binary-size(16)>>} =
               :crypto.crypto_one_time_aead(:aes_256_gcm, @key, <<0::64>>, "x", "", 16, true)

      assert_raise ErlangError, fn ->
        :crypto.crypto_one_time_aead(:aes_256_gcm, <<0::248>>, <<0::96>>, "x", "", 16, true)
      end
    end
  end

  describe "4 shape" do
    test "seal/4 refuses out-of-bound plaintext, aad and key IDs as malformed" do
      key = cred(@key, 1)

      for {plaintext, aad, key_id} <- [
            {:binary.copy(<<1>>, @max_plaintext + 1), @aad, @key_id},
            {~c"charlist", @aad, @key_id},
            {<<1::3>>, @aad, @key_id},
            {@plaintext, :binary.copy("a", 1_025), @key_id},
            {@plaintext, :not_binary, @key_id},
            {@plaintext, @aad, ""},
            {@plaintext, @aad, "a" <> String.duplicate("é", 64)},
            {@plaintext, @aad, :binary.copy("a", 129)},
            {@plaintext, @aad, <<"subject-", 0xFF>>},
            {@plaintext, @aad, "subject\0a"},
            {@plaintext, @aad, "subject\x1Fa"},
            {@plaintext, @aad, "subject\x7Fa"},
            {@plaintext, @aad, "subject\u0085a"},
            {@plaintext, @aad, "subject\u009Fa"},
            {@plaintext, @aad, :subject_a}
          ] do
        refuse(:malformed, fn -> Encryption.seal(plaintext, aad, key_id, key) end)
      end
    end

    test "key IDs just outside the control ranges are accepted" do
      for key_id <- ["subject a", "subject~a", "subject\u00A0a", :binary.copy("a", 128)] do
        envelope = sealed(@plaintext, @aad, key_id)
        assert Encryption.key_ref(envelope) == {:ok, %{key_id: key_id, version: 1}}
      end
    end

    test "seal/4 refuses bad credentials as key" do
      for credential <- [
            cred(:binary.copy(<<1>>, 31), 1),
            cred(:binary.copy(<<1>>, 33), 1),
            cred(@key, 0),
            cred(@key, @max_version + 1),
            cred(@key, 1.0),
            cred(:not_binary, 1),
            %{value: @key, version: 1, expires_at_unix_ms: 0},
            @key,
            nil
          ] do
        refuse(:key, fn -> Encryption.seal(@plaintext, @aad, @key_id, credential) end)
      end
    end

    test "open/3 and key_ref/1 refuse malformed envelopes without calling the Need" do
      body = <<0::96, "ct", 0::128>>

      envelopes = [
        :not_binary,
        ~c"EZE1",
        <<"EZE2", 9, @key_id, 1::64, body::binary>>,
        <<"EZE1", 0, 1::64, body::binary>>,
        <<"EZE1", 129, :binary.copy("a", 129)::binary, 1::64, body::binary>>,
        <<"EZE1", 9, "subject\na", 1::64, body::binary>>,
        <<"EZE1", 9, "subject", 0xC2, 0x85, 1::64, body::binary>>,
        <<"EZE1", 9, "subject", 0xFF, 0xFE, 1::64, body::binary>>,
        <<"EZE1", 9, @key_id, 0::64, body::binary>>,
        <<"EZE1", 9, @key_id, @max_version + 1::64, body::binary>>,
        <<"EZE1", 9, @key_id, 1::64, 0::96, 0::size(8 * (@max_plaintext + 1)), 0::128>>,
        <<"EZE1", 9, @key_id, 1::64, 0::96, 0::120>>,
        <<"EZE1", 20, @key_id>>,
        ""
      ]

      for envelope <- envelopes do
        refuse(:malformed, fn -> Encryption.open(envelope, @aad, echo()) end)
        refuse(:malformed, fn -> Encryption.key_ref(envelope) end)
      end

      assert calls() == 0
    end

    test "one byte shorter than an empty-plaintext envelope is malformed" do
      envelope = sealed("", "")
      assert Encryption.open(envelope, "", echo()) == {:ok, ""}
      assert calls() == 1
      short = binary_part(envelope, 0, byte_size(envelope) - 1)
      refuse(:malformed, fn -> Encryption.open(short, "", echo()) end)
      refuse(:malformed, fn -> Encryption.key_ref(short) end)
      assert calls() == 0
    end

    test "a malformed aad with a valid envelope is malformed before the Need" do
      envelope = sealed()

      for aad <- [:binary.copy("a", 1_025), :not_binary, <<1::3>>] do
        refuse(:malformed, fn -> Encryption.open(envelope, aad, echo()) end)
      end

      assert calls() == 0
    end
  end

  describe "5 Needs" do
    test "not_found is no_key after one call" do
      refuse(:no_key, fn ->
        Encryption.open(sealed(), @aad, need(fn _, _ -> {:error, :not_found} end))
      end)

      assert calls() == 1
    end

    test "crypto-shredding: dropping subject A's keys makes every A envelope no_key, B still opens" do
      keys = %{
        {"subject-a", 1} => @key,
        {"subject-a", 2} => @other_key,
        {"subject-b", 1} => :binary.copy(<<3>>, 32)
      }

      a_envelopes =
        for {{key_id, version}, key} <- keys,
            key_id == "subject-a",
            plaintext <- ["", "a1", "a2"] do
          {sealed(plaintext, @aad, key_id, key, version), plaintext}
        end

      b_envelope = sealed("b-record", @aad, "subject-b", keys[{"subject-b", 1}], 1)

      for {envelope, plaintext} <- a_envelopes do
        assert Encryption.open(envelope, @aad, from_map(keys)) == {:ok, plaintext}
      end

      shredded = Map.reject(keys, fn {{key_id, _}, _} -> key_id == "subject-a" end)
      calls()

      for {envelope, _} <- a_envelopes do
        refuse(:no_key, fn -> Encryption.open(envelope, @aad, from_map(shredded)) end, ["a1", "a2"])
        assert Encryption.key_ref(envelope) |> elem(0) == :ok
      end

      assert Encryption.open(b_envelope, @aad, from_map(shredded)) == {:ok, "b-record"}
      assert calls() == length(a_envelopes) + 1
    end

    test "faulty or mismatched Need results are unavailable after exactly one call" do
      envelope = sealed()

      answers = [
        fn _, _ -> raise "boom #{@plaintext}" end,
        fn _, _ -> throw({:thrown, @key}) end,
        fn _, _ -> exit({:exited, @aad}) end,
        fn _, _ -> {:ok, "raw"} end,
        fn _, _ -> {:ok, @key} end,
        fn _, version -> {:ok, cred(@key, version + 1)} end,
        fn _, _ -> {:ok, cred(@key, 2)} end,
        fn _, version -> {:ok, cred(:binary.copy(<<1>>, 31), version)} end,
        fn _, version -> {:ok, cred(:binary.copy(<<1>>, 33), version)} end,
        fn _, version -> {:ok, cred(:not_binary, version)} end,
        fn _, version -> {:ok, %{value: @key, version: version, expires_at_unix_ms: 0}} end,
        fn _, _ -> {:error, :unavailable} end,
        fn _, _ -> {:error, :missing} end,
        fn _, _ -> {:error, :expired} end,
        fn _, _ -> :ok end,
        fn _, _ -> nil end
      ]

      for answer <- answers do
        refuse(:unavailable, fn -> Encryption.open(envelope, @aad, need(answer)) end)
        assert calls() == 1
      end
    end

    test "a keys value that is not an arity-2 function is unavailable" do
      envelope = sealed()

      for keys <- [nil, %{}, fn _ -> {:ok, cred(@key, 1)} end] do
        refuse(:unavailable, fn -> Encryption.open(envelope, @aad, keys) end)
      end
    end
  end

  describe "6 nonces" do
    test "10,000 seals of one plaintext under one key give 10,000 distinct nonces" do
      credential = cred(@key, 1)

      nonces =
        for _ <- 1..10_000 do
          assert {:ok, envelope} = Encryption.seal(@plaintext, @aad, @key_id, credential)
          split(envelope).nonce
        end

      assert nonces |> MapSet.new() |> MapSet.size() == 10_000
    end
  end

  describe "7 secrecy and totality" do
    test "arbitrary terms give a tuple from the fixed set and never raise or log" do
      terms = [
        nil,
        1,
        :atom,
        "",
        "EZE1",
        <<"EZE1", 255>>,
        [],
        %{},
        {:a},
        self(),
        make_ref(),
        <<1::7>>,
        @key
      ]

      keys = need(fn _, _ -> {:ok, cred(@key, 1)} end)

      log =
        capture_log(fn ->
          for a <- terms, b <- terms do
            assert {:error, r} = Encryption.open(a, b, keys)
            assert r in [:malformed, :no_key, :unavailable, :invalid]
            assert {:error, :malformed} = Encryption.key_ref(a)

            for c <- terms, d <- [nil, cred(@key, 1), %{}] do
              result = Encryption.seal(a, b, c, d)
              assert match?({:ok, _}, result) or result in [{:error, :malformed}, {:error, :key}]
            end
          end
        end)

      assert log == ""
    end

    test "the compiled module calls no Logger, telemetry, clock or IO" do
      {:ok, {_, [imports: imports]}} =
        :beam_lib.chunks(:code.which(Elzoo.Encryption), [:imports])

      modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert modules -- [:crypto, :erlang, Elzoo.Secrets, String] == []
    end
  end
end
