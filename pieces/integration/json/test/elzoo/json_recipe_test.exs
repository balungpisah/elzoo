# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.JsonRecipeTest do
  use ExUnit.Case, async: true

  test "Jason handles JSON values directly and rejects malformed input" do
    for value <- [%{"items" => [1, true, nil, "日本語"]}, [], "", 4.5] do
      assert {:ok, encoded} = Jason.encode(value)
      assert Jason.decode(encoded) == {:ok, value}
    end

    assert {:error, %Jason.DecodeError{}} = Jason.decode("{broken")
    assert {:error, %Jason.EncodeError{}} = Jason.encode(<<255>>)
  end
end
