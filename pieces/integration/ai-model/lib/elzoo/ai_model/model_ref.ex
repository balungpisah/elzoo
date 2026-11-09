# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.ModelRef do
  @moduledoc """
  `%{provider: text, model_id: text, wire_surface: text}`: which provider, which
  model identifier the caller asked for and which wire API carries the call
  (for example `"anthropic"`, `"claude-sonnet-4-5"`, `"messages"`).
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  def validate(ref) do
    if exact_keys?(ref, [:provider, :model_id, :wire_surface]) and text?(ref.provider, 64) and
         text?(ref.model_id, 256) and text?(ref.wire_surface, 64),
       do: {:ok, ref},
       else: {:error, :model_ref}
  end
end
