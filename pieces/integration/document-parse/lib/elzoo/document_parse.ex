defmodule Elzoo.DocumentParse do
  @moduledoc """
  Bounded text from untrusted document bytes (`integration/document-parse`).

  A pure parse of a closed media-type set (`text/plain`, `text/markdown`, `text/html`) into
  valid UTF-8 text of 1..1,048,576 bytes that `integration/text-chunking` takes as its source,
  with the raw SHA-256 of the input and of the text and a parser identity. HTML is parsed by
  `Floki.parse_document/2` (`floki` 0.38.5) with the bundled `Floki.HTMLParser.Mochiweb`
  named in the call.

  No I/O, clock, process, storage, network, transcoding or model call; the Piece reads no
  application environment itself. The output is untrusted content: the caller marks it. See
  the Piece README for the Contract and its limits.
  """

  @max_bytes_default 8_388_608
  @max_bytes_ceiling 8_388_608
  @text_bytes_max 1_048_576
  @media_types ["text/plain", "text/markdown", "text/html"]
  @option_names [:max_bytes]
  @library "floki 0.38.5"
  @bom <<0xEF, 0xBB, 0xBF>>

  @left_out ~w(script style template noscript)
  @raw_kept ~w(title textarea)
  # Head content: inside `head`, the first child element outside this set, and every later
  # sibling, is read as body content (the parser does not close `head` itself).
  @head_content ~w(title meta link base style script noscript template)
  @blocks ~w(address article aside blockquote br caption dd details dialog div dl dt fieldset
             figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p
             pre section summary table tbody td tfoot th thead title tr ul)
  # ASCII whitespace of the text rules: U+0009, U+000A, U+000C, U+000D and U+0020.
  @whitespace ["\t", "\n", "\f", "\r", " "]

  @type result :: %{
          text: String.t(),
          format: :plaintext | :markdown,
          media_type: String.t(),
          source_sha256: <<_::256>>,
          text_sha256: <<_::256>>,
          parser: %{id: String.t(), version: 1, library: String.t() | nil}
        }

  @type reason ::
          {:invalid_option, :bytes | :opts | :unknown_option | :max_bytes}
          | :unsupported_media_type
          | :too_large
          | :invalid_utf8
          | :parse_failed
          | :unsupported_charset
          | :empty_text
          | :text_too_large

  @doc "The declared default and ceiling of the input bound, the text bound and the media types."
  @spec limits() :: map()
  def limits do
    %{
      max_bytes: %{default: @max_bytes_default, min: 1, max: @max_bytes_ceiling},
      text_bytes: %{min: 1, max: @text_bytes_max},
      media_types: @media_types
    }
  end

  @doc """
  Parses `bytes` of `media_type` into bounded UTF-8 text.

  Options: `:max_bytes` (see `limits/0`). Returns `{:ok, result}` or `{:error, reason}`;
  never raises for any term in any argument.
  """
  @spec parse(term(), term(), term()) :: {:ok, result()} | {:error, reason()}
  def parse(bytes, media_type, opts \\ []) do
    __parse__(bytes, media_type, opts, &floki_parse/1)
  end

  # Test seam: the same pipeline with an injected HTML parse function, so the tests can drive
  # each failure path of the parse. The real parse function is the default of parse/3.
  @doc false
  def __parse__(bytes, media_type, opts, parse_fun) when is_function(parse_fun, 1) do
    with :ok <- check_bytes(bytes),
         {:ok, max_bytes} <- check_options(opts),
         :ok <- check_media_type(media_type),
         :ok <- check_size(bytes, max_bytes),
         :ok <- check_utf8(bytes),
         {:ok, text} <- extract(media_type, strip_bom(bytes), parse_fun),
         :ok <- check_text(text) do
      {:ok,
       %{
         text: text,
         format: if(media_type == "text/markdown", do: :markdown, else: :plaintext),
         media_type: media_type,
         source_sha256: :crypto.hash(:sha256, bytes),
         text_sha256: :crypto.hash(:sha256, text),
         parser: %{
           id: "integration/document-parse",
           version: 1,
           library: if(media_type == "text/html", do: @library, else: nil)
         }
       }}
    end
  end

  ## Rules 1-4

  defp check_bytes(bytes) when is_binary(bytes), do: :ok
  defp check_bytes(_bytes), do: {:error, {:invalid_option, :bytes}}

  defp check_options(opts) do
    cond do
      not keyword?(opts) ->
        {:error, {:invalid_option, :opts}}

      Enum.any?(opts, fn {key, _} -> key not in @option_names end) ->
        {:error, {:invalid_option, :unknown_option}}

      true ->
        # A repeated key is refused rather than resolved silently.
        case Keyword.get_values(opts, :max_bytes) do
          [] -> {:ok, @max_bytes_default}
          [n] when is_integer(n) and n >= 1 and n <= @max_bytes_ceiling -> {:ok, n}
          _invalid -> {:error, {:invalid_option, :max_bytes}}
        end
    end
  end

  # Walks the list by hand so an improper list is refused instead of raising.
  defp keyword?([]), do: true
  defp keyword?([{key, _value} | rest]) when is_atom(key), do: keyword?(rest)
  defp keyword?(_opts), do: false

  defp check_media_type(media_type) when media_type in @media_types, do: :ok
  defp check_media_type(_media_type), do: {:error, :unsupported_media_type}

  defp check_size(bytes, max_bytes) when byte_size(bytes) > max_bytes, do: {:error, :too_large}
  defp check_size(_bytes, _max_bytes), do: :ok

  defp check_utf8(bytes) do
    if String.valid?(bytes), do: :ok, else: {:error, :invalid_utf8}
  end

  defp strip_bom(@bom <> rest), do: rest
  defp strip_bom(bytes), do: bytes

  ## Rules 7-8

  defp check_text(""), do: {:error, :empty_text}
  defp check_text(text) when byte_size(text) > @text_bytes_max, do: {:error, :text_too_large}
  defp check_text(_text), do: :ok

  ## Plain text and Markdown: CR LF to LF in one pass from the left; nothing else changes.

  defp extract("text/html", html, parse_fun) do
    with :ok <- check_cut_short(html),
         {:ok, tree} <- run_parse(parse_fun, html),
         {:ok, tokens, declarations} <- walk([{:nodes, tree, :normal, :text}], [], []),
         :ok <- check_charsets(declarations) do
      {:ok, paragraphs(tokens)}
    end
  end

  defp extract(_plain_or_markdown, text, _parse_fun),
    do: {:ok, String.replace(text, "\r\n", "\n")}

  ## Rule 5: inputs the parser would cut short, the parse itself and the tree shape

  # The bundled parser wraps the input in a root element `floki` and decodes character
  # references inside an end-tag name, so `</floki` in any ASCII case, or an end tag whose
  # name holds `&`, would end the document early; `</>` makes it take the text up to the
  # next `>` as a tag. All three are refused without decoding anything.
  # Each `</` is read once; a name ends at its first ASCII whitespace, `>`, `/`, `=` or the end
  # of the input, so it ends before the `/` of the next `</` and the scan stays linear.
  defp check_cut_short(html) do
    if Enum.any?(:binary.matches(html, "</"), fn {at, 2} -> cuts_short?(html, at + 2) end),
      do: {:error, :parse_failed},
      else: :ok
  end

  defp cuts_short?(html, from) do
    name = binary_part(html, from, byte_size(html) - from)
    floki?(name) or amp_name?(name) or match?(<<?>, _::binary>>, name)
  end

  defp floki?(<<prefix::binary-size(5), _::binary>>),
    do: String.downcase(prefix, :ascii) == "floki"

  defp floki?(_short), do: false

  defp amp_name?(<<?&, _::binary>>), do: true
  defp amp_name?(<<c, _::binary>>) when c in ~c"\t\n\f\r >/=", do: false
  defp amp_name?(<<_, rest::binary>>), do: amp_name?(rest)
  defp amp_name?(<<>>), do: false

  defp floki_parse(html),
    do: Floki.parse_document(html, html_parser: Floki.HTMLParser.Mochiweb)

  defp run_parse(parse_fun, html) do
    case parse_fun.(html) do
      {:ok, tree} -> {:ok, tree}
      _error_or_other -> {:error, :parse_failed}
    end
  rescue
    _exception -> {:error, :parse_failed}
  catch
    _kind, _value -> {:error, :parse_failed}
  end

  # An iterative walk over the tree in document order, so deep nesting uses no call stack.
  # A frame `{:nodes, siblings, context, previous}` holds the siblings still to read, the
  # context (:normal; :head among the children of `head` before the first element that is
  # not head content; :out inside a left-out element) and whether the previous sibling was a text node. It checks the shape of every
  # node, left-out subtrees included, and gives the reversed tokens (text binaries, " " and
  # :break) and the charset declarations of every `meta` element.
  defp walk([], tokens, declarations), do: {:ok, tokens, declarations}

  defp walk([:break | stack], tokens, declarations),
    do: walk(stack, [:break | tokens], declarations)

  defp walk([{:nodes, [], _context, _previous} | stack], tokens, declarations),
    do: walk(stack, tokens, declarations)

  defp walk([{:nodes, [node | siblings], context, previous} | stack], tokens, declarations) do
    kind = if is_binary(node), do: :text, else: :other
    context = head_context(node, context)

    # One U+0020 between two adjacent sibling nodes that are both not text nodes.
    tokens =
      if kind == :other and previous == :other and context != :out,
        do: [" " | tokens],
        else: tokens

    stack = [{:nodes, siblings, context, kind} | stack]

    case node do
      text when is_binary(text) ->
        cond do
          context != :normal -> walk(stack, tokens, declarations)
          String.valid?(text) -> walk(stack, [text | tokens], declarations)
          true -> {:error, :parse_failed}
        end

      {tag, attributes, children} when is_binary(tag) and is_list(children) ->
        if tag in @raw_kept and wrapper_suffix?(children) do
          {:error, :parse_failed}
        else
          declarations = meta_declarations(tag, attributes, declarations)
          inner = child_context(tag, context)
          children = {:nodes, children, inner, :text}

          if tag in @blocks and inner != :out,
            do: walk([children, :break | stack], [:break | tokens], declarations),
            else: walk([children | stack], tokens, declarations)
        end

      {:comment, _text} ->
        walk(stack, tokens, declarations)

      {:pi, _name, _attributes} ->
        walk(stack, tokens, declarations)

      _unknown_shape ->
        {:error, :parse_failed}
    end
  end

  # The tail of an improper list, or a tree that is not a list.
  defp walk([{:nodes, _not_a_list, _context, _previous} | _stack], _tokens, _declarations),
    do: {:error, :parse_failed}

  # `title` and `textarea` are raw text to the bundled parser (no character reference is
  # decoded), and an unclosed one at the end of the input takes in the parser's closing
  # wrapper: `<title>abc` gives the text node "abc</floki>". The input holds no `</floki`
  # (refused above), so such a suffix is the wrapper, never the document; it is refused.
  defp wrapper_suffix?([text | rest]) when is_binary(text),
    do: String.ends_with?(text, "</floki>") or wrapper_suffix?(rest)

  defp wrapper_suffix?([_node | rest]), do: wrapper_suffix?(rest)
  defp wrapper_suffix?(_end), do: false

  # Inside `head`, an element outside head content starts the body: it and every later
  # sibling (the rest frame takes the changed context) are read as body content.
  defp head_context({tag, _attributes, _children}, :head)
       when is_binary(tag) and tag not in @head_content,
       do: :normal

  defp head_context(_node, context), do: context

  defp child_context(_tag, :out), do: :out
  defp child_context(tag, _context) when tag in @left_out, do: :out
  defp child_context("title", _context), do: :normal
  defp child_context("head", _context), do: :head
  defp child_context(_tag, context), do: context

  # Breaks split the tokens into paragraphs; in each, every run of ASCII whitespace becomes
  # one U+0020 and the ends are trimmed; empty paragraphs are dropped.
  defp paragraphs(tokens) do
    tokens
    |> Enum.reverse()
    |> Enum.chunk_by(&(&1 == :break))
    |> Enum.reject(&(hd(&1) == :break))
    |> Enum.map(fn parts ->
      parts |> :erlang.iolist_to_binary() |> String.split(@whitespace, trim: true) |> Enum.join(" ")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  ## Rule 6: charset declarations of `meta` elements

  defp meta_declarations("meta", attributes, declarations) do
    pairs = attribute_pairs(attributes, [])
    charsets = for {"charset", value} <- pairs, do: value

    contents =
      if Enum.any?(pairs, fn {name, value} ->
           name == "http-equiv" and String.downcase(value, :ascii) == "content-type"
         end),
         do: for({"content", value} <- pairs, charset = content_charset(value), do: charset),
         else: []

    charsets ++ contents ++ declarations
  end

  defp meta_declarations(_tag, _attributes, declarations), do: declarations

  # The parser gives binary names and values; anything else is skipped, and an improper list
  # ends the read instead of raising.
  defp attribute_pairs([{name, value} | rest], acc) when is_binary(name) and is_binary(value),
    do: attribute_pairs(rest, [{name, value} | acc])

  defp attribute_pairs([_other | rest], acc), do: attribute_pairs(rest, acc)
  defp attribute_pairs(_end, acc), do: acc

  # The value after the first `charset=` (ASCII case-insensitive), up to the first `;` or
  # ASCII whitespace, with one pair of surrounding quotes removed; nil without `charset=`.
  defp content_charset(content) do
    case :binary.match(String.downcase(content, :ascii), "charset=") do
      :nomatch ->
        nil

      {at, length} ->
        content
        |> binary_part(at + length, byte_size(content) - at - length)
        |> String.split([";" | @whitespace], parts: 2)
        |> hd()
        |> unquote_once()
    end
  end

  defp unquote_once(<<q, rest::binary>> = value) when q in [?", ?'] and byte_size(rest) >= 1 do
    if :binary.last(rest) == q, do: binary_part(rest, 0, byte_size(rest) - 1), else: value
  end

  defp unquote_once(value), do: value

  defp check_charsets(declarations) do
    if Enum.all?(declarations, &utf8_label?/1),
      do: :ok,
      else: {:error, :unsupported_charset}
  end

  # Trimmed of ASCII whitespace, the label equals `utf-8` or `utf8` (ASCII case-insensitive):
  # neither holds whitespace, so the label must split into exactly that one word.
  defp utf8_label?(label) do
    case String.split(label, @whitespace, trim: true) do
      [word] -> String.downcase(word, :ascii) in ["utf-8", "utf8"]
      _none_or_more -> false
    end
  end
end
