# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CitationTest do
  use ExUnit.Case, async: true
  alias Elzoo.{Citation, PayloadSchema}

  # Every expected offset below is counted by hand from the bytes of the
  # content, not computed with the Piece's code.

  @reasons [:invalid, :malformed, :too_many, :duplicate, :unknown_item, :quote_not_found, :uncited]
  @port %{
    "id" => "answer",
    "direction" => "output",
    "schema_id" => "elzoo.citation.answer",
    "schema_version" => 1
  }
  @open %{min_citations: 0}
  # 36 distinct one-byte characters, each a quote of its own.
  @alphabet "abcdefghijklmnopqrstuvwxyz0123456789"
  # U+1F600, four bytes in UTF-8.
  @four "😀"
  @hello "héllo wörld"

  defp item(id, content, extra \\ %{}),
    do: Map.merge(%{item_id: id, source: "src/" <> id, version: 1, content: content}, extra)

  defp cite(id, quote), do: %{"item_id" => id, "quote" => quote}
  defp answer(citations, text \\ "An answer."), do: %{"text" => text, "citations" => citations}

  defp letters(n),
    do: for(<<c <- binary_part(@alphabet, 0, n)>>, do: cite("abc", <<c>>))

  defp abc, do: item("abc", @alphabet)

  describe "1 schema" do
    test "schema/0 is the version 1 object, checked through core/payload-schema" do
      assert Citation.schema() == %{
               "type" => "object",
               "properties" => %{
                 "text" => %{"type" => "string", "maxLength" => 65536},
                 "citations" => %{
                   "type" => "array",
                   "maxItems" => 32,
                   "items" => %{
                     "type" => "object",
                     "properties" => %{
                       "item_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 1024},
                       "quote" => %{"type" => "string", "minLength" => 1, "maxLength" => 1024}
                     },
                     "required" => ["item_id", "quote"],
                     "additionalProperties" => false
                   }
                 }
               },
               "required" => ["text", "citations"],
               "additionalProperties" => false
             }

      assert {:ok, checked} = PayloadSchema.build(@port, Citation.schema())
      assert :ok = PayloadSchema.check(checked, @port, answer([cite("abc", "a")]))

      for bad <- [
            Map.put(answer([]), "extra", 1),
            answer([Map.put(cite("abc", "a"), "marker", "1")]),
            %{"citations" => []},
            answer([cite("abc", "")]),
            answer(for i <- 1..33, do: cite("abc", "q#{i}"))
          ] do
        assert {:error, {:violations, _}} = PayloadSchema.check(checked, @port, bad)
      end
    end

    test "maxLength counts characters: 256 four-byte characters pass, 300 are malformed" do
      assert {:ok, checked} = PayloadSchema.build(@port, Citation.schema())

      quote = String.duplicate(@four, 256)
      assert byte_size(quote) == 1024
      long = answer([cite("emoji", quote)])
      assert :ok = PayloadSchema.check(checked, @port, long)

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 1024}]}} =
               Citation.check(long, [item("emoji", quote)], @open)

      over = String.duplicate(@four, 300)
      assert byte_size(over) == 1200
      too_long = answer([cite("emoji", over)])
      assert :ok = PayloadSchema.check(checked, @port, too_long)

      assert {:error, :malformed} =
               Citation.check(too_long, [item("emoji", over <> over)], @open)
    end
  end

  describe "2 every rule at its edge" do
    test "0, 1 and 32 citations are accepted, 33 are too_many" do
      for n <- [0, 1, 32] do
        assert {:ok, %{citations: resolved}} = Citation.check(answer(letters(n)), [abc()], @open)
        assert length(resolved) == n
      end

      assert {:error, :too_many} = Citation.check(answer(letters(33)), [abc()], @open)
    end

    test "quote bytes: 1 and 1,024 accepted; 0, 1,025 and invalid UTF-8 malformed" do
      content = String.duplicate("a", 1025)
      items = [item("a", content)]

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 1}]}} =
               Citation.check(answer([cite("a", "a")]), items, @open)

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 1024}]}} =
               Citation.check(answer([cite("a", String.duplicate("a", 1024))]), items, @open)

      for quote <- ["", content, <<0xFF>>, <<"a", 0xC3>>] do
        assert {:error, :malformed} = Citation.check(answer([cite("a", quote)]), items, @open)
      end
    end

    test "item_id of 1,024 bytes is accepted; 0 or 1,025 bytes or invalid UTF-8 is malformed" do
      id = String.duplicate("i", 1024)

      assert {:ok, %{citations: [%{item_id: ^id, start_byte: 0, end_byte: 1}]}} =
               Citation.check(answer([cite(id, "a")]), [item(id, "a", %{source: "s"})], @open)

      for id <- ["", String.duplicate("i", 1025), <<0xFF>>] do
        assert {:error, :malformed} = Citation.check(answer([cite(id, "a")]), [abc()], @open)
      end
    end

    test "text of 0 and 65,536 bytes is accepted, 65,537 bytes or invalid UTF-8 malformed" do
      for text <- ["", String.duplicate("t", 65536)] do
        assert {:ok, _} = Citation.check(answer([cite("abc", "a")], text), [abc()], @open)
      end

      for text <- [String.duplicate("t", 65537), <<0xFF>>, nil] do
        assert {:error, :malformed} =
                 Citation.check(answer([cite("abc", "a")], text), [abc()], @open)
      end
    end

    test "an item_id that differs only by case or a trailing space is unknown_item" do
      items = [item("Doc-1", "some text")]
      assert {:ok, _} = Citation.check(answer([cite("Doc-1", "text")]), items, @open)

      for id <- ["doc-1", "DOC-1", "Doc-1 "] do
        assert {:error, :unknown_item} = Citation.check(answer([cite(id, "text")]), items, @open)
      end
    end

    test "a fabricated quote is quote_not_found; the held text is accepted" do
      items = [item("a", "The office opens at nine."), item("b", "Parking is free.")]

      assert {:error, :quote_not_found} =
               Citation.check(answer([cite("a", "The office opens at ten")]), items, @open)

      assert {:ok, %{citations: [%{item_id: "a", start_byte: 0, end_byte: 23}]}} =
               Citation.check(answer([cite("a", "The office opens at nin")]), items, @open)

      # In another given item, but not in the cited one.
      assert {:error, :quote_not_found} =
               Citation.check(answer([cite("a", "Parking")]), items, @open)
    end

    test "a repeated pair is duplicate; one quote from two items, two quotes from one item are not" do
      items = [item("a", "same words"), item("b", "same words")]

      assert {:error, :duplicate} =
               Citation.check(answer([cite("a", "same"), cite("a", "same")]), items, @open)

      # The repeat need not be adjacent.
      assert {:error, :duplicate} =
               Citation.check(
                 answer([cite("a", "same"), cite("b", "words"), cite("a", "same")]),
                 items,
                 @open
               )

      assert {:ok, %{citations: [%{item_id: "a"}, %{item_id: "b"}]}} =
               Citation.check(answer([cite("a", "same"), cite("b", "same")]), items, @open)

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 4}, %{start_byte: 5, end_byte: 10}]}} =
               Citation.check(answer([cite("a", "same"), cite("a", "words")]), items, @open)
    end
  end

  describe "3 Unicode" do
    test "NFD quote against NFC content is quote_not_found; the NFC quote is found" do
      items = [item("u", "caf" <> <<0xC3, 0xA9>>)]
      nfd = "caf" <> <<?e, 0xCC, 0x81>>

      assert {:error, :quote_not_found} = Citation.check(answer([cite("u", nfd)]), items, @open)

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 5}]}} =
               Citation.check(answer([cite("u", "café")]), items, @open)
    end

    test "multi-byte offsets: wörld in héllo wörld is 7..13" do
      assert byte_size(@hello) == 13

      assert {:ok, %{citations: [%{start_byte: 7, end_byte: 13}]}} =
               Citation.check(answer([cite("h", "wörld")]), [item("h", @hello)], @open)
    end
  end

  describe "4 first occurrence" do
    test "the lowest position counts" do
      assert {:ok, %{citations: [%{start_byte: 1, end_byte: 3}]}} =
               Citation.check(answer([cite("x", "bc")]), [item("x", "abcabc")], @open)

      assert {:ok, %{citations: [%{start_byte: 0, end_byte: 2}]}} =
               Citation.check(answer([cite("x", "aa")]), [item("x", "aaaa")], @open)
    end
  end

  describe "5 source offsets" do
    test "start_byte shifts the range; 0 equals no key; source and version are the item's" do
      chunk = item("h", @hello, %{source: "manual/setup", version: 7, start_byte: 100})

      assert {:ok,
              %{
                citations: [
                  %{
                    item_id: "h",
                    source: "manual/setup",
                    version: 7,
                    start_byte: 107,
                    end_byte: 113
                  }
                ]
              }} == Citation.check(answer([cite("h", "wörld")]), [chunk], @open)

      zero =
        Citation.check(answer([cite("h", "wörld")]), [item("h", @hello, %{start_byte: 0})], @open)

      none = Citation.check(answer([cite("h", "wörld")]), [item("h", @hello)], @open)
      assert zero == none

      assert {:ok,
              %{
                citations: [
                  %{item_id: "h", source: "src/h", version: 1, start_byte: 7, end_byte: 13}
                ]
              }} ==
               none

      items = [
        item("p", "alpha beta", %{source: "s/one", version: 2}),
        item("q", "gamma delta", %{source: "s/two", version: 2_147_483_647, start_byte: 40})
      ]

      assert {:ok,
              %{
                citations: [
                  %{
                    item_id: "q",
                    source: "s/two",
                    version: 2_147_483_647,
                    start_byte: 46,
                    end_byte: 51
                  },
                  %{item_id: "p", source: "s/one", version: 2, start_byte: 6, end_byte: 10}
                ]
              }} == Citation.check(answer([cite("q", "delta"), cite("p", "beta")]), items, @open)
    end
  end

  describe "6 min_citations" do
    test "the boundary and bad policies" do
      two = answer(letters(2))
      assert {:ok, _} = Citation.check(two, [abc()], %{min_citations: 2})
      assert {:error, :uncited} = Citation.check(answer(letters(1)), [abc()], %{min_citations: 2})
      assert {:ok, %{citations: []}} = Citation.check(answer([]), [abc()], %{min_citations: 0})
      assert {:ok, _} = Citation.check(answer(letters(32)), [abc()], %{min_citations: 32})
      assert {:error, :uncited} = Citation.check(answer(letters(31)), [abc()], %{min_citations: 32})

      for policy <- [
            %{min_citations: -1},
            %{min_citations: 33},
            %{min_citations: 1.0},
            %{min_citations: "1"},
            %{min_citations: 1, match: :exact},
            %{},
            %{"min_citations" => 1},
            [min_citations: 1],
            nil
          ] do
        assert {:error, :invalid} = Citation.check(two, [abc()], policy)
      end
    end
  end

  describe "7 errors in the fixed order" do
    test "each input with two faults gives the earlier rule" do
      assert {:error, :invalid} = Citation.check(%{"text" => 1}, [%{item_id: "x"}], @open)

      bad_among_33 = answer(letters(32) ++ [%{"item_id" => "abc"}])
      assert {:error, :malformed} = Citation.check(bad_among_33, [abc()], @open)

      assert {:error, :too_many} =
               Citation.check(answer(letters(32) ++ [cite("abc", "a")]), [abc()], @open)

      assert {:error, :duplicate} =
               Citation.check(answer([cite("zzz", "a"), cite("zzz", "a")]), [abc()], @open)

      assert {:error, :unknown_item} =
               Citation.check(answer([cite("abc", "not here"), cite("zzz", "a")]), [abc()], @open)

      assert {:error, :quote_not_found} =
               Citation.check(answer([cite("abc", "not here")]), [abc()], %{min_citations: 2})
    end
  end

  describe "8 host input" do
    test "0 items with no citations is accepted; 256 items are accepted" do
      assert {:ok, %{citations: []}} = Citation.check(answer([]), [], @open)
      items = for i <- 1..256, do: item("i#{i}", "x")

      assert {:ok, %{citations: [%{item_id: "i256"}]}} =
               Citation.check(answer([cite("i256", "x")]), items, @open)
    end

    test "each bad item list is invalid" do
      ok = item("a", "text")
      big = 2 ** 53 - 1

      bad_lists = [
        for(i <- 1..257, do: item("i#{i}", "x")),
        [ok, item("a", "other")],
        [item("", "x")],
        [item(String.duplicate("i", 1025), "x")],
        [item(<<0xFF>>, "x")],
        [item("a", "x", %{source: ""})],
        [item("a", "x", %{source: String.duplicate("s", 1025)})],
        [item("a", "x", %{source: <<0xFF>>})],
        [item("a", "x", %{version: 0})],
        [item("a", "x", %{version: 2 ** 31})],
        [item("a", "x", %{version: 1.0})],
        [item("a", "x", %{start_byte: -1})],
        [item("a", "x", %{start_byte: 1.0})],
        [item("a", "abcde", %{start_byte: big - 4})],
        [item("a", "x", %{marker: true})],
        [Map.delete(ok, :source)],
        [Map.new(ok, fn {k, v} -> {Atom.to_string(k), v} end)],
        [item("a", :not_binary)],
        [item("a", :binary.copy("c", 1_048_577))],
        for(i <- 1..9, do: item("i#{i}", :binary.copy("c", 1_048_576))),
        [ok | :improper],
        [:not_a_map],
        %{},
        nil
      ]

      for items <- bad_lists do
        assert {:error, :invalid} = Citation.check(answer([]), items, @open)
      end
    end

    test "edges that are accepted" do
      big = 2 ** 53 - 1
      max = :binary.copy("c", 1_048_576)

      for items <- [
            [item("a", "abcd", %{start_byte: big - 4})],
            [item(String.duplicate("i", 1024), "x", %{source: String.duplicate("s", 1024)})],
            [item("a", "x", %{version: 2 ** 31 - 1})],
            [item("a", max)],
            for(i <- 1..8, do: item("i#{i}", max)),
            [item("a", <<0xFF, 0x00>>)]
          ] do
        assert {:ok, %{citations: []}} = Citation.check(answer([]), items, @open)
      end

      assert {:ok,
              %{citations: [%{start_byte: 9_007_199_254_740_989, end_byte: 9_007_199_254_740_991}]}} =
               Citation.check(
                 answer([cite("a", "cd")]),
                 [item("a", "abcd", %{start_byte: big - 4})],
                 @open
               )
    end
  end

  describe "9 untrusted terms" do
    test "junk answers are malformed without a raise" do
      junk = [
        [],
        ["text", "citations"],
        {"text", []},
        %{text: "t", citations: []},
        %{"text" => "t", "citations" => [cite("abc", "a") | :improper]},
        %{"text" => "t", "citations" => [:not_a_map]},
        %{"text" => "t", "citations" => [{"abc", "a"}]},
        %{"text" => "t", "citations" => [cite("abc", 1)]},
        %{"text" => "t", "citations" => [cite("abc", ~c"a")]},
        %{"text" => "t", "citations" => [cite(:abc, "a")]},
        %{"text" => "t", "citations" => [%{item_id: "abc", quote: "a"}]},
        %{"text" => "t", "citations" => %{}},
        %{"text" => "t", "citations" => nil},
        %{"text" => "t"},
        %{"text" => "t", "citations" => [], "extra" => 1},
        %URI{},
        nil,
        self(),
        make_ref(),
        fn -> :ok end,
        <<0xFF>>
      ]

      for term <- junk do
        assert {:error, :malformed} = Citation.check(term, [abc()], @open)
      end
    end

    test "no argument raises and every error is a bare fixed atom" do
      secret = "SECRET-#{System.unique_integer([:positive])}"
      items = [item(secret, secret <> " content")]

      terms = [
        nil,
        [],
        {},
        %{},
        1,
        -1,
        1.5,
        :atom,
        secret,
        <<0xFF>>,
        self(),
        [secret | secret],
        %{min_citations: secret},
        answer([cite(secret, secret <> "!")]),
        answer([cite(secret <> "x", secret)]),
        answer([cite(secret, secret), cite(secret, secret)]),
        answer([cite(secret, "absent")]),
        items,
        @open
      ]

      for a <- terms, i <- [items | terms], p <- [@open, %{min_citations: 2} | terms] do
        result = Citation.check(a, i, p)

        case result do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            assert reason in @reasons
            refute inspect(result) =~ secret
        end
      end
    end
  end

  describe "10 example" do
    test "examples/citation.exs: two items, an accepted answer and a refused fabricated quote" do
      {result, _} = Code.eval_file(Path.expand("../../examples/citation.exs", __DIR__))

      assert result == %{
               cited: [
                 %{
                   item_id: "chunk-7",
                   source: "handbook/refunds",
                   version: 12,
                   start_byte: 4113,
                   end_byte: 4127
                 },
                 %{
                   item_id: "note-1",
                   source: "notes/onboarding",
                   version: 3,
                   start_byte: 7,
                   end_byte: 18
                 }
               ],
               refused: {:error, :quote_not_found}
             }
    end
  end
end
