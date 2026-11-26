# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Conversation.Record do
  @moduledoc """
  The records of one conversation stream: the segment rule of the stream name,
  the exact host DTOs, the three kinds and their exact JSON payloads, and the
  validation of a stored row. Pure: no Store call.

  An entry is a plain map with `kind` (`:input`, `:association` or `:answer`),
  the record fields and `digest`, the SHA-256 of its canonical payload. Two
  inputs or two answers are identical exactly when their kinds and digests
  are equal.
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec

  @version 1
  @kinds %{
    input: "conversation_input",
    association: "conversation_association",
    answer: "conversation_answer"
  }
  @modes Map.new(@kinds, fn {mode, kind} -> {kind, mode} end)
  @fields %{
    input: [message_id: "message_id", role: "role", actor: "actor", text: "text"],
    association: [input_message_id: "input_message_id", run_id: "run_id"],
    answer: [
      message_id: "message_id",
      actor: "actor",
      text: "text",
      run_id: "run_id",
      input_message_id: "input_message_id"
    ]
  }
  @dto_keys %{
    input: [:message_id, :role, :actor, :text],
    association: [:input_message_id, :run_id],
    answer: [:message_id, :actor, :text, :run_id, :input_message_id, :completed]
  }
  @roles ["user", "source"]
  @max_id_bytes 128
  @max_text_bytes 4_096
  @max_segment_bytes 64
  @max_payload_bytes 27_720
  @segment ~r/\A[A-Za-z0-9._-]+\z/

  @doc "The row `schema_version` of every conversation record."
  def version, do: @version

  @doc "The three kind names, which the Store fold must declare."
  def kinds, do: Map.values(@kinds)

  @doc "The kind name of a mode (`:input`, `:association` or `:answer`)."
  def kind(mode), do: Map.fetch!(@kinds, mode)

  @doc "The largest encoded payload: an answer with four 128-byte IDs and a 4,096-byte text."
  def max_payload_bytes, do: @max_payload_bytes

  @doc """
  A stream-name segment (`state/artifact`'s rule): 1..64 bytes of
  `[A-Za-z0-9._-]`, never `.` or `..`. `target_tenant` and `conversation_id`
  are segments, so a stream name is at most 142 bytes.
  """
  def segment?(value),
    do:
      is_binary(value) and byte_size(value) in 1..@max_segment_bytes and
        String.match?(value, @segment) and value not in [".", ".."]

  @doc "The stream of one conversation; both segments are validated by `segment?/1`."
  def stream(target_tenant, conversation_id),
    do: "conversation/" <> target_tenant <> "/" <> conversation_id

  @doc "An ID: 1..128 valid UTF-8 bytes without NUL."
  def id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..@max_id_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  @doc "A message text: 1..4,096 valid UTF-8 bytes; NUL is allowed."
  def text?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_text_bytes and String.valid?(value)

  @doc """
  Validate one exact host DTO of a mode. Returns `{:ok, entry, completed}`,
  where `completed` is the answer's Run completion fact and `true` for the
  other modes, or `:error`.
  """
  def intent(mode, dto) when is_map_key(@dto_keys, mode) do
    keys = Map.fetch!(@dto_keys, mode)

    if is_map(dto) and not is_struct(dto) and map_size(dto) == length(keys) and
         Enum.all?(keys, &Map.has_key?(dto, &1)) and
         (mode != :answer or is_boolean(dto.completed)) do
      entry =
        @fields
        |> Map.fetch!(mode)
        |> Map.new(fn {field, _} -> {field, Map.fetch!(dto, field)} end)
        |> Map.put(:kind, mode)

      if valid?(entry),
        do: {:ok, with_digest(entry), Map.get(dto, :completed, true)},
        else: :error
    else
      :error
    end
  end

  def intent(_mode, _dto), do: :error

  @doc "Build an entry from record fields (used by the version 1 import)."
  def entry(mode, fields) when is_map_key(@fields, mode) do
    entry =
      @fields
      |> Map.fetch!(mode)
      |> Map.new(fn {field, _} -> {field, Map.get(fields, field)} end)
      |> Map.put(:kind, mode)

    if valid?(entry), do: {:ok, with_digest(entry)}, else: :error
  end

  @doc "The canonical payload of an entry: a JSON object with the kind's keys in declared order."
  def payload(%{kind: mode} = entry) do
    values =
      @fields
      |> Map.fetch!(mode)
      |> Enum.map(fn {field, key} -> {key, Map.fetch!(entry, field)} end)

    Jason.encode!(%Jason.OrderedObject{values: values})
  end

  @doc "The row of an entry at `sequence`, with its nonce and format-1 digest."
  def row(stream, sequence, entry, nonce) do
    row = %Log.Record{
      stream: stream,
      sequence: sequence,
      kind: kind(entry.kind),
      schema_version: @version,
      payload: payload(entry),
      nonce: nonce
    }

    %{row | digest: Log.digest(row)}
  end

  @doc "The write request that `Elzoo.DurableLog.Store.write/4` classifies an append of one row against."
  def request(row),
    do: %{
      operation: :append,
      stream: row.stream,
      expected: row.sequence - 1,
      target: row.sequence,
      nonce: row.nonce,
      digest: Codec.hash([Log.canonical_bytes(row)])
    }

  @doc """
  Validate a stored row as the record at `sequence` of `stream`: the stream,
  the sequence, the kind, the schema version, the Store's row checks (nonce,
  size, digest) and the exact payload. Returns `{:ok, entry}` or `:error`.
  """
  def decode(row, stream, sequence, fold, limits) do
    with true <- is_map(row),
         true <- Map.get(row, :stream) == stream and Map.get(row, :sequence) == sequence,
         {:ok, mode} <- Map.fetch(@modes, Map.get(row, :kind)),
         true <- Map.get(row, :schema_version) == @version,
         :ok <- Log.validate_row(row, fold, limits),
         {:ok, entry} <- decode_payload(mode, row.payload) do
      {:ok, entry}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "The public form of an entry: its record fields, `kind` and `sequence`."
  def public(entry, sequence), do: entry |> Map.delete(:digest) |> Map.put(:sequence, sequence)

  defp decode_payload(mode, payload) when is_binary(payload) do
    keys = Enum.map(Map.fetch!(@fields, mode), &elem(&1, 1))

    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(payload, objects: :ordered_objects, strings: :copy),
         true <- Enum.map(pairs, &elem(&1, 0)) == keys,
         entry <- fields(mode, pairs),
         true <- valid?(entry),
         true <- payload(entry) == payload do
      {:ok, Map.put(entry, :digest, :crypto.hash(:sha256, payload))}
    else
      _ -> :error
    end
  end

  defp decode_payload(_mode, _payload), do: :error

  defp fields(mode, pairs) do
    @fields
    |> Map.fetch!(mode)
    |> Enum.zip(pairs)
    |> Map.new(fn {{field, _key}, {_key2, value}} -> {field, value} end)
    |> Map.put(:kind, mode)
  end

  defp with_digest(entry), do: Map.put(entry, :digest, :crypto.hash(:sha256, payload(entry)))

  defp valid?(%{kind: :input} = e),
    do: id?(e.message_id) and e.role in @roles and id?(e.actor) and text?(e.text)

  defp valid?(%{kind: :association} = e), do: id?(e.input_message_id) and id?(e.run_id)

  defp valid?(%{kind: :answer} = e),
    do:
      id?(e.message_id) and id?(e.actor) and text?(e.text) and id?(e.run_id) and
        id?(e.input_message_id)
end
