# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxLimitsTest do
  @moduledoc """
  Group `counted_sticky_limits`: counted `steps` and `call_depth` at the exact boundary,
  string and memory bombs, and the budgets, parser and allocation failures of loading.

  The counts below are the pinned runtime's counts of the pinned build (Lua 5.4.9, the
  recipe of `Elzoo.LuaSandbox.Build`). Each is found here by a scan for the smallest
  passing budget, so a changed runtime or a changed counting rule fails this file instead
  of passing silently. "Boundary" is the smallest budget that succeeds, "boundary + 1" of
  cost is one budget less than that.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000
  @identity "return function(x) return x end"

  setup_all do
    {executable, directory} = Helper.build!("group2")
    %{executable: executable, directory: directory}
  end

  # The smallest budget of `key` (1..max) under which `source` succeeds, or nil. The
  # outcome is monotone in each budget (more budget never turns a success into a stop),
  # so a binary search finds the boundary.
  defp smallest(exe, source, key, max, input \\ nil) do
    ok? = fn budget -> match?({:ok, _}, Helper.run(exe, source, input, %{key => budget})) end
    if ok?.(max), do: search(ok?, 1, max)
  end

  defp search(_ok?, low, low), do: low

  defp search(ok?, low, high) do
    middle = div(low + high, 2)
    if ok?.(middle), do: search(ok?, low, middle), else: search(ok?, middle + 1, high)
  end

  # Exact boundary: success at `expected`, refusal `reason` one budget below it, and
  # success again above it (the cost is a boundary, not a window).
  defp boundary!(exe, source, key, reason, expected, input \\ nil) do
    assert smallest(exe, source, key, expected + 5, input) == expected, source
    assert {:ok, _} = Helper.run(exe, source, input, %{key => expected})
    assert {:ok, _} = Helper.run(exe, source, input, %{key => expected + 1})

    # budget 0 is not a request (`invalid_request`), so a boundary of 1 has no refusal below
    if expected > 1 do
      assert Helper.run(exe, source, input, %{key => expected - 1}) == {:refused, reason}, source
    end
  end

  describe "counted_sticky_limits: steps at the boundary" do
    test "a function that returns at once, and the chunk's own work counts", %{executable: exe} do
      boundary!(exe, "return function() return 1 end", :steps, :steps, 4)

      # the same function behind a chunk that does work first costs more
      chunk_work =
        "local a = 0 for i = 1, 3 do a = a + i end return function() return 1 end"

      boundary!(exe, chunk_work, :steps, :steps, 15)

      # work inside the chunk is part of the count even when it does not change the result
      assert {:refused, :steps} =
               Helper.run(exe, chunk_work, nil, %{steps: 4})
    end

    test "a counted loop costs two steps for each iteration", %{executable: exe} do
      boundary!(
        exe,
        "return function() local a = 0 for i = 1, 10 do a = a + i end return a end",
        :steps,
        :steps,
        28
      )

      boundary!(
        exe,
        "return function() local a = 0 for i = 1, 20 do a = a + i end return a end",
        :steps,
        :steps,
        48
      )

      boundary!(
        exe,
        "return function() local a = 0 for i = 1, 500 do a = a + i end return a end",
        :steps,
        :steps,
        1008
      )
    end

    test "the loop of a chunk and the loop of the function are summed", %{executable: exe} do
      source = """
      local a = 0
      for i = 1, 10 do a = a + i end
      return function() for i = 1, 10 do a = a + i end return a end
      """

      boundary!(exe, source, :steps, :steps, 73)
    end

    test "C-to-Lua callbacks are counted: a sort comparator and a gsub replacement function", %{
      executable: exe
    } do
      without = "return function() local t = {3, 1, 2} table.sort(t) return t end"

      comparator =
        "return function() local t = {3, 1, 2} table.sort(t, function(a, b) return a < b end) return t end"

      boundary!(exe, without, :steps, :steps, 16)
      boundary!(exe, comparator, :steps, :steps, 23)

      five =
        "return function() local t = {5, 4, 3, 2, 1} table.sort(t, function(a, b) return a < b end) return t end"

      boundary!(exe, five, :steps, :steps, 48)

      plain = "return function() return (string.gsub('abc', '.', 'x')) end"
      callback = "return function() return (string.gsub('abc', '.', function(c) return c end)) end"
      boundary!(exe, plain, :steps, :steps, 9)
      boundary!(exe, callback, :steps, :steps, 12)

      # a callback that loops reaches the limit from inside C
      assert {:refused, :steps} =
               Helper.run(
                 exe,
                 "return function() return (string.gsub('a', '.', function() while true do end end)) end"
               )

      assert {:refused, :steps} =
               Helper.run(
                 exe,
                 "return function() local t = {2, 1} table.sort(t, function(a, b) while true do end end) return t end"
               )
    end

    test "tail recursion is counted per instruction: 1000 levels fit in 4009 steps", %{
      executable: exe
    } do
      tail =
        "local function f(n) if n == 0 then return 7 end return f(n - 1) end return function() return f(1000) end"

      assert smallest(exe, tail, :steps, 5_000) == 4_009
      assert {:refused, :steps} = Helper.run(exe, tail, nil, %{steps: 4_008})
    end

    test "the maximum step budget, and an unreachable one", %{executable: exe} do
      loop = "return function() local a = 0 for i = 1, 400000 do a = a + i end return a end"
      assert {:ok, %{value: 80_000_200_000}} = Helper.run(exe, loop, nil, %{steps: 1_000_000})
      assert {:refused, :steps} = Helper.run(exe, loop, nil, %{steps: 799_999})
      assert {:refused, :steps} = Helper.run(exe, "return function() while true do end end")
    end
  end

  describe "counted_sticky_limits: call_depth at the boundary" do
    test "a plain function, a nested call, and a call made by the chunk", %{executable: exe} do
      boundary!(exe, "return function() return 1 end", :call_depth, :call_depth, 1)

      nested = "local function g() return 1 end return function() return g() + 1 end"
      boundary!(exe, nested, :call_depth, :call_depth, 2)

      # the chunk is an active Lua call too: it calls f while it is running
      chunk_call = "local function f() return 1 end local x = f() return function() return 1 end"
      boundary!(exe, chunk_call, :call_depth, :call_depth, 2)
    end

    test "ordinary recursion reaches call_depth, exactly at the largest depth 64", %{
      executable: exe
    } do
      recursion = fn n ->
        "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end " <>
          "return function() return 1 + f(#{n}) end"
      end

      # frames: the function, plus f(n) down to f(0): n + 2
      boundary!(exe, recursion.(5), :call_depth, :call_depth, 7)
      assert {:ok, %{value: 63}} = Helper.run(exe, recursion.(62), nil, %{call_depth: 64})
      assert {:refused, :call_depth} = Helper.run(exe, recursion.(63), nil, %{call_depth: 64})
      assert {:refused, :call_depth} = Helper.run(exe, recursion.(1_000), nil, %{call_depth: 64})

      assert {:refused, :call_depth} =
               Helper.run(
                 exe,
                 "local function f() return 1 + f() end return function() return f() end"
               )
    end

    test "a counter that grows with each call is not reset by a protected call", %{executable: exe} do
      # every level of this recursion runs inside pcall: the count stays real
      source = """
      local function f() return pcall(f) end
      return function() f() return 1 end
      """

      assert {:refused, :call_depth} = Helper.run(exe, source)
    end

    test "tail recursion of 1000 levels runs with call_depth 2, and with 1", %{executable: exe} do
      tail =
        "local function f(n) if n == 0 then return 7 end return f(n - 1) end return function() return f(1000) end"

      assert {:ok, %{value: 7}} = Helper.run(exe, tail, nil, %{call_depth: 2})
      assert {:ok, %{value: 7}} = Helper.run(exe, tail, nil, %{call_depth: 1})

      # the same recursion without the tail call is a refusal
      body =
        "local function f(n) if n == 0 then return 7 end return 1 + f(n - 1) end return function() return f(1000) end"

      assert {:refused, :call_depth} = Helper.run(exe, body)
      assert {:refused, :call_depth} = Helper.run(exe, body, nil, %{call_depth: 64})
    end

    test "C-to-Lua callbacks count for the depth: sort comparator and gsub function", %{
      executable: exe
    } do
      boundary!(
        exe,
        "return function() local t = {3, 1, 2} table.sort(t) return t end",
        :call_depth,
        :call_depth,
        1
      )

      comparator =
        "return function() local t = {3, 1, 2} table.sort(t, function(a, b) return a < b end) return t end"

      boundary!(exe, comparator, :call_depth, :call_depth, 2)

      callback = "return function() return (string.gsub('abc', '.', function(c) return c end)) end"
      boundary!(exe, callback, :call_depth, :call_depth, 2)

      # a callback that calls one more Lua function costs one more level
      deeper =
        "local function id(c) return c end " <>
          "return function() return (string.gsub('abc', '.', function(c) return (id(c)) end)) end"

      boundary!(exe, deeper, :call_depth, :call_depth, 3)

      # recursion through a callback reaches the depth limit
      source = """
      local function f(t) table.sort(t, function(a, b) f(t) return a < b end) end
      return function() f({2, 1}) return 1 end
      """

      assert {:refused, :call_depth} = Helper.run(exe, source)

      source = """
      local function g(s) return (string.gsub(s, '.', function(c) return g(c) end)) end
      return function() return g('a') end
      """

      assert {:refused, :call_depth} = Helper.run(exe, source)
    end
  end

  describe "counted_sticky_limits: string and memory bombs" do
    # Each bomb ends in `value_size`: the wrapper of the operation compares the result
    # with the cap before it allocates, or the allocator guard stops the one string.
    # `memory` is the earlier stop only when `memory_bytes` is below the cap.
    test "string.rep: a value_size stop before any large allocation", %{executable: exe} do
      # `memory_bytes` is 100_000: an allocation of ten million bytes would be `memory`
      low = %{memory_bytes: 100_000}

      for source <- [
            "return function() return #string.rep('x', 10000000) end",
            "return function() return #('x'):rep(10000000) end",
            "return function() return #string.rep('x', 5000000, 'yy') end",
            "return function() return #('x'):rep(5000000, ',') end",
            "return function() return #string.rep('xyz', 1 << 62) end",
            "return function() return #string.rep('x', math.maxinteger) end",
            "return function() return #string.rep('', 1 << 62, 'x') end"
          ] do
        assert Helper.run(exe, source, nil, low) == {:refused, :value_size}, source
        assert Helper.run(exe, source) == {:refused, :value_size}, source
      end

      # a zero or negative count, and an empty string with an empty separator, are cheap
      assert {:ok, %{value: 0}} =
               Helper.run(
                 exe,
                 "return function() return #string.rep('x', 0) + #string.rep('x', -5) + #string.rep('', 1 << 40) end"
               )
    end

    test "repeated concatenation that doubles a string", %{executable: exe} do
      doubling = "return function() local s = 'x' for i = 1, 40 do s = s .. s end return 1 end"
      # the string guard stops the first string above the cap
      assert Helper.run(exe, doubling) == {:refused, :value_size}
      # a memory limit below the cap is reached first: a host outcome
      assert Helper.run(exe, doubling, nil, %{memory_bytes: 100_000}) == {:host_outcome, :memory}

      # also through `rep`, `..` with numbers and `table.concat` of the string itself
      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "return function() local s = 'xx' for i = 1, 40 do s = s .. s .. 1 end return 1 end"
               )

      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "return function() local s = 'x' for i = 1, 40 do s = table.concat({s, s}) end return 1 end"
               )
    end

    test "table.concat of a large array and of a separator", %{executable: exe} do
      big =
        "return function() local t = {} for i = 1, 60000 do t[i] = 'abcdefghij' end return #table.concat(t) end"

      assert Helper.run(exe, big) == {:refused, :value_size}
      # the array alone is more than the memory limit: a host outcome
      assert Helper.run(exe, big, nil, %{memory_bytes: 300_000}) == {:host_outcome, :memory}

      sep =
        "return function() local t = {} for i = 1, 3000 do t[i] = 'abcdefghij' end return #table.concat(t, string.rep('-', 30)) end"

      assert Helper.run(exe, sep) == {:refused, :value_size}

      # exactly at the cap and one over: ten pieces of ten bytes, and nine separators
      ten =
        "return function() local t = {} for i = 1, 10 do t[i] = 'abcdefghij' end return #table.concat(t) end"

      assert {:ok, %{value: 100}} = Helper.run(exe, ten, nil, %{value_bytes: 100})
      assert Helper.run(exe, ten, nil, %{value_bytes: 99}) == {:refused, :value_size}

      with_sep =
        "return function() local t = {} for i = 1, 10 do t[i] = 'abcdefghij' end return #table.concat(t, ',') end"

      assert {:ok, %{value: 109}} = Helper.run(exe, with_sep, nil, %{value_bytes: 109})
      assert Helper.run(exe, with_sep, nil, %{value_bytes: 108}) == {:refused, :value_size}
    end

    test "string.pack with large counts and with s and z strings", %{executable: exe} do
      limits = %{value_bytes: 1_000}

      for {source, expected} <- [
            # a count of a billion and of 2^32 bytes: the cap stops before the allocation
            {"return function() return string.pack('c1000000000', 'a') end",
             {:refused, :value_size}},
            {"return function() return string.pack('c4294967296', 'a') end",
             {:refused, :value_size}},
            {"return function() return #string.pack('c2000', 'a') end", {:refused, :value_size}},
            {"return function() return #string.pack('c1001', 'a') end", {:refused, :value_size}},
            {"return function() return #string.pack('c1000', 'a') end", {:ok, %{value: 1_000}}},
            # a string with a length prefix, a zero-terminated string
            {"return function() return #string.pack('s4', string.rep('x', 996)) end",
             {:ok, %{value: 1_000}}},
            {"return function() return #string.pack('s4', string.rep('x', 997)) end",
             {:refused, :value_size}},
            {"return function() return #string.pack('z', string.rep('x', 1000)) end",
             {:refused, :value_size}},
            # padding bytes in the format
            {"return function() return #string.pack(string.rep('x', 900)) end",
             {:ok, %{value: 900}}},
            {"return function() return #string.pack(string.rep('x', 900) .. string.rep('x', 900)) end",
             {:refused, :value_size}}
          ] do
        result = Helper.run(exe, source, nil, limits)

        case expected do
          {:ok, %{value: value}} -> assert {:ok, %{value: ^value}} = result, source
          other -> assert result == other, source
        end
      end

      # a two-gigabyte request under a small memory limit is `memory`, still no large allocation
      assert Helper.run(exe, "return function() return string.pack('c1000000000', 'a') end", nil, %{
               memory_bytes: 100_000
             }) == {:host_outcome, :memory}

      # a repeated format with too few arguments is an error, not an allocation
      assert {:refused, :lua_error} =
               Helper.run(
                 exe,
                 "return function() return string.pack(string.rep('i8', 20000), 1) end"
               )
    end

    test "string.format with a wide width", %{executable: exe} do
      # `%99d` is the widest width the pinned runtime accepts: 99 bytes
      wide = "return function() return #string.format('%99d', 1) end"
      assert {:ok, %{value: 99}} = Helper.run(exe, wide, nil, %{value_bytes: 99})
      assert Helper.run(exe, wide, nil, %{value_bytes: 98}) == {:refused, :value_size}

      assert Helper.run(exe, "return function() return string.format('%99d', 1) end", nil, %{
               value_bytes: 50
             }) == {:refused, :value_size}

      assert Helper.run(exe, "return function() return string.format('%-99s', 'x') end", nil, %{
               value_bytes: 50
             }) == {:refused, :value_size}

      assert Helper.run(
               exe,
               "return function() return #string.format('%99.99f', 1e308) end",
               nil,
               %{value_bytes: 100}
             ) ==
               {:refused, :value_size}

      # a width of three digits is an error of the pinned runtime, never a large buffer
      assert Helper.run(exe, "return function() return string.format('%100d', 1) end") ==
               {:refused, :lua_error}

      assert Helper.run(exe, "return function() return string.format('%99999d', 1) end") ==
               {:refused, :lua_error}

      # two large arguments of %s together are more than the cap
      two =
        "local s = string.rep('x', 900) return function() return #string.format('%s%s', s, s) end"

      assert Helper.run(exe, two, nil, %{value_bytes: 1_000}) == {:refused, :value_size}
    end

    test "string.gsub that grows its result, with a string and with a function", %{executable: exe} do
      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "return function() return (string.gsub(string.rep('a', 30000), 'a', 'bbbb')) end"
               )

      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "return function() return (string.gsub(string.rep('a', 30000), 'a', function() return 'bbbb' end)) end"
               )

      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "return function() local s = string.rep('ab', 30000) return s:upper() .. s:upper() end"
               )
    end

    test "a string built in Lua: value_size at the cap and one over", %{executable: exe} do
      cap = %{value_bytes: 100}

      # strings over 40 bytes are long strings in the pinned runtime: the cap is exact
      assert {:ok, %{value: 100}} =
               Helper.run(
                 exe,
                 "return function() local s = string.rep('x', 100) return #s end",
                 nil,
                 cap
               )

      assert Helper.run(
               exe,
               "return function() local s = string.rep('x', 101) return #s end",
               nil,
               cap
             ) ==
               {:refused, :value_size}

      assert {:ok, %{value: 100}} =
               Helper.run(
                 exe,
                 "return function() local s = string.rep('x', 50) .. string.rep('y', 50) return #s end",
                 nil,
                 cap
               )

      assert Helper.run(
               exe,
               "return function() local s = string.rep('x', 50) .. string.rep('y', 51) return #s end",
               nil,
               cap
             ) ==
               {:refused, :value_size}

      # a short string at the cap of 40 too
      small = %{value_bytes: 40}

      assert {:ok, %{value: 40}} =
               Helper.run(exe, "return function() return #string.rep('x', 40) end", nil, small)

      assert Helper.run(exe, "return function() return #string.rep('x', 41) end", nil, small) ==
               {:refused, :value_size}

      # an intermediate string counts as much as a returned one
      assert Helper.run(
               exe,
               "return function() local s = string.rep('x', 101) return 1 end",
               nil,
               cap
             ) ==
               {:refused, :value_size}

      assert {:ok, %{value: 1}} =
               Helper.run(
                 exe,
                 "return function() local s = string.rep('x', 100) return 1 end",
                 nil,
                 cap
               )
    end

    test "memory: a bomb that is not a string", %{executable: exe} do
      assert {:host_outcome, :memory} =
               Helper.run(
                 exe,
                 "return function() local t = {} for i = 1, 100000 do t[i] = {} end return 1 end",
                 nil,
                 %{memory_bytes: 300_000}
               )

      assert {:host_outcome, :memory} =
               Helper.run(
                 exe,
                 "return function() local t = {} for i = 1, 1000000 do t[i] = {i} end return 1 end",
                 nil,
                 %{memory_bytes: 1_000_000}
               )

      # the same loop below the budget succeeds: the stop is the budget, not the program
      assert {:ok, %{value: 1}} =
               Helper.run(
                 exe,
                 "return function() local t = {} for i = 1, 100 do t[i] = {} end return 1 end",
                 nil,
                 %{
                   memory_bytes: 1_000_000
                 }
               )
    end
  end

  describe "counted_sticky_limits: initialization, parser and allocation failures" do
    test "value_bytes below initialization: 1..3 refuse, 4 runs", %{executable: exe} do
      for limit <- 1..3 do
        assert Helper.run(exe, @identity, 1, %{value_bytes: limit}) == {:refused, :value_size}
      end

      assert {:ok, %{value: 1}} = Helper.run(exe, @identity, 1, %{value_bytes: 4})
      # a program that would loop forever never starts: nothing counted, nothing run
      assert Helper.run(exe, "while true do end", nil, %{value_bytes: 3}) == {:refused, :value_size}
    end

    test "memory_bytes below the baseline is a host outcome and runs no user code", %{
      executable: exe
    } do
      baseline = smallest(exe, @identity, :memory_bytes, 40_000, 1)
      assert is_integer(baseline) and baseline > 1_000 and baseline < 40_000

      assert {:ok, _} = Helper.run(exe, @identity, 1, %{memory_bytes: baseline})

      assert Helper.run(exe, @identity, 1, %{memory_bytes: baseline - 1}) ==
               {:host_outcome, :memory}

      for limit <- [1, 100, 5_000, baseline - 1] do
        assert Helper.run(exe, @identity, 1, %{memory_bytes: limit}) == {:host_outcome, :memory}
        # an infinite loop never starts either: the outcome is the memory stop, not `steps`
        assert Helper.run(exe, "return function() while true do end end", nil, %{
                 memory_bytes: limit
               }) ==
                 {:host_outcome, :memory}
      end
    end

    test "steps 1, call_depth 1 and wall_ms 1 at their smallest values", %{executable: exe} do
      assert Helper.run(exe, @identity, 1, %{steps: 1}) == {:refused, :steps}
      assert Helper.run(exe, @identity, 1, %{steps: 2}) == {:refused, :steps}
      boundary!(exe, @identity, :steps, :steps, 3, 1)

      assert {:ok, %{value: 1}} = Helper.run(exe, @identity, 1, %{call_depth: 1})

      assert Helper.run(
               exe,
               "local function g() return 1 end return function() return g() + 1 end",
               nil,
               %{call_depth: 1}
             ) ==
               {:refused, :call_depth}

      # the smallest wall budget: the process can answer first, or the deadline passes
      result = Helper.run(exe, @identity, 1, %{wall_ms: 1})
      assert match?({:ok, %{value: 1}}, result) or result == {:host_outcome, :wall_time}
    end

    test "a syntax error and a source that is not a program", %{executable: exe} do
      for source <- [
            "return function(",
            "x = = 1",
            "return 'unfinished",
            "return function() end end",
            "@@@",
            "\x1bLua"
          ] do
        assert Helper.run(exe, source) == {:refused, :lua_error}, source
      end
    end

    test "an expression nested deeper than the parser allows is a lua_error", %{executable: exe} do
      deep = fn open, close, n, inner ->
        "return function() return " <>
          String.duplicate(open, n) <> inner <> String.duplicate(close, n) <> " end"
      end

      assert {:ok, %{value: 1}} = Helper.run(exe, deep.("(", ")", 100, "1"))
      assert Helper.run(exe, deep.("(", ")", 300, "1")) == {:refused, :lua_error}
      assert Helper.run(exe, deep.("{", "}", 300, "")) == {:refused, :lua_error}
      assert Helper.run(exe, deep.("-", "", 10_000, "1")) == {:refused, :lua_error}

      assert Helper.run(
               exe,
               String.duplicate("return function() ", 250) <> String.duplicate("end ", 250)
             ) ==
               {:refused, :lua_error}

      # a long chain of `..` is right associative and nests too
      chain = "return function() return " <> String.duplicate("'a' .. ", 300) <> "'a' end"
      assert Helper.run(exe, chain) == {:refused, :lua_error}
    end

    test "a constant string that exceeds value_bytes while the source loads", %{executable: exe} do
      constant = fn n, quote ->
        {open, close} = if quote == :long, do: {"[[", "]]"}, else: {"'", "'"}
        "return function() return #" <> open <> String.duplicate("a", n) <> close <> " end"
      end

      for quote <- [:short, :long] do
        assert {:ok, %{value: 1_000}} =
                 Helper.run(exe, constant.(1_000, quote), nil, %{value_bytes: 1_000})

        assert Helper.run(exe, constant.(1_001, quote), nil, %{value_bytes: 1_000}) ==
                 {:refused, :value_size}

        assert Helper.run(exe, constant.(5_000, quote), nil, %{value_bytes: 1_000}) ==
                 {:refused, :value_size}
      end

      # short strings too
      assert {:ok, %{value: 40}} = Helper.run(exe, constant.(40, :short), nil, %{value_bytes: 40})

      assert Helper.run(exe, constant.(40, :short), nil, %{value_bytes: 39}) ==
               {:refused, :value_size}

      # a long name is a string too
      assert Helper.run(
               exe,
               "local #{String.duplicate("a", 200)} = 1 return function() return 1 end",
               nil,
               %{
                 value_bytes: 100
               }
             ) == {:refused, :value_size}
    end

    test "a source that exhausts memory while it loads", %{executable: exe} do
      table = "local a = {" <> String.duplicate("1,", 20_000) <> "} return function() return 1 end"
      assert Helper.run(exe, table, nil, %{memory_bytes: 100_000}) == {:host_outcome, :memory}

      constant = "local s = '" <> String.duplicate("a", 5_000) <> "' return function() return 1 end"
      assert Helper.run(exe, constant, nil, %{memory_bytes: 8_000}) == {:host_outcome, :memory}

      # the source is accepted when the budget is large enough
      assert {:ok, %{value: 1}} = Helper.run(exe, constant, nil, %{memory_bytes: 1_000_000})
      assert {:ok, %{value: 1}} = Helper.run(exe, table, nil, %{memory_bytes: 16_777_216})
    end

    test "limits at their inclusive maxima and outside them", %{executable: exe} do
      maxima = %{
        steps: 1_000_000,
        call_depth: 64,
        value_bytes: 65_536,
        memory_bytes: 16_777_216,
        wall_ms: 1_000
      }

      assert {:ok, %{value: 1}} = Helper.run(exe, @identity, 1, maxima)

      for {key, value} <- maxima do
        good = Helper.request(@identity, 1, %{})

        assert LuaSandbox.run(exe, put_in(good, [:limits, key], value + 1)) ==
                 {:refused, :invalid_request}

        assert LuaSandbox.run(exe, put_in(good, [:limits, key], 0)) == {:refused, :invalid_request}
      end
    end
  end
end
