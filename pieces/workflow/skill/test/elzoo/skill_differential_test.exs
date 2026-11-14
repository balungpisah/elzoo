defmodule Elzoo.SkillDifferentialTest do
  # The group `scan_agrees_with_the_reader`: the frontmatter scan of
  # `Elzoo.Skill.read/4` against the token stream of the pinned YAML parser.
  #
  # Test-only oracle: `:yamerl_parser.string/2` (exported, on hexdocs for the
  # exactly pinned yamerl 0.10.0) with the option `token_fun`, which the docs do
  # not expand (it is defined in an internal header). The test therefore opens
  # with a positive control: the oracle must report each forbidden token in a
  # fixed text, and none in a plain map. No file under `lib/` names the parser.
  #
  # A generated text is `accepted` when `read/4` gives `{:ok, _}`: a refused text
  # gives no entry, so nothing of it reaches a package. A forbidden token in the
  # token stream of an accepted text is a disagreement. The sample is finite: it
  # is not a proof.
  use ExUnit.Case, async: true

  alias Elzoo.Skill

  # Indicator bytes, quotes, blanks, line breaks and a few letters. No CR, no `.`.
  @alphabet String.to_charlist("-?:,[]{}#&*!|>'\"%@`<=~\\ \t\nabk")
  # A smaller alphabet that reaches deeper structures within 24 bytes.
  @dense String.to_charlist("?:[]{}&*'\" ,\na<")
  # The alphabet of the exhaustive part.
  @exhaustive String.to_charlist("?:[{&*' \na")

  @allowed_tags Enum.map(
                  ["str", "int", "float", "bool", "null", "binary", "seq", "map"],
                  &String.to_charlist("tag:yaml.org,2002:" <> &1)
                )

  @max_length 24

  # The default run is a seeded sample; the full run (tag `scan_differential_full`,
  # run with `--include scan_differential_full`) is the sample of the Contract.
  @default_run %{random: 20_000, exhaustive_length: 5}
  @full_run %{random: 200_000, exhaustive_length: 6}

  # The full run is skipped unless `--include scan_differential_full` (or
  # `--only`) asks for it; the test helper of the repository has no module-level
  # exclusion, and the include list is already set when this file loads.
  @full_skip (if :scan_differential_full in ExUnit.configuration()[:include] do
                false
              else
                "run with --include scan_differential_full"
              end)

  # The oracle: the tokens that the parser emits for `text`, in order, and
  # whether it raised. The `yamerl` application must be started.
  defp oracle(text) do
    Process.put(:differential_tokens, [])

    collect = fn token ->
      Process.put(:differential_tokens, [token | Process.get(:differential_tokens)])
      :ok
    end

    status =
      try do
        :yamerl_parser.string(text, [{:token_fun, collect}])
        :ok
      catch
        _kind, _reason -> :raised
      end

    {status, Enum.reverse(Process.delete(:differential_tokens))}
  end

  # The forbidden tokens of a token stream, each as an atom.
  defp forbidden(tokens, text) do
    lines = String.split(text, "\n")

    {found, _previous} =
      Enum.reduce(tokens, {[], nil}, fn token, {found, previous} ->
        {found ++ findings(token, previous, lines), token}
      end)

    found
  end

  defp findings({:yamerl_anchor, _, _, _}, _previous, _lines), do: [:anchor]
  defp findings({:yamerl_alias, _, _, _}, _previous, _lines), do: [:alias]
  defp findings({:yamerl_tag, _, _, uri}, _previous, _lines), do: tag_findings(uri)

  defp findings({:yamerl_scalar, _, _, {:yamerl_tag, _, _, uri}, _, _, text}, previous, _lines) do
    merge_key =
      if text == ~c"<<" and match?({:yamerl_mapping_key, _, _}, previous),
        do: [:merge_key],
        else: []

    tag_findings(uri) ++ merge_key
  end

  defp findings({:yamerl_collection_start, _, _, {:yamerl_tag, _, _, uri}, _, _}, _prev, _lines),
    do: tag_findings(uri)

  # An explicit key: a mapping key whose position is a `?` byte of the text and
  # that a space, a tab, a line break or the end of the text follows. Lines and
  # columns start at 1.
  defp findings({:yamerl_mapping_key, line, column}, _previous, lines) do
    case lines |> Enum.at(line - 1, "") |> binary_part_from(column - 1) do
      <<??>> -> [:explicit_key]
      <<??, c, _::binary>> when c in [?\s, ?\t] -> [:explicit_key]
      _ -> []
    end
  end

  defp findings(_token, _previous, _lines), do: []

  defp binary_part_from(line, offset) when offset <= byte_size(line),
    do: binary_part(line, offset, byte_size(line) - offset)

  defp binary_part_from(_line, _offset), do: ""

  # The non-specific tags `!` and `?` (an untagged node) and the listed core tags
  # are allowed; every other tag is forbidden.
  defp tag_findings({:non_specific, _}), do: []
  defp tag_findings(uri) when uri in @allowed_tags, do: []
  defp tag_findings(_uri), do: [:tag]

  # The folder of a generated text: the frontmatter is `text` and a line break.
  defp accepted?(text) do
    match?({:ok, _}, Skill.read("s", "1", [], %{"SKILL.md" => "---\n" <> text <> "\n---\nbody\n"}))
  end

  # `nil` when the oracle and the scan agree, else the forbidden tokens or the
  # reason. A text that the oracle raises on counts as refused by the reader only
  # when the pinned reader itself gives `{:error, _}`.
  defp disagreement(text) do
    frontmatter = text <> "\n"

    case oracle(frontmatter) do
      {:ok, tokens} ->
        case forbidden(tokens, frontmatter) do
          [] -> nil
          found -> {text, found}
        end

      {:raised, tokens} ->
        case YamlElixir.read_from_string(frontmatter, []) do
          {:error, _error} -> nil
          _other -> {text, [:oracle_raised | forbidden(tokens, frontmatter)]}
        end
    end
  end

  defp skip?(text), do: text |> String.split("\n") |> Enum.any?(&String.starts_with?(&1, "---"))

  # Counts `{generated, accepted, disagreements}` over `texts`, in chunks that run
  # on all schedulers; the counts do not depend on the order of the chunks.
  defp compare(texts) do
    texts
    |> Stream.chunk_every(1_000)
    |> Task.async_stream(&compare_chunk/1,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({0, 0, []}, fn {:ok, {g, a, f}}, {gs, as, fs} -> {gs + g, as + a, f ++ fs} end)
  end

  defp compare_chunk(texts) do
    Enum.reduce(texts, {0, 0, []}, fn text, {generated, accepted, found} ->
      cond do
        skip?(text) ->
          {generated, accepted, found}

        accepted?(text) ->
          case disagreement(text) do
            nil -> {generated + 1, accepted + 1, found}
            one -> {generated + 1, accepted + 1, [one | found]}
          end

        true ->
          {generated + 1, accepted, found}
      end
    end)
  end

  defp random_texts(alphabet, count, seed) do
    symbols = List.to_tuple(alphabet)
    size = tuple_size(symbols)

    Stream.transform(1..count, :rand.seed_s(:exsss, seed), fn _index, state ->
      {length, state} = :rand.uniform_s(@max_length, state)

      {bytes, state} =
        Enum.map_reduce(1..length, state, fn _position, state ->
          {at, state} = :rand.uniform_s(size, state)
          {elem(symbols, at - 1), state}
        end)

      {[List.to_string(bytes)], state}
    end)
  end

  # Every text of 1 to `max` bytes over `alphabet`.
  defp all_texts(alphabet, max) do
    base = length(alphabet)

    Stream.flat_map(1..max, fn size ->
      count = Integer.pow(base, size)
      Stream.map(0..(count - 1), &digits(&1, size, alphabet))
    end)
  end

  defp digits(index, size, alphabet) do
    base = length(alphabet)

    {bytes, _rest} =
      Enum.map_reduce(1..size, index, fn _position, rest ->
        {Enum.at(alphabet, rem(rest, base)), div(rest, base)}
      end)

    List.to_string(bytes)
  end

  describe "scan_agrees_with_the_reader" do
    test "positive control: the oracle sees each forbidden token and none in a plain map" do
      assert {:ok, tokens} = oracle("a: b\nc: d\n")
      assert forbidden(tokens, "a: b\nc: d\n") == []

      controls = [
        {"a: &x b\n", :anchor},
        {"a: &x b\nc: *x\n", :alias},
        {"a: !foo b\n", :tag},
        {"a: !<tag:example.org,2000:t> b\n", :tag},
        {"<<: x\n", :merge_key},
        {"a: {<<: x}\n", :merge_key},
        {"? a\n: b\n", :explicit_key},
        {"- ? a\n", :explicit_key},
        {"a: [? b]\n", :explicit_key}
      ]

      for {text, kind} <- controls do
        {_status, tokens} = oracle(text)
        assert kind in forbidden(tokens, text), "the oracle misses #{kind} in #{inspect(text)}"
      end

      # The allowed tags and an untagged plain scalar that begins with ? are
      # not reported.
      for text <- ["a: !!str b\n", "a: !!binary //4=\n", "a: ?x\n", "?x: y\n", "a: !!map {}\n"] do
        assert {:ok, tokens} = oracle(text)
        assert forbidden(tokens, text) == [], "the oracle reports a token in #{inspect(text)}"
      end
    end

    test "the scan and the reader agree on a seeded sample" do
      run_differential(@default_run)
    end

    @tag :scan_differential_full
    @tag timeout: :infinity
    @tag skip: @full_skip
    test "the scan and the reader agree on the full seeded sample" do
      run_differential(@full_run)
    end
  end

  # Two seeded random parts (the whole alphabet and the dense alphabet, each of
  # `random` texts of 1 to 24 bytes) and every text of up to `exhaustive_length`
  # bytes over the small alphabet.
  defp run_differential(%{random: random, exhaustive_length: exhaustive_length}) do
    assert {:ok, tokens} = oracle("a: &x b\n")
    assert :anchor in forbidden(tokens, "a: &x b\n")

    {time, parts} =
      :timer.tc(fn ->
        [
          compare(random_texts(@alphabet, random, {1, 2, 3})),
          compare(random_texts(@dense, random, {4, 5, 6})),
          compare(all_texts(@exhaustive, exhaustive_length))
        ]
      end)

    for {{generated, accepted, found}, part} <- Enum.zip(parts, ["random", "dense", "exhaustive"]) do
      IO.puts(
        "scan_agrees_with_the_reader #{part}: generated #{generated}, accepted #{accepted}, " <>
          "disagreed #{length(found)}"
      )
    end

    IO.puts("scan_agrees_with_the_reader: #{div(time, 1000)} ms")

    found = parts |> Enum.flat_map(fn {_generated, _accepted, found} -> found end) |> Enum.sort()
    assert Enum.take(found, 60) == []
  end
end
