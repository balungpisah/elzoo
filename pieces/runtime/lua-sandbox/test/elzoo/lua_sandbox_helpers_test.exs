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
  @helpers ~w(null object text_split text_trim text_utf8_len)

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
  end

  # the least `steps` limit under which `return function(x) return <call> end` finishes
  defp min_steps(exe, call, input) do
    source = "return function(x) return " <> call <> " end"
    bisect(exe, source, input, 1, 1_000_000)
  end

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
