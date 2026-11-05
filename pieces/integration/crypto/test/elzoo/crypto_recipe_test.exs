# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CryptoRecipeTest do
  use ExUnit.Case, async: true

  test "OTP SHA-256 matches the published abc vector" do
    assert :crypto.hash(:sha256, "abc") |> Base.encode16(case: :lower) ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
