# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Descriptor do
  @moduledoc """
  The embedding descriptor carried by every completed result:
  `%{provider: text, model: text, dimensions: n, dtype: :float32, normalization:
  :unit_l2_verified | :none}`.

  - `provider` is the provider Piece's provider name (for example `"openai"`);
    `model` the requested allowlisted model identifier, which the response's
    served model must equal; `dimensions` the validated vector length; `dtype`
    is always `:float32` in this slice.
  - `normalization` is `:unit_l2_verified` when the Adapter checked that every
    vector of the call satisfies `abs(norm_l2(v) - 1) <= 1.0e-3` (`tolerance/0`,
    fixed by the Contract, not configurable), otherwise `:none`.

  Two descriptors are compatible only when all five fields are equal
  (`compatible?/2`); a store keyed on a descriptor relies on that.
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  @tolerance 1.0e-3
  @float32_max 3.4028234663852886e38

  def tolerance, do: @tolerance
  def float32_max, do: @float32_max

  @doc "Validates a descriptor value."
  def validate(d) do
    if exact_keys?(d, [:provider, :model, :dimensions, :dtype, :normalization]) and
         text?(d.provider, 64) and text?(d.model, 256) and is_integer(d.dimensions) and
         d.dimensions >= 1 and d.dtype == :float32 and
         d.normalization in [:unit_l2_verified, :none],
       do: {:ok, d},
       else: {:error, :descriptor}
  end

  @doc "True only when both are valid descriptors with all five fields equal."
  def compatible?(a, b) do
    match?({:ok, _}, validate(a)) and match?({:ok, _}, validate(b)) and a == b
  end

  @doc "`:unit_l2_verified` when every vector's L2 norm is within `tolerance/0` of 1, else `:none`."
  def normalization(vectors) when is_list(vectors) do
    if vectors != [] and Enum.all?(vectors, &unit?/1), do: :unit_l2_verified, else: :none
  end

  defp unit?(v) do
    norm = :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
    abs(norm - 1.0) <= @tolerance
  end
end
