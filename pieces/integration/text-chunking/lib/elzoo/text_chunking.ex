defmodule Elzoo.TextChunking do
  @moduledoc """
  Bounded text chunking with byte offsets to a frozen source (`integration/text-chunking`).

  A pure Recipe over `TextChunker.split/2` (`text_chunker` 1.0.1). The caller hands over the
  frozen source binary together with its SHA-256 digest and an opaque source reference; the
  Recipe checks the bounds and the digest, lets `text_chunker` choose the cut points, then
  re-checks every chunk's byte range against the source and returns ordered chunk records
  with their own SHA-256.

  No I/O, no process, no application environment, no telemetry. Sizes are graphemes, as
  `text_chunker` measures them. See the Piece README for the Contract and its limits.
  """

  @max_source_bytes_default 1_048_576
  @max_source_bytes_ceiling 1_048_576
  @chunk_size_default 2000
  @chunk_size_min 16
  @chunk_size_max 65_536
  @chunk_overlap_default 200
  @format_default :plaintext
  @formats [:plaintext, :markdown]
  @max_chunks_default 4096
  @max_chunks_ceiling 65_536
  @source_ref_max_bytes 1024
  @option_names [:max_source_bytes, :chunk_size, :chunk_overlap, :format, :max_chunks]

  @typedoc "One chunk record; `content` is exactly `binary_part(source, start_byte, end_byte - start_byte)`."
  @type chunk :: %{
          index: non_neg_integer(),
          start_byte: non_neg_integer(),
          end_byte: pos_integer(),
          content: String.t(),
          content_digest: <<_::256>>
        }

  @type result :: %{
          source_ref: String.t(),
          source_digest: <<_::256>>,
          source_bytes: pos_integer(),
          chunks: [chunk()]
        }

  @type option_name ::
          :opts
          | :unknown_option
          | :max_source_bytes
          | :chunk_size
          | :chunk_overlap
          | :format
          | :max_chunks
          | :source
          | :source_digest
          | :source_ref

  @type reason ::
          {:invalid_option, option_name()}
          | :source_too_large
          | :empty_source
          | :digest_mismatch
          | :invalid_utf8
          | :too_many_chunks
          | :chunker_invariant

  @doc "The declared defaults and hard ceilings of the per-call options."
  @spec limits() :: map()
  def limits do
    %{
      max_source_bytes: %{
        default: @max_source_bytes_default,
        min: 1,
        max: @max_source_bytes_ceiling
      },
      chunk_size: %{default: @chunk_size_default, min: @chunk_size_min, max: @chunk_size_max},
      chunk_overlap: %{default: @chunk_overlap_default, min: 0, max: :half_of_chunk_size},
      format: %{default: @format_default, allowed: @formats},
      max_chunks: %{default: @max_chunks_default, min: 1, max: @max_chunks_ceiling},
      source_ref_bytes: %{min: 1, max: @source_ref_max_bytes}
    }
  end

  @doc """
  Splits `source` into bounded chunk records.

  `source_digest` must be the 32-byte SHA-256 of `source`; `source_ref` is an opaque caller
  identity of 1..1024 UTF-8 bytes. Options: `:max_source_bytes`, `:chunk_size`,
  `:chunk_overlap`, `:format`, `:max_chunks` (see `limits/0`).

  Returns `{:ok, result}` or `{:error, reason}`; never raises for any input term.
  """
  @spec chunk(term(), term(), term(), term()) :: {:ok, result()} | {:error, reason()}
  def chunk(source, source_digest, source_ref, opts \\ []) do
    __chunk__(source, source_digest, source_ref, opts, &upstream_split/2)
  end

  # Test seam: the same pipeline with an injected split function, so the tests can show that
  # the split is never reached on a refusal and that a bad upstream result is refused whole.
  @doc false
  def __chunk__(source, source_digest, source_ref, opts, split_fun)
      when is_function(split_fun, 2) do
    with :ok <- check_inputs(source, source_digest, source_ref),
         {:ok, config} <- check_options(opts),
         :ok <- check_size(source, config),
         :ok <- check_digest(source, source_digest),
         :ok <- check_utf8(source),
         :ok <- precheck_count(source, config),
         {:ok, chunks} <- split(source, config, split_fun),
         :ok <- check_count(chunks, config) do
      {:ok,
       %{
         source_ref: source_ref,
         source_digest: source_digest,
         source_bytes: byte_size(source),
         chunks: chunks
       }}
    end
  end

  ## Positional inputs

  defp check_inputs(source, _digest, _ref) when not is_binary(source),
    do: {:error, {:invalid_option, :source}}

  defp check_inputs(_source, digest, _ref) when not (is_binary(digest) and byte_size(digest) == 32),
    do: {:error, {:invalid_option, :source_digest}}

  defp check_inputs(_source, _digest, ref)
       when not (is_binary(ref) and byte_size(ref) >= 1 and byte_size(ref) <= @source_ref_max_bytes),
       do: {:error, {:invalid_option, :source_ref}}

  defp check_inputs(_source, _digest, ref) do
    if String.valid?(ref), do: :ok, else: {:error, {:invalid_option, :source_ref}}
  end

  ## Options

  defp check_options(opts) do
    if keyword?(opts) do
      case Enum.find(opts, fn {key, _} -> key not in @option_names end) do
        nil -> build_config(opts)
        _unknown -> {:error, {:invalid_option, :unknown_option}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  # Walks the list by hand so an improper list is refused instead of raising.
  defp keyword?([]), do: true
  defp keyword?([{key, _value} | rest]) when is_atom(key), do: keyword?(rest)
  defp keyword?(_opts), do: false

  defp build_config(opts) do
    with {:ok, max_source_bytes} <-
           int_option(
             opts,
             :max_source_bytes,
             @max_source_bytes_default,
             1,
             @max_source_bytes_ceiling
           ),
         {:ok, chunk_size} <-
           int_option(opts, :chunk_size, @chunk_size_default, @chunk_size_min, @chunk_size_max),
         {:ok, chunk_overlap} <-
           int_option(opts, :chunk_overlap, @chunk_overlap_default, 0, div(chunk_size, 2)),
         {:ok, format} <- format_option(opts),
         {:ok, max_chunks} <-
           int_option(opts, :max_chunks, @max_chunks_default, 1, @max_chunks_ceiling) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         chunk_size: chunk_size,
         chunk_overlap: chunk_overlap,
         format: format,
         max_chunks: max_chunks
       }}
    end
  end

  # A repeated key is refused rather than resolved silently.
  defp int_option(opts, name, default, min, max) do
    case Keyword.get_values(opts, name) do
      [] -> {:ok, default}
      [value] when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _invalid -> {:error, {:invalid_option, name}}
    end
  end

  defp format_option(opts) do
    case Keyword.get_values(opts, :format) do
      [] -> {:ok, @format_default}
      [format] when format in @formats -> {:ok, format}
      _invalid -> {:error, {:invalid_option, :format}}
    end
  end

  ## Source checks (in Contract order)

  defp check_size(source, %{max_source_bytes: max}) do
    cond do
      byte_size(source) > max -> {:error, :source_too_large}
      source == "" -> {:error, :empty_source}
      true -> :ok
    end
  end

  defp check_digest(source, digest) do
    if :crypto.hash(:sha256, source) == digest, do: :ok, else: {:error, :digest_mismatch}
  end

  defp check_utf8(source) do
    if String.valid?(source), do: :ok, else: {:error, :invalid_utf8}
  end

  # Every upstream chunk has at most chunk_size graphemes and the chunks cover the source
  # (upstream behaviour checked by the tests, not promised upstream), so more than
  # max_chunks * chunk_size graphemes cannot fit in max_chunks chunks. The post-check in
  # check_count/2 stays the authority; this only avoids the split for a certain refusal.
  defp precheck_count(source, %{chunk_size: chunk_size, max_chunks: max_chunks}) do
    if String.length(source) > max_chunks * chunk_size,
      do: {:error, :too_many_chunks},
      else: :ok
  end

  defp check_count(chunks, %{max_chunks: max_chunks}) do
    if length(chunks) > max_chunks, do: {:error, :too_many_chunks}, else: :ok
  end

  ## Split and offset re-check

  defp upstream_split(source, config) do
    TextChunker.split(source,
      chunk_size: config.chunk_size,
      chunk_overlap: config.chunk_overlap,
      format: config.format
    )
  end

  defp split(source, config, split_fun) do
    case split_fun.(source, config) do
      [_ | _] = upstream -> build(upstream, source, byte_size(source), 0, nil, [])
      _empty_or_not_a_list -> {:error, :chunker_invariant}
    end
  end

  defp build([], _source, _size, _index, _previous_start, acc), do: {:ok, Enum.reverse(acc)}

  defp build([upstream | rest], source, size, index, previous_start, acc) do
    case record(upstream, source, size, index, previous_start) do
      {:ok, record} -> build(rest, source, size, index + 1, record.start_byte, [record | acc])
      :error -> {:error, :chunker_invariant}
    end
  end

  # The non-list tail of an improper list.
  defp build(_tail, _source, _size, _index, _previous_start, _acc),
    do: {:error, :chunker_invariant}

  # The A1 re-check, one step at a time in the Contract order; binary_part/3 runs only after
  # the shape and bounds hold. The digest (b) is computed here, never taken from upstream.
  defp record(upstream, source, size, index, previous_start) do
    with {:ok, start, stop, text} <- shape(upstream),
         :ok <- bounds(start, stop, size),
         :ok <- non_empty(text),
         :ok <- slice_matches(source, start, stop, text),
         :ok <- first_start(index, start),
         :ok <- non_descending(previous_start, start) do
      {:ok,
       %{
         index: index,
         start_byte: start,
         end_byte: stop,
         content: text,
         content_digest: :crypto.hash(:sha256, text)
       }}
    end
  end

  defp shape(%{start_byte: start, end_byte: stop, text: text})
       when is_integer(start) and is_integer(stop) and is_binary(text),
       do: {:ok, start, stop, text}

  defp shape(_upstream), do: :error

  defp bounds(start, stop, size) when start >= 0 and start < stop and stop <= size, do: :ok
  defp bounds(_start, _stop, _size), do: :error

  defp non_empty(""), do: :error
  defp non_empty(_text), do: :ok

  defp slice_matches(source, start, stop, text) do
    if binary_part(source, start, stop - start) == text, do: :ok, else: :error
  end

  defp first_start(0, 0), do: :ok
  defp first_start(0, _start), do: :error
  defp first_start(_index, _start), do: :ok

  defp non_descending(nil, _start), do: :ok
  defp non_descending(previous, start) when start >= previous, do: :ok
  defp non_descending(_previous, _start), do: :error
end
