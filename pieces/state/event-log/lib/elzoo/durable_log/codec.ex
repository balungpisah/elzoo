# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Codec do
  @moduledoc "Versioned canonical encodings shared by the storage boundary."
  @reasons [
    :sequence_identity_mismatch,
    :invalid_stream,
    :invalid_revision,
    :unknown_kind,
    :unsupported_version,
    :malformed_row,
    :record_too_large,
    :digest_mismatch,
    :reducer_failure,
    # Appended by the PR #51 fix; existing indices stay stable.
    :beyond_head
  ]

  def field(binary) when is_binary(binary), do: <<byte_size(binary)::32, binary::binary>>
  def hash(bytes), do: :crypto.hash(:sha256, bytes)
  def nonce?(n), do: is_binary(n) and byte_size(n) == 16
  def uint?(n), do: is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807
  def small_uint?(n), do: is_integer(n) and n > 0 and n <= 2_147_483_647

  def text?(s),
    do: is_binary(s) and String.valid?(s) and not String.contains?(s, <<0>>)

  def stream?(s), do: text?(s) and byte_size(s) in 1..200
  def destination?(s), do: text?(s) and byte_size(s) > 0

  def fold_valid?(fold),
    do:
      is_map(fold) and is_map(Map.get(fold, :kinds)) and
        Enum.all?(fold.kinds, fn {kind, role} ->
          text?(kind) and role in [:state_bearing, :non_state_bearing]
        end) and
        is_list(Map.get(fold, :versions)) and Enum.all?(fold.versions, &small_uint?/1) and
        is_list(Map.get(fold, :destinations, [])) and
        Enum.all?(Map.get(fold, :destinations, []), &destination?/1)

  def checkpoint_bytes(c) do
    {applied, damaged, diagnostics} = c.cursor

    witnesses =
      c.seen |> Enum.sort() |> Enum.map(fn {s, digest} -> <<s::64, digest::binary-size(32)>> end)

    IO.iodata_to_binary([
      <<1, 1>>,
      field(c.stream),
      <<c.sequence::64, c.fold_version::32>>,
      field(c.model),
      <<applied::64, bool(damaged), length(diagnostics)::32>>,
      Enum.map(diagnostics, &diagnostic/1),
      <<map_size(c.seen)::32>>,
      witnesses,
      field(c.nonce)
    ])
  end

  def cursor_bytes({applied, damaged, diagnostics}),
    do:
      IO.iodata_to_binary([
        <<1, applied::64, bool(damaged), length(diagnostics)::32>>,
        Enum.map(diagnostics, &diagnostic/1)
      ])

  def seen_bytes(seen),
    do:
      IO.iodata_to_binary([
        <<1, map_size(seen)::32>>,
        seen |> Enum.sort() |> Enum.map(fn {s, d} -> <<s::64, d::binary-size(32)>> end)
      ])

  def decode_cursor(<<1, applied::64, damaged, count::32, rest::binary>>) when damaged in [0, 1] do
    with true <- uint?(applied), {:ok, diagnostics, <<>>} <- decode_diagnostics(rest, count, []) do
      {:ok, {applied, damaged == 1, diagnostics}}
    else
      _ -> {:error, :malformed}
    end
  end

  def decode_cursor(_), do: {:error, :malformed}

  def decode_seen(<<1, count::32, rest::binary>>) when byte_size(rest) == count * 40,
    do: decode_witnesses(rest, %{})

  def decode_seen(_), do: {:error, :malformed}
  defp decode_witnesses(<<>>, seen), do: {:ok, seen}

  defp decode_witnesses(<<s::64, d::binary-size(32), rest::binary>>, seen) do
    if uint?(s) and s > 0 and not Map.has_key?(seen, s),
      do: decode_witnesses(rest, Map.put(seen, s, d)),
      else: {:error, :malformed}
  end

  defp decode_diagnostics(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_diagnostics(<<tag, s::64, rest::binary>>, count, acc) when tag in [1, 2] do
    order = if tag == 1, do: :gap, else: :out_of_order
    decode_diagnostic({s, order}, rest, count, acc)
  end

  defp decode_diagnostics(<<3, h::64, l::64, rest::binary>>, count, acc),
    do: decode_diagnostic({:truncated, h, l}, rest, count, acc)

  defp decode_diagnostics(<<4, s::64, reason, rest::binary>>, count, acc),
    do: decode_diagnostic({:corrupt, s, Enum.at(@reasons, reason)}, rest, count, acc)

  defp decode_diagnostics(_, _, _), do: {:error, :malformed}

  defp decode_diagnostic(d, rest, count, acc) do
    if count > 0 and diagnostic_valid?(d),
      do: decode_diagnostics(rest, count - 1, [d | acc]),
      else: {:error, :malformed}
  end

  def checkpoint_valid?(c) when is_map(c) do
    try do
      {applied, damaged, diagnostics} = c.cursor

      stream?(c.stream) and uint?(c.sequence) and c.sequence == applied and
        small_uint?(c.fold_version) and
        is_binary(c.model) and is_boolean(damaged) and is_list(diagnostics) and
        Enum.all?(diagnostics, &diagnostic_valid?/1) and
        (diagnostics == [] or damaged or Enum.all?(diagnostics, &match?({_, :out_of_order}, &1))) and
        is_map(c.seen) and
        Enum.all?(c.seen, fn {seq, digest} ->
          uint?(seq) and seq > 0 and seq <= applied and is_binary(digest) and
            byte_size(digest) == 32
        end) and (applied == 0 or Map.has_key?(c.seen, applied)) and nonce?(c.nonce) and
        c.digest == hash(checkpoint_bytes(c))
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  def checkpoint_valid?(_), do: false

  def receipt(operation, stream, expected, target, nonce, extra \\ <<>>) do
    bytes =
      IO.iodata_to_binary([
        <<1, operation_tag(operation)>>,
        field(stream),
        <<expected::64, target::64>>,
        field(nonce),
        field(extra)
      ])

    %{
      operation: operation,
      stream: stream,
      expected: expected,
      target: target,
      nonce: nonce,
      extra: extra,
      digest: hash(bytes)
    }
  end

  def receipt_valid?(r) when is_map(r) do
    try do
      stream?(r.stream) and uint?(r.expected) and uint?(r.target) and nonce?(r.nonce) and
        is_binary(r.extra) and
        r == receipt(r.operation, r.stream, r.expected, r.target, r.nonce, r.extra)
    rescue
      _ -> false
    end
  end

  def receipt_valid?(_), do: false

  def item_key(stream, sequence, position), do: "#{stream}/#{sequence}/#{position}"

  def parse_key(key) when is_binary(key) do
    case key |> String.split("/") |> Enum.reverse() do
      [position, sequence | rest] when rest != [] ->
        with {p, ""} when p > 0 <- Integer.parse(position),
             {s, ""} when s > 0 <- Integer.parse(sequence),
             stream = rest |> Enum.reverse() |> Enum.join("/"),
             true <-
               stream?(stream) and uint?(s) and small_uint?(p) and item_key(stream, s, p) == key do
          {:ok, {stream, s, p}}
        else
          _ -> {:error, :invalid_outbox_item}
        end

      _ ->
        {:error, :invalid_outbox_item}
    end
  end

  def parse_key(_), do: {:error, :invalid_outbox_item}

  def item_bytes(i) do
    IO.iodata_to_binary([
      <<1, 5>>,
      field(i.stream),
      <<i.sequence::64, i.position::64>>,
      field(i.destination),
      field(i.idempotency_key),
      field(i.payload),
      field(i.nonce)
    ])
  end

  def item_valid?(i) when is_map(i) do
    try do
      stream?(i.stream) and uint?(i.sequence) and i.sequence > 0 and small_uint?(i.position) and
        destination?(i.destination) and
        is_binary(i.payload) and nonce?(i.nonce) and
        i.idempotency_key == item_key(i.stream, i.sequence, i.position) and
        i.digest == hash(item_bytes(i)) and valid_ack?(i)
    rescue
      _ -> false
    end
  end

  def item_valid?(_), do: false

  def ack_receipt(key, nonce) do
    {:ok, {stream, sequence, _}} = parse_key(key)
    receipt(:ack, stream, sequence, sequence, nonce, key)
  end

  defp valid_ack?(%{state: :pending, ack_nonce: nil, ack_digest: nil}), do: true

  defp valid_ack?(%{state: :acked} = i) do
    nonce?(i.ack_nonce) and i.ack_digest == ack_receipt(i.idempotency_key, i.ack_nonce).digest
  end

  defp valid_ack?(_), do: false
  defp bool(false), do: 0
  defp bool(true), do: 1
  defp operation_tag(:retain), do: 2
  defp operation_tag(:ack), do: 3
  defp operation_tag(:repair_torn_tail), do: 4
  defp diagnostic({s, :gap}), do: <<1, s::64>>
  defp diagnostic({s, :out_of_order}), do: <<2, s::64>>
  defp diagnostic({:truncated, head, last}), do: <<3, head::64, last::64>>

  defp diagnostic({:corrupt, s, reason}),
    do: <<4, s::64, Enum.find_index(@reasons, &(&1 == reason))::8>>

  defp diagnostic_valid?({s, order}) when order in [:gap, :out_of_order], do: uint?(s) and s > 0
  defp diagnostic_valid?({:truncated, h, l}), do: uint?(h) and uint?(l) and h > l
  defp diagnostic_valid?({:corrupt, s, reason}), do: uint?(s) and reason in @reasons
  defp diagnostic_valid?(_), do: false
end
