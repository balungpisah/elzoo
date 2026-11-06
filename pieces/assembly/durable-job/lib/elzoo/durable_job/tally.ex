# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.Tally do
  @moduledoc "Exemplar pure handler: the sum of the submitted integers. No Effect."
  def run(input) when is_list(input), do: {:ok, Enum.sum(input)}
end
