# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxBindingsTest do
  @moduledoc """
  Groups `request_shape` and `none_is_version_2_surface` of the module-call bindings
  (policy version 3): the five-key request with its `calls` operand, decided before
  any process starts and again by the host, the version 3 identity, and the surface
  that mode `"none"` leaves as it was in version 2.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.{Descriptor, Json}

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000

  @valid "return function() return 1 end"
  @invalid %{"status" => "refused", "reason" => "invalid_request"}
  @mismatch %{"status" => "refused", "reason" => "policy_mismatch"}

  setup_all do
    {executable, directory} = Helper.build!("bindings")
    marker = Path.join(directory, "fake-ran")
    fake = Helper.fake!(directory, "fake-host", "touch '#{marker}'")
    control_marker = Path.join(directory, "control-ran")
    control = Helper.fake!(directory, "control-host", "touch '#{control_marker}'")

    %{
      executable: executable,
      fake: fake,
      marker: marker,
      control: control,
      control_marker: control_marker
    }
  end

  defp record(name \\ "a"), do: %{name: name, arguments: 1, result: 2}

  defp good_calls do
    %{mode: "replay", names: ["a", "b"], recorded: [record("a")]}
  end

  defp names(count), do: for(i <- 1..count, do: "n#{i}")

  # Each shape here is a plain Elixir term of a malformed `calls` (not JSON-encodable
  # ones included).
  defp malformed_calls do
    good = good_calls()

    missing = for key <- [:mode, :names, :recorded], do: Map.delete(good, key)
    extra = [Map.put(good, :extra, 1), Map.put(good, "mode", "none")]
    non_map = [nil, [], "none", 1, [mode: "none", names: [], recorded: []]]
    modes = for mode <- ["other", "NONE", "", :none, nil, 1], do: %{good | mode: mode}

    bad_names =
      for name <- [
            "",
            "A",
            "aB",
            "1a",
            "_a",
            String.duplicate("a", 65),
            "a-b",
            "a b",
            "é",
            1,
            :a,
            nil
          ] do
        %{good | names: [name]}
      end

    names_shape =
      for names <- [nil, "a", %{}, ["a" | "b"], ["a", "a"], names(65)],
          do: %{good | names: names}

    recorded_shape =
      for recorded <- [nil, "a", %{}, [record() | :tail], List.duplicate(record(), 257)],
          do: %{good | recorded: recorded}

    records =
      [
        [record("c")],
        [%{record() | name: 1}],
        [%{record() | name: nil}],
        [Map.delete(record(), :name)],
        [Map.delete(record(), :arguments)],
        [Map.delete(record(), :result)],
        [Map.put(record(), :extra, 1)],
        [%{"name" => "a", "arguments" => 1, "result" => 2}],
        [nil],
        ["a"],
        [[:name, "a"]]
      ]
      |> Enum.map(&%{good | recorded: &1})

    modes_shape = [
      %{mode: "none", names: ["a"], recorded: []},
      %{mode: "none", names: [], recorded: [record()]},
      %{mode: "none", names: ["a"], recorded: [record()]},
      %{mode: "data", names: ["a"], recorded: [record()]},
      %{mode: "data", names: [], recorded: [record()]}
    ]

    non_plain = [
      %{good | recorded: [%{record() | arguments: self()}]},
      %{good | recorded: [%{record() | result: self()}]},
      %{good | recorded: [%{record() | arguments: %{1 => 2}}]},
      %{good | recorded: [%{record() | result: [1 | 2]}]},
      %{good | recorded: [%{record() | result: nested(33)}]}
    ]

    missing ++
      extra ++
      non_map ++
      modes ++
      bad_names ++
      names_shape ++
      recorded_shape ++
      records ++
      modes_shape ++ non_plain
  end

  defp nested(0), do: 1
  defp nested(depth), do: [nested(depth - 1)]

  describe "request_shape" do
    test "each malformed calls is invalid_request and no process starts", ctx do
      for calls <- malformed_calls() do
        request = Helper.request(@valid, nil, %{}, calls)
        assert LuaSandbox.run(ctx.fake, request) == {:refused, :invalid_request}, inspect(calls)
      end

      refute File.exists?(ctx.marker)
    end

    test "the request has exactly five keys and a request without calls is invalid_request", ctx do
      good = Helper.request(@valid)

      for bad <- [Map.delete(good, :calls), Map.put(good, :extra, 1), Map.delete(good, :input)] do
        assert LuaSandbox.run(ctx.fake, bad) == {:refused, :invalid_request}
      end

      assert LuaSandbox.run(ctx.fake, %{good | calls: nil}) == {:refused, :invalid_request}
      refute File.exists?(ctx.marker)
    end

    test "a control: a well-formed request does start the process", ctx do
      refute File.exists?(ctx.control_marker)
      # the fake writes no reply, so the outcome is a host outcome, not a refusal
      assert {:host_outcome, _} = LuaSandbox.run(ctx.control, Helper.request(@valid))
      assert File.exists?(ctx.control_marker)
    end

    test "the bounds are inclusive: 64 names and 256 records are accepted", %{executable: exe} do
      all = names(64)
      assert length(all) == 64

      assert {:ok, %{value: 1}} =
               Helper.run(exe, @valid, nil, %{}, %{mode: "data", names: all, recorded: []})

      records = for i <- 1..256, do: %{name: "a", arguments: i, result: nil}

      assert {:ok, %{value: 1}} =
               Helper.run(exe, @valid, nil, %{}, %{mode: "replay", names: ["a"], recorded: records})

      assert {:ok, %{value: 1}} =
               Helper.run(exe, @valid, nil, %{}, %{
                 mode: "replay",
                 names: ["a" <> String.duplicate("b_9", 21), String.duplicate("z", 64)],
                 recorded: []
               })
    end

    test "a recorded argument or result over value_bytes is value_size, at the bound it passes",
         %{executable: exe, fake: fake, marker: marker} do
      limits = %{value_bytes: 100}
      # the canonical JSON of a binary is its length plus two quotes
      fits = String.duplicate("x", 98)
      over = String.duplicate("x", 99)

      calls = fn arguments, result ->
        %{
          mode: "replay",
          names: ["a"],
          recorded: [%{name: "a", arguments: arguments, result: result}]
        }
      end

      assert {:ok, %{value: 1}} = Helper.run(exe, @valid, nil, limits, calls.(fits, nil))
      assert {:ok, %{value: 1}} = Helper.run(exe, @valid, nil, limits, calls.(nil, fits))
      assert {:ok, %{value: 1}} = Helper.run(exe, @valid, nil, limits, calls.(fits, fits))

      for calls <- [
            calls.(over, nil),
            calls.(nil, over),
            calls.(over, over),
            calls.(%{"k" => over}, 1)
          ] do
        request = Helper.request(@valid, nil, limits, calls)
        assert LuaSandbox.run(fake, request) == {:refused, :value_size}
      end

      # the second record is the one that is too large
      second = %{mode: "replay", names: ["a"], recorded: [record(), %{record() | result: over}]}

      assert LuaSandbox.run(fake, Helper.request(@valid, nil, limits, second)) ==
               {:refused, :value_size}

      refute File.exists?(marker)
    end

    test "a frame over the frame bound is invalid_request before any process starts", ctx do
      big = String.duplicate("x", 60_000)
      records = for _ <- 1..20, do: %{name: "a", arguments: big, result: big}
      calls = %{mode: "replay", names: ["a"], recorded: records}

      assert LuaSandbox.run(ctx.fake, Helper.request(@valid, nil, %{}, calls)) ==
               {:refused, :invalid_request}

      refute File.exists?(ctx.marker)
    end

    test "the frame carries calls as one more member with string keys", ctx do
      calls = %{
        mode: "replay",
        names: ["a"],
        recorded: [%{name: "a", arguments: [1], result: %{"k" => 2}}]
      }

      path = Path.join(Path.dirname(ctx.fake), "frame-copy")

      echo =
        Helper.fake!(
          Path.dirname(ctx.fake),
          "echo-host",
          "dd bs=1 count=4 of=/dev/null 2>/dev/null; cat > '#{path}'"
        )

      LuaSandbox.run(echo, Helper.request(@valid, nil, %{wall_ms: 200}, calls))
      # the fake consumed the four length bytes; the file holds the body
      frame = path |> File.read!() |> Jason.decode!()
      assert Enum.sort(Map.keys(frame)) == ["calls", "input", "limits", "policy", "source"]

      assert frame["calls"] == %{
               "mode" => "replay",
               "names" => ["a"],
               "recorded" => [%{"name" => "a", "arguments" => [1], "result" => %{"k" => 2}}]
             }
    end

    test "the host itself refuses each malformed calls of a raw frame", %{executable: exe} do
      for calls <- raw_malformed_calls() do
        {output, 0} = Helper.raw_exchange(exe, raw_frame(calls))
        assert Helper.decode_frame!(output) == @invalid, inspect(calls)
      end
    end

    test "the host refuses a frame with four or six members and a frame without calls",
         %{executable: exe} do
      base = raw_base(raw_good_calls())

      for frame <- [
            Map.delete(base, "calls"),
            Map.delete(base, "input"),
            Map.put(base, "extra", 1),
            Map.put(Map.delete(base, "calls"), "extra", 1),
            Map.put(base, "calls", nil)
          ] do
        {output, 0} = Helper.raw_exchange(exe, Helper.frame(Jason.encode!(frame)))
        assert Helper.decode_frame!(output) == @invalid, inspect(Map.keys(frame))
      end
    end

    test "the host accepts each well-formed calls of a raw frame", %{executable: exe} do
      for calls <- [
            %{"mode" => "none", "names" => [], "recorded" => []},
            %{"mode" => "data", "names" => ["a", "b_1"], "recorded" => []},
            raw_good_calls(),
            %{"mode" => "replay", "names" => [], "recorded" => []},
            %{"mode" => "replay", "names" => names(64), "recorded" => []},
            %{"mode" => "replay", "names" => ["a"], "recorded" => raw_records(256)}
          ] do
        {output, 0} = Helper.raw_exchange(exe, raw_frame(calls))
        assert %{"status" => "ok", "value" => 1} = Helper.decode_frame!(output), inspect(calls)
      end
    end

    test "the identity is policy-v3 over the digest of the descriptor and the descriptor names it" do
      %{identity: identity, descriptor: descriptor} = LuaSandbox.policy()

      assert identity =~ ~r/\Apolicy-v3:sha256:[0-9a-f]{64}\z/
      assert identity == Descriptor.identity(descriptor)
      assert descriptor["policy_version"] == 3

      assert descriptor["bindings"] == %{
               "mechanism_version" => 1,
               "max_names" => 64,
               "max_recorded" => 256
             }

      # the two bounds are stated under bindings and not under bounds
      refute Map.has_key?(descriptor["bounds"], "max_names")
      refute Map.has_key?(descriptor["bounds"], "max_recorded")

      "policy-v3:sha256:" <> digest = identity
      assert digest == Base.encode16(:crypto.hash(:sha256, Json.encode(descriptor)), case: :lower)
    end

    test "a policy-v2 identity is policy_mismatch in Elixir and in the host", ctx do
      %{identity: identity, descriptor: descriptor} = LuaSandbox.policy()
      "policy-v3:sha256:" <> digest = identity
      old_descriptor = %{descriptor | "bindings" => %{}} |> Map.put("policy_version", 2)
      "policy-v3:sha256:" <> old_digest = Descriptor.identity(old_descriptor)
      refute old_digest == digest

      for other <- ["policy-v2:sha256:" <> digest, "policy-v2:sha256:" <> old_digest] do
        assert LuaSandbox.run(ctx.fake, %{Helper.request(@valid) | policy: other}) ==
                 {:refused, :policy_mismatch}

        {output, 0} =
          Helper.raw_exchange(
            ctx.executable,
            Helper.frame(Jason.encode!(%{raw_base(raw_good_calls()) | "policy" => other}))
          )

        assert Helper.decode_frame!(output) == @mismatch, other
      end

      refute File.exists?(ctx.marker)
    end
  end

  defp raw_base(calls) do
    %{
      "source" => @valid,
      "input" => nil,
      "policy" => LuaSandbox.policy().identity,
      "limits" => Map.new(Helper.default_limits(), fn {k, v} -> {Atom.to_string(k), v} end),
      "calls" => calls
    }
  end

  defp raw_frame(calls), do: Helper.frame(Jason.encode!(raw_base(calls)))

  defp raw_good_calls do
    %{
      "mode" => "replay",
      "names" => ["a", "b"],
      "recorded" => [%{"name" => "a", "arguments" => 1, "result" => 2}]
    }
  end

  defp raw_records(count),
    do: for(i <- 1..count, do: %{"name" => "a", "arguments" => i, "result" => nil})

  defp raw_malformed_calls do
    good = raw_good_calls()
    record = %{"name" => "a", "arguments" => 1, "result" => 2}

    missing = for key <- ["mode", "names", "recorded"], do: Map.delete(good, key)
    extra = [Map.put(good, "extra", 1), Map.put(good, "Mode", "none")]
    non_object = [nil, [], "none", 1, true, [["mode", "none"]]]

    modes =
      for mode <- ["other", "NONE", "", "None", nil, 1, ["none"]], do: %{good | "mode" => mode}

    bad_names =
      for name <- [
            "",
            "A",
            "aB",
            "1a",
            "_a",
            String.duplicate("a", 65),
            "a-b",
            "a b",
            "é",
            1,
            nil,
            ["a"]
          ] do
        %{good | "names" => [name]}
      end

    names_shape =
      for names <- [nil, "a", %{}, ["a", "a"], names(65)], do: %{good | "names" => names}

    recorded_shape =
      for recorded <- [nil, "a", %{}, raw_records(257)], do: %{good | "recorded" => recorded}

    records =
      for rec <- [
            %{record | "name" => "c"},
            %{record | "name" => 1},
            %{record | "name" => nil},
            Map.delete(record, "name"),
            Map.delete(record, "arguments"),
            Map.delete(record, "result"),
            Map.put(record, "extra", 1),
            Map.put(Map.delete(record, "name"), "extra", 1),
            nil,
            "a",
            [record]
          ] do
        %{good | "recorded" => [rec]}
      end

    modes_shape = [
      %{"mode" => "none", "names" => ["a"], "recorded" => []},
      %{"mode" => "none", "names" => [], "recorded" => [record]},
      %{"mode" => "none", "names" => ["a"], "recorded" => [record]},
      %{"mode" => "data", "names" => ["a"], "recorded" => [record]},
      %{"mode" => "data", "names" => [], "recorded" => [record]}
    ]

    missing ++
      extra ++
      non_object ++ modes ++ bad_names ++ names_shape ++ recorded_shape ++ records ++ modes_shape
  end

  describe "none_is_version_2_surface" do
    test "with mode none, bindings and bindings.x are unlisted_name, also inside pcall",
         %{executable: exe} do
      for source <- [
            "return function() return bindings end",
            "return function() return bindings.x end",
            "return function() local ok = pcall(function() return bindings end) return ok end",
            "return function() local ok = pcall(function() return bindings.x end) return ok end",
            "return function() return pcall(function() return bindings.x end) end",
            "return function() return type(bindings) end",
            "return function() bindings.x = 1 return 1 end",
            "return function() return bindings.x == nil end"
          ] do
        assert Helper.run(exe, source) == {:refused, :unlisted_name}, source
      end

      # the chunk level reads the same global
      assert Helper.run(exe, "local b = bindings return function() return 1 end") ==
               {:refused, :unlisted_name}

      # the unlisted name is sticky: the same names that were refused in version 2
      assert Helper.run(exe, Helper.function_source("return binding")) == {:refused, :unlisted_name}
    end

    test "the modes data and replay change nothing else of the surface", %{executable: exe} do
      for calls <- [
            %{mode: "data", names: [], recorded: []},
            %{mode: "data", names: ["a"], recorded: []},
            %{mode: "replay", names: [], recorded: []},
            %{mode: "replay", names: ["a", "b"], recorded: []},
            %{mode: "replay", names: ["a"], recorded: [record()]}
          ] do
        assert {:ok, %{value: 14, identity: identity}} =
                 Helper.run(exe, "return function() return (3 + 4) * 2 end", nil, %{}, calls)

        assert identity == LuaSandbox.policy().identity

        assert {:ok, %{value: %{"s" => "ABC", "n" => 3}}} =
                 Helper.run(
                   exe,
                   "return function(x) return {s = string.upper(x), n = #x} end",
                   "abc",
                   %{},
                   calls
                 )

        # a missing global is still the sticky unlisted_name, and os and io are absent
        assert Helper.run(exe, "return function() return os end", nil, %{}, calls) ==
                 {:refused, :unlisted_name}

        assert Helper.run(exe, "return function() return pairs end", nil, %{}, calls) ==
                 {:refused, :unlisted_name}
      end
    end
  end

  @data %{mode: "data", names: ["fetch", "store"], recorded: []}

  defp data(exe, source, input \\ nil, limits \\ %{}, calls \\ @data),
    do: Helper.run(exe, source, input, limits, calls)

  defp call(binding, arguments), do: %{"binding" => binding, "arguments" => arguments}

  # The least `steps` budget at which the source runs to the end on this input.
  defp least_steps(exe, source, input) do
    least_steps(exe, source, input, 1, 200_000)
  end

  defp least_steps(_exe, _source, _input, low, high) when low == high, do: low

  defp least_steps(exe, source, input, low, high) do
    middle = div(low + high, 2)

    case data(exe, source, input, %{steps: middle}) do
      {:ok, _} -> least_steps(exe, source, input, low, middle)
      {:refused, :steps} -> least_steps(exe, source, input, middle + 1, high)
    end
  end

  describe "data_mode_builds_data" do
    test "two bindings build two objects in place, one nested in the other", %{executable: exe} do
      source = """
      return function()
        local a = bindings.fetch({id = 1})
        local b = bindings.store(helpers.object())
        local c = bindings.store(bindings.fetch({id = 2}))
        return {a = a, b = b, c = c}
      end
      """

      assert {:ok, %{value: value, identity: identity}} = data(exe, source)
      assert identity == LuaSandbox.policy().identity

      assert value == %{
               "a" => call("fetch", %{"id" => 1}),
               "b" => call("store", %{}),
               "c" => call("store", call("fetch", %{"id" => 2}))
             }
    end

    test "nil is null, an empty object stays an object and an empty array stays an array",
         %{executable: exe} do
      source = """
      return function(x)
        return {
          n = bindings.fetch(nil),
          z = bindings.fetch(helpers.null),
          o = bindings.fetch(helpers.object()),
          a = bindings.fetch({}),
          io = bindings.fetch(x.o),
          ia = bindings.fetch(x.a),
          s = bindings.store("text"),
          f = bindings.store(1.5),
          t = bindings.store(true)
        }
      end
      """

      assert {:ok, %{value: value}} = data(exe, source, %{"o" => %{}, "a" => []})

      assert value == %{
               "n" => call("fetch", nil),
               "z" => call("fetch", nil),
               "o" => call("fetch", %{}),
               "a" => call("fetch", []),
               "io" => call("fetch", %{}),
               "ia" => call("fetch", []),
               "s" => call("store", "text"),
               "f" => call("store", 1.5),
               "t" => call("store", true)
             }
    end

    test "the arguments are a copy: a change after the call does not reach the object",
         %{executable: exe} do
      source = """
      return function()
        local t = {x = 1, list = {1, 2}}
        local r = bindings.fetch(t)
        t.x = 2
        t.list[1] = 99
        t.extra = true
        r.arguments.x = 5
        r.arguments.list[2] = 7
        return {r = r, t = t}
      end
      """

      assert {:ok, %{value: value}} = data(exe, source)

      assert value == %{
               "r" => call("fetch", %{"x" => 5, "list" => [1, 7]}),
               "t" => %{"x" => 2, "list" => [99, 2], "extra" => true}
             }

      # a copy that is not shared: two calls on one table give two tables
      shared = """
      return function()
        local t = {x = 1}
        local a = bindings.fetch(t)
        local b = bindings.fetch(t)
        a.arguments.x = 2
        return {a = a, b = b, same = a.arguments == b.arguments, t = t}
      end
      """

      assert {:ok, %{value: value}} = data(exe, shared)

      assert value == %{
               "a" => call("fetch", %{"x" => 2}),
               "b" => call("fetch", %{"x" => 1}),
               "same" => false,
               "t" => %{"x" => 1}
             }
    end

    test "1,000 calls in a loop record nothing and the reply holds only the value",
         %{executable: exe} do
      source = """
      return function()
        local last
        for i = 1, 1000 do last = bindings.fetch(i) end
        return last
      end
      """

      first = data(exe, source)
      assert {:ok, reply} = first
      assert reply.value == call("fetch", 1000)
      assert Enum.sort(Map.keys(reply)) == [:identity, :runtime, :value]
      assert data(exe, source) == first
    end

    test "bindings.unknown is unlisted_name, called or not and inside pcall", %{executable: exe} do
      for source <- [
            "return function() return bindings.unknown end",
            "return function() return bindings.unknown(1) end",
            "return function() local ok = pcall(function() return bindings.unknown end) return 1 end",
            "return function() local ok = pcall(function() return bindings.unknown(1) end) return 1 end",
            "return function() local ok = pcall(bindings.unknown, 1) return 1 end",
            "return function() return bindings.Fetch end",
            "return function() return bindings[1] end"
          ] do
        assert data(exe, source) == {:refused, :unlisted_name}, source
      end
    end

    test "a wrong argument count or a non-plain argument is an error that pcall catches",
         %{executable: exe} do
      count = "bindings: expected one value"
      plain = "bindings: value is not plain data"

      cases = [
        {"pcall(bindings.fetch)", count},
        {"pcall(bindings.fetch, 1, 2)", count},
        {"pcall(bindings.fetch, nil, nil)", count},
        # called from Lua, the message carries the position of the caller
        {"pcall(function() return bindings.fetch() end)", "lua:1: " <> count},
        {"pcall(bindings.fetch, function() end)", plain},
        {"pcall(bindings.fetch, {f = function() end})", plain},
        {"pcall(bindings.fetch, (function() local t = {} t.t = t return t end)())", plain},
        {"pcall(bindings.fetch, {1, a = 2})", plain},
        {"pcall(bindings.fetch, {[1] = 1, [3] = 3})", plain},
        {"pcall(bindings.fetch, {[0] = 1})", plain},
        {"pcall(bindings.fetch, 0 / 0)", plain},
        {"pcall(bindings.fetch, 1 / 0)", plain},
        {"pcall(bindings.fetch, -1 / 0)", plain},
        {"pcall(bindings.fetch, (function() local t = 1 for i = 1, 33 do t = {t} end return t end)())",
         plain}
      ]

      for {call, message} <- cases do
        source = "return function() local ok, msg = #{call} return {ok, msg, \"marker\"} end"
        assert data(exe, source) == data_ok([false, message, "marker"], exe), call
      end

      # a good call after the errors still works, and 32 nested containers are plain data
      source = """
      return function()
        pcall(bindings.fetch)
        pcall(bindings.fetch, 1, 2)
        local t = 1
        for i = 1, 32 do t = {t} end
        local ok = pcall(bindings.fetch, t)
        return {ok, bindings.store(2)}
      end
      """

      assert {:ok, %{value: [true, value]}} = data(exe, source)
      assert value == call("store", 2)
    end

    # The reply that a source with no binding object gets for this value.
    defp data_ok(value, exe) do
      assert {:ok, reply} = Helper.run(exe, "return function() return nil end")
      {:ok, %{reply | value: value}}
    end

    test "an argument over value_bytes is the value_size stop and pcall does not continue",
         %{executable: exe} do
      limits = %{value_bytes: 100}
      # the canonical JSON of a binary is its length plus two quotes
      over =
        "return function() local ok = pcall(bindings.fetch, string.rep('x', 99)) return 'marker' end"

      direct = "return function() return bindings.fetch(string.rep('x', 99)) end"

      table =
        "return function() local ok = pcall(bindings.fetch, {k = string.rep('x', 96)}) return 'marker' end"

      for source <- [over, direct, table] do
        assert data(exe, source, nil, limits) == {:refused, :value_size}, source
      end

      # at the bound the call goes through (the object is not returned: it is larger)
      fits = "return function() local r = bindings.fetch(string.rep('x', 98)) return 1 end"
      assert {:ok, %{value: 1}} = data(exe, fits, nil, limits)
    end

    test "each byte of the argument and of the returned value costs one step",
         %{executable: exe} do
      source = "return function(s) local r = bindings.fetch(s) return 1 end"
      small = String.duplicate("x", 10)
      large = String.duplicate("x", 2_010)

      least_small = least_steps(exe, source, small)
      least_large = least_steps(exe, source, large)

      # 2,000 more bytes: one step each for the argument and one each for the returned object
      assert least_large - least_small == 4_000

      # the budget that is enough for the small argument is not for the large one
      assert {:ok, %{value: 1}} = data(exe, source, small, %{steps: least_small})
      assert data(exe, source, small, %{steps: least_small - 1}) == {:refused, :steps}
      assert data(exe, source, large, %{steps: least_small}) == {:refused, :steps}
      assert {:ok, %{value: 1}} = data(exe, source, large, %{steps: least_large})
      assert data(exe, source, large, %{steps: least_large - 1}) == {:refused, :steps}

      # reached while the argument is charged, inside pcall: still the sticky steps stop
      caught = "return function(s) local ok = pcall(bindings.fetch, s) return 'marker' end"
      assert data(exe, caught, large, %{steps: 1_000}) == {:refused, :steps}
    end

    test "a source that assigns bindings.fetch uses its own value, the next run has the binding",
         %{executable: exe} do
      own = """
      return function()
        bindings.fetch = function(x) return "own" end
        return bindings.fetch(1)
      end
      """

      assert {:ok, %{value: "own"}} = data(exe, own)

      again = "return function() return bindings.fetch(1) end"
      assert {:ok, %{value: value}} = data(exe, again)
      assert value == call("fetch", 1)

      # another name is untouched by the assignment, and a new field is the source's own
      mixed = """
      return function()
        bindings.fetch = 1
        bindings.extra = 2
        return {bindings.fetch, bindings.extra, bindings.store(3)}
      end
      """

      assert {:ok, %{value: [1, 2, value]}} = data(exe, mixed)
      assert value == call("store", 3)
    end

    test "mode data with no names has a bindings table and every field is unlisted_name",
         %{executable: exe} do
      none = %{mode: "data", names: [], recorded: []}

      assert {:ok, %{value: "table"}} =
               data(exe, "return function() return type(bindings) end", nil, %{}, none)

      assert data(exe, "return function() return bindings.a end", nil, %{}, none) ==
               {:refused, :unlisted_name}

      assert data(exe, "return function() return bindings.a(1) end", nil, %{}, none) ==
               {:refused, :unlisted_name}
    end
  end
end
