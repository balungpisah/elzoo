# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxHelpersTest do
  @moduledoc """
  Groups `policy_v2_identity`, `helpers_surface`, `text_helpers` and `helpers_are_bounded`
  (the `text_split` scenario so far) of the helper set (policy version 2).

  The helper names of the contract are one module attribute (`@helpers`); each helper that
  the host gains is added there and the descriptor, the audit and the probes must agree.

  Negative control (recorded in the pull request, never committed): granting one more field
  of `helpers` in the C host makes the audit and the descriptor disagree.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Descriptor

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 180_000

  # The helper names of the contract; each later helper is added here.
  @helpers ~w(null object text_trim)

  @valid "return function() return 1 end"
  @mismatch %{"status" => "refused", "reason" => "policy_mismatch"}

  setup_all do
    {executable, _directory} = Helper.build!("helpers")
    %{executable: executable}
  end

  defp audit!(exe) do
    {output, 0} = System.cmd(exe, ["--audit"])
    Helper.decode_frame!(output)
  end

  defp raw_frame(policy) do
    Helper.frame(
      Jason.encode!(%{
        "source" => @valid,
        "input" => nil,
        "policy" => policy,
        "limits" => %{
          "steps" => 1000,
          "call_depth" => 8,
          "value_bytes" => 1000,
          "memory_bytes" => 16_777_216,
          "wall_ms" => 500
        }
      })
    )
  end

  defp run(exe, body), do: Helper.run(exe, Helper.function_source(body))

  describe "policy_v2_identity" do
    test "the descriptor names version 2 and the sorted helpers, with the v2 identity" do
      %{identity: identity, descriptor: descriptor} = LuaSandbox.policy()

      assert descriptor["policy_version"] == 2

      assert descriptor["helpers"] ==
               for(name <- Enum.sort(@helpers), do: %{"name" => name, "version" => 1})

      assert identity =~ ~r/\Apolicy-v2:sha256:[0-9a-f]{64}\z/
      assert identity == Descriptor.identity(descriptor)
    end

    test "a v1 identity and an identity with one helper removed are policy_mismatch", %{
      executable: exe
    } do
      %{identity: identity, descriptor: descriptor} = LuaSandbox.policy()
      "policy-v2:sha256:" <> digest = identity
      v1 = "policy-v1:sha256:" <> digest
      removed = Descriptor.identity(put_in(descriptor, ["helpers"], tl(descriptor["helpers"])))

      refute removed == identity
      assert removed =~ ~r/\Apolicy-v2:sha256:[0-9a-f]{64}\z/

      # the same source succeeds under the right identity
      assert {:ok, %{value: 1}} = Helper.run(exe, @valid)

      for other <- [v1, removed] do
        request = %{Helper.request(@valid) | policy: other}
        assert LuaSandbox.run(exe, request) == {:refused, :policy_mismatch}, other

        # the host itself gives the same answer to the raw frame
        {output, 0} = Helper.raw_exchange(exe, raw_frame(other))
        assert Helper.decode_frame!(output) == @mismatch, other
      end

      # and the raw frame of the right identity is accepted
      {output, 0} = Helper.raw_exchange(exe, raw_frame(identity))
      assert %{"status" => "ok", "value" => 1} = Helper.decode_frame!(output)
    end

    test "the audit, the descriptor and fixed-name probes agree on the helper names", %{
      executable: exe
    } do
      audit = audit!(exe)
      listed = for %{"name" => name} <- LuaSandbox.policy().descriptor["helpers"], do: name

      assert listed == Enum.sort(@helpers)
      assert audit["names"]["helpers"] == "table"

      assert for({"helpers." <> name, _} <- audit["names"], do: name) |> Enum.sort() == listed

      for name <- listed do
        audited = audit["names"]["helpers." <> name]
        assert audited in ["function", "userdata"], name
        assert {:ok, %{value: ^audited}} = run(exe, "return type(helpers.#{name})")
      end
    end
  end

  describe "helpers_surface" do
    test "each listed helper is reachable", %{executable: exe} do
      assert {:ok, %{value: "userdata"}} = run(exe, "return type(helpers.null)")
      assert {:ok, %{value: true}} = run(exe, "return helpers.null ~= nil")
      assert {:ok, %{value: true}} = run(exe, "return helpers.null == helpers.null")
      assert {:ok, %{value: "function"}} = run(exe, "return type(helpers.object)")
      assert {:ok, %{value: "table"}} = run(exe, "return type(helpers)")
    end

    test "a name that is not listed is unlisted_name, also inside pcall", %{executable: exe} do
      for name <- ~w(helpers.x helpers.json helpers.__index json text time clock now helper_echo) do
        assert run(exe, "return #{name}") == {:refused, :unlisted_name}, name
        assert run(exe, "return type(#{name})") == {:refused, :unlisted_name}, name

        assert run(exe, "return pcall(function() return #{name} end)") ==
                 {:refused, :unlisted_name},
               name
      end
    end

    test "an assignment to helpers lasts one run, and the next run has the policy", %{
      executable: exe
    } do
      assert {:ok, %{value: [1, 2]}} =
               run(
                 exe,
                 "helpers.object = 1 helpers.newfield = 2 return {helpers.object, helpers.newfield}"
               )

      assert {:ok, %{value: "function"}} = run(exe, "return type(helpers.object)")
      assert run(exe, "return helpers.newfield") == {:refused, :unlisted_name}

      # a listed field assigned to nil is a value of that run only
      assert {:ok, %{value: "function"}} =
               run(exe, "helpers.null = nil return type(helpers.object)")

      assert {:ok, %{value: "userdata"}} = run(exe, "return type(helpers.null)")
    end

    test "the metatable of helpers is not reachable", %{executable: exe} do
      assert run(exe, "return getmetatable(helpers)") == {:refused, :unlisted_name}
      assert run(exe, "return (\"\").helpers") == {:refused, :unlisted_name}
      assert run(exe, "return pcall(getmetatable, helpers)") == {:refused, :unlisted_name}
    end

    test "tostring of a helper is a lua_error", %{executable: exe} do
      assert run(exe, "return tostring(helpers.object)") == {:refused, :lua_error}
      assert run(exe, "return tostring(helpers.null)") == {:refused, :lua_error}
    end

    test "null and object values encode as the contract says", %{executable: exe} do
      assert {:ok, %{value: value}} = run(exe, "return helpers.object()")
      assert value == %{}

      assert {:ok, %{value: [nil]}} = run(exe, "return {helpers.null}")
      assert {:ok, %{value: nil}} = run(exe, "return helpers.null")
      assert {:ok, %{value: [%{}]}} = run(exe, "return {helpers.object()}")
      assert {:ok, %{value: %{"a" => %{}}}} = run(exe, "return {a = helpers.object()}")
      assert {:ok, %{value: %{"a" => 1}}} = run(exe, "local o = helpers.object() o.a = 1 return o")
      assert {:ok, %{value: [%{}, []]}} = run(exe, "return {helpers.object(), {}}")

      # each call makes a fresh table
      assert {:ok, %{value: true}} = run(exe, "return helpers.object() ~= helpers.object()")
    end

    test "helpers.object takes no argument: pcall catches the error, uncaught it is lua_error", %{
      executable: exe
    } do
      assert {:ok, %{value: true}} = run(exe, "return select(1, pcall(helpers.object, 1)) == false")
      assert {:ok, %{value: true}} = run(exe, "return select(1, pcall(helpers.object)) == true")
      assert run(exe, "return helpers.object(1)") == {:refused, :lua_error}
      assert run(exe, "return helpers.object(nil)") == {:refused, :lua_error}
    end
  end

  describe "text_helpers" do
    test "trim removes each of the six ASCII space characters at the start and at the end", %{
      executable: exe
    } do
      source = ~S"""
      local ok = true
      for _, c in ipairs({"\x20", "\x09", "\x0A", "\x0B", "\x0C", "\x0D"}) do
        ok = ok and helpers.text_trim(c .. "ab" .. c) == "ab"
        ok = ok and helpers.text_trim(c .. c .. c .. "ab") == "ab"
        ok = ok and helpers.text_trim("ab" .. c .. c .. c) == "ab"
        ok = ok and helpers.text_trim(c) == ""
      end
      return ok
      """

      assert {:ok, %{value: true}} = run(exe, source)
    end

    test "trim: mixed runs, no space, all space, empty, inner space kept", %{executable: exe} do
      assert {:ok, %{value: "a b\tc"}} =
               run(exe, ~S|return helpers.text_trim(" \t\n\v\f\r a b\tc \r\f\v\n\t ")|)

      assert {:ok, %{value: "abc"}} = run(exe, ~S|return helpers.text_trim("abc")|)
      assert {:ok, %{value: ""}} = run(exe, ~S|return helpers.text_trim(" \t\n\v\f\r ")|)
      assert {:ok, %{value: ""}} = run(exe, ~S|return helpers.text_trim("")|)
      assert {:ok, %{value: "a  b"}} = run(exe, ~S|return helpers.text_trim("  a  b  ")|)
    end

    test "trim removes nothing else: not NUL, not 0xA0, not U+00A0", %{executable: exe} do
      source = ~S"""
      local nul, nbsp, latin, other = "\0", "\xC2\xA0", "\xA0", "\x1F\x7F"
      return {
        helpers.text_trim(nul .. "a" .. nul) == nul .. "a" .. nul,
        helpers.text_trim(nbsp .. "a" .. nbsp) == nbsp .. "a" .. nbsp,
        helpers.text_trim(" " .. latin .. "a" .. latin .. " ") == latin .. "a" .. latin,
        helpers.text_trim(other .. "a" .. other) == other .. "a" .. other,
        #helpers.text_trim(nul) == 1,
        #helpers.text_trim(" " .. nbsp .. " ") == 2
      }
      """

      assert {:ok, %{value: [true, true, true, true, true, true]}} = run(exe, source)
    end

    test "trim: wrong arguments are errors that pcall catches", %{executable: exe} do
      assert {:ok, %{value: results}} =
               run(exe, wrong_arguments("helpers.text_trim", [~S|"a", "b"|]))

      assert results == List.duplicate(false, 6)

      for call <- ~w[helpers.text_trim() helpers.text_trim(1) helpers.text_trim(nil)
                     helpers.text_trim({})] ++ [~S|helpers.text_trim("a", "b")|] do
        assert run(exe, "return " <> call) == {:refused, :lua_error}, call
      end
    end
  end

  # pcall of each wrong argument list: none, a number, a table, nil, a boolean and the extras;
  # every entry is the first result of pcall
  defp wrong_arguments(name, extras) do
    calls = ["", "1", "{}", "nil", "true"] ++ extras

    entries =
      Enum.map_join(calls, ",\n", &"  (pcall(#{name}#{if &1 == "", do: "", else: ", " <> &1}))")

    "return {\n" <> entries <> "\n}"
  end
end
