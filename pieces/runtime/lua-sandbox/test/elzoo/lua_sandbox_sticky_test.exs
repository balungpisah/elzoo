# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxStickyTest do
  @moduledoc """
  Group `no_catching_or_continuation`: a stop cannot be caught, continued or reset.

  For each stop (`steps`, `call_depth`, `value_size`, `memory`, `unlisted_name`,
  `wall_time`) the sources catch it with nested `pcall`, raise it again from the path that
  handles a caught failure, and attempt a hundred catches in a row. Each source ends in a
  `POST-STOP-MARKER` return if the stop were continued: the outcome must be the stop, never
  the marker, never `{:ok, _}` and never `lua_error`.

  Memory and wall time are host outcomes. `wall_time` is decided by the caller's deadline
  and the OS kill; it does not depend on the instruction count.

  Negative control (recorded in the pull request, never committed): the sticky guard is
  the pcall wrapper's rethrow, the hook's raise, the rethrow in the generic wrapper and
  the sticky report at the top level together. With all four disabled a caught stop
  continues and the post-stop marker comes back.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 180_000
  @marker "POST-STOP-MARKER"

  # {statement that causes the stop, limits it needs, the expected outcome}
  @stops [
    steps: {"while true do end", %{}, {:refused, :steps}},
    call_depth: {"local function f() return 1 + f() end f()", %{}, {:refused, :call_depth}},
    value_size: {"local s = string.rep('x', 1000000)", %{}, {:refused, :value_size}},
    memory:
      {"local t = {} for i = 1, 100000 do t[i] = {} end", %{memory_bytes: 300_000},
       {:host_outcome, :memory}},
    unlisted_name: {"local x = os", %{}, {:refused, :unlisted_name}},
    # a pattern match of the pinned runtime runs in C and counts no step
    wall_time:
      {"local x = string.find(string.rep('a', 4000), 'a*a*a*a*a*a*b')", %{wall_ms: 300},
       {:host_outcome, :wall_time}}
  ]

  setup_all do
    {executable, directory} = Helper.build!("group3")
    %{executable: executable, directory: directory}
  end

  # Source templates: each places `stop` where a catch could follow it.
  defp templates(stop) do
    marker = "return '#{@marker}'"

    [
      nested_three_levels:
        Helper.function_source("""
        local r = pcall(function()
          return pcall(function()
            return pcall(function() #{stop} end)
          end)
        end)
        #{marker}
        """),
      handler_path_raises_again:
        Helper.function_source("""
        local ok = pcall(function() #{stop} end)
        if not ok then
          local ok2 = pcall(function() #{stop} end)
          if not ok2 then return 'handled' end
        end
        #{marker}
        """),
      pcall_inside_the_handler_of_a_failed_pcall:
        Helper.function_source("""
        local ok, e = pcall(error, 'first')
        if not ok then
          pcall(function() #{stop} end)
        end
        #{marker}
        """),
      sort_comparator_under_pcall:
        Helper.function_source("""
        pcall(table.sort, {3, 2, 1}, function(a, b) #{stop} return a < b end)
        #{marker}
        """),
      gsub_callback_under_pcall:
        Helper.function_source("""
        pcall(string.gsub, 'abc', '.', function() #{stop} end)
        #{marker}
        """),
      hundred_repeated_catches:
        Helper.function_source("""
        for i = 1, 100 do pcall(function() #{stop} end) end
        #{marker}
        """),
      stop_in_the_chunk:
        "pcall(function() #{stop} end) pcall(function() #{stop} end) " <>
          "return function() #{marker} end",
      count_of_results:
        Helper.function_source("""
        local n = select('#', pcall(function() #{stop} end))
        #{marker}
        """)
    ]
  end

  describe "no_catching_or_continuation: each stop is the outcome of every catching shape" do
    for {name, {stop, limits, expected}} <- @stops do
      @tag stop: name
      test "#{name} is never caught, handled again or followed by the marker", %{executable: exe} do
        {stop, limits, expected} = unquote(Macro.escape({stop, limits, expected}))

        for {shape, source} <- templates(stop) do
          result = Helper.run(exe, source, nil, limits)
          assert result == expected, "#{unquote(name)} / #{shape}: #{inspect(result)}"
          refute inspect(result) =~ @marker
          refute match?({:ok, _}, result)
          refute result == {:refused, :lua_error}
        end
      end
    end

    test "the stops are the expected kinds of outcome" do
      # memory and wall time are host outcomes; the rest are refusals
      kinds = for {name, {_, _, {kind, _}}} <- @stops, into: %{}, do: {name, kind}

      assert kinds == %{
               steps: :refused,
               call_depth: :refused,
               value_size: :refused,
               memory: :host_outcome,
               unlisted_name: :refused,
               wall_time: :host_outcome
             }
    end
  end

  describe "no_catching_or_continuation: the stop is not reset or replaced from Lua" do
    @first_stops [
      steps: "while true do end",
      call_depth: "local function f() return 1 + f() end f()",
      value_size: "local s = string.rep('x', 1000000)",
      unlisted_name: "local x = os"
    ]

    test "a second stop after a caught first stop still reports the first stop", %{executable: exe} do
      for {first, first_stop} <- @first_stops,
          {second, second_stop} <- @first_stops,
          first != second do
        source =
          Helper.function_source("""
          pcall(function() #{first_stop} end)
          pcall(function() #{second_stop} end)
          return '#{@marker}'
          """)

        assert Helper.run(exe, source) == {:refused, first},
               "#{first} then #{second}: the first stop is the reason"
      end
    end

    test "a memory stop is not replaced by a later stop either", %{executable: exe} do
      source =
        Helper.function_source("""
        pcall(function() local t = {} for i = 1, 100000 do t[i] = {} end end)
        pcall(function() return os end)
        return '#{@marker}'
        """)

      assert Helper.run(exe, source, nil, %{memory_bytes: 300_000}) == {:host_outcome, :memory}
    end

    test "there is no name for the sticky state", %{executable: exe} do
      for name <- ~w(sticky stop reset clear _STICKY _STOP G host stop_raise unlisted set_sticky) do
        for access <- ["#{name}", "_ENV.#{name}", "_ENV['#{name}']", "string.#{name}"] do
          assert Helper.run(exe, Helper.function_source("return #{access}")) ==
                   {:refused, :unlisted_name},
                 access
        end
      end

      # no way to reach or replace the environment or the registry from Lua
      for source <- [
            {"_ENV = nil pcall(function() return os end) return 1", :lua_error},
            {"pcall = function() return true end local x = os", :unlisted_name}
          ] do
        {body, reason} = source
        assert Helper.run(exe, "return function() #{body} end") == {:refused, reason}, body
      end
    end

    test "a failure that is not a stop is still catchable data", %{executable: exe} do
      source =
        Helper.function_source("""
        local ok, message = pcall(error, 'plain')
        local ok2 = pcall(function() local x = nil; return x.y end)
        return {ok, ok2, message}
        """)

      assert {:ok, %{value: [false, false, "plain"]}} = Helper.run(exe, source)

      # and the result of a normal pcall keeps its values
      assert {:ok, %{value: [true, 1, 2]}} =
               Helper.run(exe, Helper.function_source("return {pcall(function() return 1, 2 end)}"))
    end
  end

  describe "no_catching_or_continuation: xpcall and coroutines are unreachable" do
    @names [
      "xpcall",
      "coroutine",
      "coroutine.resume",
      "coroutine.wrap",
      "coroutine.create",
      "coroutine.yield"
    ]

    test "on every lookup path", %{executable: exe} do
      for name <- @names do
        [head | rest] = String.split(name, ".")
        tail = Enum.map_join(rest, &".#{&1}")

        paths = [
          name,
          "_ENV.#{head}#{tail}",
          "_ENV[\"#{head}\"]#{tail}",
          "(\"x\").#{head}#{tail}",
          "string.#{head}#{tail}",
          "table.#{head}#{tail}",
          "math.#{head}#{tail}",
          "string[\"#{head}\"]#{tail}",
          "(\"x\"):#{head}()",
          "select(1, string).#{head}#{tail}"
        ]

        for path <- paths do
          assert Helper.run(exe, Helper.function_source("return #{path}")) ==
                   {:refused, :unlisted_name},
                 path

          # the same lookup in the chunk, before the function exists
          assert Helper.run(exe, "local x = #{path} return function() return 1 end") ==
                   {:refused, :unlisted_name},
                 path
        end
      end
    end

    test "as a call, a method call, behind pcall and as an argument", %{executable: exe} do
      for source <- [
            "return xpcall(function() end, function() end)",
            "return coroutine.wrap(function() end)()",
            "local co = coroutine.create(function() end) return coroutine.resume(co)",
            "return ('x'):xpcall(print)",
            "return pcall(xpcall, function() end, print)",
            "return pcall(coroutine.wrap, function() end)",
            "return select('#', xpcall)",
            "return type(coroutine)",
            "return tostring(coroutine.resume)",
            "local t = {coroutine.wrap} return #t"
          ] do
        assert Helper.run(exe, Helper.function_source(source)) == {:refused, :unlisted_name}, source
      end
    end
  end

  describe "no_catching_or_continuation: a blocked child ends at the wall deadline" do
    test "SIGSTOP on the real child: wall_time, independent of the instruction count", %{
      executable: exe,
      directory: directory
    } do
      unique = Helper.unique_exe!(exe, directory, "sigstop-real")
      # a pattern match runs in C and counts no step; the instruction budget is the maximum
      source =
        Helper.function_source("return string.find(string.rep('a', 20000), 'a*a*a*a*a*a*b')")

      started = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          LuaSandbox.run(unique, Helper.request(source, nil, %{wall_ms: 400, steps: 1_000_000}))
        end)

      pid = Helper.wait_for_pid(unique)
      assert {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(pid)])

      assert Task.await(task, 10_000) == {:host_outcome, :wall_time}
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 400 + 2_000, "the caller waited #{elapsed} ms"

      assert Helper.gone?(pid)
      assert Helper.pids(unique) == []
    end

    test "a fake executable that sleeps: wall_time, child reaped", %{directory: directory} do
      path =
        Helper.fake!(directory, "sleeper-#{System.unique_integer([:positive])}", "exec sleep 30")

      started = System.monotonic_time(:millisecond)

      assert LuaSandbox.run(
               path,
               Helper.request("return function() return 1 end", nil, %{wall_ms: 300})
             ) ==
               {:host_outcome, :wall_time}

      assert System.monotonic_time(:millisecond) - started < 300 + 2_000
      assert Helper.pids(path) == []

      # one that ignores its input and sleeps in a loop, with children
      loop =
        Helper.fake!(
          directory,
          "loop-#{System.unique_integer([:positive])}",
          "while true; do sleep 1; done"
        )

      assert LuaSandbox.run(
               loop,
               Helper.request("return function() return 1 end", nil, %{wall_ms: 300})
             ) ==
               {:host_outcome, :wall_time}

      assert Helper.pids(loop) == []
    end

    test "the deadline is the caller's: a fake child that sleeps answers wall_time at any budget",
         %{
           directory: directory
         } do
      path =
        Helper.fake!(directory, "sleeper2-#{System.unique_integer([:positive])}", "exec sleep 30")

      for wall <- [1, 50, 200] do
        started = System.monotonic_time(:millisecond)

        assert LuaSandbox.run(
                 path,
                 Helper.request("return function() return 1 end", nil, %{wall_ms: wall})
               ) ==
                 {:host_outcome, :wall_time}

        assert System.monotonic_time(:millisecond) - started < wall + 2_000
      end

      assert Helper.pids(path) == []
    end
  end
end
