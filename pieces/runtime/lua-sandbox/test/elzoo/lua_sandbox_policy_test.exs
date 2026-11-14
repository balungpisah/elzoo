# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxPolicyTest do
  @moduledoc """
  The identity and the descriptor of policy version 2, and a first comparison of the
  descriptor with the audit of the host's fresh environment (no Lua path to the audit).
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.{Descriptor, Json}

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000

  setup_all do
    {executable, _directory} = Helper.build!("policy")
    %{executable: executable}
  end

  test "policy is immutable plain data with a canonical identity" do
    %{identity: identity, descriptor: descriptor} = LuaSandbox.policy()
    assert identity =~ ~r/\Apolicy-v2:sha256:[0-9a-f]{64}\z/
    assert identity == Descriptor.identity(descriptor)
    assert LuaSandbox.policy() == LuaSandbox.policy()

    assert descriptor["helpers"] == [
             %{"name" => "json_decode", "version" => 1},
             %{"name" => "json_encode", "version" => 1},
             %{"name" => "null", "version" => 1},
             %{"name" => "object", "version" => 1},
             %{"name" => "text_split", "version" => 1},
             %{"name" => "text_trim", "version" => 1},
             %{"name" => "text_utf8_len", "version" => 1}
           ]

    assert descriptor["bindings"] == %{}
    assert descriptor["framing"]["version"] == 1
    assert descriptor["bounds"]["steps"] == 1_000_000
    assert leaves_are_plain?(descriptor)

    # any change of the descriptor changes the identity
    changed = put_in(descriptor, ["bounds", "steps"], 999_999)
    refute Descriptor.identity(changed) == identity
    assert Json.encode(%{"b" => 1, "a" => [true, nil]}) == ~s({"a":[true,null],"b":1})
  end

  test "the audit of the fresh environment equals the descriptor", %{executable: executable} do
    {output, 0} = System.cmd(executable, ["--audit"])
    <<length::unsigned-little-32, body::binary>> = output
    assert byte_size(body) == length
    audit = Jason.decode!(body)
    names = LuaSandbox.policy().descriptor["names"]

    helper_names =
      for %{"name" => name} <- LuaSandbox.policy().descriptor["helpers"], do: "helpers." <> name

    assert audit["names"] |> Map.keys() |> Enum.sort() ==
             Enum.sort(
               names["functions"] ++
                 names["libraries"] ++
                 ["helpers"] ++ helper_names ++ Map.keys(names["constants"])
             )

    functions =
      for {name, "function"} <- audit["names"],
          not String.starts_with?(name, "helpers."),
          do: name

    assert Enum.sort(functions) == Enum.sort(names["functions"])

    assert for({name, "table"} <- audit["names"], do: name) |> Enum.sort() ==
             Enum.sort(["helpers" | names["libraries"]])

    assert for({name, "number"} <- audit["names"], do: name) |> Enum.sort() ==
             Enum.sort(Map.keys(names["constants"]))

    assert audit["constants"] == names["constants"]
    assert audit["string_metatable"] == LuaSandbox.policy().descriptor["string_metatable"]["keys"]
    assert audit["environment_metatable"] == ["__index"]
    assert audit["helpers_metatable"] == ["__index"]
    assert audit["library_metatable"] == ["__index"]
  end

  defp leaves_are_plain?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and leaves_are_plain?(v) end)

  defp leaves_are_plain?(list) when is_list(list), do: Enum.all?(list, &leaves_are_plain?/1)
  defp leaves_are_plain?(leaf), do: is_integer(leaf) or is_binary(leaf)
end
