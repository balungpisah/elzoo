# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckedCommand.Codec do
  @moduledoc false
  @record_tag :checked_command_record
  @request_tag :checked_command_request
  @mutation_tag :checked_command_mutation
  @stream_prefix "cc1:"
  @max_request_bytes 65_536
  @max_record_bytes 1_048_576

  def stream(tenant) when is_binary(tenant) do
    encoded = :erlang.term_to_binary({:cc, 1, tenant}, [:deterministic])
    @stream_prefix <> Base.url_encode64(encoded, padding: false)
  end

  def canonical_request(tenant, actor, operation_id, descriptor, resource, revision, payload, facts) do
    bytes =
      :erlang.term_to_binary(
        {@request_tag, 1, tenant, actor, operation_id, descriptor, resource, revision, payload,
         facts},
        [:deterministic]
      )

    if byte_size(bytes) <= @max_request_bytes, do: {:ok, bytes}, else: {:error, :too_large}
  rescue
    _ -> {:error, :invalid}
  end

  def mutation_binding(canonical, writes, response) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({@mutation_tag, 1, canonical, writes, response}, [:deterministic])
    )
  rescue
    _ -> nil
  end

  def encode_record(record) when is_map(record) do
    tuple =
      {@record_tag, 1, record.identity, record.descriptor, record.canonical, record.resource,
       record.expected_revision, record.payload, record.portable_payload, record.facts,
       record.prepared, record.mutation_binding, record.decision, record.outcome, record.delta,
       record.approval_events}

    bytes = :erlang.term_to_binary(tuple, [:deterministic])
    if byte_size(bytes) <= @max_record_bytes, do: {:ok, bytes}, else: {:error, :too_large}
  rescue
    _ -> {:error, :invalid}
  end

  def decode_record(bytes) when is_binary(bytes) and byte_size(bytes) in 3..@max_record_bytes do
    case bytes do
      <<131, 104, _::binary>> -> decode_record_term(bytes)
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  def decode_record(_), do: {:error, :invalid}

  defp decode_record_term(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {@record_tag, 1, identity, descriptor, canonical, resource, expected_revision, payload,
       portable_payload, facts, prepared, binding, decision, outcome, delta, approval_events} =
          term ->
        if :erlang.term_to_binary(term, [:deterministic]) == bytes do
          {:ok,
           %{
             identity: identity,
             descriptor: descriptor,
             canonical: canonical,
             resource: resource,
             expected_revision: expected_revision,
             payload: payload,
             portable_payload: portable_payload,
             facts: facts,
             prepared: prepared,
             mutation_binding: binding,
             decision: decision,
             outcome: outcome,
             delta: delta,
             approval_events: approval_events
           }}
        else
          {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end
end
