# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Secrets.Credential do
  @moduledoc """
  Sampled credential with constant redacted Inspect. Not an access-control or
  memory-protection boundary: trusted injection code uses `Elzoo.Secrets.reveal/1`.
  """
  @enforce_keys [:value, :version, :expires_at_unix_ms]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(_, _), do: "#Elzoo.Secrets.Credential<redacted>"
  end
end
