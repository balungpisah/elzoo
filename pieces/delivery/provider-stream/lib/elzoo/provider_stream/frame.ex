# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream.Frame do
  @moduledoc """
  One offered frame: `chunk` is `%{seq, kind, payload}` (see
  `Elzoo.ProviderStream.Chunk`). The sink acknowledges it with
  `{:ack, frame.callback_ref, frame.seq}`. A frame is partial output and data
  only; a tool call is usable only from a complete result.
  """
  defstruct [:callback_ref, :seq, :chunk]
end
