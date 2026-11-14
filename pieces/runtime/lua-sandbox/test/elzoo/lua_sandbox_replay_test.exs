# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxReplayTest do
  @moduledoc """
  Group `replay_and_survival`.

  Replay: a fixed list of pure cases (numeric boundaries, formatting, patterns, sparse
  length, sort with equal keys, array and map results, counted refusals) runs in 20 fresh
  calls and in two fresh BEAM processes with one build and one policy. Every call returns
  the same encoded term: an equal value or an equal deterministic refusal. The two BEAMs
  load the compiled modules of this test run and write their results as encoded terms;
  the test compares the bytes.

  Memory and wall-time outcomes are recorded for the same build but are not part of the
  comparison: they are host outcomes, never deterministic replay decisions.

  Identity: a request with another policy identity is `policy_mismatch` (in Elixir, and in
  the host itself, before it creates a Lua state); two builds of the same bytes have equal
  runtime identity maps.

  Survival: after each adverse case of groups 2 to 5 the owning BEAM is alive, no child of
  the executable remains (`pgrep -f` on a unique path, `kill -0` on the observed pid) and a
  following valid call returns 42. A caller killed while its child runs leaves no live
  child after `wall_ms` plus a margin: cleanup, not only the closing of the Port.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Build

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 300_000
  @valid "return function() return 42 end"

  setup_all do
    {executable, directory} = Helper.build!("group6")
    %{executable: executable, directory: directory}
  end

  defp fun(body), do: Helper.function_source(body)

  # {name, source, input, limits}: policy-only sources, no clock, no memory or wall limit
  defp replay_cases do
    stable = [
      # numeric boundaries
      {"integer add wraps", fun("return math.maxinteger + 1"), nil, %{}},
      {"integer mul wraps", fun("return math.maxinteger * 2"), nil, %{}},
      {"minint // -1", fun("return math.mininteger // -1"), nil, %{}},
      {"minint % -1", fun("return math.mininteger % -1"), nil, %{}},
      {"abs minint", fun("return math.abs(math.mininteger)"), nil, %{}},
      {"integer division by zero", fun("return 1 // 0"), nil, %{}},
      {"modulo by zero", fun("return 1 % 0"), nil, %{}},
      {"1 / 0 is nonfinite", fun("return 1 / 0"), nil, %{}},
      {"-1 / 0 is nonfinite", fun("return -1 / 0"), nil, %{}},
      {"0 / 0 is nonfinite", fun("return 0 / 0"), nil, %{}},
      {"1 // 0.0 is nonfinite", fun("return 1 // 0.0"), nil, %{}},
      {"integer and float division",
       fun("return {7 // 2, 7.0 // 2, -7 // 2, 7 % -3, -7 % 3, 7 / 2, 2^63, 7 // 2.0, -7.5 % 2}"),
       nil, %{}},
      {"tointeger and rounding",
       fun(
         "return {tostring(math.tointeger(3.0)), tostring(math.tointeger(3.5)), tostring(math.tointeger('8')), tostring(math.tointeger(2^63)), tostring(math.tointeger(-2^63)), math.floor(-0.5), math.ceil(-0.5), math.floor(2^62)}"
       ), nil, %{}},
      {"bitwise", fun("return {3 | 4, 3 & 6, 3 ~ 5, ~0, 1 << 63, 1 << 64, -1 >> 1, 1 << -1}"), nil,
       %{}},
      {"ult fmod max min",
       fun(
         "return {math.ult(1, -1), math.fmod(-6, 4), math.fmod(6, -4), math.max(1, 2.5), math.min(3, 2)}"
       ), nil, %{}},
      {"libm functions",
       fun(
         "return {math.sqrt(2), math.sin(1), math.cos(1), math.exp(1), math.log(10), math.log(8, 2), math.atan(1, 2), math.pi * 2, math.tan(0.5), math.deg(1), math.rad(90)}"
       ), nil, %{}},
      {"integer for loop at the maximum",
       fun("local n = 0 for i = math.maxinteger - 2, math.maxinteger do n = n + 1 end return n"),
       nil, %{}},
      {"float for loop", fun("local n = 0 for x = 0, 1, 0.1 do n = n + 1 end return n"), nil, %{}},
      {"coercions",
       fun(
         "return {'10' + 5, '3' * '4', 10 .. 20, 1 == 1.0, '10' < '9', 'a' < 'b', math.type(1), math.type(1.0)}"
       ), nil, %{}},
      {"float keys", fun("local t = {} t[1.0] = 'a' t[2^53] = 'b' return {t[1], #t, t[2^53]}"), nil,
       %{}},
      # numeric formatting
      {"tostring of floats",
       fun(
         "return {tostring(0.1), tostring(1/3), tostring(1e15), tostring(1e16), tostring(2^53), tostring(-0.0), tostring(100/2), tostring(3.0), tostring(1e100), tostring(123456789012345678)}"
       ), nil, %{}},
      {"concat of numbers",
       fun("return {1e15 .. '', 2^63 .. '', -0.0 .. '', 0.1 .. '', 10 // 3 .. ''}"), nil, %{}},
      {"format %.17g",
       fun(
         "return {string.format('%.17g', 0.1), string.format('%.17g', 1/3), string.format('%.17g', 2^63), string.format('%.3f', 2/3)}"
       ), nil, %{}},
      {"format %5.2f and friends",
       fun(
         "return {string.format('%5.2f', 3.14159), string.format('%e', 12345.678), string.format('%g', 1e-5), string.format('%10.4f|', 2.5), string.format('%x', 255), string.format('%5d|', 42), string.format('%-5d|', 42), string.format('%05d', 42), string.format('%+d', 42), string.format('%a', 1.0), string.format('%d', 3.0)}"
       ), nil, %{}},
      {"format %d of a fraction", fun("return string.format('%d', 3.5)"), nil, %{}},
      {"tonumber",
       fun(
         "return {tostring(tonumber('0x10')), tostring(tonumber('  12  ')), tostring(tonumber('1e2')), tostring(tonumber('10', 2)), tostring(tonumber('z', 36)), tostring(tonumber('abc')), tostring(tonumber('0x')), tostring(tonumber(''))}"
       ), nil, %{}},
      # patterns
      {"find", fun("return {string.find('hello world', 'o w')}"), nil, %{}},
      {"find with captures", fun("return {string.find('abc', '(b)(c)')}"), nil, %{}},
      {"find plain", fun("return {string.find('a.b', '.', 1, true)}"), nil, %{}},
      {"match captures", fun("return {string.match('key=val', '(%w+)=(%w+)')}"), nil, %{}},
      {"match date", fun("return {string.match('2024-11-14', '(%d+)-(%d+)-(%d+)')}"), nil, %{}},
      {"match trim", fun("return string.match('  trim  ', '^%s*(.-)%s*$')"), nil, %{}},
      {"match balanced", fun("return string.match('f(a(b)c)d', '%b()')"), nil, %{}},
      {"match position capture", fun("return {string.match('hello', '()ll()')}"), nil, %{}},
      {"gsub plain", fun("return {string.gsub('hello world', 'o', '0')}"), nil, %{}},
      {"gsub whole match", fun("return {string.gsub('abc', '%w', '%0%0')}"), nil, %{}},
      {"gsub swapped captures", fun("return {string.gsub('abc', '(a)(b)', '%2%1')}"), nil, %{}},
      {"gsub with a table", fun("return {string.gsub('$a and $b', '%$(%w+)', {a = 'X', b = 'Y'})}"),
       nil, %{}},
      {"gsub with a function",
       fun("return {string.gsub('a1b22', '%d+', function(d) return '<' .. d .. '>' end)}"), nil,
       %{}},
      {"gsub frontier", fun("return {string.gsub('THE (quick) fox', '%f[%a]%a+', 'X')}"), nil, %{}},
      {"gmatch",
       fun(
         "local r = {} for k, v in string.gmatch('a=1, b=2', '(%w+)=(%w+)') do r[#r + 1] = k .. v end return r"
       ), nil, %{}},
      {"string functions",
       fun(
         "return {string.rep('ab', 3, ','), string.reverse('abc'), string.byte('A'), string.char(72, 105), string.sub('hello', -3, -2), string.lower('AbC'), string.upper('AbC'), string.len('héllo'), string.format('%q', 'a\\nb\"')}"
       ), nil, %{}},
      {"pack and unpack",
       fun(
         "local a, b = string.unpack('<i4', string.pack('<i4', -2)) return {a, b, string.packsize('i4i8'), #string.pack('d', 1.5), string.unpack('z', 'ab\\0cd')}"
       ), nil, %{}},
      # sparse length and tables
      {"sparse length of a constructor", fun("local t = {1, 2, nil, 4}; return #t"), nil, %{}},
      {"sparse length by assignment", fun("local t = {}; t[1] = 1; t[2] = 2; t[4] = 4; return #t"),
       nil, %{}},
      {"sparse length of leading nils", fun("return \#{nil, nil, 3}"), nil, %{}},
      {"trailing nil", fun("local t = {10, 20, 30, nil}; return #t"), nil, %{}},
      {"hole made after a loop",
       fun("local t = {} for i = 1, 10 do t[i] = i end t[5] = nil return #t"), nil, %{}},
      {"append after a field", fun("local t = {n = 3, 10, 20}; t[#t + 1] = 30; return #t"), nil,
       %{}},
      {"remove the last", fun("local t = {1, 2, 3}; t[#t] = nil; return #t"), nil, %{}},
      {"ipairs stops at nil",
       fun("local n = 0 for _ in ipairs({1, 2, nil, 4}) do n = n + 1 end return n"), nil, %{}},
      {"select of a hole", fun("return select('#', table.unpack({1, nil, 3}, 1, 3))"), nil, %{}},
      {"table library",
       fun(
         "local t = {1, 2, 3} table.insert(t, 2, 9) local r = table.remove(t, 1) return {t, r, table.concat({1, 2, 3}, '-'), table.move({1, 2, 3}, 1, 3, 2)}"
       ), nil, %{}},
      # sort
      {"sort with a comparator and equal keys, 200 elements",
       fun(
         "local t = {} for i = 1, 200 do t[i] = {k = i % 5, id = i} end table.sort(t, function(a, b) return a.k < b.k end) local r = {} for i = 1, 200 do r[i] = t[i].id end return r"
       ), nil, %{}},
      {"sort of numbers, 300 elements",
       fun(
         "local t, x = {}, 12345 for i = 1, 300 do x = (x * 1103515245 + 12345) % 2147483648 t[i] = x end table.sort(t) return {t[1], t[150], t[300]}"
       ), nil, %{}},
      {"sort of equal strings",
       fun(
         "local t = {} for i = 1, 150 do t[i] = (i % 3 == 0) and 'b' or 'a' end table.sort(t) return {t[1], t[75], t[150]}"
       ), nil, %{}},
      {"sort descending with ties, 120 elements",
       fun(
         "local t = {} for i = 1, 120 do t[i] = {k = i % 7, id = i} end table.sort(t, function(a, b) return a.k > b.k end) local r = {} for i = 1, 120 do r[i] = t[i].id end return r"
       ), nil, %{}},
      # results
      {"array and map results",
       fun("return {b = 2, a = {1, 2}, c = {x = 'y', z = {true, false}}, d = {1.5, 'two', {3}}}"),
       nil, %{}},
      {"empty containers", fun("return {a = {}, b = {{}, {}}}"), nil, %{}},
      {"input transformed", "return function(x) return {x.a + 1, x.b .. '!', #x.c, x.d * 2} end",
       %{"a" => 1, "b" => "s", "c" => [1, 2, 3], "d" => 1.25}, %{}},
      {"pcall data",
       fun(
         "local ok, e = pcall(error, 'boom') local ok2, e2 = pcall(function() local x = nil; return x.y end) return {ok, e, ok2, e2}"
       ), nil, %{}},
      # identity formatting attempts
      {"tostring of a table", fun("return tostring({})"), nil, %{}},
      {"tostring of a function", fun("return tostring(function() end)"), nil, %{}},
      {"format %p", fun("return string.format('%p', {})"), nil, %{}},
      {"format %s of a table", fun("return string.format('%s', {})"), nil, %{}},
      # counted refusals
      {"steps: an infinite loop", fun("while true do end"), nil, %{}},
      {"steps: boundary", fun("local a = 0 for i = 1, 10 do a = a + i end return a"), nil,
       %{steps: 28}},
      {"steps: boundary - 1", fun("local a = 0 for i = 1, 10 do a = a + i end return a"), nil,
       %{steps: 27}},
      {"steps: a long loop under the maximum",
       fun("local a = 0 for i = 1, 400000 do a = a + i end return a"), nil, %{}},
      {"steps: a long loop over the maximum",
       fun("local a = 0 for i = 1, 600000 do a = a + i end return a"), nil, %{}},
      {"call_depth: recursion",
       "local function f() return 1 + f() end return function() return f() end", nil, %{}},
      {"call_depth: boundary",
       "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return function() return 1 + f(62) end",
       nil, %{}},
      {"call_depth: boundary + 1",
       "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return function() return 1 + f(63) end",
       nil, %{}},
      {"call_depth: a callback",
       "return function() return (string.gsub('abc', '.', function(c) return c end)) end", nil,
       %{call_depth: 1}},
      {"value_size: rep", fun("return #string.rep('x', 100000)"), nil, %{}},
      {"value_size: doubling", fun("local s = 'x' for i = 1, 40 do s = s .. s end return 1"), nil,
       %{}},
      {"value_size: at the cap", fun("return #string.rep('x', 100)"), nil, %{value_bytes: 100}},
      {"value_size: over the cap", fun("return #string.rep('x', 101)"), nil, %{value_bytes: 100}},
      {"value_size: pack", fun("return #string.pack('c2000', 'a')"), nil, %{value_bytes: 1_000}},
      {"unlisted_name", fun("return os"), nil, %{}},
      {"stop under pcall", fun("pcall(function() while true do end end) return 1"), nil, %{}},
      {"parse failure", "return function(", nil, %{}}
    ]

    stable
  end

  # Cases whose outcome is a host outcome: recorded, never compared.
  defp host_cases do
    [
      {"memory", fun("local t = {} for i = 1, 100000 do t[i] = {} end return 1"), nil,
       %{memory_bytes: 300_000}, {:host_outcome, :memory}},
      {"wall time", fun("return string.find(string.rep('a', 20000), 'a*a*a*a*a*b')"), nil,
       %{wall_ms: 200}, {:host_outcome, :wall_time}}
    ]
  end

  defp run_case(exe, {_name, source, input, limits}), do: Helper.run(exe, source, input, limits)

  # The second BEAM: loads the compiled modules of this run, runs each case once.
  @beam_script """
  [executable, cases_file, out_file] = System.argv()
  cases = cases_file |> File.read!() |> :erlang.binary_to_term()

  results =
    for {name, request} <- cases do
      {name, Elzoo.LuaSandbox.run(executable, request)}
    end

  File.write!(out_file, :erlang.term_to_binary(results, [:deterministic]))
  """

  defp other_beam!(exe, cases, directory, label) do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir), "the elixir executable is missing"

    cases_file = Path.join(directory, "cases-#{label}.bin")
    out_file = Path.join(directory, "out-#{label}.bin")
    script = Path.join(directory, "beam-#{label}.exs")
    File.write!(script, @beam_script)

    requests =
      for {name, source, input, limits} <- cases, do: {name, Helper.request(source, input, limits)}

    File.write!(cases_file, :erlang.term_to_binary(requests))

    # Every code path outside the Erlang and Elixir installations: the compiled Piece and
    # its providers, which a copied consumer may build outside its own build path.
    installed = [List.to_string(:code.root_dir()), Path.dirname(Application.app_dir(:elixir))]

    code_paths =
      for path <- :code.get_path(),
          path = List.to_string(path),
          not Enum.any?(installed, &String.starts_with?(path, &1)),
          arg <- ["-pa", path],
          do: arg

    {output, status} =
      System.cmd(elixir, code_paths ++ [script, exe, cases_file, out_file], stderr_to_stdout: true)

    assert status == 0, "second BEAM failed: #{String.slice(output, 0, 500)}"
    out_file |> File.read!() |> :erlang.binary_to_term()
  end

  describe "replay_and_survival: replay" do
    test "20 fresh calls of each pure case return one encoded term", %{executable: exe} do
      for {name, _, _, _} = replay <- replay_cases() do
        first = run_case(exe, replay)
        encoded = :erlang.term_to_binary(first, [:deterministic])

        for call <- 2..20 do
          again = :erlang.term_to_binary(run_case(exe, replay), [:deterministic])
          assert again == encoded, "#{name}: call #{call} differs from the first"
        end
      end
    end

    test "the cases cover values and refusals of each kind", %{executable: exe} do
      outcomes = for replay <- replay_cases(), do: run_case(exe, replay)

      assert Enum.any?(outcomes, &match?({:ok, _}, &1))

      for reason <- ~w(steps call_depth value_size unlisted_name lua_error invalid_result)a do
        assert {:refused, reason} in outcomes, "no case ends in #{reason}"
      end

      # the numeric boundary cases are what they claim to be
      by_name = Map.new(replay_cases(), fn {name, _, _, _} = r -> {name, run_case(exe, r)} end)
      assert {:ok, %{value: -9_223_372_036_854_775_808}} = by_name["integer add wraps"]
      assert {:ok, %{value: -9_223_372_036_854_775_808}} = by_name["minint // -1"]
      assert {:refused, :lua_error} = by_name["integer division by zero"]
      assert {:refused, :invalid_result} = by_name["1 / 0 is nonfinite"]
      assert {:refused, :invalid_result} = by_name["0 / 0 is nonfinite"]
      assert {:ok, %{value: 4}} = by_name["sparse length of a constructor"]
      assert {:refused, :steps} = by_name["steps: boundary - 1"]
      assert {:ok, %{value: 55}} = by_name["steps: boundary"]
      assert {:ok, %{value: 63}} = by_name["call_depth: boundary"]
      assert {:refused, :call_depth} = by_name["call_depth: boundary + 1"]
    end

    test "two fresh BEAM processes return the same encoded terms", %{
      executable: exe,
      directory: directory
    } do
      cases = replay_cases()
      parent = for {name, _, _, _} = c <- cases, do: {name, run_case(exe, c)}

      tasks =
        for label <- ["a", "b"] do
          Task.async(fn -> other_beam!(exe, cases, directory, label) end)
        end

      [first, second] = Task.await_many(tasks, 120_000)

      assert length(first) == length(cases)

      assert :erlang.term_to_binary(first, [:deterministic]) ==
               :erlang.term_to_binary(second, [:deterministic])

      for {{name, mine}, {name, theirs}} <- Enum.zip(parent, first) do
        assert :erlang.term_to_binary(mine, [:deterministic]) ==
                 :erlang.term_to_binary(theirs, [:deterministic]),
               "#{name}: this process and a fresh BEAM disagree"
      end
    end

    test "memory and wall-time stops are recorded separately, not compared", %{
      executable: exe,
      directory: directory
    } do
      hosts = host_cases()

      cases = for {name, source, input, limits, _} <- hosts, do: {name, source, input, limits}

      recorded =
        for {name, source, input, limits, expected} <- hosts do
          {name, expected, Helper.run(exe, source, input, limits)}
        end

      beam = other_beam!(exe, cases, directory, "host")

      for {{name, expected, mine}, {name, theirs}} <- Enum.zip(recorded, beam) do
        # each is a host outcome of its kind in every process; the term is not a replay decision
        assert mine == expected, name
        assert theirs == expected, name
        assert match?({:host_outcome, _}, mine)
      end
    end
  end

  describe "replay_and_survival: changed identity" do
    test "another policy identity is policy_mismatch in Elixir, before any process" do
      good = Helper.request(@valid)
      mismatch = %{good | policy: "policy-v1:sha256:" <> String.duplicate("0", 64)}
      assert LuaSandbox.run("/nonexistent/executable", mismatch) == {:refused, :policy_mismatch}

      # a changed descriptor is a changed identity
      %{descriptor: descriptor, identity: identity} = LuaSandbox.policy()
      changed = put_in(descriptor, ["helpers"], tl(descriptor["helpers"]))
      refute LuaSandbox.Descriptor.identity(changed) == identity
    end

    test "the host itself refuses another policy before it creates a Lua state", %{executable: exe} do
      limits = fn memory ->
        %{
          "steps" => 1000,
          "call_depth" => 8,
          "value_bytes" => 1000,
          "memory_bytes" => memory,
          "wall_ms" => 500
        }
      end

      frame = fn policy, source, memory ->
        Helper.frame(
          Jason.encode!(%{
            "source" => source,
            "input" => nil,
            "policy" => policy,
            "limits" => limits.(memory)
          })
        )
      end

      identity = LuaSandbox.policy().identity
      other = "policy-v1:sha256:" <> String.duplicate("f", 64)
      mismatch = %{"status" => "refused", "reason" => "policy_mismatch"}

      for policy <- [
            other,
            "",
            "x",
            identity <> "0",
            String.slice(identity, 0..-2//1),
            String.upcase(identity)
          ] do
        # a loop that would end in `steps`, and a memory limit of 1 that would end in `memory`:
        # the answer is neither, because no state is created and no source is read
        {output, 0} =
          Helper.raw_exchange(
            exe,
            frame.(policy, "return function() while true do end end", 1_000_000)
          )

        assert Helper.decode_frame!(output) == mismatch, inspect(policy)
        {output, 0} = Helper.raw_exchange(exe, frame.(policy, "return function() return 1 end", 1))
        assert Helper.decode_frame!(output) == mismatch, inspect(policy)
      end

      # the same requests under the right policy reach the state
      {output, 0} = Helper.raw_exchange(exe, frame.(identity, "return function() return 1 end", 1))
      assert Helper.decode_frame!(output) == %{"status" => "memory"}

      {output, 0} =
        Helper.raw_exchange(
          exe,
          frame.(identity, "return function() while true do end end", 1_000_000)
        )

      assert Helper.decode_frame!(output) == %{"status" => "refused", "reason" => "steps"}

      # a host reply of policy_mismatch is a refusal of the caller too
      path =
        Helper.fake!(
          Helper.tmp_dir!("mismatch"),
          "mismatch-host",
          Helper.printf(Helper.frame(Jason.encode!(mismatch)))
        )

      assert LuaSandbox.run(path, Helper.request(@valid)) == {:refused, :policy_mismatch}
    end

    test "two builds of the same bytes have equal runtime identity maps", %{
      executable: exe,
      directory: directory
    } do
      {second, second_directory} = Helper.build!("group6-second")
      assert second != exe

      {:ok, %{runtime: first_runtime, identity: first_identity}} = Helper.run(exe, @valid)
      {:ok, %{runtime: second_runtime, identity: second_identity}} = Helper.run(second, @valid)

      assert first_runtime == second_runtime
      assert first_identity == second_identity
      assert first_runtime == Build.runtime_identity()

      assert Map.keys(first_runtime) |> Enum.sort() ==
               ~w(build_options host_sha256 lua_release seed upstream_revision)a

      # the host SHA-256 is that of the C source that the build copied
      copied = File.read!(Path.join(directory, "lua_sandbox_host.c"))
      assert File.read!(Path.join(second_directory, "lua_sandbox_host.c")) == copied
      assert first_runtime.host_sha256 == Base.encode16(:crypto.hash(:sha256, copied), case: :lower)
      assert first_runtime.upstream_revision =~ ~r/\A[0-9a-f]{40}\z/
      assert first_runtime.seed == "0x4c5a5eed"
      assert first_runtime.build_options =~ "-Dluai_makeseed(L)=0x4c5a5eedu"
      assert first_runtime.build_options =~ "-Dl_randomizePivot()=0u"
      assert first_runtime.lua_release == "Lua 5.4.9"
    end
  end

  # one valid call must work after each adverse case
  defp assert_survived(exe, label) do
    assert Process.alive?(self())
    assert Helper.pids(exe) == [], "#{label}: a child of the executable is still alive"
    assert {:ok, %{value: 42}} = Helper.run(exe, @valid), "#{label}: the next valid call failed"
    assert Helper.pids(exe) == []
  end

  describe "replay_and_survival: survival" do
    test "after each adverse case the child is reaped and the next call works", %{
      executable: exe,
      directory: directory
    } do
      unique = Helper.unique_exe!(exe, directory, "survival")

      adverse = [
        {"steps loop", fun("while true do end"), nil, %{}},
        {"call_depth recursion",
         "local function f() return 1 + f() end return function() return f() end", nil, %{}},
        {"rep bomb", fun("return #string.rep('x', 100000000)"), nil, %{}},
        {"doubling bomb", fun("local s = 'x' for i = 1, 40 do s = s .. s end return 1"), nil, %{}},
        {"pack bomb", fun("return string.pack('c1000000000', 'a')"), nil, %{}},
        {"concat bomb",
         fun("local t = {} for i = 1, 60000 do t[i] = 'abcdefghij' end return #table.concat(t)"),
         nil, %{}},
        {"memory loop", fun("local t = {} for i = 1, 100000 do t[i] = {} end return 1"), nil,
         %{memory_bytes: 300_000}},
        {"memory below the baseline", @valid, nil, %{memory_bytes: 1}},
        {"value_bytes below initialization", @valid, nil, %{value_bytes: 3}},
        {"steps 1", @valid, nil, %{steps: 1}},
        {"unlisted name", fun("return os"), nil, %{}},
        {"unlisted method", fun("return ('x'):nope()"), nil, %{}},
        {"xpcall", fun("return xpcall(print, print)"), nil, %{}},
        {"coroutine", fun("return coroutine.wrap(print)"), nil, %{}},
        {"stop under nested pcall",
         fun("pcall(function() pcall(function() while true do end end) end) return 1"), nil, %{}},
        {"stop under a hundred catches",
         fun("for i = 1, 100 do pcall(string.rep, 'x', 1e9) end return 1"), nil, %{}},
        {"parse failure", "return function(", nil, %{}},
        {"parser nesting",
         "return " <> String.duplicate("(", 300) <> "1" <> String.duplicate(")", 300), nil, %{}},
        {"constant over the cap",
         "return function() return '" <> String.duplicate("a", 2000) <> "' end", nil,
         %{value_bytes: 1000}},
        {"memory while loading",
         "local a = {" <> String.duplicate("1,", 20_000) <> "} return function() return 1 end", nil,
         %{memory_bytes: 100_000}},
        {"runtime error", fun("error('boom')"), nil, %{}},
        {"error with a table", fun("error({})"), nil, %{}},
        {"result that is a function", fun("return type"), nil, %{}},
        {"result nonfinite", fun("return 1 / 0"), nil, %{}},
        {"result cycle", fun("local t = {} t[1] = t return t"), nil, %{}},
        {"no function", "return 1", nil, %{}},
        {"tostring of a table", fun("return tostring({})"), nil, %{}},
        {"format %p", fun("return string.format('%p', {})"), nil, %{}},
        {"input too deep", "return function(x) return x end",
         Enum.reduce(1..33, [], fn _, acc -> [acc] end), %{}},
        {"input over the cap", "return function(x) return x end", String.duplicate("a", 100),
         %{value_bytes: 50}},
        {"input that is a pid", "return function(x) return x end", self(), %{}}
      ]

      for {label, source, input, limits} <- adverse do
        result = Helper.run(unique, source, input, limits)

        assert match?({:refused, _}, result) or match?({:host_outcome, _}, result),
               "#{label}: #{inspect(result)}"

        assert_survived(unique, label)
      end
    end

    test "a wall-time stop: the observed child pid is gone after run returns", %{
      executable: exe,
      directory: directory
    } do
      unique = Helper.unique_exe!(exe, directory, "survival-wall")
      source = fun("return string.find(string.rep('a', 20000), 'a*a*a*a*a*b')")

      task = Task.async(fn -> Helper.run(unique, source, nil, %{wall_ms: 300}) end)
      pid = Helper.wait_for_pid(unique)
      refute Helper.gone?(pid)

      assert Task.await(task, 10_000) == {:host_outcome, :wall_time}
      assert Helper.gone?(pid)
      assert_survived(unique, "wall time")
    end

    test "a crashing, malformed or silent child leaves no process and the next call works", %{
      executable: exe,
      directory: directory
    } do
      fake_dir = Helper.tmp_dir!("survival-fakes")

      bodies = [
        {"exit 3", "exit 3"},
        {"killed", "kill -KILL $$"},
        {"segfault", "kill -SEGV $$"},
        {"empty exit", "exit 0"},
        {"zero length", Helper.printf(<<0, 0, 0, 0>>) <> "\nexec sleep 30"},
        {"overbound length", Helper.printf(<<255, 255, 255, 255>>) <> "\nexec sleep 30"},
        {"partial header", Helper.printf(<<7, 0>>) <> "\nexec sleep 30"},
        {"stderr text", "echo PRIVATE-MARKER >&2\nexit 0"},
        {"stops itself", "kill -STOP $$"},
        {"sleeps", "exec sleep 30"}
      ]

      unique = Helper.unique_exe!(exe, directory, "survival-valid")

      for {label, body} <- bodies do
        path = Helper.fake!(fake_dir, "fake-#{System.unique_integer([:positive])}", body)
        result = LuaSandbox.run(path, Helper.request(@valid, nil, %{wall_ms: 300}))
        assert match?({:host_outcome, _}, result), "#{label}: #{inspect(result)}"
        assert Helper.pids(path) == [], "#{label}: a child is still alive"
        assert_survived(unique, label)
      end
    end
  end

  describe "replay_and_survival: caller death" do
    test "a killed caller leaves no live child after wall_ms plus a margin", %{
      executable: exe,
      directory: directory
    } do
      unique = Helper.unique_exe!(exe, directory, "caller-death")
      source = fun("return string.find(string.rep('a', 20000), 'a*a*a*a*a*b')")
      wall_ms = 600
      margin = 1_500
      test_pid = self()

      caller =
        spawn(fn ->
          result = Helper.run(unique, source, nil, %{wall_ms: wall_ms})
          send(test_pid, {:caller_finished, result})
        end)

      pid = Helper.wait_for_pid(unique)
      refute Helper.gone?(pid)

      killed_at = System.monotonic_time(:millisecond)
      Process.exit(caller, :kill)
      refute_receive {:caller_finished, _}, 50

      # the child is not left to run: it ends by itself within its own deadline
      wait_until_gone(unique, killed_at + wall_ms + 250 + margin)
      assert Helper.gone?(pid)
      assert Helper.pids(unique) == []
      assert System.monotonic_time(:millisecond) - killed_at < wall_ms + 250 + margin
      assert_survived(unique, "after caller death")
    end

    test "many killed callers leave no live child", %{executable: exe, directory: directory} do
      unique = Helper.unique_exe!(exe, directory, "caller-death-many")
      source = fun("return string.find(string.rep('a', 20000), 'a*a*a*a*a*b')")

      callers =
        for _ <- 1..4 do
          spawn(fn -> Helper.run(unique, source, nil, %{wall_ms: 500}) end)
        end

      # wait for the children to exist, then kill every caller
      Enum.find(1..300, fn _ ->
        Process.sleep(10)
        length(Helper.pids(unique)) >= 1
      end)

      started = System.monotonic_time(:millisecond)
      Enum.each(callers, &Process.exit(&1, :kill))
      wait_until_gone(unique, started + 500 + 250 + 1_500)
      assert Helper.pids(unique) == []
    end
  end

  defp wait_until_gone(path, deadline) do
    cond do
      Helper.pids(path) == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(20)
        wait_until_gone(path, deadline)
    end
  end
end
