# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.Failure do
  @moduledoc """
  The two failure classes shared by every model type.

  - `{:refused, reason}`: attested not sent, or rejected by the provider before any
    work was done.
  - `{:unknown, reason}`: the request may have been processed and charged.

  Each type interface owns its closed reason sets; this module checks the class
  and membership only. Reasons are atoms; no provider text is carried.
  """
  def classes, do: [:refused, :unknown]

  def validate({class, reason} = failure, reasons) when class in [:refused, :unknown] and is_map(reasons) do
    if is_atom(reason) and reason in Map.get(reasons, class, []),
      do: {:ok, failure},
      else: {:error, :failure}
  end

  def validate(_, _), do: {:error, :failure}
end
