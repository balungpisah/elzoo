# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxHelpersTest do
  @moduledoc """
  Groups `policy_v2_identity`, `helpers_surface`, `text_helpers`, `json_round_trip`,
  `helpers_are_bounded` and `time_values` of the helper set (policy version 2).

  The helper names of the contract are one module attribute (`@helpers`); each helper that
  the host gains is added there and the descriptor, the audit and the probes must agree.

  Negative control (recorded in the pull request, never committed): granting one more field
  of `helpers` in the C host makes the audit and the descriptor disagree.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Descriptor
  alias Elzoo.LuaSandbox.Json

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 180_000

  # The helper names of the contract.
  @helpers ~w(json_decode json_encode null object text_split text_trim text_utf8_len time_iso8601 time_parts time_unix_ms)

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

      # the exact ten names, as a literal, sorted
      assert for(%{"name" => name} <- descriptor["helpers"], do: name) ==
               ~w(json_decode json_encode null object text_split text_trim text_utf8_len time_iso8601 time_parts time_unix_ms)
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

    test "split: separator at the start, at the end, doubled, absent, several", %{executable: exe} do
      assert {:ok, %{value: ["", "a", "b"]}} = run(exe, ~S|return helpers.text_split(",a,b", ",")|)
      assert {:ok, %{value: ["a", "b", ""]}} = run(exe, ~S|return helpers.text_split("a,b,", ",")|)
      assert {:ok, %{value: ["a", "", "b"]}} = run(exe, ~S|return helpers.text_split("a,,b", ",")|)
      assert {:ok, %{value: ["abc"]}} = run(exe, ~S|return helpers.text_split("abc", ",")|)

      assert {:ok, %{value: ["a", "b", "c"]}} =
               run(exe, ~S|return helpers.text_split("a,b,c", ",")|)

      assert {:ok, %{value: ["", ""]}} = run(exe, ~S|return helpers.text_split(",", ",")|)
      assert {:ok, %{value: ["", "", ""]}} = run(exe, ~S|return helpers.text_split(",,", ",")|)
    end

    test "split: a multi-byte separator, plain and non-overlapping, left to right", %{
      executable: exe
    } do
      assert {:ok, %{value: ["a", "b", "c"]}} =
               run(exe, ~S|return helpers.text_split("a::b::c", "::")|)

      # not a pattern: the separator is plain text
      assert {:ok, %{value: ["a", "b"]}} = run(exe, ~S|return helpers.text_split("a.%b", ".%")|)
      assert {:ok, %{value: ["a", "b"]}} = run(exe, ~S|return helpers.text_split("a b", " ")|)

      # overlapping candidates: ":::" holds "::" once, then ":" is left
      assert {:ok, %{value: ["", ":"]}} = run(exe, ~S|return helpers.text_split(":::", "::")|)
      assert {:ok, %{value: ["", "", ""]}} = run(exe, ~S|return helpers.text_split("::::", "::")|)
      assert {:ok, %{value: ["", "aa"]}} = run(exe, ~S|return helpers.text_split("aaaaa", "aaa")|)

      # a partial match at the end is not a separator
      assert {:ok, %{value: ["x", "a"]}} = run(exe, ~S|return helpers.text_split("xaba", "ab")|)

      assert {:ok, %{value: ["x", "y", "", ""]}} =
               run(exe, ~S|return helpers.text_split("xabyabab", "ab")|)

      assert {:ok, %{value: ["aab"]}} = run(exe, ~S|return helpers.text_split("aab", "abb")|)

      assert {:ok, %{value: ["é", "è"]}} = run(exe, ~S'return helpers.text_split("é|è", "|")')
    end

    test "split: the empty text, a separator longer than the text, a one-byte text", %{
      executable: exe
    } do
      assert {:ok, %{value: [""]}} = run(exe, ~S|return helpers.text_split("", ",")|)
      assert {:ok, %{value: ["ab"]}} = run(exe, ~S|return helpers.text_split("ab", "abc")|)
      assert {:ok, %{value: [""]}} = run(exe, ~S|return helpers.text_split("", "abc")|)
      assert {:ok, %{value: ["", ""]}} = run(exe, ~S|return helpers.text_split("a", "a")|)
    end

    test "split: the result is a dense array of n + 1 parts", %{executable: exe} do
      source = ~S"""
      local t = helpers.text_split("a,b,,c,", ",")
      local n = 0
      for _ in ipairs(t) do n = n + 1 end
      return {#t, n, t[1], t[2], t[3], t[4], t[5], t[6] == nil}
      """

      assert {:ok, %{value: [5, 5, "a", "b", "", "c", "", true]}} = run(exe, source)
    end

    test "split: the empty separator is an error that pcall catches, uncaught lua_error", %{
      executable: exe
    } do
      assert {:ok, %{value: [false, "helpers.text_split: empty separator"]}} =
               run(exe, ~S|return {pcall(helpers.text_split, "abc", "")}|)

      assert {:ok, %{value: [false, "helpers.text_split: empty separator"]}} =
               run(exe, ~S|return {pcall(helpers.text_split, "", "")}|)

      assert run(exe, ~S|return helpers.text_split("abc", "")|) == {:refused, :lua_error}
    end

    test "split: wrong arguments are errors that pcall catches", %{executable: exe} do
      extras = [~S|"a"|, ~S|"a", 1|, ~S|1, ","|, ~S|"a", ",", "c"|, ~S|"a", nil|, ~S|{}, ","|]

      assert {:ok, %{value: results}} = run(exe, wrong_arguments("helpers.text_split", extras))
      assert results == List.duplicate(false, 11)

      for call <-
            ~w[helpers.text_split() helpers.text_split(1) helpers.text_split(nil)] ++
              [
                ~S|helpers.text_split("a")|,
                ~S|helpers.text_split("a", 1)|,
                ~S|helpers.text_split(1, "a")|,
                ~S|helpers.text_split("a", ",", "c")|
              ] do
        assert run(exe, "return " <> call) == {:refused, :lua_error}, call
      end
    end

    test "utf8_len counts code points of ASCII, two-, three- and four-byte characters", %{
      executable: exe
    } do
      source = ~S"""
      return {
        helpers.text_utf8_len(""),
        helpers.text_utf8_len("abc"),
        helpers.text_utf8_len("\xC3\xA9"),
        helpers.text_utf8_len("\xE2\x82\xAC"),
        helpers.text_utf8_len("\xF0\x9F\x98\x80"),
        helpers.text_utf8_len("a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80z"),
        helpers.text_utf8_len("\0\0"),
        helpers.text_utf8_len("\xC2\x80\xDF\xBF\xE0\xA0\x80\xED\x9F\xBF\xEE\x80\x80\xEF\xBF\xBF\xF0\x90\x80\x80\xF4\x8F\xBF\xBF"),
        math.type(helpers.text_utf8_len("abc"))
      }
      """

      assert {:ok, %{value: [0, 3, 1, 1, 1, 5, 2, 8, "integer"]}} = run(exe, source)
    end

    test "utf8_len: each invalid form is an error that pcall catches", %{executable: exe} do
      invalid = ~w(
        \\x80 \\xBF a\\x80 \\xC2 \\xC2a \\xE2\\x82 \\xE2\\x82a \\xF0\\x9F\\x98 \\xF0\\x9F\\x98a
        \\xC0\\xAF \\xC1\\xBF \\xE0\\x80\\xAF \\xE0\\x9F\\xBF \\xF0\\x80\\x80\\xAF \\xF0\\x8F\\xBF\\xBF
        \\xED\\xA0\\x80 \\xED\\xBF\\xBF \\xF4\\x90\\x80\\x80 \\xF5\\x80\\x80\\x80 \\xF8\\x88\\x80\\x80\\x80
        \\xFF \\xFE \\xC2\\xC2 \\xE2\\x82\\xAC\\x80
      )

      for form <- invalid do
        source = ~s|return {pcall(helpers.text_utf8_len, "#{form}")}|

        assert {:ok, %{value: [false, "helpers.text_utf8_len: invalid UTF-8"]}} =
                 run(exe, source),
               form

        assert run(exe, ~s|return helpers.text_utf8_len("#{form}")|) == {:refused, :lua_error},
               form
      end
    end

    test "utf8_len: wrong arguments are errors that pcall catches", %{executable: exe} do
      assert {:ok, %{value: results}} =
               run(exe, wrong_arguments("helpers.text_utf8_len", [~S|"a", "b"|, ~S|"a", nil|]))

      assert results == List.duplicate(false, 7)

      for call <-
            ~w[helpers.text_utf8_len() helpers.text_utf8_len(1) helpers.text_utf8_len(nil)] ++
              [~S|helpers.text_utf8_len("a", "b")|] do
        assert run(exe, "return " <> call) == {:refused, :lua_error}, call
      end
    end
  end

  describe "json_round_trip" do
    test "json_encode of each scalar type, null, nil and the empty containers", %{executable: exe} do
      source = ~S"""
      local e = helpers.json_encode
      return {
        e(true), e(false), e(0), e(-7), e(math.maxinteger), e(math.mininteger),
        e(1.5), e(0.1), e(-0.0), e(1e300), e(2^53), e(100.0),
        e(""), e("abc"), e(helpers.null), e(nil), e({}), e(helpers.object()),
        e({1, 2, 3}), e({{}, helpers.object(), {{}}}), e({b = 1, a = {true, false}})
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)

      assert values == [
               "true",
               "false",
               "0",
               "-7",
               "9223372036854775807",
               "-9223372036854775808",
               "1.5",
               "0.1",
               "-0.0",
               "1.0e300",
               "9007199254740992.0",
               "100.0",
               ~s(""),
               ~s("abc"),
               "null",
               "null",
               "[]",
               "{}",
               "[1,2,3]",
               "[[],{},[[]]]",
               ~s({"a":[true,false],"b":1})
             ]
    end

    test "json_encode of a string: each escape, control bytes, ASCII and multi-byte characters", %{
      executable: exe
    } do
      source = ~S"""
      local e = helpers.json_encode
      return {
        e("\""), e("\\"), e("\b"), e("\f"), e("\n"), e("\r"), e("\t"),
        e("\0"), e("\1"), e("\31"), e("\127"), e("/"),
        e("\xC3\xA9"), e("\xE2\x82\xAC"), e("\xF0\x9F\x98\x80"),
        e("a\"b\\c\n\xF0\x9F\x98\x80z")
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)

      assert values == [
               ~S("\""),
               ~S("\\"),
               ~S("\b"),
               ~S("\f"),
               ~S("\n"),
               ~S("\r"),
               ~S("\t"),
               ~S("\u0000"),
               ~S("\u0001"),
               ~S("\u001f"),
               "\"\x7F\"",
               ~S("/"),
               ~s("é"),
               ~s("€"),
               ~s("😀"),
               ~s("a\\"b\\\\c\\n😀z")
             ]
    end

    test "json_encode sorts object keys by bytes and keeps arrays dense", %{executable: exe} do
      source = ~S"""
      local t = {}
      t["b"] = 1 t["a"] = 2 t["\xC3\xA9"] = 3 t["Z"] = 4 t[""] = 5 t["aa"] = 6
      local arr = {}
      for i = 1, 5 do arr[i] = i * 2 end
      return {helpers.json_encode(t), helpers.json_encode(arr)}
      """

      assert {:ok, %{value: [object, array]}} = run(exe, source)
      assert object == ~s({"":5,"Z":4,"a":2,"aa":6,"b":1,"é":3})
      assert array == "[2,4,6,8,10]"
    end

    test "json_encode of a nested document at depth 32 passes and 33 is an error", %{
      executable: exe
    } do
      source = ~S"""
      local function nest(n) local v = {} for _ = 2, n do v = {v} end return v end
      local function obj(n) local v = {} for _ = 2, n do v = {a = v} end return v end
      local ok32, a = pcall(helpers.json_encode, nest(32))
      local ok33, b = pcall(helpers.json_encode, nest(33))
      local okO32, c = pcall(helpers.json_encode, obj(32))
      local okO33, d = pcall(helpers.json_encode, obj(33))
      return {ok32, a == string.rep("[", 31) .. "[]" .. string.rep("]", 31),
              ok33, b, okO32, #c, okO33, d}
      """

      assert {:ok, %{value: values}} = run(exe, source)

      assert values == [
               true,
               true,
               false,
               "helpers.json_encode: value is not plain data",
               true,
               # 31 members `{"a":` (5 bytes) around `{}`, and 31 closing braces
               31 * 5 + 2 + 31,
               false,
               "helpers.json_encode: value is not plain data"
             ]
    end

    # each value that a result refuses: built in the source, passed to json_encode
    @not_plain [
      "function() end",
      "helpers.json_encode",
      "(function() local t = {} t[1] = t return t end)()",
      "(function() local t = {} t.a = t return t end)()",
      ~S|{1, a = 2}|,
      ~S|{a = 1, [1] = 2}|,
      "{1, nil, 3}",
      "{[1] = 1, [3] = 3}",
      "{[2] = 1}",
      "{[0] = 1}",
      "{[-1] = 1}",
      "{[1.5] = 1}",
      "{[true] = 1}",
      "{[{}] = 1}",
      "{[helpers.null] = 1}",
      "0/0",
      "1/0",
      "-1/0",
      ~S|"\xff"|,
      ~S|"a\xC3"|,
      ~S|"\xED\xA0\x80"|,
      ~S|{["\xff"] = 1}|,
      ~S|{"\xff"}|,
      "(function() local v = {} for _ = 1, 32 do v = {v} end return v end)()",
      "(function() local v = {} for _ = 1, 32 do v = {a = v} end return v end)()",
      "{function() end}",
      "{a = 0/0}",
      "{{{1/0}}}"
    ]

    test "json_encode refuses what a result refuses: pcall catches, uncaught is lua_error", %{
      executable: exe
    } do
      for expression <- @not_plain do
        caught = "return {pcall(helpers.json_encode, #{expression})}"

        assert {:ok, %{value: [false, "helpers.json_encode: value is not plain data"]}} =
                 run(exe, caught),
               expression

        assert run(exe, "return helpers.json_encode(#{expression})") == {:refused, :lua_error},
               expression
      end
    end

    test "json_encode: wrong numbers of arguments are errors", %{executable: exe} do
      assert {:ok, %{value: [false, "helpers.json_encode: expected one value"]}} =
               run(exe, "return {pcall(helpers.json_encode)}")

      assert {:ok, %{value: [false, "helpers.json_encode: expected one value"]}} =
               run(exe, "return {pcall(helpers.json_encode, 1, 2)}")

      assert {:ok, %{value: [false, "helpers.json_encode: expected one value"]}} =
               run(exe, "return {pcall(helpers.json_encode, nil, nil)}")

      assert run(exe, "return helpers.json_encode()") == {:refused, :lua_error}
      assert run(exe, "return helpers.json_encode(1, 2)") == {:refused, :lua_error}
    end

    test "json_encode: a catching pcall leaves the run usable", %{executable: exe} do
      source = ~S"""
      local results = {}
      for i = 1, 5 do
        local ok = pcall(helpers.json_encode, {[true] = i})
        results[#results + 1] = ok
      end
      results[#results + 1] = helpers.json_encode({1, 2})
      return results
      """

      assert {:ok, %{value: [false, false, false, false, false, "[1,2]"]}} = run(exe, source)
    end

    test "json_decode of each scalar type; integers and floats keep their Lua subtype", %{
      executable: exe
    } do
      source = ~S"""
      local d = helpers.json_decode
      return {
        d("true"), d("false"), d("0"), d("-7"), d("9223372036854775807"), d("-9223372036854775808"),
        d("1.5"), d("0.1"), d("1e300"), d("1E2"), d("2e0"), d("-1.5e-3"), d('"abc"'), d('""'),
        d(" \t\r\n 5 \n"),
        math.type(d("1")), math.type(d("-0")), math.type(d("1.0")), math.type(d("1e2")),
        math.type(d("-0.0")), 1 / d("-0.0") < 0, d("-0") == 0,
        d("null") == helpers.null, d("true") == true, d("false") == false
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)

      assert values == [
               true,
               false,
               0,
               -7,
               9_223_372_036_854_775_807,
               -9_223_372_036_854_775_808,
               1.5,
               0.1,
               1.0e300,
               100.0,
               2.0,
               -0.0015,
               "abc",
               "",
               5,
               "integer",
               "integer",
               "float",
               "float",
               "float",
               true,
               true,
               true,
               true,
               true
             ]
    end

    test "json_decode of strings: each escape, surrogate pairs, raw UTF-8, long strings", %{
      executable: exe
    } do
      source = ~S"""
      local d = helpers.json_decode
      local long = string.rep("a\\n\\u00e9", 2000)
      return {
        d([==["é😀\n\/\b\f\r\t\"\\"]==]) == "\xC3\xA9\xF0\x9F\x98\x80\n/\b\f\r\t\"\\",
        d([==["\u0000\u001f\u007F€😀"]==]) == "\0\31\127\xE2\x82\xAC\xF0\x9F\x98\x80",
        d('"\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80 \x7f"') == "\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80 \x7f",
        d('"' .. long .. '"') == string.rep("a\n\xC3\xA9", 2000),
        d('"' .. string.rep("x", 30000) .. '"') == string.rep("x", 30000),
        #d('"' .. string.rep("\\u0041", 5000) .. '"'),
        d([==["😀😀"]==]) == "\xF0\x9F\x98\x80\xF0\x9F\x98\x80",
        d([==["aAb"]==])
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)
      assert values == [true, true, true, true, true, 5000, true, "aAb"]
    end

    test "json_decode: null is helpers.null, empty containers stay distinct, arrays are dense", %{
      executable: exe
    } do
      source = ~S"""
      local d, e = helpers.json_decode, helpers.json_encode
      local a = d("[1,null,3]")
      return {
        d("null") == helpers.null,
        a[2] == helpers.null, #a == 3, a[1], a[3],
        e(d("{}")), e(d("[]")), e(d(" [ ] ")), e(d("{ }")),
        e(d("[[],{},[{}],{\"a\":[],\"b\":{}}]")),
        e(d("{\"1\":\"a\",\"2\":\"b\"}")),
        e(d("{\"b\":1,\"a\":2}")),
        d("[]"), d("{}"), d("[[],{}]"), d("{\"a\":[],\"b\":{}}"), d("null"), d("[null,[null]]")
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)

      assert values == [
               true,
               true,
               true,
               1,
               3,
               "{}",
               "[]",
               "[]",
               "{}",
               ~s([[],{},[{}],{"a":[],"b":{}}]),
               ~s({"1":"a","2":"b"}),
               ~s({"a":2,"b":1}),
               [],
               %{},
               [[], %{}],
               %{"a" => [], "b" => %{}},
               nil,
               [nil, [nil]]
             ]
    end

    test "json_decode of a document at depth 32 passes and 33 is an error, in both directions", %{
      executable: exe
    } do
      source = ~S"""
      local d, e = helpers.json_decode, helpers.json_encode
      local function arr(n) return string.rep("[", n) .. string.rep("]", n) end
      local function obj(n) return string.rep('{"a":', n - 1) .. "{}" .. string.rep("}", n - 1) end
      local ok1, a = pcall(d, arr(32))
      local ok2, b = pcall(d, arr(33))
      local ok3, c = pcall(d, obj(32))
      local ok4, f = pcall(d, obj(33))
      local ok5, g = pcall(d, string.rep("[", 64) .. string.rep("]", 64))
      local ok6, h = pcall(d, string.rep("[", 10000) .. string.rep("]", 10000))
      return {
        ok1, ok1 and e(a) == arr(32), ok2, b,
        ok3, ok3 and e(c) == obj(32), ok4, f, ok5, g, ok6, h
      }
      """

      assert {:ok, %{value: values}} = run(exe, source)
      invalid = "helpers.json_decode: invalid JSON"

      assert values == [
               true,
               true,
               false,
               invalid,
               true,
               true,
               false,
               invalid,
               false,
               invalid,
               false,
               invalid
             ]

      assert run(exe, ~S|return helpers.json_decode(string.rep("[", 33) .. string.rep("]", 33))|) ==
               {:refused, :lua_error}
    end

    @bad_documents [
      ~S|""|,
      ~S|"  \n\t "|,
      ~S|'{"a":1,"a":2}'|,
      ~S|'{"a":1,"b":2,"a":3}'|,
      ~S|'{"a":1,"\\u0061":2}'|,
      ~S|'[{"a":1,"a":1}]'|,
      ~S|"1 2"|,
      ~S|"{} x"|,
      ~S|"[]]"|,
      ~S|"1\0"|,
      ~S|'"\xff"'|,
      ~S|'"a\xC3"'|,
      ~S|'"\xC0\xAF"'|,
      ~S|'"\xED\xA0\x80"'|,
      ~S|'"\xF4\x90\x80\x80"'|,
      ~S|'{"\xff":1}'|,
      ~S|'"\\ud800"'|,
      ~S|'"\\udc00"'|,
      ~S|'"\\ud800\\u0041"'|,
      ~S|'"\\ud800\\ud800"'|,
      ~S|'"\\u12"'|,
      ~S|'"\\u12zz"'|,
      ~S|'"\\x"'|,
      ~S|'"\\'|,
      ~S|'"abc'|,
      ~S|'"a\nb"'|,
      ~S|'"a\0b"'|,
      ~S|'"a\x1fb"'|,
      ~S|"9223372036854775808"|,
      ~S|"-9223372036854775809"|,
      ~S|"1e999"|,
      ~S|"-1e999"|,
      ~S|"0." .. string.rep("0", 70) .. "1"|,
      ~S|string.rep("1", 70)|,
      ~S|"01"|,
      ~S|"+1"|,
      ~S|".5"|,
      ~S|"1."|,
      ~S|"1e"|,
      ~S|"-"|,
      ~S|"--1"|,
      ~S|"0x10"|,
      ~S|"NaN"|,
      ~S|"Infinity"|,
      ~S|"[1,]"|,
      ~S|"[,1]"|,
      ~S|"[1 2]"|,
      ~S|"[1"|,
      ~S|'{"a"}'|,
      ~S|'{"a":}'|,
      ~S|'{"a":1,}'|,
      ~S|'{a:1}'|,
      ~S|'{"a":1'|,
      ~S|"nul"|,
      ~S|"tru"|,
      ~S|"nulll"|,
      ~S|"True"|,
      ~S|"'a'"|,
      ~S|"\xEF\xBB\xBF1"|,
      ~S|"\x0b1"|,
      ~S|"\x0c1"|,
      ~S|"\xC2\xA01"|,
      ~S|string.rep("[", 33) .. string.rep("]", 33)|,
      ~S|string.rep('{"a":', 33) .. "1" .. string.rep("}", 33)|
    ]

    test "json_decode refuses what the reader of a request refuses: pcall catches, uncaught is lua_error",
         %{executable: exe} do
      for expression <- @bad_documents do
        caught = "return {pcall(helpers.json_decode, #{expression})}"

        assert {:ok, %{value: [false, "helpers.json_decode: invalid JSON"]}} = run(exe, caught),
               expression

        assert run(exe, "return helpers.json_decode(#{expression})") == {:refused, :lua_error},
               expression
      end
    end

    test "json_decode: wrong arguments are errors that pcall catches", %{executable: exe} do
      assert {:ok, %{value: results}} =
               run(exe, wrong_arguments("helpers.json_decode", [~S|"1", "2"|, ~S|"1", nil|]))

      assert results == List.duplicate(false, 7)

      for call <-
            ~w[helpers.json_decode() helpers.json_decode(1) helpers.json_decode(nil)
               helpers.json_decode({}) helpers.json_decode(true)] ++
              [~S|helpers.json_decode("1", "2")|] do
        assert run(exe, "return " <> call) == {:refused, :lua_error}, call
      end
    end

    @round_trip_documents [
      nil,
      true,
      false,
      0,
      -1,
      9_223_372_036_854_775_807,
      -9_223_372_036_854_775_808,
      1.5,
      0.1,
      -0.0,
      1.0e300,
      1.0e-300,
      5.0e-324,
      123_456_789.125,
      100.0,
      "",
      "plain",
      "q\" b\\ n\n r\r t\t b\b f\f \u0000 \u001F \u007F / é € 😀",
      [],
      %{},
      [[]],
      [%{}],
      %{"a" => []},
      %{"a" => %{}},
      [nil, [nil], %{"n" => nil}],
      [1, 2.5, "x", true, false, nil, [], %{}],
      %{"b" => 1, "a" => 2, "" => 3, "é" => 4, "Z" => 5, "aa" => [6]},
      %{"k" => %{"k" => %{"k" => [%{"k" => [[[%{}]]]}]}}},
      Enum.reduce(1..32, [], fn _, acc -> [acc] end) |> then(fn [inner] -> inner end),
      Enum.reduce(1..31, %{}, fn _, acc -> %{"a" => acc} end),
      Enum.map(1..300, &%{"id" => &1, "tags" => ["x", "y"], "score" => &1 / 4, "none" => nil})
    ]

    test "json_encode(json_decode(t)) is the canonical text t of each document", %{executable: exe} do
      texts = Enum.map(@round_trip_documents, &Json.encode/1)

      source = """
      return function(x)
        local out = {}
        for i = 1, #x do out[i] = helpers.json_encode(helpers.json_decode(x[i])) end
        return out
      end
      """

      assert {:ok, %{value: results}} = Helper.run(exe, source, texts, %{steps: 1_000_000})
      assert results == texts
    end

    test "a text that is not canonical decodes to the canonical text", %{executable: exe} do
      pairs = [
        {~S| { "b" : [ 1 , 2.50 , "é\/" ] , "a" : null } |, ~s({"a":null,"b":[1,2.5,"é/"]})},
        {"1E2", "100.0"},
        {"-0", "0"},
        {"1e2", "100.0"},
        {"0.10", "0.1"},
        {"[1.0,2.0]", "[1.0,2.0]"},
        {~S|"Aé😀"|, ~s("Aé😀")},
        {~S|"\/\u001f\u007f"|, ~s("/\\u001f\x7F")},
        {~S|{"b":1,"a":2}|, ~s({"a":2,"b":1})},
        {"[ ]", "[]"},
        {"{ }", "{}"},
        {"\r\n[\t1\n]\r", "[1]"}
      ]

      source = """
      return function(x)
        local out = {}
        for i = 1, #x do out[i] = helpers.json_encode(helpers.json_decode(x[i])) end
        return out
      end
      """

      assert {:ok, %{value: results}} = Helper.run(exe, source, Enum.map(pairs, &elem(&1, 0)))
      assert results == Enum.map(pairs, &elem(&1, 1))
    end

    test "json_decode(json_encode(v)) encodes to the same text", %{executable: exe} do
      source = ~S"""
      local values = {
        true, false, 0, -1, math.maxinteger, math.mininteger, 1.5, 0.1, -0.0, 1e300, 5e-324,
        "", "a\"b\\c\n\0\31\xC3\xA9\xF0\x9F\x98\x80", helpers.null, {}, helpers.object(),
        {1, 2, 3}, {{}, helpers.object(), {{}}}, {b = 1, a = {true, helpers.null}},
        {k = {1.5, "x", {n = helpers.null, e = helpers.object(), f = {}}}}
      }
      local out = {}
      for i, v in ipairs(values) do
        local t = helpers.json_encode(v)
        local w = helpers.json_decode(t)
        out[#out + 1] = helpers.json_encode(w) == t
        out[#out + 1] = helpers.json_encode(helpers.json_decode(helpers.json_encode(w))) == t
      end
      out[#out + 1] = #values
      return out
      """

      assert {:ok, %{value: results}} = run(exe, source)
      {flags, [count]} = Enum.split(results, -1)
      assert count == 20
      assert flags == List.duplicate(true, 40)
    end

    test "a decode in the function of a request leaves its input unchanged", %{executable: exe} do
      document = %{
        "list" => [1, 2.5, "x", nil, [], %{}, [%{"deep" => [true, false]}]],
        "map" => %{"b" => %{"c" => []}, "a" => nil},
        "text" => "é\n",
        "empty" => %{}
      }

      input = %{"doc" => document, "text" => Json.encode(document)}

      source = """
      return function(x)
        local decoded = helpers.json_decode(x.text)
        -- the decoded copy is a separate value: change it in many ways
        decoded.list = helpers.null
        decoded.map = helpers.null
        decoded.text = helpers.null
        decoded.empty = helpers.null
        decoded.added = {1, 2, 3}
        local second = helpers.json_decode(x.text)
        second.list[7] = nil
        second.map.a = 1
        return {x.doc, decoded, second, helpers.json_encode(x.doc) == x.text}
      end
      """

      assert {:ok, %{value: [first, decoded, second, same]}} = Helper.run(exe, source, input)

      assert first == document
      assert same == true

      assert decoded == %{
               "list" => nil,
               "map" => nil,
               "text" => nil,
               "empty" => nil,
               "added" => [1, 2, 3]
             }

      assert second["map"] == %{"b" => %{"c" => []}, "a" => 1}
      assert length(second["list"]) == 6
    end

    test "1,000 encode and decode calls in one run give equal results", %{executable: exe} do
      source = ~S"""
      local v = {a = {1, 2, {b = "c\n"}}, s = "x\"y", f = 1.5, n = helpers.null,
                 e = helpers.object(), l = {}, big = math.maxinteger}
      local first = helpers.json_encode(v)
      local equal = true
      for _ = 1, 1000 do
        local text = helpers.json_encode(v)
        local back = helpers.json_decode(text)
        if text ~= first or helpers.json_encode(back) ~= first then equal = false end
      end
      return {equal, first}
      """

      assert {:ok, %{value: [true, first]}} = run(exe, source)

      assert first ==
               ~s({"a":[1,2,{"b":"c\\n"}],"big":9223372036854775807,"e":{},"f":1.5,"l":[],"n":null,"s":"x\\"y"})
    end

    # one rule for both: the text of the helper equals the text of the reply writer
    @reply_values [
      "true",
      "false",
      "0",
      "-9",
      "math.maxinteger",
      "math.mininteger",
      "1.5",
      "-1.5",
      "0.1",
      "-0.0",
      "1e300",
      "1e-300",
      "123456789.125",
      "2^53",
      "2^63",
      "100.0",
      ~S|""|,
      ~S|"a\"b\\c\b\f\n\r\t\0\1\31\127/"|,
      ~S|"\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80"|,
      "helpers.null",
      "{}",
      "helpers.object()",
      "{1, 2, 3}",
      "{{}, helpers.object(), {{}}, helpers.null}",
      ~S|{b = 1, a = 2, ["\xC3\xA9"] = 3, Z = 4, [""] = 5, aa = 6}|,
      ~S|{k = {1.5, "x", {true, false}, {n = helpers.null}}, e = helpers.object(), f = {}}|,
      # the pair and the list around the value take two of the 32 containers
      "(function() local v = {} for _ = 2, 30 do v = {v} end return v end)()",
      "(function() local v = {} for _ = 2, 30 do v = {a = v} end return v end)()"
    ]

    test "json_encode of a value at depth 32 equals the reply writer's text of it", %{
      executable: exe
    } do
      for build <- ["v = {v}", "v = {a = v, b = {}}"] do
        nested = "local v = {} for _ = 2, 32 do #{build} end"

        assert {:ok, %{value: text}} = run(exe, nested <> " return helpers.json_encode(v)")
        assert {:ok, %{value: value}} = run(exe, nested <> " return v")
        assert text == Json.encode(value), build
      end
    end

    test "json_encode(v) equals the reply writer's text of the same value", %{executable: exe} do
      pairs = Enum.map_join(@reply_values, ",\n", &"  {helpers.json_encode(#{&1}), #{&1}}")
      source = "return {\n" <> pairs <> "\n}"

      assert {:ok, %{value: results}} = run(exe, source)
      assert length(results) == length(@reply_values)

      for {[text, value], expression} <- Enum.zip(results, @reply_values) do
        assert text == Json.encode(value), expression
      end
    end
  end

  describe "helpers_are_bounded" do
    @bounded_limits %{steps: 10_000, value_bytes: 65_536, memory_bytes: 16_777_216}

    test "split of 65,536 separator bytes under 10,000 steps is the steps stop", %{executable: exe} do
      # string.rep itself costs no step here, so the helper makes the stop
      source = Helper.function_source(~S|return helpers.text_split(string.rep(",", 65536), ",")|)
      assert Helper.run(exe, source, nil, @bounded_limits) == {:refused, :steps}

      counted = Helper.function_source(~S|return #helpers.text_split(string.rep(",", 65536), ",")|)
      assert {:ok, %{value: 65_537}} = Helper.run(exe, counted, nil, %{steps: 1_000_000})

      # the text as input (the largest input that the request accepts is 65,534 bytes)
      commas = String.duplicate(",", 65_534)
      from_input = "return function(x) return helpers.text_split(x, \",\") end"
      assert Helper.run(exe, from_input, commas, @bounded_limits) == {:refused, :steps}
    end

    test "a pcall around the split does not continue after the steps stop", %{executable: exe} do
      split = ~S|helpers.text_split(string.rep(",", 65536), ",")|

      sources = [
        ~s|return pcall(function() return #{split} end) and "after" or "after"|,
        ~s|local ok = pcall(function() return #{split} end) if not ok then return "marker" end return "after"|,
        ~s|local ok = pcall(function() return #{split} end) return "marker"|,
        ~s|local ok = pcall(helpers.text_split, string.rep(",", 65536), ",") return "after"|
      ]

      for body <- sources do
        assert Helper.run(exe, Helper.function_source(body), nil, @bounded_limits) ==
                 {:refused, :steps},
               body
      end
    end

    test "split charges the compare work: a near-match separator is the steps stop", %{
      executable: exe
    } do
      # the separator nearly matches at about 35,000 positions: without a charge for each compare
      # the helper would read about 10^9 bytes under a limit of 10^6 steps
      call = ~S|helpers.text_split(string.rep("a", 65536), string.rep("a", 30000) .. "b")|
      limits = %{steps: 1_000_000}

      sources = [
        "return " <> call,
        "return pcall(function() return " <> call <> " end)",
        ~s|local ok = pcall(helpers.text_split, string.rep("a", 65536), string.rep("a", 30000) .. "b") return "marker"|
      ]

      for body <- sources do
        assert Helper.run(exe, Helper.function_source(body), nil, limits) == {:refused, :steps},
               body
      end

      # a smaller near-match fits the same limit and gives one part
      small = ~S|return #helpers.text_split(string.rep("a", 200), string.rep("a", 50) .. "b")|
      assert {:ok, %{value: 1}} = Helper.run(exe, Helper.function_source(small), nil, limits)
    end

    test "an encode over value_bytes is the value_size stop, also inside pcall", %{executable: exe} do
      # each string is under value_bytes (65,536); together they are over
      big = ~S|local a = string.rep("a", 30000) local t = {a, a, a}|

      sources = [
        big <> " return helpers.json_encode(t)",
        big <> " return pcall(helpers.json_encode, t)",
        big <> ~S| local ok = pcall(helpers.json_encode, t) return "marker"|,
        big <>
          ~S| local ok = pcall(function() return helpers.json_encode(t) end) if not ok then return "marker" end return "after"|,
        # more members than 5 bytes each can fill: the sorted-key array is refused first
        ~S|local t = {} for i = 1, 14000 do t["k" .. i] = 1 end return helpers.json_encode(t)|,
        ~S|local t = {} for i = 1, 14000 do t["k" .. i] = 1 end local ok = pcall(helpers.json_encode, t) return "marker"|,
        # one string whose escapes make the text longer than value_bytes
        ~S|return helpers.json_encode(string.rep("\n", 40000))|,
        ~S|return pcall(helpers.json_encode, string.rep("\n", 40000)) and "marker"|
      ]

      for body <- sources do
        assert Helper.run(exe, Helper.function_source(body), nil, %{steps: 1_000_000}) ==
                 {:refused, :value_size},
               body
      end

      # a text of exactly value_bytes passes: the quotes and 65,534 bytes
      exact = Helper.function_source(~S|return #helpers.json_encode(string.rep("a", 65534))|)
      assert {:ok, %{value: 65_536}} = Helper.run(exe, exact, nil, %{steps: 1_000_000})

      over = Helper.function_source(~S|return #helpers.json_encode(string.rep("a", 65535))|)
      assert Helper.run(exe, over, nil, %{steps: 1_000_000}) == {:refused, :value_size}
    end

    test "an encode under steps is the steps stop, also inside pcall", %{executable: exe} do
      array = ~S|local t = {} for i = 1, 3000 do t[i] = "abc" end|

      for body <- [
            array <> " return helpers.json_encode(t)",
            array <> " local ok = pcall(helpers.json_encode, t) return \"marker\""
          ] do
        assert Helper.run(exe, Helper.function_source(body), nil, %{steps: 20_000}) ==
                 {:refused, :steps},
               body
      end
    end

    test "a decode of a document near value_bytes in a loop is the memory host outcome", %{
      executable: exe
    } do
      # 64,001 bytes: 8,000 small objects in an array
      document = ~S|local text = "[" .. string.rep('{"a":1},', 7999) .. '{"a":1}]'|
      keep = "local keep = {} for i = 1, LOOP do keep[i] = helpers.json_decode(text) end"
      limits = %{memory_bytes: 4_194_304, steps: 1_000_000}

      loop = fn count ->
        String.replace(document <> " " <> keep, "LOOP", Integer.to_string(count))
      end

      # the text is near the bound, and one decode fits in the memory limit
      assert {:ok, %{value: [64_001, 8_000]}} =
               Helper.run(
                 exe,
                 Helper.function_source(
                   document <> ~S| return {#text, #helpers.json_decode(text)}|
                 ),
                 nil,
                 limits
               )

      assert {:ok, %{value: "kept"}} =
               Helper.run(exe, Helper.function_source(loop.(1) <> ~S| return "kept"|), nil, limits)

      # the loop keeps every result: the memory limit is reached first, not the steps limit
      for body <- [
            loop.(100) <> ~S| return "marker"|,
            "local ok = pcall(function() " <> loop.(100) <> " end) return \"marker\"",
            "local ok = pcall(function() " <>
              loop.(100) <> " end) if not ok then return \"marker\" end return \"after\"",
            document <>
              ~S| local keep = {} for i = 1, 100 do local ok = pcall(function() keep[i] = helpers.json_decode(text) end) end return "marker"|
          ] do
        assert Helper.run(exe, Helper.function_source(body), nil, limits) ==
                 {:host_outcome, :memory},
               body
      end

      # the same loop under a limit that fits its work in steps and a big memory limit is not memory
      assert {:ok, %{value: "kept"}} =
               Helper.run(
                 exe,
                 Helper.function_source(loop.(3) <> ~S| return "kept"|),
                 nil,
                 %{memory_bytes: 16_777_216, steps: 1_000_000}
               )
    end

    test "the step count of one decode grows with its input, on each side of a limit", %{
      executable: exe
    } do
      call = "#helpers.json_decode(x)"
      # a string: the bytes read (the quotes included), the bytes given back
      string = fn n -> Json.encode(String.duplicate("a", n)) end
      # an array of one-digit integers: two bytes read and one entry for each
      array = fn n -> Json.encode(List.duplicate(1, n)) end
      # an object with five-byte keys: `"k0001":1,` is ten bytes read, one entry
      # and the key given back (five bytes)
      object = fn n ->
        Json.encode(Map.new(1..n, &{"k" <> String.pad_leading(Integer.to_string(&1), 4, "0"), 1}))
      end

      for {name, input, per_unit} <- [
            {"string", string, 2},
            {"array", array, 3},
            {"object", object, 16}
          ] do
        small = min_steps(exe, call, input.(500))
        large = min_steps(exe, call, input.(2_000))

        assert {name, large - small} == {name, per_unit * 1_500}

        limit = div(small + large, 2)
        source = "return function(x) return #{call} end"

        assert {:ok, %{value: _}} = Helper.run(exe, source, input.(500), %{steps: limit}), name

        assert Helper.run(exe, source, input.(2_000), %{steps: limit}) == {:refused, :steps},
               name

        assert {:ok, _} = Helper.run(exe, source, input.(500), %{steps: small}), name
        assert Helper.run(exe, source, input.(500), %{steps: small - 1}) == {:refused, :steps}, name
      end
    end

    test "a decode under steps is the steps stop, also inside pcall", %{executable: exe} do
      document = ~S|local text = "[" .. string.rep("1,", 5000) .. "1]"|

      for body <- [
            document <> " return #helpers.json_decode(text)",
            document <> ~S| local ok = pcall(helpers.json_decode, text) return "marker"|
          ] do
        assert Helper.run(exe, Helper.function_source(body), nil, %{steps: 10_000}) ==
                 {:refused, :steps},
               body
      end
    end

    test "the step count grows with the size of the input of each text helper", %{executable: exe} do
      # the cost of one call: the bytes read, the bytes given back, one for each table entry
      for {name, call, per_byte} <- [
            {"text_split", ~S|#helpers.text_split(x, ",")|, 2},
            {"text_trim", ~S|#helpers.text_trim(x)|, 2},
            {"text_utf8_len", ~S|helpers.text_utf8_len(x)|, 1}
          ] do
        base = min_steps(exe, call, String.duplicate("a", 0))
        small = min_steps(exe, call, String.duplicate("a", 1_000))
        large = min_steps(exe, call, String.duplicate("a", 4_000))

        assert small - base == per_byte * 1_000, name
        assert large - base == per_byte * 4_000, name

        # a limit between the two costs: 1,000 bytes pass, 4,000 bytes end in steps
        limit = div(small + large, 2)

        assert {:ok, %{value: _}} =
                 Helper.run(
                   exe,
                   "return function(x) return #{call} end",
                   String.duplicate("a", 1_000),
                   %{steps: limit}
                 ),
               name

        assert Helper.run(
                 exe,
                 "return function(x) return #{call} end",
                 String.duplicate("a", 4_000),
                 %{steps: limit}
               ) == {:refused, :steps},
               name
      end
    end

    test "the step count of one encode grows with its input, on each side of a limit", %{
      executable: exe
    } do
      call = "#helpers.json_encode(x)"

      # a string: its bytes read and its bytes given back (the quotes are constant)
      string = fn n -> String.duplicate("a", n) end
      # an array of one-byte strings: one entry, one byte read and the four bytes `"a",`
      array = fn n -> List.duplicate("a", n) end
      # an object with five-byte keys: one entry, the key read, the key text of seven bytes,
      # the colon, the value `1` and the comma
      object = fn n ->
        Map.new(1..n, &{"k" <> String.pad_leading(Integer.to_string(&1), 4, "0"), 1})
      end

      for {name, input, per_unit} <- [
            {"string", string, 2},
            {"array", array, 6},
            {"object", object, 16}
          ] do
        small = min_steps(exe, call, input.(500))
        large = min_steps(exe, call, input.(2_000))

        # the difference of two sizes (the first member has no comma, so no size 0)
        assert {name, large - small} == {name, per_unit * 1_500}

        limit = div(small + large, 2)
        source = "return function(x) return #{call} end"

        assert {:ok, %{value: _}} = Helper.run(exe, source, input.(500), %{steps: limit}), name

        assert Helper.run(exe, source, input.(2_000), %{steps: limit}) == {:refused, :steps},
               name

        # exactly on each side of the computed cost of the small input
        assert {:ok, _} = Helper.run(exe, source, input.(500), %{steps: small}), name
        assert Helper.run(exe, source, input.(500), %{steps: small - 1}) == {:refused, :steps}, name
      end
    end
  end

  describe "time_values" do
    @max_ms 253_402_300_799_999
    @parts_error "helpers.time_parts: expected an integer in range"
    @iso_error "helpers.time_iso8601: expected an integer in range"
    @unix_error "helpers.time_unix_ms: expected the parts of a real date and time"
    @fields ~w(year month day hour minute second millisecond)

    # {unix_ms, {year, month, day, hour, minute, second, millisecond, weekday}, iso text}
    @known [
      {0, {1970, 1, 1, 0, 0, 0, 0, 4}, "1970-01-01T00:00:00.000Z"},
      {946_684_799_999, {1999, 12, 31, 23, 59, 59, 999, 5}, "1999-12-31T23:59:59.999Z"},
      {946_684_800_000, {2000, 1, 1, 0, 0, 0, 0, 6}, "2000-01-01T00:00:00.000Z"},
      {951_782_400_000, {2000, 2, 29, 0, 0, 0, 0, 2}, "2000-02-29T00:00:00.000Z"},
      {1_704_067_200_000, {2024, 1, 1, 0, 0, 0, 0, 1}, "2024-01-01T00:00:00.000Z"},
      {4_107_456_000_000, {2100, 2, 28, 0, 0, 0, 0, 7}, "2100-02-28T00:00:00.000Z"},
      {4_107_542_400_000, {2100, 3, 1, 0, 0, 0, 0, 1}, "2100-03-01T00:00:00.000Z"},
      {@max_ms, {9999, 12, 31, 23, 59, 59, 999, 5}, "9999-12-31T23:59:59.999Z"}
    ]

    @valid_parts %{
      "year" => 2000,
      "month" => 2,
      "day" => 29,
      "hour" => 0,
      "minute" => 0,
      "second" => 0,
      "millisecond" => 0
    }

    defp lua_value(value) when is_integer(value), do: Integer.to_string(value)
    defp lua_value(value) when is_float(value), do: Float.to_string(value)
    defp lua_value(value) when is_binary(value), do: inspect(value)
    defp lua_value(raw) when is_atom(raw), do: Atom.to_string(raw)

    defp lua_table(map) do
      "{" <> Enum.map_join(map, ", ", fn {k, v} -> "#{k} = #{lua_value(v)}" end) <> "}"
    end

    defp parts_map({year, month, day, hour, minute, second, millisecond, weekday}) do
      %{
        "year" => year,
        "month" => month,
        "day" => day,
        "hour" => hour,
        "minute" => minute,
        "second" => second,
        "millisecond" => millisecond,
        "weekday" => weekday
      }
    end

    test "time_parts, time_unix_ms and time_iso8601 of the boundary values", %{executable: exe} do
      for {ms, parts, iso} <- @known do
        expected = parts_map(parts)
        assert {:ok, %{value: ^expected}} = run(exe, "return helpers.time_parts(#{ms})"), "#{ms}"

        assert {:ok, %{value: ^ms}} =
                 run(exe, "return helpers.time_unix_ms(#{lua_table(expected)})"),
               "#{ms}"

        assert {:ok, %{value: ^iso}} = run(exe, "return helpers.time_iso8601(#{ms})"), "#{ms}"
      end
    end

    test "the weekday of five known dates", %{executable: exe} do
      for {ms, weekday} <- [
            {0, 4},
            {946_684_800_000, 6},
            {951_782_400_000, 2},
            {1_704_067_200_000, 1},
            {@max_ms, 5}
          ] do
        assert {:ok, %{value: ^weekday}} = run(exe, "return helpers.time_parts(#{ms}).weekday"),
               "#{ms}"
      end
    end

    test "time_parts is an object table with exactly eight integer fields", %{executable: exe} do
      source = ~S"""
      local p = helpers.time_parts(86400000 * 365 + 5)
      local n, ints = 0, true
      for _, name in ipairs({"year", "month", "day", "hour", "minute", "second", "millisecond", "weekday"}) do
        n = n + 1
        ints = ints and math.type(p[name]) == "integer"
      end
      return {n, ints, helpers.json_encode(helpers.time_parts(0))}
      """

      assert {:ok,
              %{
                value: [
                  8,
                  true,
                  ~s({"day":1,"hour":0,"millisecond":0,"minute":0,"month":1,"second":0,"weekday":4,"year":1970})
                ]
              }} = run(exe, source)

      # an object, also when it is empty of nothing: it encodes as an object
      assert {:ok, %{value: "{" <> _}} =
               run(exe, "return helpers.json_encode(helpers.time_parts(1))")
    end

    test "an independent calendar (Elixir DateTime) agrees on 400 spread values", %{executable: exe} do
      values = for k <- 0..399, do: k * 633_505_751_999 + rem(k * 7_919_113, 86_400_000)
      assert Enum.all?(values, &(&1 in 0..@max_ms))

      source =
        "return function(list) local r = {} for i = 1, #list do r[i] = helpers.time_parts(list[i]) end return r end"

      assert {:ok, %{value: results}} = Helper.run(exe, source, values, %{steps: 1_000_000})

      for {ms, result} <- Enum.zip(values, results) do
        dt = DateTime.from_unix!(ms, :millisecond)

        assert result == %{
                 "year" => dt.year,
                 "month" => dt.month,
                 "day" => dt.day,
                 "hour" => dt.hour,
                 "minute" => dt.minute,
                 "second" => dt.second,
                 "millisecond" => elem(dt.microsecond, 0) |> div(1000),
                 "weekday" => Date.day_of_week(dt)
               },
               "#{ms}"

        assert {:ok, %{value: iso}} = run(exe, "return helpers.time_iso8601(#{ms})")
        assert iso == DateTime.to_iso8601(dt), "#{ms}"
      end
    end

    test "the two are inverse for 10,000 values spread over the range", %{executable: exe} do
      source = ~S"""
      local bad = 0
      for k = 0, 9999 do
        local v = k * 25340230079 + k * 7919
        if helpers.time_unix_ms(helpers.time_parts(v)) ~= v then bad = bad + 1 end
      end
      local top = 253402300799999
      if helpers.time_unix_ms(helpers.time_parts(top)) ~= top then bad = bad + 1 end
      return bad == 0
      """

      assert {:ok, %{value: true}} =
               Helper.run(exe, Helper.function_source(source), nil, %{
                 steps: 1_000_000
               })
    end

    test "a value outside the range, a fraction, a string or no integer is an error", %{
      executable: exe
    } do
      args = [
        "-1",
        "253402300800000",
        "math.maxinteger",
        "math.mininteger",
        "0.5",
        "1.0",
        ~S|"0"|,
        "nil",
        "",
        "{}",
        "true",
        "0, 0",
        "helpers.null",
        "math.huge"
      ]

      for {name, message} <- [{"time_parts", @parts_error}, {"time_iso8601", @iso_error}] do
        entries =
          Enum.map_join(
            args,
            ", ",
            &"(select(2, pcall(helpers.#{name}#{if &1 == "", do: "", else: ", " <> &1})))"
          )

        assert {:ok, %{value: values}} = run(exe, "return {#{entries}}")
        assert values == List.duplicate(message, length(args)), name

        for arg <- args do
          assert run(exe, "return helpers.#{name}(#{arg})") == {:refused, :lua_error},
                 "#{name} #{arg}"
        end
      end
    end

    test "time_unix_ms: each wrong field or date is an error that pcall catches", %{executable: exe} do
      missing = for f <- @fields, do: {"missing #{f}", Map.delete(@valid_parts, f)}

      wrong =
        for {label, field, value} <- [
              {"float", "year", 2000.0},
              {"float", "month", 2.0},
              {"float", "day", 1.5},
              {"float", "hour", 1.0},
              {"float", "minute", 0.5},
              {"float", "second", 1.0},
              {"float", "millisecond", 0.5},
              {"string", "year", "2000"},
              {"string", "month", "2"},
              {"string", "millisecond", "0"},
              {"year", "year", 1969},
              {"year", "year", 10_000},
              {"year", "year", -2000},
              {"month", "month", 0},
              {"month", "month", 13},
              {"day", "day", 0},
              {"day", "day", 32},
              {"hour", "hour", 24},
              {"hour", "hour", -1},
              {"minute", "minute", 60},
              {"second", "second", 60},
              {"millisecond", "millisecond", 1000},
              {"millisecond", "millisecond", -1}
            ],
            do: {"#{label} #{field} #{value}", Map.put(@valid_parts, field, value)}

      dates =
        for {label, y, m, d} <- [
              {"30 February", 2000, 2, 30},
              {"29 February 2100", 2100, 2, 29},
              {"29 February 2001", 2001, 2, 29},
              {"31 April", 2000, 4, 31},
              {"31 June", 2000, 6, 31},
              {"31 September", 2000, 9, 31},
              {"31 November", 2000, 11, 31}
            ],
            do: {label, Map.merge(@valid_parts, %{"year" => y, "month" => m, "day" => d})}

      for {label, parts} <- missing ++ wrong ++ dates do
        assert {:ok, %{value: @unix_error}} =
                 run(exe, "return select(2, pcall(helpers.time_unix_ms, #{lua_table(parts)}))"),
               label

        assert run(exe, "return helpers.time_unix_ms(#{lua_table(parts)})") ==
                 {:refused, :lua_error},
               label
      end

      # the same date, valid
      assert {:ok, %{value: 951_782_400_000}} =
               run(exe, "return helpers.time_unix_ms(#{lua_table(@valid_parts)})")
    end

    test "time_unix_ms: a non-table argument or the wrong count is an error", %{executable: exe} do
      for arg <- [
            "1",
            ~S|"2000"|,
            "nil",
            "",
            "true",
            "helpers.null",
            "helpers.time_parts",
            "{}, {}"
          ] do
        call = "helpers.time_unix_ms(#{arg})"

        assert {:ok, %{value: @unix_error}} =
                 run(
                   exe,
                   "return select(2, pcall(helpers.time_unix_ms#{if arg == "", do: "", else: ", " <> arg}))"
                 ),
               "#{arg}"

        assert run(exe, "return " <> call) == {:refused, :lua_error}, "#{arg}"
      end
    end

    test "time_unix_ms reads only the seven fields; weekday and extra fields are ignored", %{
      executable: exe
    } do
      for extra <- [%{"weekday" => 99}, %{"extra" => "x"}, %{"weekday" => "no", "extra" => 1.5}] do
        parts = lua_table(Map.merge(@valid_parts, extra))

        assert {:ok, %{value: 951_782_400_000}} = run(exe, "return helpers.time_unix_ms(#{parts})"),
               inspect(extra)
      end
    end

    test "time_unix_ms of helpers or a library table is an error, not unlisted_name", %{
      executable: exe
    } do
      for table <- ["helpers", "math", "string", "table"] do
        assert {:ok, %{value: @unix_error}} =
                 run(exe, "return select(2, pcall(helpers.time_unix_ms, #{table}))"),
               table

        assert run(exe, "return helpers.time_unix_ms(#{table})") == {:refused, :lua_error}, table
      end
    end

    test "no helper result changes between two runs one second apart", %{executable: exe} do
      source = ~S"""
      return {
        helpers.json_decode('{"a":[1,2,{"b":null}],"c":"d"}'),
        helpers.json_encode({3, 2, 1, {x = "y"}}),
        helpers.null,
        helpers.json_encode(helpers.object()),
        helpers.text_split("a,b,,c", ","),
        helpers.text_trim("  \t x y \n"),
        helpers.text_utf8_len("aé€😀"),
        helpers.time_parts(951782400000),
        helpers.time_unix_ms({year = 2100, month = 3, day = 1, hour = 0, minute = 0, second = 0, millisecond = 0}),
        helpers.time_iso8601(253402300799999)
      }
      """

      first = run(exe, source)

      assert {:ok,
              %{value: [_, _, nil, "{}", ["a", "b", "", "c"], "x y", 4, %{}, 4_107_542_400_000, _]}} =
               first

      Process.sleep(1_000)
      assert run(exe, source) == first
    end

    test "the step cost of each time helper is a constant, exact on each side of its limit", %{
      executable: exe
    } do
      # the same instruction shape on both sides, so the difference is the charge alone
      base = min_steps(exe, ~S|type(helpers.text_utf8_len(x)) == "number"|, "")

      cases = [
        {"time_parts", ~S|type(helpers.time_parts(x)) == "table"|, 0, 8},
        {"time_iso8601", ~S|type(helpers.time_iso8601(x)) == "string"|, 0, 24},
        {"time_unix_ms", ~S|type(helpers.time_unix_ms(x)) == "number"|, @valid_parts, 7}
      ]

      for {name, call, input, charge} <- cases do
        cost = min_steps(exe, call, input)
        assert {name, cost - base} == {name, charge}

        source = "return function(x) return #{call} end"
        assert {:ok, %{value: true}} = Helper.run(exe, source, input, %{steps: cost}), name
        assert Helper.run(exe, source, input, %{steps: cost - 1}) == {:refused, :steps}, name
      end
    end

    test "1,000 calls of each time helper end under a steps limit that 1,000 type calls need", %{
      executable: exe
    } do
      loop = fn call -> "for i = 1, 1000 do local _ = #{call} end return true" end
      limit = fn call -> bisect_source(exe, Helper.function_source(loop.(call)), 1, 1_000_000) end

      type_cost = limit.("type(i)")
      assert type_cost > 0

      # each call charges a constant: the limit grows by 1,000 times the charge
      assert limit.("helpers.time_parts(i)") - type_cost >= 8_000
      assert limit.("helpers.time_iso8601(i)") - type_cost >= 24_000
    end

    test "time_iso8601 under a value_bytes limit of 23 is value_size; 24 passes", %{executable: exe} do
      # the length is taken inside the run, so only the helper can end it with value_size
      source = Helper.function_source("return #helpers.time_iso8601(0)")
      assert Helper.run(exe, source, nil, %{value_bytes: 23}) == {:refused, :value_size}
      assert {:ok, %{value: 24}} = Helper.run(exe, source, nil, %{value_bytes: 24})

      # as a result the text has two quotes more
      result = Helper.function_source("return helpers.time_iso8601(0)")

      assert {:ok, %{value: "1970-01-01T00:00:00.000Z"}} =
               Helper.run(exe, result, nil, %{value_bytes: 26})

      # a pcall around it does not continue
      caught = Helper.function_source("local ok = pcall(helpers.time_iso8601, 0) return 'after'")
      assert Helper.run(exe, caught, nil, %{value_bytes: 23}) == {:refused, :value_size}
    end
  end

  # the least `steps` limit under which `return function(x) return <call> end` finishes
  defp min_steps(exe, call, input) do
    source = "return function(x) return " <> call <> " end"
    bisect(exe, source, input, 1, 1_000_000)
  end

  # the least `steps` limit under which the source (a chunk that returns a function) finishes
  defp bisect_source(exe, source, low, high), do: bisect(exe, source, nil, low, high)

  defp bisect(_exe, _source, _input, low, high) when low >= high, do: low

  defp bisect(exe, source, input, low, high) do
    middle = div(low + high, 2)

    case Helper.run(exe, source, input, %{steps: middle}) do
      {:ok, _} -> bisect(exe, source, input, low, middle)
      {:refused, :steps} -> bisect(exe, source, input, middle + 1, high)
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
