defmodule Elzoo.TextChunkingTest do
  @moduledoc """
  Named scenarios for `integration/text-chunking` (ELZ-081). Finite tests over listed and
  seeded generated inputs; no proof is claimed. Scenario names follow docs/work/ELZ-081.md.
  """
  use ExUnit.Case, async: true

  alias Elzoo.TextChunking

  defp sha(bytes), do: :crypto.hash(:sha256, bytes)

  defp chunk(source, opts \\ []), do: TextChunking.chunk(source, sha(source), "doc:1", opts)

  # Asserts invariants (a)-(d) and the content digest (b) for one result.
  defp assert_invariants(source, %{chunks: chunks} = result) do
    assert result.source_bytes == byte_size(source)
    assert result.source_digest == sha(source)
    assert chunks != []
    assert hd(chunks).start_byte == 0

    chunks
    |> Enum.with_index()
    |> Enum.reduce(0, fn {c, i}, previous_start ->
      assert c.index == i
      assert 0 <= c.start_byte and c.start_byte < c.end_byte and c.end_byte <= byte_size(source)
      assert binary_part(source, c.start_byte, c.end_byte - c.start_byte) == c.content
      assert c.content_digest == sha(c.content)
      assert c.start_byte >= previous_start
      c.start_byte
    end)
  end

  # Fixed-seed generator over mixed ASCII, multi-byte UTF-8, ZWJ emoji, combining marks,
  # CRLF and the markdown and plaintext separators.
  @alphabet [
    "a", "b", "c", "word", " ", "  ", "\n", "\n\n", "\t", "\r\n",
    "é", "ß", "日本語", "🙂", "👩‍👩‍👧", "é", "## ", "\n## ", "\n### ", "```\n\n", "\n\n---\n\n"
  ]

  defp generate(state, units) do
    Enum.map_reduce(1..units, state, fn _, s ->
      {i, s} = :rand.uniform_s(length(@alphabet), s)
      {Enum.at(@alphabet, i - 1), s}
    end)
    |> then(fn {parts, s} -> {IO.iodata_to_binary(parts), s} end)
  end

  describe "T1 seeded generator: offsets and digests" do
    test "every chunk of every generated input reproduces its bytes and digest" do
      state = :rand.seed_s(:exsss, {81, 154, 2026})

      {count, _state} =
        Enum.reduce(1..400, {0, state}, fn _, {count, s} ->
          {units, s} = :rand.uniform_s(2000, s)
          {source, s} = generate(s, units)
          {size_pick, s} = :rand.uniform_s(4, s)
          chunk_size = Enum.at([16, 40, 200, 2000], size_pick - 1)
          {overlap, s} = :rand.uniform_s(div(chunk_size, 2) + 1, s)
          {fmt, s} = :rand.uniform_s(2, s)
          format = Enum.at([:plaintext, :markdown], fmt - 1)
          opts = [chunk_size: chunk_size, chunk_overlap: overlap - 1, format: format]

          assert {:ok, result} = chunk(source, opts)
          assert_invariants(source, result)
          # Observed upstream properties the pre-check relies on (not claimed to callers).
          assert Enum.all?(result.chunks, &(String.length(&1.content) <= chunk_size))
          assert covered?(result.chunks, byte_size(source))
          {count + length(result.chunks), s}
        end)

      assert count > 1000
    end
  end

  defp covered?(chunks, size) do
    Enum.reduce_while(chunks, 0, fn c, reach ->
      if c.start_byte <= reach, do: {:cont, max(reach, c.end_byte)}, else: {:halt, -1}
    end) == size
  end

  test "T2 equal inputs give equal outputs" do
    source = String.duplicate("Alpha beta gamma.\n\nDelta 🙂 epsilon é. ", 400)
    opts = [chunk_size: 100, chunk_overlap: 20, format: :markdown]
    assert {:ok, first} = chunk(source, opts)
    assert {:ok, ^first} = chunk(source, opts)
    assert_invariants(source, first)
  end

  describe "T3 fixed cases" do
    test "leading and trailing whitespace, separator-only text and a single grapheme" do
      for source <- ["   lead and trail   ", "\n\n\n\n", "    ", "x", "👩‍👩‍👧", "\r\n\r\n", "a\n"] do
        assert {:ok, result} = chunk(source, chunk_size: 16, chunk_overlap: 0)
        assert_invariants(source, result)
      end
    end

    test "overlap 0 and the maximum overlap" do
      source = String.duplicate("lorem ipsum dolor sit amet ", 200)

      for overlap <- [0, 50] do
        assert {:ok, result} = chunk(source, chunk_size: 100, chunk_overlap: overlap)
        assert_invariants(source, result)
      end
    end

    test "a source exactly at the bound is accepted, one byte more is refused" do
      source = String.duplicate("abcd ", 20)
      assert {:ok, result} = chunk(source, max_source_bytes: byte_size(source))
      assert_invariants(source, result)
      assert {:error, :source_too_large} = chunk(source, max_source_bytes: byte_size(source) - 1)
    end

    test "defaults are the declared ones" do
      limits = TextChunking.limits()
      assert limits.max_source_bytes == %{default: 1_048_576, min: 1, max: 1_048_576}
      assert limits.chunk_size == %{default: 2000, min: 16, max: 65_536}
      assert limits.chunk_overlap.default == 200
      assert limits.format == %{default: :plaintext, allowed: [:plaintext, :markdown]}
      assert limits.max_chunks == %{default: 4096, min: 1, max: 65_536}

      source = String.duplicate("x", 5000)
      assert {:ok, %{chunks: chunks}} = chunk(source)
      assert Enum.all?(chunks, &(String.length(&1.content) <= 2000))
      assert {:error, :source_too_large} = chunk(String.duplicate("x", 1_048_577))
    end

    test "the source reference and digest are echoed" do
      source = "hello world"

      assert {:ok, %{source_ref: "s3://bucket/key ✓", source_digest: digest}} =
               TextChunking.chunk(source, sha(source), "s3://bucket/key ✓")

      assert digest == sha(source)
    end
  end

  describe "T4 every error reason is returned without raising and without bytes" do
    @secret "SECRET-SOURCE-BYTES"

    test "the declared reasons" do
      good = @secret <> " text"
      bad_utf8 = @secret <> <<0xFF, 0xFE>>

      cases = [
        {TextChunking.chunk(good, sha("other"), "r"), :digest_mismatch},
        {TextChunking.chunk(bad_utf8, sha(bad_utf8), "r"), :invalid_utf8},
        {TextChunking.chunk("", sha(""), "r"), :empty_source},
        {TextChunking.chunk(good, sha(good), "r", max_source_bytes: 4), :source_too_large},
        {TextChunking.chunk(String.duplicate(@secret, 10), sha(String.duplicate(@secret, 10)), "r",
           chunk_size: 16, chunk_overlap: 0, max_chunks: 2), :too_many_chunks}
      ]

      for {result, reason} <- cases do
        assert result == {:error, reason}
        refute inspect(result) =~ "SECRET"
      end
    end
  end

  describe "T5 a digest mismatch computes nothing" do
    test "the split is never reached and UTF-8 is not scanned" do
      bad_utf8 = <<0xFF, 0xFE, 0xFD>>
      split = fn _, _ -> flunk("split reached") end

      assert {:error, :digest_mismatch} =
               TextChunking.__chunk__(bad_utf8, sha("something else"), "r", [], split)

      assert {:error, :digest_mismatch} =
               TextChunking.__chunk__("valid text", sha("other"), "r", [], split)
    end
  end

  describe "T6 too_many_chunks" do
    test "the pre-check refuses before the split" do
      source = String.duplicate("x", 100)
      split = fn _, _ -> flunk("split reached") end

      assert {:error, :too_many_chunks} =
               TextChunking.__chunk__(source, sha(source), "r",
                 [chunk_size: 16, chunk_overlap: 0, max_chunks: 6], split)
    end

    test "the post-check refuses a result over the bound as a whole" do
      # 64 graphemes pass the pre-check for 4 * 16, but overlap forces more than 4 chunks.
      source = String.duplicate("x", 64)
      assert {:ok, %{chunks: chunks}} = chunk(source, chunk_size: 16, chunk_overlap: 8)
      assert length(chunks) > 4
      assert {:error, :too_many_chunks} = chunk(source, chunk_size: 16, chunk_overlap: 8, max_chunks: 4)

      assert {:ok, %{chunks: ^chunks}} =
               chunk(source, chunk_size: 16, chunk_overlap: 8, max_chunks: length(chunks))
    end
  end

  describe "T7 an upstream offset violation is refused whole (chunker_invariant)" do
    @source "hello brave new world"

    defp with_upstream(chunks) do
      TextChunking.__chunk__(@source, sha(@source), "r", [], fn _, _ -> chunks end)
    end

    defp c(s, e, text), do: %TextChunker.Chunk{start_byte: s, end_byte: e, text: text}

    test "a well-formed upstream result passes through the seam" do
      assert {:ok, %{chunks: [_, _]}} = with_upstream([c(0, 11, "hello brave"), c(6, 21, "brave new world")])
    end

    test "each violation" do
      for bad <- [
            [c(0, 5, "hellx")],
            [c(0, 6, "hello")],
            [c(1, 5, "ello")],
            [c(0, 0, "")],
            [c(0, 5, "hello"), c(6, 6, "")],
            [c(6, 11, "brave"), c(0, 5, "hello")],
            [c(0, 5, "hello"), c(12, 15, "new"), c(6, 11, "brave")],
            [c(0, 22, @source <> "!")],
            [c(-1, 5, "hello")],
            [%{start_byte: 0, end_byte: 5}],
            [],
            :not_a_list
          ] do
        assert with_upstream(bad) == {:error, :chunker_invariant}, inspect(bad)
      end
    end
  end

  describe "T8 invalid options and inputs" do
    test "each invalid option names itself" do
      s = "some text"

      cases = [
        {[chunk_size: 15], :chunk_size},
        {[chunk_size: 65_537], :chunk_size},
        {[chunk_size: "2000"], :chunk_size},
        {[chunk_size: 100, chunk_overlap: 51], :chunk_overlap},
        {[chunk_overlap: -1], :chunk_overlap},
        {[chunk_size: 100, chunk_overlap: 100], :chunk_overlap},
        {[format: :html], :format},
        {[format: "markdown"], :format},
        {[max_chunks: 0], :max_chunks},
        {[max_chunks: 65_537], :max_chunks},
        {[max_source_bytes: 0], :max_source_bytes},
        {[max_source_bytes: 1_048_577], :max_source_bytes},
        {[max_source_bytes: 8 * 1_048_576], :max_source_bytes},
        {[chunk_size: 100, chunk_size: 200], :chunk_size},
        {[get_chunk_size: &byte_size/1], :unknown_option},
        {[strategy: TextChunker.Strategies.RecursiveChunk], :unknown_option},
        {%{chunk_size: 100}, :opts},
        {[{"chunk_size", 100}], :opts},
        {[{:chunk_size, 100} | :improper], :opts},
        {:nope, :opts}
      ]

      for {opts, name} <- cases do
        result = TextChunking.chunk(s, sha(s), "r", opts)
        assert result == {:error, {:invalid_option, name}}, inspect(opts)
      end
    end

    test "malformed positional inputs" do
      s = "some text"
      assert {:error, {:invalid_option, :source}} = TextChunking.chunk(~c"text", sha(s), "r")
      assert {:error, {:invalid_option, :source_digest}} = TextChunking.chunk(s, binary_part(sha(s), 0, 31), "r")
      assert {:error, {:invalid_option, :source_digest}} = TextChunking.chunk(s, nil, "r")
      assert {:error, {:invalid_option, :source_ref}} = TextChunking.chunk(s, sha(s), "")
      assert {:error, {:invalid_option, :source_ref}} = TextChunking.chunk(s, sha(s), String.duplicate("r", 1025))
      assert {:error, {:invalid_option, :source_ref}} = TextChunking.chunk(s, sha(s), <<0xFF>>)
      assert {:error, {:invalid_option, :source_ref}} = TextChunking.chunk(s, sha(s), :ref)
      assert {:ok, _} = TextChunking.chunk(s, sha(s), String.duplicate("r", 1024))
    end
  end

  test "T9 the Recipe calls no I/O, process, environment or telemetry module" do
    {:ok, {_, [imports: imports]}} =
      :beam_lib.chunks(:code.which(Elzoo.TextChunking), [:imports])

    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    # :elixir_erl_pass is the compiler's helper for map dot access (`config.chunk_size`).
    allowed = [:crypto, :elixir_erl_pass, :erlang, Enum, Keyword, String, TextChunker]
    assert called -- allowed == [], inspect(called)
  end

  @tag timeout: 600_000
  test "T10 observation: the no-separator worst case at the default bound" do
    source = String.duplicate("x", TextChunking.limits().max_source_bytes.default)
    digest = sha(source)
    {micros, result} = :timer.tc(fn -> TextChunking.chunk(source, digest, "observation") end)
    assert {:ok, %{chunks: chunks} = ok} = result
    assert_invariants(source, ok)

    IO.puts(
      "ELZOO OBSERVATION text-chunking no-separator input=#{byte_size(source)} bytes of \"x\" " <>
        "options=defaults(chunk_size 2000, chunk_overlap 200, format plaintext) " <>
        "chunks=#{length(chunks)} wall_ms=#{div(micros, 1000)} schedulers=#{System.schedulers_online()}"
    )
  end
end
