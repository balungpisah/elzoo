# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.CacheHint do
  @moduledoc """
  A provider-neutral prompt-cache hint:
  `%{tenant: text, local_key: text, ttl: ttl, breakpoints: [breakpoint]}`.

  `tenant` must equal the dispatch tenant; a mismatch is refused
  `:invalid_request`. A provider derives any wire cache key from both `tenant` and
  `local_key` and never accepts a caller-supplied global wire key. `ttl` is one of
  `Elzoo.AiModel.Usage.ttls/0`. A breakpoint is `:tools`, `:system` or
  `{:message, index}` (index a non-negative integer); 1 to 4 distinct breakpoints.
  A provider maps the hint to its documented mechanism or refuses the request
  `:unsupported_feature`; it never drops the hint silently.
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  @max_breakpoints 4

  def max_breakpoints, do: @max_breakpoints

  @doc "Validates `hint` for a call whose dispatch tenant is `dispatch_tenant`."
  def validate(hint, dispatch_tenant) do
    cond do
      not exact_keys?(hint, [:tenant, :local_key, :ttl, :breakpoints]) -> {:error, :invalid_request}
      not (text?(hint.tenant, 256) and text?(hint.local_key, 256)) -> {:error, :invalid_request}
      hint.ttl not in Elzoo.AiModel.Usage.ttls() -> {:error, :invalid_request}
      not breakpoints?(hint.breakpoints) -> {:error, :invalid_request}
      not (is_binary(dispatch_tenant) and hint.tenant == dispatch_tenant) -> {:error, :invalid_request}
      true -> {:ok, hint}
    end
  end

  defp breakpoints?(list) do
    is_list(list) and length(list) in 1..@max_breakpoints and Enum.all?(list, &breakpoint?/1) and
      length(Enum.uniq(list)) == length(list)
  end

  defp breakpoint?(:tools), do: true
  defp breakpoint?(:system), do: true
  defp breakpoint?({:message, i}), do: is_integer(i) and i >= 0
  defp breakpoint?(_), do: false
end
