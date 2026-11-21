# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PiiRedactionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elzoo.PiiRedaction

  @marker ~r/\[pii:(known|email|card|phone)(:[A-Za-z0-9_-]{1,64})?\]/

  # Every successful call goes through one of these helpers, which also checks
  # that each `[pii:` in the output is a marker that the call emitted.
  defp mask(text, known \\ []), do: checked(PiiRedaction.redact(text, mode: :mask, known: known))

  defp tok(text, vault, known \\ []),
    do: checked(PiiRedaction.redact(text, mode: :tokenize, known: known, vault: vault))

  defp checked({:ok, %{text: out, findings: findings}} = result) do
    total = Enum.sum(Enum.map(findings, & &1.count))
    assert length(:binary.matches(out, "[pii:")) == total
    assert length(Regex.scan(@marker, out)) == total
    assert Enum.all?(findings, &(Map.keys(&1) == [:count, :kind]))
    result
  end

  defp checked(error), do: error

  defp masked(text, known \\ []) do
    {:ok, %{text: out, findings: findings}} = mask(text, known)
    {out, findings}
  end

  defp none(text, known \\ []), do: assert(masked(text, known) == {text, []})

  defp counting(answer \\ fn _kind, span -> {:ok, ref(span)} end) do
    test = self()

    fn kind, span ->
      send(test, {:vault, kind, span})
      answer.(kind, span)
    end
  end

  defp ref(span), do: "r" <> Integer.to_string(:erlang.phash2(span))

  defp calls do
    receive do
      {:vault, kind, span} -> [{kind, span} | calls()]
    after
      0 -> []
    end
  end

  defp sized(unit, size),
    do: binary_part(String.duplicate(unit, div(size, byte_size(unit)) + 1), 0, size)

  describe "1 kinds in both modes" do
    test "email at the start, middle and end and next to punctuation" do
      assert masked("a@b.com is here") == {"[pii:email] is here", [%{kind: :email, count: 1}]}

      assert masked("mail x.y+z@sub.example.org now") ==
               {"mail [pii:email] now", [%{kind: :email, count: 1}]}

      assert masked("to: a@b.com") == {"to: [pii:email]", [%{kind: :email, count: 1}]}

      assert masked("(a@b.com), <c@d.net>; \"e@f.io\". g@h.co!") ==
               {"([pii:email]), <[pii:email]>; \"[pii:email]\". [pii:email]!",
                [%{kind: :email, count: 4}]}
    end

    test "13-, 16- and 19-digit cards that pass Luhn, and one changed digit" do
      for {card, changed} <- [
            {"4222222222222", "4222222222223"},
            {"4111111111111111", "4111111111111112"},
            {"6011000000000000001", "6011000000000000002"}
          ] do
        assert masked("pay #{card} now") == {"pay [pii:card] now", [%{kind: :card, count: 1}]}
        none("pay #{changed} now")
      end
    end

    test "grouped cards with spaces and with hyphens; mixed separators are no finding" do
      assert masked("4111 1111 1111 1111") == {"[pii:card]", [%{kind: :card, count: 1}]}
      assert masked("x 4111-1111-1111-1111.") == {"x [pii:card].", [%{kind: :card, count: 1}]}
      none("4111 1111-1111 1111")
      none("4111-1111 1111-1111")
    end

    test "phones with and without separators; 7 and 16 digits are no finding" do
      assert masked("call +6281234567890.") == {"call [pii:phone].", [%{kind: :phone, count: 1}]}
      assert masked("+62 812-3456-7890") == {"[pii:phone]", [%{kind: :phone, count: 1}]}

      assert masked("+12345678 +123456789012345") ==
               {"[pii:phone] [pii:phone]", [%{kind: :phone, count: 2}]}

      none("+1234567")
      none("+1234567890123456")
      none("6281234567890")
    end

    test "a known value inside a word, case sensitive and exact bytes" do
      assert masked("helloJohnDoe!", ["JohnDoe"]) ==
               {"hello[pii:known]!", [%{kind: :known, count: 1}]}

      none("hellojohndoe!", ["JohnDoe"])
      none("Jose\u0301", ["José"])

      assert masked("ab ab", ["ab", "ab"]) ==
               {"[pii:known] [pii:known]", [%{kind: :known, count: 2}]}
    end

    test "every kind in tokenize mode, with counts in the fixed kind order" do
      vault = counting()
      text = "+6281234567890, 4111111111111111, a@b.com Ann"

      assert {:ok, %{text: out, findings: findings}} = tok(text, vault, ["Ann"])

      assert out ==
               "[pii:phone:#{ref("+6281234567890")}], [pii:card:#{ref("4111111111111111")}], " <>
                 "[pii:email:#{ref("a@b.com")}] [pii:known:#{ref("Ann")}]"

      assert findings == [
               %{kind: :known, count: 1},
               %{kind: :email, count: 1},
               %{kind: :card, count: 1},
               %{kind: :phone, count: 1}
             ]

      assert masked(text, ["Ann"]) ==
               {"[pii:phone], [pii:card], [pii:email] [pii:known]", findings}
    end

    test "no finding and an empty text" do
      assert tok("", counting()) == {:ok, %{text: "", findings: []}}
      none("")
      none("nothing to see, 123 456 and +12.")
      assert calls() == []
    end

    test "the same input and Need answers give the same output" do
      text = "a@b.com 4111111111111111 +6281234567890 Ann a@b.com"
      assert tok(text, counting(), ["Ann"]) == tok(text, counting(), ["Ann"])
      assert mask(text, ["Ann"]) == mask(text, ["Ann"])
    end
  end

  describe "2 boundaries" do
    test "local part of 64 and 65 bytes" do
      assert {"[pii:email]", _} = masked(String.duplicate("a", 64) <> "@example.com")
      none(String.duplicate("a", 65) <> "@example.com")
      none("x" <> String.duplicate(".", 64) <> "@example.com")
    end

    test "label of 63 and 64 bytes" do
      assert {"[pii:email]", _} = masked("a@" <> String.duplicate("b", 63) <> ".com")
      none("a@" <> String.duplicate("b", 64) <> ".com")
      assert {"[pii:email]", _} = masked("a@x." <> String.duplicate("c", 63))
      none("a@x." <> String.duplicate("c", 64))
    end

    test "domain of 253 and 254 bytes" do
      l63 = String.duplicate("d", 63)
      domain253 = Enum.join([l63, l63, l63, String.duplicate("e", 57), "com"], ".")
      domain254 = Enum.join([l63, l63, l63, String.duplicate("e", 58), "com"], ".")
      assert byte_size(domain253) == 253 and byte_size(domain254) == 254

      assert {"[pii:email]", _} = masked("a@" <> domain253)
      none("a@" <> domain254)
    end

    test "labels: hyphens, last label letters only, at least two labels" do
      assert {"[pii:email]", _} = masked("a@my-host.example.com")
      none("a@-host.com")
      none("a@host-.com")
      none("a@b.c")
      none("a@b.123")
      none("a@b.c0m")
      none("a@localhost")
      none("a@b.com.-x")
      assert masked("a@b.com.") == {"[pii:email].", [%{kind: :email, count: 1}]}
    end

    test "a digit directly before or after a card or phone span" do
      none("74111111111111111")
      none("41111111111111117")
      none("7+6281234567890")
      none("+1234567890123456")
      none("+628123456789012-3")
    end

    test "a longer grouped run is not its first digits" do
      none("+1234 5678 9012 3456")
    end

    test "the mixed-separator run 1111-4111 1111 1111 1111" do
      assert masked("4111 1111 1111 1111") == {"[pii:card]", [%{kind: :card, count: 1}]}
      none("1111-4111 1111 1111 1111")
    end

    test "a card run preceded by 7 and space, and one followed by space and 7" do
      none("7 4111 1111 1111 1111")
      none("4111 1111 1111 1111 7")
      # Limit: the extra digit joins the run; this 17-digit run fails Luhn.
      none("4111 1111 1111 1111 7 items")
      # And this one passes Luhn, so it is found with the extra digit.
      assert masked("4111 1111 1111 1111 3 items") ==
               {"[pii:card] items", [%{kind: :card, count: 1}]}

      # A phone and a card joined by one space are one 29-digit run.
      none("+6281234567890 4111111111111111")
      # A double space or a separator before a non-digit ends the run.
      assert masked("7  4111 1111 1111 1111 - 7") ==
               {"7  [pii:card] - 7", [%{kind: :card, count: 1}]}
    end

    test "text of 65,536 bytes passes and 65,537 is refused" do
      assert {:ok, %{findings: []}} = mask(String.duplicate("x", 65_536))

      assert {:ok, %{findings: [%{kind: :email, count: 1}]}} =
               mask(sized("x", 65_528) <> " a@b.com")

      assert PiiRedaction.redact(String.duplicate("x", 65_537), mode: :mask, known: []) ==
               {:error, :malformed}
    end

    test "64 and 65 known values" do
      values = for i <- 1..65, do: "v#{i}w"
      assert {:ok, _} = mask("v64w", Enum.take(values, 64))
      assert PiiRedaction.redact("v64w", mode: :mask, known: values) == {:error, :malformed}
    end

    test "known values of 1, 256 and 257 bytes" do
      assert masked("xyz", ["y"]) == {"x[pii:known]z", [%{kind: :known, count: 1}]}
      v256 = String.duplicate("k", 256)
      assert masked(v256, [v256]) == {"[pii:known]", [%{kind: :known, count: 1}]}
      v257 = String.duplicate("k", 257)
      assert PiiRedaction.redact(v257, mode: :mask, known: [v257]) == {:error, :malformed}
      assert PiiRedaction.redact("k", mode: :mask, known: [""]) == {:error, :malformed}
    end

    test "invalid UTF-8 and a non-binary text are malformed" do
      for text <- [<<0xFF>>, "a@b.com" <> <<0xC3>>, ~c"a@b.com", :text, 1, nil, <<1::3>>] do
        assert PiiRedaction.redact(text, mode: :mask, known: []) == {:error, :malformed}
      end

      assert PiiRedaction.redact("x", mode: :mask, known: [<<0xFF>>]) == {:error, :malformed}
    end

    test "option shape" do
      vault = counting()

      for opts <- [
            [],
            [mode: :mask],
            [known: []],
            [mode: :redact, known: []],
            [mode: :mask, known: [], vault: vault],
            [mode: :tokenize, known: []],
            [mode: :tokenize, known: [], vault: fn _ -> {:ok, "r"} end],
            [mode: :tokenize, known: [], vault: :vault],
            [mode: :mask, known: [], extra: 1],
            [mode: :mask, mode: :mask, known: []],
            [mode: :mask, known: [], known: []],
            [mode: :mask, known: "Ann"],
            [mode: :mask, known: ["Ann" | "Bob"]],
            [mode: :mask, known: [:ann]],
            %{mode: :mask, known: []},
            [{"mode", :mask}, {:known, []}],
            [:mode, :known]
          ] do
        assert PiiRedaction.redact("a@b.com", opts) == {:error, :malformed}, inspect(opts)
      end

      assert {:ok, _} = checked(PiiRedaction.redact("a@b.com", known: [], mode: :mask))
      assert calls() == []
    end
  end

  describe "3 overlap" do
    test "a known value that contains an email" do
      assert masked("say contact a@b.com now", ["contact a@b.com"]) ==
               {"say [pii:known] now", [%{kind: :known, count: 1}]}
    end

    test "the leftmost start wins, then the longer span, then the earlier kind" do
      # The email starts first, so the overlapping known value is not found.
      assert masked("a@b.com x", ["b.com x"]) == {"[pii:email] x", [%{kind: :email, count: 1}]}
      # Same start: the longer email wins over a shorter known value.
      assert masked("a@b.com", ["a@b"]) == {"[pii:email]", [%{kind: :email, count: 1}]}
      # Same start and length: the earlier kind (known) wins.
      assert masked("a@b.com", ["a@b.com"]) == {"[pii:known]", [%{kind: :known, count: 1}]}
      # A phone starts at its `+`, before the card on the same digits.
      assert masked("+4222222222222") == {"[pii:phone]", [%{kind: :phone, count: 1}]}
      # Same start: the longer card wins over a known value inside it.
      assert masked("4111111111111111", ["1111"]) == {"[pii:card]", [%{kind: :card, count: 1}]}
    end

    test "an email whose local part is all digits and would be a card" do
      assert masked("4111111111111111@example.com") == {"[pii:email]", [%{kind: :email, count: 1}]}

      assert masked("4111111111111111 @example.com") ==
               {"[pii:card] @example.com", [%{kind: :card, count: 1}]}
    end

    test "findings after a chosen span are still found" do
      assert masked("Ann a@b.com Ann 4111111111111111 Ann", ["Ann"]) ==
               {"[pii:known] [pii:email] [pii:known] [pii:card] [pii:known]",
                [%{kind: :known, count: 3}, %{kind: :email, count: 1}, %{kind: :card, count: 1}]}
    end
  end

  describe "4 escaping" do
    test "an input marker is rewritten" do
      assert masked("[pii:email:abc]") == {"[pii_:email:abc]", []}

      assert masked("[pii:card] 4111111111111111 [pii:") ==
               {"[pii_:card] [pii:card] [pii_:", [%{kind: :card, count: 1}]}

      assert {:ok, %{text: out}} = tok("[[pii:known:x] a@b.com", counting())
      assert out == "[[pii_:known:x] [pii:email:#{ref("a@b.com")}]"
    end

    test "known values match the rewritten text" do
      assert masked("[pii:x", ["[pii:x"]) == {"[pii_:x", []}
      assert masked("[pii:x", ["[pii_:x"]) == {"[pii:known]", [%{kind: :known, count: 1}]}
    end
  end

  describe "5 vault Need" do
    test "one call for each distinct {kind, span}, in first-occurrence order" do
      vault = counting()
      text = "b@c.com a@b.com b@c.com +6281234567890 x 4111111111111111 a@b.com Ann Ann"

      assert {:ok, %{text: out}} = tok(text, vault, ["Ann"])
      parts = String.split(out, " ")
      assert Enum.at(parts, 0) == Enum.at(parts, 2) and Enum.at(parts, 1) == Enum.at(parts, 6)
      assert Enum.at(parts, 7) == Enum.at(parts, 8) and Enum.at(parts, 0) != Enum.at(parts, 1)

      assert calls() == [
               {:email, "b@c.com"},
               {:email, "a@b.com"},
               {:phone, "+6281234567890"},
               {:card, "4111111111111111"},
               {:known, "Ann"}
             ]
    end

    test "the same email twice gives one call and two equal markers" do
      assert {:ok, %{text: out}} =
               tok("a@b.com and a@b.com", counting(fn _, _ -> {:ok, "R-1_z"} end))

      assert out == "[pii:email:R-1_z] and [pii:email:R-1_z]"
      assert calls() == [{:email, "a@b.com"}]
    end

    test "never called for malformed or too_many" do
      vault = counting()
      many = String.duplicate("a@b.co ", 257)

      assert PiiRedaction.redact(many, mode: :tokenize, known: [], vault: vault) ==
               {:error, :too_many}

      assert PiiRedaction.redact(<<0xFF>>, mode: :tokenize, known: [], vault: vault) ==
               {:error, :malformed}

      assert PiiRedaction.redact("a@b.com", mode: :tokenize, known: [<<0xFF>>], vault: vault) ==
               {:error, :malformed}

      assert calls() == []
    end

    test "a raise, throw, exit, malformed result or invalid ref is unavailable" do
      for answer <- [
            fn _, _ -> raise "boom" end,
            fn _, _ -> throw(:boom) end,
            fn _, _ -> exit(:boom) end,
            fn _, _ -> {:ok, "bad ref!"} end,
            fn _, _ -> {:ok, String.duplicate("r", 65)} end,
            fn _, _ -> {:ok, ""} end,
            fn _, _ -> {:ok, :ref} end,
            fn _, _ -> {:ok, "r", :extra} end,
            fn _, _ -> {:ok, "é"} end,
            fn _, _ -> :error end,
            fn _, _ -> "ref" end
          ] do
        assert PiiRedaction.redact("a@b.com", mode: :tokenize, known: [], vault: counting(answer)) ==
                 {:error, :unavailable}

        assert calls() == [{:email, "a@b.com"}]
      end

      r64 = String.duplicate("r", 64)
      assert {:ok, %{text: out}} = tok("a@b.com", fn _, _ -> {:ok, r64} end)
      assert out == "[pii:email:#{r64}]"
    end

    test "a failing later call returns no partial text and stops the calls" do
      answer = fn
        :email, _ -> {:ok, "ok"}
        :card, _ -> {:error, :down}
        :phone, _ -> {:ok, "ok"}
      end

      text = "a@b.com 4111111111111111 +6281234567890"

      assert PiiRedaction.redact(text, mode: :tokenize, known: [], vault: counting(answer)) ==
               {:error, :unavailable}

      assert calls() == [{:email, "a@b.com"}, {:card, "4111111111111111"}]
    end

    test "256 findings pass and 257 give too_many, in both modes" do
      ok = String.duplicate("a@b.co ", 256)
      assert {:ok, %{findings: [%{kind: :email, count: 256}]}} = mask(ok)
      assert {:ok, %{findings: [%{kind: :email, count: 256}]}} = tok(ok, counting())
      assert calls() == [{:email, "a@b.co"}]

      many = ok <> "+6281234567890"
      assert PiiRedaction.redact(many, mode: :mask, known: []) == {:error, :too_many}

      assert PiiRedaction.redact(many, mode: :tokenize, known: [], vault: counting()) ==
               {:error, :too_many}

      assert calls() == []
    end
  end

  describe "6 adversarial size" do
    test "65,536-byte texts complete within the default timeout" do
      l63 = String.duplicate("d", 63)

      texts = [
        {"a@ repeated", String.duplicate("a@", 32_768)},
        {"+1 repeated", sized("+1 ", 65_536)},
        {"one digit run", String.duplicate("1", 65_536)},
        {"one grouped digit run", sized("1 ", 65_536)},
        {"[pii: repeated", sized("[pii:", 65_536)},
        {"long dotted domain", "a@" <> sized("a.", 65_534)},
        {"long local part runs", sized(String.duplicate("a", 64) <> "@", 65_536)},
        {"labels at the bound", sized("a@" <> l63 <> "." <> l63 <> ".", 65_536)},
        {"near-miss known values", sized("k", 65_536)}
      ]

      known = for i <- 1..64, do: String.duplicate("k", 255) <> Integer.to_string(rem(i, 10))

      for {name, text} <- texts do
        assert byte_size(text) == 65_536
        {micros, result} = :timer.tc(fn -> PiiRedaction.redact(text, mode: :mask, known: known) end)
        assert match?({:ok, _}, checked(result)) or result == {:error, :too_many}, name
        # Observation only, not a time guarantee.
        IO.puts("observation: #{name}: #{div(micros, 1000)} ms")
      end
    end
  end

  describe "7 secrecy" do
    @secret "secret.person@example.com 4111111111111111 +6281234567890 SecretName"

    test "no span byte appears in a refusal or a captured log" do
      fail = [
        fn _, _ -> raise ArgumentError, "#{@secret}" end,
        fn _, span -> throw(span) end,
        fn _, span -> exit(span) end,
        fn _, span -> {:ok, span} end,
        fn _, span -> {:error, span} end
      ]

      cases =
        [
          {@secret <> <<0xFF>>, mode: :mask, known: []},
          {@secret <> String.duplicate(" ", 65_536), mode: :mask, known: []},
          {@secret, mode: :mask, known: ["SecretName"], vault: counting()},
          {@secret, mode: :mask, known: [String.duplicate("SecretName", 26)]},
          {String.duplicate(@secret <> " ", 70), mode: :mask, known: ["SecretName"]},
          {String.duplicate(@secret <> " ", 70),
           mode: :tokenize, known: ["SecretName"], vault: counting()}
        ] ++
          for(answer <- fail, do: {@secret, mode: :tokenize, known: ["SecretName"], vault: answer})

      log =
        capture_log(fn ->
          for {text, opts} <- cases do
            result = PiiRedaction.redact(text, opts)
            assert result in [{:error, :malformed}, {:error, :too_many}, {:error, :unavailable}]

            for part <- ["secret", "person", "example", "4111", "6281", "SecretName"] do
              refute inspect(result) =~ part
            end
          end
        end)

      assert log == ""
      assert calls() == []
    end

    test "a successful call emits no log and its findings hold no span" do
      log =
        capture_log(fn ->
          assert {:ok, %{findings: findings}} = mask(@secret, ["SecretName"])
          refute inspect(findings) =~ "secret"
          refute inspect(findings) =~ "4111"
        end)

      assert log == ""
    end
  end
end
