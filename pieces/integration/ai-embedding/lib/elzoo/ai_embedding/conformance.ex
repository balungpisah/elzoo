# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Conformance do
  @moduledoc """
  The provider conformance kit of the embedding interface: provider-neutral
  scenario data plus plain functions (no ExUnit macro, no test-only
  dependency), exported with the interface so every provider Piece, and every
  consumer that copies one, runs the same expectations.

  For each scenario a provider's own test builds the request with `request/3`,
  answers it with a stub in the provider's documented format that realizes the
  scenario's `stub` meaning, drives one call through `Elzoo.AiEmbedding` and the
  EffectIntent owner, and passes the sink delivery, the number of HTTP requests
  the stub observed and the expected vector dimension to `check/4`, which
  returns `:ok` or `{:error, scenario, reason}`.

  Stub meanings: `{:items, items}` means a success response listing exactly
  `items(id, dims)` (each `%{index, vector}`, in that order; a `nil` element is
  the provider format's null) with the requested model as the served model and
  full usage; `{:items_no_usage, items}` the same without a usage object;
  `{:items_other_model, items}` the same with another served model;
  `:malformed_success` a 2xx that is not the provider's documented success
  object; `:timeout` a transport timeout after the request was sent;
  `:throttled` the provider's documented rate-limit status with a 7-second
  retry-after; `:overloaded` its documented overload status; `:server_error` its
  documented internal-error status.
  """

  @inputs ["alpha", "beta", "gamma"]

  @scenarios [
    %{id: :single_input, inputs: 1, stub: :items},
    %{id: :multiple_inputs, inputs: 3, stub: :items},
    %{id: :out_of_order, inputs: 3, stub: :items},
    %{id: :fewer, inputs: 3, stub: :items},
    %{id: :more, inputs: 3, stub: :items},
    %{id: :duplicate_index, inputs: 3, stub: :items},
    %{id: :out_of_range_index, inputs: 3, stub: :items},
    %{id: :wrong_length, inputs: 3, stub: :items},
    %{id: :non_number, inputs: 3, stub: :items},
    %{id: :beyond_float32, inputs: 3, stub: :items},
    %{id: :non_unit, inputs: 3, stub: :items},
    %{id: :other_model, inputs: 3, stub: :items_other_model},
    %{id: :usage_omitted, inputs: 3, stub: :items_no_usage},
    %{id: :malformed_success, inputs: 3, stub: :malformed_success},
    %{id: :timeout_after_send, inputs: 3, stub: :timeout},
    %{id: :throttled, inputs: 3, stub: :throttled},
    %{id: :overloaded, inputs: 3, stub: :overloaded},
    %{id: :server_error, inputs: 3, stub: :server_error}
  ]

  @malformed [
    :fewer,
    :more,
    :duplicate_index,
    :out_of_range_index,
    :wrong_length,
    :non_number,
    :beyond_float32,
    :other_model,
    :malformed_success
  ]

  def scenarios, do: @scenarios
  def ids, do: Enum.map(@scenarios, & &1.id)
  def scenario(id), do: Enum.find(@scenarios, &(&1.id == id))

  @doc "The scenario's request object for `model`; `dimensions` nil means the model's native one."
  def request(id, model, dimensions) do
    %{inputs: n} = scenario(id)
    base = %{"version" => 1, "model" => model, "inputs" => Enum.take(@inputs, n)}
    if dimensions, do: Map.put(base, "dimensions", dimensions), else: base
  end

  @doc "A `core/effect` declaration carrying `request` for logical reference `ref`."
  def declaration(request, ref, deadline_unix_ms) do
    %{
      "capability_id" => "integration/ai-embedding",
      "operation" => "embed",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "msg-" <> ref,
        "schema_id" => "elzoo/ai-embedding-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "conformance", "port_id" => "out"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline_unix_ms,
        "payload" => Elzoo.AiEmbedding.Request.canonical(request)
      }
    }
  end

  @doc "The scenario's stub meaning: `{kind, items}` or an atom (see the module documentation)."
  def stub(id, dims) do
    case scenario(id).stub do
      kind when kind in [:items, :items_no_usage, :items_other_model] -> {kind, items(id, dims)}
      other -> other
    end
  end

  @doc "The neutral items a success stub lists for scenario `id` (unit basis vectors unless the scenario says otherwise)."
  def items(id, dims) do
    n = scenario(id).inputs
    good = for i <- 0..(n - 1), do: %{index: i, vector: basis(i, dims)}

    case id do
      :out_of_order ->
        Enum.reverse(good)

      :fewer ->
        Enum.drop(good, -1)

      :more ->
        good ++ [%{index: n, vector: basis(0, dims)}]

      :duplicate_index ->
        List.replace_at(good, 2, %{index: 1, vector: basis(2, dims)})

      :out_of_range_index ->
        List.replace_at(good, 2, %{index: n, vector: basis(2, dims)})

      :wrong_length ->
        List.update_at(good, 1, &%{&1 | vector: Enum.drop(&1.vector, -1)})

      :non_number ->
        List.update_at(good, 1, &%{&1 | vector: List.replace_at(&1.vector, 0, nil)})

      :beyond_float32 ->
        List.update_at(good, 1, &%{&1 | vector: List.replace_at(&1.vector, 0, 1.0e39)})

      :non_unit ->
        Enum.map(good, &%{&1 | vector: Enum.map(&1.vector, fn x -> x * 2.0 end)})

      _ ->
        good
    end
  end

  # The unit vector e_(i mod dims).
  defp basis(i, dims), do: for(k <- 0..(dims - 1), do: if(k == rem(i, dims), do: 1.0, else: 0.0))

  @doc """
  Checks the sink delivery (`{:outcome, attempt_id, outcome}`), the number of
  HTTP requests the provider's stub observed and the expected dimension for
  scenario `id`.
  """
  def check(id, delivery, requests, dims) do
    cond do
      scenario(id) == nil -> {:error, id, :unknown_scenario}
      requests != 1 -> {:error, id, {:requests, requests}}
      true -> expect(id, outcome(delivery), dims) |> result(id)
    end
  end

  defp outcome({:outcome, _attempt, outcome}), do: outcome
  defp outcome(other), do: {:no_outcome, other}

  defp result(:ok, _), do: :ok
  defp result({:error, reason}, id), do: {:error, id, reason}

  defp expect(id, {:completed, c}, dims)
       when id in [:single_input, :multiple_inputs, :out_of_order] do
    n = scenario(id).inputs

    with :ok <- is(Enum.map(c.embeddings, & &1.index) == Enum.to_list(0..(n - 1)), :order),
         :ok <-
           is(Enum.all?(c.embeddings, &(&1.vector == basis(&1.index, dims))), :vectors),
         :ok <- is(c.descriptor.dimensions == dims and c.descriptor.dtype == :float32, :dims),
         :ok <- is(c.descriptor.normalization == :unit_l2_verified, :normalization),
         :ok <- is(c.descriptor.model == c.provenance.model_ref.model_id, :model) do
      is(c.usage.source == :provider_reported, :usage_source)
    end
  end

  defp expect(:non_unit, {:completed, c}, _dims) do
    with :ok <- is(length(c.embeddings) == 3, :count) do
      is(c.descriptor.normalization == :none, :normalization)
    end
  end

  defp expect(:usage_omitted, {:completed, c}, _dims) do
    with :ok <- is(c.usage.source == :unknown, :usage_source) do
      is(Elzoo.AiModel.Usage.amount(c.usage, :input_uncached_tokens) == :unknown, :usage)
    end
  end

  defp expect(id, o, _dims) when id in @malformed,
    do: is(o == {:unknown, :malformed_response}, :outcome)

  defp expect(:timeout_after_send, o, _), do: is(o == {:unknown, :timeout}, :outcome)

  defp expect(:throttled, o, _),
    do: is(o == {:refused, :throttled, %{retry_after: 7}}, :outcome)

  defp expect(:overloaded, o, _), do: is(match?({:refused, :overloaded, _}, o), :outcome)
  defp expect(:server_error, o, _), do: is(o == {:unknown, :provider_error}, :outcome)
  defp expect(_, _, _), do: {:error, :outcome}

  defp is(true, _), do: :ok
  defp is(_, reason), do: {:error, reason}
end
