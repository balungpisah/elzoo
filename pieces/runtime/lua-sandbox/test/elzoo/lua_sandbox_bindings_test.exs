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
      asking = "return function() for i = 1, 256 do bindings.a(i) end return 1 end"

      assert {:ok, %{value: 1}} =
               Helper.run(exe, asking, nil, %{}, %{mode: "replay", names: ["a"], recorded: records})

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

      asking = "return function(x) bindings.a(x) return 1 end"
      assert {:ok, %{value: 1}} = Helper.run(exe, asking, fits, limits, calls.(fits, nil))
      assert {:ok, %{value: 1}} = Helper.run(exe, asking, nil, limits, calls.(nil, fits))
      assert {:ok, %{value: 1}} = Helper.run(exe, asking, fits, limits, calls.(fits, fits))

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
            %{"mode" => "replay", "names" => [], "recorded" => []},
            %{"mode" => "replay", "names" => names(64), "recorded" => []}
          ] do
        {output, 0} = Helper.raw_exchange(exe, raw_frame(calls))
        assert %{"status" => "ok", "value" => 1} = Helper.decode_frame!(output), inspect(calls)
      end

      # a well-formed record list that the source does not ask for is call_mismatch, not
      # invalid_request: the shape is accepted
      for calls <- [
            raw_good_calls(),
            %{"mode" => "replay", "names" => ["a"], "recorded" => raw_records(256)}
          ] do
        {output, 0} = Helper.raw_exchange(exe, raw_frame(calls))

        assert Helper.decode_frame!(output) ==
                 %{"status" => "refused", "reason" => "call_mismatch"},
               inspect(calls)
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
            %{mode: "replay", names: ["a", "b"], recorded: []}
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

  @replay_names ["fetch", "store"]

  defp replay(exe, source, recorded, input \\ nil, limits \\ %{}, names \\ @replay_names) do
    Helper.run(exe, source, input, limits, %{mode: "replay", names: names, recorded: recorded})
  end

  defp rec(name, arguments, result), do: %{name: name, arguments: arguments, result: result}

  @two_calls """
  return function()
    local a = bindings.fetch({k = 1})
    local b = bindings.store({prev = a})
    return {a = a, b = b}
  end
  """

  @first %{name: "fetch", arguments: %{"k" => 1}, result: "r0"}
  @second %{name: "store", arguments: %{"prev" => "r0"}, result: [1, 2]}

  describe "replay_in_order" do
    test "no record is the pending call 0, one record the pending call 1, two the value",
         %{executable: exe} do
      assert replay(exe, @two_calls, []) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: %{"k" => 1}}}

      # the source saw the recorded result of call 0: it is in the arguments of call 1
      assert replay(exe, @two_calls, [@first]) ==
               {:pending_call, %{index: 1, name: "store", arguments: %{"prev" => "r0"}}}

      assert {:ok, %{value: %{"a" => "r0", "b" => [1, 2]}, identity: identity}} =
               replay(exe, @two_calls, [@first, @second])

      assert identity == LuaSandbox.policy().identity
    end

    test "a binding call in the chunk is call 0", %{executable: exe} do
      source = """
      local first = bindings.fetch(1)
      return function() return {first, bindings.store(first)} end
      """

      assert replay(exe, source, []) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: 1}}

      assert replay(exe, source, [rec("fetch", 1, "x")]) ==
               {:pending_call, %{index: 1, name: "store", arguments: "x"}}

      assert {:ok, %{value: ["x", 9]}} =
               replay(exe, source, [rec("fetch", 1, "x"), rec("store", "x", 9)])
    end

    test "every plain result comes back as it was recorded, and a nil argument is null",
         %{executable: exe} do
      results = [nil, true, 1, -2.5, "s", [1, [2]], %{"a" => %{"b" => []}}, %{}, []]

      for result <- results do
        source = "return function() return bindings.fetch(nil) end"
        assert {:ok, %{value: ^result}} = replay(exe, source, [rec("fetch", nil, result)])
      end

      assert replay(exe, "return function() return bindings.fetch(nil) end", []) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: nil}}
    end

    test "a call made again is a new call with its own index", %{executable: exe} do
      source = """
      return function()
        local out = {}
        for i = 1, 3 do out[i] = bindings.fetch(i) end
        return out
      end
      """

      records = for i <- 1..3, do: rec("fetch", i, i * 10)

      for count <- 0..2 do
        assert {:pending_call, %{index: ^count, name: "fetch", arguments: arguments}} =
                 replay(exe, source, Enum.take(records, count))

        assert arguments == count + 1
      end

      assert {:ok, %{value: [10, 20, 30]}} = replay(exe, source, records)
    end
  end

  describe "replay_mismatch" do
    @direct "return function() local v = bindings.fetch({k = 1}) return 'marker' end"
    @caught "return function() local ok = pcall(bindings.fetch, {k = 1}) return 'marker' end"
    @caught_all """
    return function()
      local ok = pcall(function() return bindings.fetch({k = 1}) end)
      return 'marker'
    end
    """

    test "another name, a changed argument and a longer list are each call_mismatch, pcall or not",
         %{executable: exe} do
      for recorded <- [
            [rec("store", %{"k" => 1}, 1)],
            [rec("fetch", %{"k" => 2}, 1)],
            [rec("fetch", %{"k" => 1, "extra" => 0}, 1)],
            [rec("fetch", [%{"k" => 1}], 1)],
            [rec("fetch", %{"k" => "1"}, 1)],
            [rec("fetch", nil, 1)]
          ] do
        for source <- [@direct, @caught, @caught_all] do
          assert replay(exe, source, recorded) == {:refused, :call_mismatch},
                 inspect({recorded, source})
        end
      end

      # a list longer than the calls of the source: the extra record is a different run
      good = rec("fetch", %{"k" => 1}, 1)

      for source <- [@direct, @caught, @caught_all] do
        assert replay(exe, source, [good, good]) == {:refused, :call_mismatch}
        assert replay(exe, source, [good, rec("store", 1, 1)]) == {:refused, :call_mismatch}
      end

      assert replay(exe, "return function() return 1 end", [good]) == {:refused, :call_mismatch}

      # the control: the record that matches lets the source reach its marker
      for source <- [@direct, @caught, @caught_all] do
        assert {:ok, %{value: "marker"}} = replay(exe, source, [good])
      end
    end

    test "a mismatch inside a sort comparator or a gsub callback ends the run", %{executable: exe} do
      sort = """
      return function()
        local t = {2, 1}
        table.sort(t, function(a, b) bindings.fetch(a) return a < b end)
        return 'marker'
      end
      """

      gsub = """
      return function()
        string.gsub("abc", ".", function(c) bindings.fetch(c) return c end)
        return 'marker'
      end
      """

      assert replay(exe, sort, [rec("fetch", 99, 1)]) == {:refused, :call_mismatch}
      assert replay(exe, gsub, [rec("fetch", "z", 1)]) == {:refused, :call_mismatch}
    end

    test "the same arguments built in another insertion order are equal", %{executable: exe} do
      source = """
      return function()
        local t = {}
        t.c = {z = 1, y = 2, x = {n = 3, m = 4}}
        t.b = 2
        t.a = 1
        return bindings.fetch(t)
      end
      """

      arguments = %{"a" => 1, "b" => 2, "c" => %{"x" => %{"m" => 4, "n" => 3}, "y" => 2, "z" => 1}}
      assert {:ok, %{value: 7}} = replay(exe, source, [rec("fetch", arguments, 7)])

      # one value changed deep inside is a different call
      other = put_in(arguments, ["c", "x", "n"], 5)
      assert replay(exe, source, [rec("fetch", other, 7)]) == {:refused, :call_mismatch}
    end

    test "a raw frame with the recorded keys in another order replays", %{executable: exe} do
      limits =
        Jason.encode!(Map.new(Helper.default_limits(), fn {k, v} -> {Atom.to_string(k), v} end))

      source =
        Jason.encode!("return function() return bindings.fetch({a = 1, b = {d = 4, c = 3}}) end")

      body = fn arguments ->
        ~s({"source":#{source},"limits":#{limits},"calls":{"recorded":[{"result":7,) <>
          ~s("name":"fetch","arguments":#{arguments}}],"names":["fetch"],"mode":"replay"},) <>
          ~s("policy":"#{LuaSandbox.policy().identity}","input":null})
      end

      {output, 0} = Helper.raw_exchange(exe, Helper.frame(body.(~s({"b":{"d":4,"c":3},"a":1}))))
      assert %{"status" => "ok", "value" => 7} = Helper.decode_frame!(output)

      {output, 0} = Helper.raw_exchange(exe, Helper.frame(body.(~s({"b":{"d":4,"c":3},"a":2}))))
      assert Helper.decode_frame!(output) == %{"status" => "refused", "reason" => "call_mismatch"}
    end

    test "an integer is not a float of the same value: the canonical text differs",
         %{executable: exe} do
      as_int = "return function() return bindings.fetch(1) end"
      as_float = "return function() return bindings.fetch(1.0) end"

      assert replay(exe, as_int, [rec("fetch", 1.0, 5)]) == {:refused, :call_mismatch}
      assert replay(exe, as_float, [rec("fetch", 1, 5)]) == {:refused, :call_mismatch}
      assert {:ok, %{value: 5}} = replay(exe, as_int, [rec("fetch", 1, 5)])
      assert {:ok, %{value: 5}} = replay(exe, as_float, [rec("fetch", 1.0, 5)])
    end

    test "an empty array and an empty object are different arguments", %{executable: exe} do
      array = "return function() return bindings.fetch({}) end"
      object = "return function() return bindings.fetch(helpers.object()) end"

      assert {:ok, %{value: 1}} = replay(exe, array, [rec("fetch", [], 1)])
      assert replay(exe, array, [rec("fetch", %{}, 1)]) == {:refused, :call_mismatch}
      assert {:ok, %{value: 1}} = replay(exe, object, [rec("fetch", %{}, 1)])
      assert replay(exe, object, [rec("fetch", [], 1)]) == {:refused, :call_mismatch}
    end

    test "an uncaught error or two results after fewer calls keep their own refusal",
         %{executable: exe} do
      records = [@first, @second]

      errors = """
      return function()
        bindings.fetch({k = 1})
        error("stop here")
      end
      """

      two = """
      return function()
        bindings.fetch({k = 1})
        return 1, 2
      end
      """

      assert replay(exe, errors, records) == {:refused, :lua_error}
      assert replay(exe, two, records) == {:refused, :invalid_result}

      # a function that returns nothing after fewer calls is invalid_result too
      none = "return function() bindings.fetch({k = 1}) end"
      assert replay(exe, none, records) == {:refused, :invalid_result}
    end

    test "a result that is too large to return is value_size, a call is still counted",
         %{executable: exe} do
      source = "return function() return {bindings.fetch(1), bindings.fetch(1)} end"
      big = String.duplicate("x", 50)

      assert replay(exe, source, [rec("fetch", 1, big), rec("fetch", 1, big)], nil, %{
               value_bytes: 100
             }) == {:refused, :value_size}
    end
  end

  describe "pending_is_sticky" do
    test "a pending call inside pcall ends the run with the pending reply", %{executable: exe} do
      source = """
      return function()
        local ok, err = pcall(bindings.fetch, {k = 1})
        return 'marker'
      end
      """

      assert replay(exe, source, []) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: %{"k" => 1}}}

      nested = """
      return function()
        local ok = pcall(function() pcall(function() bindings.fetch(1) end) return 'inner' end)
        return 'marker'
      end
      """

      assert replay(exe, nested, []) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: 1}}
    end

    test "a pending call inside a table.sort comparator ends the run", %{executable: exe} do
      source = """
      return function()
        local t = {3, 1, 2}
        table.sort(t, function(a, b) bindings.fetch({a, b}) return a < b end)
        return 'marker'
      end
      """

      assert {:pending_call, %{index: 0, name: "fetch", arguments: [_, _]}} =
               replay(exe, source, [])

      caught = """
      return function()
        local t = {3, 1, 2}
        local ok = pcall(table.sort, t, function(a, b) bindings.fetch({a, b}) return a < b end)
        return 'marker'
      end
      """

      assert {:pending_call, %{index: 0, name: "fetch"}} = replay(exe, caught, [])
    end

    test "a pending call inside a string.gsub callback ends the run", %{executable: exe} do
      source = """
      return function()
        local out = string.gsub("abc", ".", function(c) return bindings.fetch(c) end)
        return 'marker'
      end
      """

      assert replay(exe, source, []) == {:pending_call, %{index: 0, name: "fetch", arguments: "a"}}

      # the first call is replayed, the second is pending inside the same gsub
      assert replay(exe, source, [rec("fetch", "a", "A")]) ==
               {:pending_call, %{index: 1, name: "fetch", arguments: "b"}}

      assert {:ok, %{value: "marker"}} =
               replay(exe, source, [
                 rec("fetch", "a", "A"),
                 rec("fetch", "b", "B"),
                 rec("fetch", "c", "C")
               ])
    end

    test "a steps limit reached before the call, or while its argument is charged, is steps",
         %{executable: exe} do
      before = "return function() for i = 1, 1000 do end return bindings.fetch(1) end"
      assert replay(exe, before, [], nil, %{steps: 100}) == {:refused, :steps}

      assert {:pending_call, %{index: 0}} = replay(exe, before, [], nil, %{steps: 100_000})

      source = "return function(s) local ok = pcall(bindings.fetch, s) return 'marker' end"
      small = "abcde"
      large = String.duplicate("x", 1_000)

      # the same budget: a small argument reaches the pending stop, a large one does not
      assert {:pending_call, %{index: 0, arguments: ^small}} =
               replay(exe, source, [], small, %{steps: 100})

      assert replay(exe, source, [], large, %{steps: 100}) == {:refused, :steps}

      # the exact edge: the charge of the argument is one step for each byte
      assert {:pending_call, %{index: 0}} = replay(exe, source, [], large, %{steps: 100_000})
    end

    test "a wrong call gets no index: the next good call is call 0", %{executable: exe} do
      source = """
      return function()
        local ok1 = pcall(bindings.fetch, 1, 2)
        local ok2 = pcall(bindings.fetch, function() end)
        local ok3 = pcall(bindings.fetch)
        local ok4 = pcall(bindings.fetch, {1, 2, nil, 4})
        return bindings.store({ok1, ok2, ok3, ok4})
      end
      """

      assert replay(exe, source, []) ==
               {:pending_call, %{index: 0, name: "store", arguments: [false, false, false, false]}}

      # the wrong calls are not recorded: one record is enough for the whole run
      assert {:ok, %{value: 5}} =
               replay(exe, source, [rec("store", [false, false, false, false], 5)])
    end

    test "the first stop wins: a value_size stop before the pending call stays value_size",
         %{executable: exe} do
      source = """
      return function(s)
        local ok = pcall(bindings.fetch, {s, s})
        return bindings.store(1)
      end
      """

      assert replay(exe, source, [], String.duplicate("x", 60), %{value_bytes: 100}) ==
               {:refused, :value_size}
    end

    test "a pending stop is not an error that a later statement sees", %{executable: exe} do
      source = """
      return function()
        local seen = false
        local ok = pcall(function() bindings.fetch(1) end)
        seen = true
        local ok2 = pcall(function() seen = true end)
        return seen
      end
      """

      assert {:pending_call, %{index: 0}} = replay(exe, source, [])
    end

    test "a name that is not listed is unlisted_name, never a pending call", %{executable: exe} do
      source = "return function() return bindings.other(1) end"
      assert replay(exe, source, []) == {:refused, :unlisted_name}

      assert replay(exe, "return function() return bindings.fetch(1) end", [], nil, %{}, []) ==
               {:refused, :unlisted_name}
    end
  end

  describe "the pending reply in Elixir" do
    setup do
      %{dir: Helper.tmp_dir!("pending")}
    end

    @pending ~s({"status":"pending","call":{"index":1,"name":"fetch","arguments":[1,{"a":null}]}})

    defp fake_reply(dir, body, calls, limits \\ %{}) do
      path =
        Helper.fake!(
          dir,
          "pending-#{System.unique_integer([:positive])}",
          Helper.printf(Helper.frame(body))
        )

      LuaSandbox.run(path, Helper.request(@valid, nil, limits, calls))
    end

    defp one_record,
      do: %{mode: "replay", names: ["fetch", "store"], recorded: [rec("fetch", 1, 2)]}

    test "the exact pending shape decodes", %{dir: dir} do
      assert fake_reply(dir, @pending, one_record()) ==
               {:pending_call, %{index: 1, name: "fetch", arguments: [1, %{"a" => nil}]}}

      zero = ~s({"call":{"arguments":null,"index":0,"name":"store"},"status":"pending"})
      calls = %{mode: "replay", names: ["fetch", "store"], recorded: []}

      assert fake_reply(dir, zero, calls) ==
               {:pending_call, %{index: 0, name: "store", arguments: nil}}
    end

    test "a wrong index, an unlisted name or an extra or missing key is protocol_error",
         %{dir: dir} do
      for body <- [
            ~s({"status":"pending","call":{"index":0,"name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{"index":2,"name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{"index":-1,"name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{"index":1.0,"name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{"index":"1","name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{"index":1,"name":"other","arguments":1}}),
            ~s({"status":"pending","call":{"index":1,"name":7,"arguments":1}}),
            ~s({"status":"pending","call":{"index":1,"name":"fetch","arguments":1,"x":1}}),
            ~s({"status":"pending","call":{"index":1,"name":"fetch"}}),
            ~s({"status":"pending","call":{"index":1,"arguments":1}}),
            ~s({"status":"pending","call":{"name":"fetch","arguments":1}}),
            ~s({"status":"pending","call":{}}),
            ~s({"status":"pending","call":null}),
            ~s({"status":"pending","call":[]}),
            ~s({"status":"pending"}),
            ~s({"status":"pending","call":{"index":1,"name":"fetch","arguments":1},"x":1}),
            ~s({"status":"pending","call":{"index":1,"name":"fetch","arguments":1},"runtime":{}})
          ] do
        assert fake_reply(dir, body, one_record()) == {:host_outcome, :protocol_error}, body
      end
    end

    test "the pending frame is accepted only for a mode replay request", %{dir: dir} do
      for calls <- [
            %{mode: "data", names: ["fetch", "store"], recorded: []},
            %{mode: "none", names: [], recorded: []}
          ] do
        body = ~s({"status":"pending","call":{"index":0,"name":"fetch","arguments":1}})
        assert fake_reply(dir, body, calls) == {:host_outcome, :protocol_error}
      end
    end

    test "pending arguments over value_bytes are protocol_error", %{dir: dir} do
      calls = %{mode: "replay", names: ["fetch"], recorded: []}
      fits = String.duplicate("x", 98)
      over = String.duplicate("x", 99)

      body = fn arguments ->
        ~s({"status":"pending","call":{"index":0,"name":"fetch","arguments":#{Jason.encode!(arguments)}}})
      end

      assert fake_reply(dir, body.(fits), calls, %{value_bytes: 100}) ==
               {:pending_call, %{index: 0, name: "fetch", arguments: fits}}

      assert fake_reply(dir, body.(over), calls, %{value_bytes: 100}) ==
               {:host_outcome, :protocol_error}
    end

    test "call_mismatch is a child refusal", %{dir: dir} do
      body = ~s({"status":"refused","reason":"call_mismatch"})
      assert fake_reply(dir, body, one_record()) == {:refused, :call_mismatch}
    end
  end
end
