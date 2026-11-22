defmodule Elzoo.DocumentParseTest do
  @moduledoc """
  Acceptance groups 1-12 of `integration/document-parse` (ELZ-333). Finite tests over listed
  and seeded generated inputs; no proof is claimed. Expected texts are written out by hand.
  Not async: group 11 changes the `:floki` application environment.
  """
  use ExUnit.Case, async: false

  alias Elzoo.DocumentParse

  @bom <<0xEF, 0xBB, 0xBF>>
  @mib 1_048_576
  @max 8_388_608
  @media_types ["text/plain", "text/markdown", "text/html"]
  @reasons [
    {:invalid_option, :bytes},
    {:invalid_option, :opts},
    {:invalid_option, :unknown_option},
    {:invalid_option, :max_bytes},
    :unsupported_media_type,
    :too_large,
    :invalid_utf8,
    :parse_failed,
    :unsupported_charset,
    :empty_text,
    :text_too_large
  ]

  defp sha(bytes), do: :crypto.hash(:sha256, bytes)

  defp text!(bytes, media_type, opts \\ []) do
    assert {:ok, %{text: text}} = result = DocumentParse.parse(bytes, media_type, opts)
    fits!(result)
    text
  end

  defp html(bytes), do: DocumentParse.parse(bytes, "text/html")
  defp html!(bytes), do: text!(bytes, "text/html")

  defp fits!({:ok, result}) do
    assert {:ok, _} =
             Elzoo.TextChunking.chunk(result.text, result.text_sha256, "doc", format: result.format)
  end

  # Every outcome is a result or one of the fixed errors.
  defp fixed!({:ok, %{text: text}}), do: assert(String.valid?(text) and text != "")
  defp fixed!({:error, reason}), do: assert(reason in @reasons, inspect(reason))

  describe "1 each media type" do
    test "plain text, Markdown and HTML give the result map" do
      assert DocumentParse.parse("hello\nworld", "text/plain") ==
               {:ok,
                %{
                  text: "hello\nworld",
                  format: :plaintext,
                  media_type: "text/plain",
                  source_sha256: sha("hello\nworld"),
                  text_sha256: sha("hello\nworld"),
                  parser: %{id: "integration/document-parse", version: 1, library: nil}
                }}

      assert {:ok, md} = DocumentParse.parse("# T\n\n*a*", "text/markdown")
      assert %{text: "# T\n\n*a*", format: :markdown, media_type: "text/markdown"} = md
      assert md.parser.library == nil

      assert DocumentParse.parse("<p>a</p>", "text/html") ==
               {:ok,
                %{
                  text: "a",
                  format: :plaintext,
                  media_type: "text/html",
                  source_sha256: sha("<p>a</p>"),
                  text_sha256: sha("a"),
                  parser: %{
                    id: "integration/document-parse",
                    version: 1,
                    library: "floki 0.38.5"
                  }
                }}
    end

    test "every other media type is unsupported" do
      for media_type <- [
            "text/HTML",
            "text/html; charset=utf-8",
            " text/html",
            "text/html ",
            "application/pdf",
            "",
            :html,
            nil,
            ~c"text/html"
          ] do
        assert DocumentParse.parse("<p>a</p>", media_type) == {:error, :unsupported_media_type}
      end
    end

    test "limits/0" do
      assert DocumentParse.limits() == %{
               max_bytes: %{default: 8_388_608, min: 1, max: 8_388_608},
               text_bytes: %{min: 1, max: 1_048_576},
               media_types: ["text/plain", "text/markdown", "text/html"]
             }
    end
  end

  describe "2 BOM and CR LF" do
    test "one BOM removed, CR LF to LF from the left, lone CR kept" do
      input = @bom <> "a\r\nb\rc"
      assert {:ok, result} = DocumentParse.parse(input, "text/plain")
      assert result.text == "a\nb\rc"
      assert result.source_sha256 == sha(input)
      assert result.text_sha256 == sha("a\nb\rc")

      assert text!("x\r\r\ny", "text/plain") == "x\r\ny"
      assert text!("x\r\r\ny", "text/markdown") == "x\r\ny"
      assert text!(@bom <> @bom <> "a", "text/plain") == @bom <> "a"
      assert text!(@bom <> "<p>x</p>", "text/html") == "x"
    end

    test "a lone BOM is empty text in every media type" do
      for media_type <- @media_types do
        assert DocumentParse.parse(@bom, media_type) == {:error, :empty_text}
      end
    end
  end

  describe "3 left-out text" do
    test "no sentinel from a left-out place reaches the text" do
      doc = """
      <html><head><title>T</title><meta name="d" content="SENTcontent">
      SENThead<style>SENTstyle</style><link href="SENThref"><p>headp</p></head>
      <body><script>SENTscript</script><template><p>SENTtemplate</p></template>
      <noscript><p>SENTnoscript</p></noscript><!-- SENTcomment --><?SENTpi x="SENTpiattr"?>
      <p><img alt="SENTalt" title="SENTtitle"><a href="SENThref2">link</a> v</p></body></html>
      """

      # The `p` in head starts the body: it is read as body content.
      assert html!(doc) == "T\n\nheadp\n\nlink v"
    end

    test "head keeps only title until an element that is not head content starts the body" do
      # The bundled parser does not close head at body or at body content.
      assert html!("<html><head><title>T</title><body><p>body text</p></body></html>") ==
               "T\n\nbody text"

      assert html!("<html><head><meta charset=utf-8><body><p>body text</p></body></html>") ==
               "body text"

      assert html!("<head><title>T</title><p>text</p>") == "T\n\ntext"
      # Text before the first such element is head text; every later sibling is body.
      assert html!("<head>x<meta><p>y</p>z<title>t</title><script>s</script></head>") ==
               "y\n\nz\n\nt"

      assert html!("<head><link><b>x</b></head>") == "x"
      # Comments, processing instructions and head content do not start the body.
      assert html(
               "<head><!-- c -->x<?p?>y<meta><link><base><style>s</style><noscript>n</noscript>z</head>"
             ) == {:error, :empty_text}

      assert html!("<head><template><p>t</p></template>w</head><p>b</p>") == "b"
    end

    test "head keeps only title; a title outside head is kept" do
      assert html!("<head><title>T</title></head><body><p>b</p></body>") == "T\n\nb"
      assert html!("<title>T</title><p>x</p>") == "T\n\nx"
      assert html!("<p>x</p><title>T</title>") == "x\n\nT"
      assert html!("<script><title>S</title></script><p>x</p>") == "x"
    end

    test "a script holding an end tag" do
      assert html!("<script>if (a < b) { '</p>' }</script><p>ok</p>") == "ok"
    end

    # Each place holds a sentinel; visible words sit in kept places. Well-formed shapes keep
    # every visible word; unclosed shapes may swallow the rest of the document.
    @well_formed [
      "<script>zzs@</script>",
      "<style>zzs@</style>",
      "<template><p>zzs@</p></template>",
      "<noscript><b>zzs@</b></noscript>",
      "<head><title>v@</title><meta content=\"zzs@\">zzh@<p>v@</p></head>",
      "<!-- zzs@ -->",
      "<?zzs@ a=\"zzs@\"?>",
      "<img alt=\"zzs@\" title=\"zzt@\">",
      "<a href=\"zzs@\">v@</a>",
      "<p>v@</p>",
      " v@ ",
      "<b>v@</b>",
      "<title>v@</title>",
      "<div><span>v@</span><script>zzs@</script></div>"
    ]
    # Unclosed elements can stand anywhere: what follows becomes their content. An unclosed
    # comment, processing instruction or attribute value stands only at the end: the tokenizer
    # reads the markup after it as part of it (as an HTML5 tokenizer reads `<?x<style>` as one
    # bogus comment), so a later `<style>` there is not a style element.
    @unclosed_elements [
      "<script>zzs@",
      "<style>zzs@",
      "<noscript>zzs@",
      "<template><p>zzs@",
      "<head><meta content=zzs@>zzh@",
      "<p>v@",
      "<b>v@"
    ]
    @unclosed_tails ["<!-- zzs@", "<?zzs@", "<?zzs@ a=zzs@", "<img alt='zzs@", "<p title=\"zzs@"]

    defp sample(pool, i, s) do
      {pick, s} = :rand.uniform_s(length(pool), s)
      {String.replace(Enum.at(pool, pick - 1), "@", Integer.to_string(i)), s}
    end

    test "seeded generator: no sentinel appears in well-formed or unclosed shapes" do
      state = :rand.seed_s(:exsss, {333, 3, 2026})

      Enum.reduce(1..600, state, fn round, s ->
        {count, s} = :rand.uniform_s(12, s)
        unclosed? = rem(round, 2) == 0
        pool = if unclosed?, do: @well_formed ++ @unclosed_elements, else: @well_formed
        {parts, s} = Enum.map_reduce(1..count, s, &sample(pool, &1, &2))
        {tail, s} = if unclosed?, do: sample(@unclosed_tails, count + 1, s), else: {"", s}
        parts = parts ++ [tail]

        doc = IO.iodata_to_binary(parts)

        case html(doc) do
          {:ok, %{text: text}} ->
            refute text =~ "zz", inspect({doc, text})

            unless unclosed? do
              for i <- 1..count,
                  Enum.at(parts, i - 1) =~ "v#{i}",
                  do: assert(text =~ ~r/\bv#{i}\b/, inspect({doc, text}))
            end

          {:error, :empty_text} ->
            :ok
        end

        s
      end)
    end
  end

  describe "4 blocks and whitespace" do
    test "listed cases" do
      assert html!("<div>a<p>b</p>c</div>") == "a\n\nb\n\nc"
      assert html!("<ul><li>1</li><li>2</li></ul>a<br>b") == "1\n\n2\n\na\n\nb"
      assert html!("<p><b>Hello</b> <i>world</i></p>") == "Hello world"
      assert html!("<a>one</a>\n<a>two</a>") == "one two"
      assert html!("<span>a</span><span>b</span>") == "a b"
      assert html!("<b>Hel</b>lo") == "Hello"
      assert html!("<b>Hel</b><!-- c -->lo") == "Hel lo"
      assert html!("<p>a <b>b</b> c</p>") == "a b c"
      assert html!("<p>one  two\n three</p>") == "one two three"
      assert html!("<p> </p><p>x</p>") == "x"
      assert html!("x&nbsp;y") == "x\u00A0y"
    end

    test "edges of the space and block rules" do
      # A left-out element still counts as a node that is not a text node.
      assert html!("<b>a</b><script>x</script><i>b</i>") == "a b"
      # Every block of the set breaks, also in a table and in the head.
      assert html!("<table><tr><td>a</td><td>b</td></tr></table>") == "a\n\nb"
      assert html!("<h1>t</h1><h6>u</h6><pre>p  q\n r</pre>") == "t\n\nu\n\np q r"
      # The space rule applies among the children of any element, head included.
      assert html!("a<head><meta><meta></head>b") == "a b"
      # Tab, line feed, form feed and carriage return collapse; U+00A0 does not.
      assert html!("<p>\ta\n\f\rb \u00A0 c</p>") == "a b \u00A0 c"
      assert html!("<p>a\r\nb</p>") == "a b"
    end
  end

  describe "5 entities" do
    test "decoded as the parser decodes them in HTML, never in plain text or Markdown" do
      assert html!("<p>a&amp;b &eacute; &#x1F600; &#xD800; &bogus;</p>") ==
               "a&b é 😀 \u{FFFD} &bogus;"

      assert text!("a&amp;b", "text/plain") == "a&amp;b"
      assert text!("a&amp;b", "text/markdown") == "a&amp;b"
      # Title and textarea are raw text to the bundled parser.
      assert html!("<title>a&amp;b</title>") == "a&amp;b"
    end
  end

  describe "6 malformed HTML" do
    test "a result or empty text, never a parse failure" do
      assert html!("<p>unclosed <b>bold <i>it") == "unclosed bold it"
      assert html!("<p>a</p></div><p>b</p>") == "a\n\nb"
      assert html!("<p>a<!-- unclosed") == "a"
      assert html!("<p hidden>x</p>") == "x"
      assert html("<?>x") == {:error, :empty_text}
      assert html!("<?x = ?><p>y</p>") == "y"
      assert html!(<<"<p ", 0xC3, 0x89, "=1>z</p>">>) == "z"
      # Markup that an unclosed processing instruction takes in is no element: the style tag
      # below is part of the instruction, so its content is a text node (a stated limit).
      assert html!("<?x<style>s</style>") == "s"
    end

    test "inputs that would end the document early are refused" do
      for doc <- [
            "<p>a</p></floki><p>b</p>",
            "<p>a</p></FLOKI ><p>b</p>",
            "<p>a</p></FlOkI\n><p>b</p>",
            "<p>a</p></flokix><p>b</p>",
            "<p>a</p></floki",
            "<p>a</p></flo&#107;i><p>b</p>",
            "<p>a</p></&#102;loki><p>b</p>",
            "<p>a</p></flo&#x6B;i><p>b</p>",
            "<p>a</p></p&amp;><p>b</p>",
            "<p>a</p></p&><p>b</p>",
            "<p>a</p></x</p&><p>b</p>",
            "<p>a</p></x&",
            "<p>a</p></>b<p>c</p>",
            "<p>a</p></>rest"
          ] do
        assert html(doc) == {:error, :parse_failed}, doc
      end
    end

    test "near misses of the end-tag rule are accepted" do
      assert html!("<p>a&lt;/floki&gt;</p>") == "a</floki>"
      assert html!("<p>a & b</p>") == "a & b"
      assert html!("<p>a</p></ floki><p>b</p>") == "a\n\nb"
      # The name ends at whitespace, `>`, `/` or `=`; a later `&` is not in it.
      assert html!("<p>a</p></p x&y><p>b</p>") == "a\n\nb"
      assert html!("<p>a</p></p>&amp;<p>b</p>") == "a\n\n&\n\nb"
      assert html!("<p>a</p></p/&><p>b</p>") == "a\n\nb"
      assert html!("<p>a</p></p=&><p>b</p>") == "a\n\nb"
      # Only the exact bytes `</>` are refused.
      assert html!("<p>a</p></ >b<p>c</p>") == "a\n\nb\n\nc"
      assert html!("<p>a</p><//>b<p>c</p>") == "a\n\nb\n\nc"

      for ws <- ["\t", "\n", "\f", "\r", " "],
          do: assert(html!("<p>a</p></p#{ws}&><p>b</p>") == "a\n\nb", inspect(ws))
    end

    test "an unclosed title or textarea that takes in the parser's wrapper is refused" do
      for doc <- [
            "<title>abc",
            "<p>a</p><textarea>x",
            "<head><title>abc",
            "<title>x</title",
            "<title>a</title><title>b",
            "<template><textarea>x"
          ] do
        assert html(doc) == {:error, :parse_failed}, doc
      end

      assert html!("<title>abc</title>") == "abc"
      assert html!("<p>a</p><textarea>x</textarea>") == "a\n\nx"
      assert html!("<textarea>a&lt;/floki&gt;</textarea>") == "a&lt;/floki&gt;"
    end
  end

  describe "7 charset" do
    test "declarations that are not UTF-8 are refused" do
      for doc <- [
            ~s(<meta charset="windows-1252"><p>a</p>),
            ~s(<meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1"><p>a</p>),
            ~s(<meta charset=utf-8><meta charset=latin1><p>a</p>),
            ~s(<meta charset=utf-8 charset=latin1><p>a</p>),
            ~s(<meta charset="utf-8;"><p>a</p>),
            ~s(<meta charset="utf-16"><p>a</p>),
            ~s(<noscript><meta charset=latin1></noscript><p>a</p>),
            ~s(<meta http-equiv=CONTENT-TYPE content="text/html; CHARSET=koi8-r"><p>a</p>),
            ~s(<meta charset=utf-8<p>a</p>),
            # Only the first charset= of content is read.
            ~s(<meta http-equiv="content-type" content="text/html; charset=latin1; charset=utf-8">a)
          ] do
        assert html(doc) == {:error, :unsupported_charset}, doc
      end
    end

    test "UTF-8 declarations and none are accepted" do
      for doc <- [
            ~s(<META CHARSET="UTF-8"><p>a</p>),
            ~s(<meta charset=utf8><p>a</p>),
            ~s(<meta charset=" utf-8 "><p>a</p>),
            ~s(<meta http-equiv="content-type" content="text/html; charset='utf-8'"><p>a</p>),
            ~s(<meta http-equiv="Content-Type" content='text/html;charset="UTF8";x=y'><p>a</p>),
            # Without http-equiv content-type, content is not a declaration.
            ~s(<meta content="text/html; charset=latin1"><p>a</p>),
            ~s(<meta http-equiv="refresh" content="charset=latin1"><p>a</p>),
            ~s(<meta http-equiv="content-type" content="text/html; charset=utf-8; charset=latin1">a),
            # Only meta declarations are read.
            ~s(<?xml version="1.0" encoding="latin1"?><p>a</p>),
            "<p>a</p>"
          ] do
        assert html!(doc) == "a", doc
      end
    end

    test "UTF-8 is checked before the charset, and a parse failure before it too" do
      assert html("caf" <> <<0xE9>> <> ~s(<meta charset="windows-1252">)) ==
               {:error, :invalid_utf8}

      for media_type <- @media_types do
        assert DocumentParse.parse(<<0xFF, 0xFE>> <> "<p>x</p>", media_type) ==
                 {:error, :invalid_utf8}
      end

      assert html(~s(<meta charset=latin1><p>a</p></floki>)) == {:error, :parse_failed}
      assert html(~s(<meta charset=latin1><title>a)) == {:error, :parse_failed}
      # A declaration that is not UTF-8 reports before empty text.
      assert html("<meta charset=latin1>") == {:error, :unsupported_charset}
      assert html("<meta charset=latin1><script>x</script>") == {:error, :unsupported_charset}
    end
  end

  defp html_of_size(size), do: "<p>hi</p><!--" <> String.duplicate("x", size - 16) <> "-->"

  describe "8 bounds" do
    test "the 8 MiB input bound" do
      at = html_of_size(@max)
      assert byte_size(at) == @max
      {micros, result} = :timer.tc(fn -> html(at) end)
      assert {:ok, %{text: "hi"}} = result
      fits!(result)
      assert html(html_of_size(@max + 1)) == {:error, :too_large}

      assert DocumentParse.parse(String.duplicate("a", @max + 1), "text/plain") ==
               {:error, :too_large}

      IO.puts(
        "ELZOO OBSERVATION document-parse 8MiB-comment input=#{@max} bytes " <>
          "wall_ms=#{div(micros, 1000)} schedulers=#{System.schedulers_online()}"
      )
    end

    test "max_bytes narrows the bound" do
      for media_type <- @media_types do
        assert {:ok, _} =
                 result =
                 DocumentParse.parse(String.duplicate("a", 100), media_type, max_bytes: 100)

        fits!(result)

        assert DocumentParse.parse(String.duplicate("a", 101), media_type, max_bytes: 100) ==
                 {:error, :too_large}
      end

      assert text!("a", "text/plain", max_bytes: 1) == "a"
    end

    test "bad options" do
      for {opts, name} <- [
            {[max_bytes: 0], :max_bytes},
            {[max_bytes: @max + 1], :max_bytes},
            {[max_bytes: 1.0], :max_bytes},
            {[max_bytes: nil], :max_bytes},
            {[max_bytes: 5, max_bytes: 5], :max_bytes},
            {[foo: 1], :unknown_option},
            {[max_bytes: 5, foo: 1], :unknown_option},
            {%{max_bytes: 5}, :opts},
            {[{:max_bytes, 5} | :tail], :opts},
            {[{"max_bytes", 5}], :opts},
            {[:max_bytes], :opts},
            {:nope, :opts}
          ] do
        assert DocumentParse.parse("a", "text/plain", opts) == {:error, {:invalid_option, name}},
               inspect(opts)
      end
    end

    test "the 1 MiB text bound" do
      at = String.duplicate("a", @mib)
      assert {:ok, %{text: ^at}} = result = DocumentParse.parse(at, "text/plain")
      fits!(result)

      assert DocumentParse.parse(at <> "a", "text/plain") == {:error, :text_too_large}
      assert DocumentParse.parse(at <> "a", "text/markdown") == {:error, :text_too_large}
      assert html("<p>" <> at <> "a</p>") == {:error, :text_too_large}

      assert {:ok, %{text: ^at}} = bom_result = DocumentParse.parse(@bom <> at, "text/plain")
      fits!(bom_result)
      crlf = String.duplicate("a", @mib - 1) <> "\r\n"
      assert byte_size(crlf) == @mib + 1
      assert {:ok, %{text: text}} = result = DocumentParse.parse(crlf, "text/plain")
      assert byte_size(text) == @mib
      fits!(result)
    end

    test "an empty input is empty text in every media type" do
      for media_type <- @media_types do
        assert DocumentParse.parse("", media_type) == {:error, :empty_text}
      end

      assert html("<script>x</script><!-- c -->   ") == {:error, :empty_text}
    end
  end

  describe "9 fit with integration/text-chunking" do
    test "accepted results of groups 1 and 4 chunk as they are" do
      for {bytes, media_type} <- [
            {"hello\nworld", "text/plain"},
            {"# T\n\n*a*", "text/markdown"},
            {"<p>a</p>", "text/html"},
            {"<div>a<p>b</p>c</div>", "text/html"},
            {"<ul><li>1</li><li>2</li></ul>a<br>b", "text/html"},
            {"<p><b>Hello</b> <i>world</i></p>", "text/html"},
            {"x&nbsp;y", "text/html"},
            {@bom <> "a\r\nb\rc", "text/plain"}
          ] do
        fits!(DocumentParse.parse(bytes, media_type))
      end
    end
  end

  describe "10 never a raise" do
    test "junk terms in every argument give fixed errors in rule order" do
      for bytes <- [nil, 1, :a, ~c"abc", {"a"}, ["a"], %{}] do
        assert DocumentParse.parse(bytes, "text/plain") == {:error, {:invalid_option, :bytes}}
        # Two faults: the first rule wins.
        assert DocumentParse.parse(bytes, nil, :bad) == {:error, {:invalid_option, :bytes}}
      end

      assert DocumentParse.parse("a", nil, :bad) == {:error, {:invalid_option, :opts}}
      assert DocumentParse.parse("a", nil, max_bytes: 0) == {:error, {:invalid_option, :max_bytes}}

      assert DocumentParse.parse(<<0xFF, 0xFF>>, "x", max_bytes: 1) ==
               {:error, :unsupported_media_type}

      assert DocumentParse.parse(<<0xFF, 0xFF>>, "text/plain", max_bytes: 1) ==
               {:error, :too_large}

      assert DocumentParse.parse(<<0xFF>> <> "</floki>", "text/html") == {:error, :invalid_utf8}
    end

    test "seeded random bytes" do
      state = :rand.seed_s(:exsss, {333, 10, 1})

      Enum.reduce(1..1500, state, fn _, s ->
        {size, s} = :rand.uniform_s(300, s)
        {bytes, s} = :rand.bytes_s(size, s)
        for media_type <- @media_types, do: fixed!(DocumentParse.parse(bytes, media_type))
        s
      end)
    end

    @units [
      "<p>",
      "</p>",
      "<div>",
      "</div>",
      "<b>",
      "</b>",
      "<title>",
      "</title>",
      "<textarea>",
      "<script>",
      "</script>",
      "<style>",
      "<head>",
      "</head>",
      "<meta charset=utf-8>",
      "<meta charset=latin1>",
      "<br>",
      "<!-- ",
      " -->",
      "<?pi a=b?>",
      "<?",
      "<!DOCTYPE html>",
      "<![CDATA[",
      "]]>",
      "&amp;",
      "&eacute;",
      "&#x1F600;",
      "&#xD800;",
      "&#0;",
      "&bogus;",
      "&",
      "<",
      ">",
      "</",
      "</floki>",
      "</p&>",
      "=",
      "\"",
      "'",
      " ",
      "\n",
      "\r\n",
      "\t",
      "word",
      "é",
      "日本",
      "🙂",
      "\u00A0",
      @bom,
      "<a href='",
      "<img alt=x>"
    ]

    test "seeded valid UTF-8 over HTML tags, entities, comments and text" do
      state = :rand.seed_s(:exsss, {333, 10, 2})

      outcomes =
        Enum.map_reduce(1..2000, state, fn _, s ->
          {count, s} = :rand.uniform_s(40, s)

          {parts, s} =
            Enum.map_reduce(1..count, s, fn _, s ->
              {i, s} = :rand.uniform_s(length(@units), s)
              {Enum.at(@units, i - 1), s}
            end)

          doc = IO.iodata_to_binary(parts)
          result = html(doc)
          fixed!(result)
          if match?({:ok, _}, result), do: fits!(result)
          {elem(result, 0) == :ok or elem(result, 1), s}
        end)
        |> elem(0)
        |> Enum.frequencies()

      # The generator reaches accepted results and several refusals, not only one path.
      assert outcomes[true] > 100
      assert outcomes[:parse_failed] > 100
      assert outcomes[:unsupported_charset] > 10
    end

    @tag timeout: 300_000
    test "deeply nested HTML up to 8 MiB" do
      n = div(@max - 1, 5)
      deep = String.duplicate("<div>", n) <> "x"
      assert byte_size(deep) <= @max
      {micros, result} = :timer.tc(fn -> html(deep) end)
      assert {:ok, %{text: "x"}} = result

      inline = String.duplicate("<b>", div(@max - 1, 3)) <> "x"
      {inline_micros, inline_result} = :timer.tc(fn -> html(inline) end)
      assert {:ok, %{text: "x"}} = inline_result

      IO.puts(
        "ELZOO OBSERVATION document-parse nested-div depth=#{n} input=#{byte_size(deep)} bytes " <>
          "wall_ms=#{div(micros, 1000)}; nested-b depth=#{div(@max - 1, 3)} " <>
          "wall_ms=#{div(inline_micros, 1000)} schedulers=#{System.schedulers_online()}"
      )
    end

    test "the seam: each failure of the parse function is a parse failure" do
      seam = fn fun -> DocumentParse.__parse__("<p>a</p>", "text/html", [], fun) end

      for fun <- [
            fn _ -> {:error, "x"} end,
            fn _ -> raise "boom" end,
            fn _ -> throw(:boom) end,
            fn _ -> exit(:boom) end,
            fn _ -> :ok end,
            fn _ -> {:ok, :not_a_list} end,
            fn _ -> {:ok, [{:weird}]} end,
            fn _ -> {:ok, [{:p, [], ["a"]}]} end,
            fn _ -> {:ok, [{"p", [], :not_a_list}]} end,
            fn _ -> {:ok, ["a" | :tail]} end,
            fn _ -> {:ok, [{"div", [], [{"p", [], [1]}]}]} end,
            fn _ -> {:ok, [{"p", [], [<<0xFF>>]}]} end
          ] do
        assert seam.(fun) == {:error, :parse_failed}
      end

      pi = fn _ -> {:ok, [{:pi, ~c"x", [{~c"=", ~c"="}]}, "t"]} end
      assert {:ok, %{text: "t"}} = seam.(pi)
      # Only text that goes into the text must be UTF-8; attributes are not read for shape.
      assert {:ok, %{text: "t"}} = seam.(fn _ -> {:ok, [{"script", [], [<<0xFF>>]}, "t"]} end)
      assert {:ok, %{text: "t"}} = seam.(fn _ -> {:ok, [{"meta", :junk, []}, "t"]} end)

      assert {:ok, %{text: "t"}} =
               seam.(fn _ -> {:ok, [{"meta", [{~c"charset", "latin1"} | :tail], []}, "t"]} end)
    end

    test "the seam: the parse is reached only for HTML that passes the earlier rules" do
      spy = fn bytes ->
        send(self(), {:parsed, bytes})
        Floki.parse_document(bytes, html_parser: Floki.HTMLParser.Mochiweb)
      end

      assert {:ok, %{text: "x"}} = DocumentParse.__parse__(@bom <> "<p>x</p>", "text/html", [], spy)
      assert_received {:parsed, "<p>x</p>"}

      for media_type <- ["text/plain", "text/markdown"] do
        assert {:ok, %{text: "<p>x</p>"}} = DocumentParse.__parse__("<p>x</p>", media_type, [], spy)
        refute_received {:parsed, _}
      end

      for {bytes, media_type} <- [
            {"<p>x</p></floki>", "text/html"},
            {"<p>x</p></p&amp;>", "text/html"},
            {<<0xFF>>, "text/html"}
          ] do
        assert {:error, _} = DocumentParse.__parse__(bytes, media_type, [], spy)
        refute_received {:parsed, _}
      end

      # The real parse function is the default of parse/3.
      for doc <- ["<p>a</p>", "<title>T</title><b>x</b><i>y</i>", "<p>a&amp;b</p>"] do
        real = &Floki.parse_document(&1, html_parser: Floki.HTMLParser.Mochiweb)
        assert html(doc) == DocumentParse.__parse__(doc, "text/html", [], real)
      end
    end

    test "no error holds a byte of the input" do
      secret = "s3cr3t"

      for {bytes, media_type, opts} <- [
            {secret <> "</floki>", "text/html", []},
            {~s(<meta charset="#{secret}">#{secret}), "text/html", []},
            {secret <> <<0xFF>>, "text/plain", []},
            {String.duplicate(secret, 10), "text/plain", [max_bytes: 5]},
            {secret, secret, []},
            {secret, "text/plain", [{String.to_atom(secret), 1}]}
          ] do
        assert {:error, reason} = DocumentParse.parse(bytes, media_type, opts)
        refute inspect(reason) =~ secret
      end
    end
  end

  defmodule RaisingParser do
    @moduledoc false
    def parse_document(_html, _args), do: raise("the host's parser was called")
    def parse_fragment(_html, _args), do: raise("the host's parser was called")
    def parse_document_with_attributes_as_maps(_html, _args), do: raise("called")
    def parse_fragment_with_attributes_as_maps(_html, _args), do: raise("called")
  end

  describe "11 configuration does not leak in" do
    setup do
      previous = Application.fetch_env(:floki, :html_parser)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:floki, :html_parser, value)
          :error -> Application.delete_env(:floki, :html_parser)
        end
      end)
    end

    test "a host's :floki :html_parser setting does not change the result" do
      Application.put_env(:floki, :html_parser, RaisingParser)
      assert_raise RuntimeError, fn -> Floki.parse_document("<p>a</p>") end
      assert html!("<p>a</p>") == "a"
    end

    test "the loaded floki is the version parser.library names" do
      Application.load(:floki)
      assert Application.spec(:floki, :vsn) == ~c"0.38.5"
      assert {:ok, %{parser: %{library: "floki 0.38.5"}}} = html("<p>a</p>")
    end
  end

  describe "12 example" do
    test "examples/document_parse.exs: an HTML page with a script, parsed and chunked" do
      {result, _} = Code.eval_file(Path.expand("../../examples/document_parse.exs", __DIR__))

      text =
        "Refund policy\n\nRefunds\n\nRefunds are paid within 14 days.\n\n" <>
          "Keep the receipt.\n\nAsk the help desk."

      assert result == %{
               text: text,
               parser: %{id: "integration/document-parse", version: 1, library: "floki 0.38.5"},
               chunks: [text]
             }
    end
  end

  # The audit reads exactly the lib sources the Piece manifest lists. The manifest sits next to
  # the Piece directory in the repository and under .elzoo/pieces/<id>/ in an exported
  # consumer; in both layouts the listed files are relative to the directory two levels up.
  @piece_id "integration/document-parse"

  test "the manifest's lib sources call no I/O, process, environment or telemetry module" do
    root = Path.expand("../..", __DIR__)

    [path] =
      [
        Path.join(root, "piece.json"),
        Path.join([root, ".elzoo", "pieces", @piece_id, "piece.json"])
      ]
      |> Enum.filter(&File.regular?/1)

    manifest = :json.decode(File.read!(path))
    assert manifest["id"] == @piece_id
    lib_files = Enum.filter(manifest["files"], &String.starts_with?(&1, "lib/"))
    assert lib_files == ["lib/elzoo/document_parse.ex"]

    # :elixir_erl_pass is the compiler's helper for map dot access.
    # Exception (from rescue) and :lists are pure helpers the compiler calls.
    allowed = [
      :binary,
      :crypto,
      :elixir_erl_pass,
      :erlang,
      :lists,
      Enum,
      Exception,
      Floki,
      Keyword,
      String
    ]

    module = Elzoo.DocumentParse
    assert to_string(module.module_info(:compile)[:source]) == Path.join(root, hd(lib_files))
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    assert called -- allowed == [], inspect(called)
  end
end
