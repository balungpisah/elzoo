# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PiiRedaction do
  @moduledoc """
  Deterministic redaction of listed personal-data patterns and host-named exact
  values in one text.

  `redact(text, mode: :mask, known: values)` replaces each finding with
  `[pii:<kind>]`; `redact(text, mode: :tokenize, known: values, vault: need)`
  replaces it with `[pii:<kind>:<ref>]`, where `need.(kind, span)` returns
  `{:ok, ref}`. Returns `{:ok, %{text: out, findings: findings}}` or
  `{:error, :malformed | :too_many | :unavailable}`.

  Pattern matching, not classification: a text with no finding is not public
  data. No I/O, clock, process, telemetry, log or rehydration; errors never echo
  the text.
  """

  @max_text 65_536
  @max_known 64
  @max_known_bytes 256
  @max_findings 256
  @max_ref 64
  @kinds [:known, :email, :card, :phone]

  defguardp digit?(b) when b in ?0..?9
  defguardp letter?(b) when b in ?a..?z or b in ?A..?Z
  defguardp label?(b) when digit?(b) or letter?(b) or b == ?-
  defguardp local?(b) when label?(b) or b in [?., ?_, ?%, ?+]
  defguardp ref?(b) when digit?(b) or letter?(b) or b in [?_, ?-]

  @doc "Redact one text. See the module documentation and the README."
  def redact(text, opts) do
    with {:ok, mode, known, vault} <- shape(text, opts) do
      text = :binary.replace(text, "[pii:", "[pii_:", [:global])
      findings = select(text, candidates(text), known_matcher(known), 0, nil, [], 0)

      if length(findings) > @max_findings do
        {:error, :too_many}
      else
        spans = for {start, len, kind} <- findings, do: {kind, binary_part(text, start, len)}

        with {:ok, refs} <- refs(mode, vault, spans) do
          {:ok, %{text: output(text, findings, spans, refs), findings: counts(findings)}}
        end
      end
    end
  end

  # Step 1: shape.

  defp shape(text, opts)
       when is_binary(text) and byte_size(text) <= @max_text and is_list(opts) do
    with true <- String.valid?(text) and Keyword.keyword?(opts),
         {:ok, mode, vault} <- mode(Enum.sort(Keyword.keys(opts)), opts),
         known = Keyword.fetch!(opts, :known),
         :ok <- known(known, 0) do
      {:ok, mode, known, vault}
    else
      _ -> {:error, :malformed}
    end
  end

  defp shape(_text, _opts), do: {:error, :malformed}

  defp mode([:known, :mode], opts) do
    if opts[:mode] == :mask, do: {:ok, :mask, nil}, else: :error
  end

  defp mode([:known, :mode, :vault], opts) do
    vault = opts[:vault]

    if opts[:mode] == :tokenize and is_function(vault, 2),
      do: {:ok, :tokenize, vault},
      else: :error
  end

  defp mode(_keys, _opts), do: :error

  defp known([], _n), do: :ok

  defp known([value | rest], n)
       when n < @max_known and is_binary(value) and byte_size(value) in 1..@max_known_bytes do
    if String.valid?(value), do: known(rest, n + 1), else: :error
  end

  defp known(_values, _n), do: :error

  # Step 3: candidates of :email, :card and :phone, sorted by start, then the
  # longer span, then the earlier kind. :known candidates are found lazily.

  defp candidates(text) do
    (emails(text) ++ numbers(text, 0, []))
    |> Enum.sort_by(fn {start, len, kind} -> {start, -len, rank(kind)} end)
  end

  defp rank(:known), do: 0
  defp rank(:email), do: 1
  defp rank(:card), do: 2
  defp rank(:phone), do: 3

  # An email span is unique per `@`: the whole local-part run before it and
  # the whole dotted label run after it, or no candidate.
  defp emails(text) do
    size = byte_size(text)

    for {at, 1} <- :binary.matches(text, "@"),
        local <- [local_len(text, at - 1, 0)],
        local in 1..64,
        {:ok, domain} <- [domain(binary_part(text, at + 1, size - at - 1), 0)] do
      {at - local, local + 1 + domain, :email}
    end
  end

  defp local_len(text, i, n) when i >= 0 and n <= 64 do
    if local?(:binary.at(text, i)), do: local_len(text, i - 1, n + 1), else: n
  end

  defp local_len(_text, _i, n), do: n

  # Labels separated by `.`; ends where the next byte is neither a label byte
  # nor a `.` followed by a label byte. 127 labels is implied by 253 bytes.
  defp domain(bin, len) do
    n = label_len(bin, 0)
    label = binary_part(bin, 0, n)
    rest = binary_part(bin, n, byte_size(bin) - n)
    len = len + n

    cond do
      n not in 1..63 or len > 253 or :binary.first(label) == ?- or :binary.last(label) == ?- ->
        :error

      match?(<<?., b, _::binary>> when label?(b), rest) ->
        domain(binary_part(rest, 1, byte_size(rest) - 1), len + 1)

      len > n and byte_size(label) >= 2 and letters?(label) ->
        {:ok, len}

      true ->
        :error
    end
  end

  defp label_len(<<b, rest::binary>>, n) when label?(b) and n <= 63, do: label_len(rest, n + 1)
  defp label_len(_bin, n), do: n

  defp letters?(<<b, rest::binary>>) when letter?(b), do: letters?(rest)
  defp letters?(<<>>), do: true
  defp letters?(_bin), do: false

  # A number run is a maximal sequence of digits joined by single spaces or
  # hyphens. It is a card when it has 13..19 digits, one separator kind and
  # passes Luhn; it is a phone with the `+` before it when it has 8..15 digits
  # and no digit stands before the `+`.
  defp numbers(text, i, acc) do
    case text do
      <<_::binary-size(^i), d, _::binary>> when digit?(d) ->
        run(text, i + 1, i, 1, [d - ?0], [], acc)

      <<_::binary-size(^i), _, _::binary>> ->
        numbers(text, i + 1, acc)

      _ ->
        acc
    end
  end

  defp run(text, i, start, n, digits, seps, acc) do
    case text do
      <<_::binary-size(^i), d, _::binary>> when digit?(d) ->
        run(text, i + 1, start, n + 1, push(digits, n, d), seps, acc)

      <<_::binary-size(^i), sep, d, _::binary>> when sep in [?\s, ?-] and digit?(d) ->
        run(text, i + 2, start, n + 1, push(digits, n, d), [sep | seps] |> Enum.uniq(), acc)

      _ ->
        acc = if card?(n, digits, seps), do: [{start, i - start, :card} | acc], else: acc
        acc = if phone?(text, start, n), do: [{start - 1, i - start + 1, :phone} | acc], else: acc
        numbers(text, i, acc)
    end
  end

  defp push(digits, n, d) when n < 19, do: [d - ?0 | digits]
  defp push(digits, _n, _d), do: digits

  defp card?(n, digits, seps), do: n in 13..19 and length(seps) <= 1 and luhn?(digits)

  # `digits` holds the run's digits from the right.
  defp luhn?(digits) do
    {sum, _double} =
      Enum.reduce(digits, {0, false}, fn
        d, {sum, false} -> {sum + d, true}
        d, {sum, true} when d < 5 -> {sum + 2 * d, false}
        d, {sum, true} -> {sum + 2 * d - 9, false}
      end)

    rem(sum, 10) == 0
  end

  defp phone?(text, start, n) do
    n in 8..15 and start >= 1 and :binary.at(text, start - 1) == ?+ and
      (start == 1 or not digit?(:binary.at(text, start - 2)))
  end

  defp known_matcher([]), do: nil
  defp known_matcher(known), do: :binary.compile_pattern(known)

  # Left to right from `cursor`: the leftmost start wins, then the longer span,
  # then the earlier kind. Stops after one finding over the bound.
  defp select(_text, _cands, _matcher, _cursor, _next, acc, n) when n > @max_findings,
    do: Enum.reverse(acc)

  defp select(text, cands, matcher, cursor, next, acc, n) do
    cands = Enum.drop_while(cands, fn {start, _len, _kind} -> start < cursor end)
    next = next_known(text, matcher, cursor, next)

    case pick(next, cands) do
      nil ->
        Enum.reverse(acc)

      {start, len, _kind} = finding ->
        select(text, cands, matcher, start + len, next, [finding | acc], n + 1)
    end
  end

  defp next_known(_text, nil, _cursor, _next), do: :none

  defp next_known(_text, _matcher, cursor, {start, _len, :known} = next) when start >= cursor,
    do: next

  defp next_known(_text, _matcher, _cursor, :none), do: :none

  defp next_known(text, matcher, cursor, _stale) do
    case :binary.match(text, matcher, scope: {cursor, byte_size(text) - cursor}) do
      {start, len} -> {start, len, :known}
      :nomatch -> :none
    end
  end

  defp pick(:none, []), do: nil
  defp pick(:none, [cand | _]), do: cand
  defp pick(known, []), do: known

  defp pick({ks, kl, :known} = known, [{cs, cl, _kind} = cand | _]) do
    if ks < cs or (ks == cs and kl >= cl), do: known, else: cand
  end

  # Step 4: one vault call for each distinct {kind, span}, in first-occurrence order.

  defp refs(:mask, nil, _spans), do: {:ok, %{}}

  defp refs(:tokenize, vault, spans) do
    spans
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn {kind, span} = key, {:ok, refs} ->
      case call(vault, kind, span) do
        {:ok, ref} -> {:cont, {:ok, Map.put(refs, key, ref)}}
        :error -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp call(vault, kind, span) do
    case vault.(kind, span) do
      {:ok, ref} when is_binary(ref) and byte_size(ref) in 1..@max_ref ->
        if ref_bytes?(ref), do: {:ok, ref}, else: :error

      _other ->
        :error
    end
  catch
    _class, _reason -> :error
  end

  defp ref_bytes?(<<b, rest::binary>>) when ref?(b), do: ref_bytes?(rest)
  defp ref_bytes?(<<>>), do: true
  defp ref_bytes?(_ref), do: false

  # Step 5: replacement.

  defp output(text, findings, spans, refs) do
    {parts, cursor} =
      findings
      |> Enum.zip(spans)
      |> Enum.reduce({[], 0}, fn {{start, len, kind}, key}, {parts, cursor} ->
        {[marker(kind, Map.get(refs, key)), binary_part(text, cursor, start - cursor) | parts],
         start + len}
      end)

    IO.iodata_to_binary(Enum.reverse(parts, [binary_part(text, cursor, byte_size(text) - cursor)]))
  end

  defp marker(kind, nil), do: ["[pii:", Atom.to_string(kind), "]"]
  defp marker(kind, ref), do: ["[pii:", Atom.to_string(kind), ":", ref, "]"]

  defp counts(findings) do
    freq = Enum.frequencies_by(findings, fn {_start, _len, kind} -> kind end)
    for kind <- @kinds, Map.has_key?(freq, kind), do: %{kind: kind, count: freq[kind]}
  end
end
