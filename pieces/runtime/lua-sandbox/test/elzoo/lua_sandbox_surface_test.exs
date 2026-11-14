# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxSurfaceTest do
  @moduledoc """
  Group `exact_capability_surface`: three sources of the capability surface must agree
  with each other and with the lists of the contract.

  * (a) probes from inside the sandbox: one process per name asks `type(name)`. There is
    no `pairs` or `next`, so the names come from a fixed universe: every name of the
    upstream 5.4 libraries plus the names that this policy must not grant. A listed name
    gives its type, any other name is `{:refused, :unlisted_name}`.
  * (b) the `--audit` frame of the C host (environment, each library table, the shared
    string metatable). The audit is an argument of the executable: no request, no Lua
    name and no frame can reach it.
  * (c) the descriptor of `Elzoo.LuaSandbox.policy/0`, and fixed probes of constants.

  The expected lists below are copied from the contract (Policy version 3), not from the
  descriptor, so a change of any one source fails here.

  Negative control (recorded in the pull request, never committed): granting `print` in
  the C host makes (a), (b) and (c) disagree.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 180_000

  # The contract's lists.
  @globals ~w(ipairs select type tostring tonumber error assert pcall)
  @string ~w(byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper)
  @table ~w(concat insert move pack remove sort unpack)
  @math_functions ~w(abs acos asin atan ceil cos deg exp floor fmod log max min modf rad sin sqrt tan tointeger type ult)
  @math_constants ~w(huge maxinteger mininteger pi)
  @libraries ~w(math string table)
  @operator_metamethods ~w(__add __div __idiv __mod __mul __pow __sub __unm)
  # The helpers of policy version 3: name => type of the value (each part adds its names).
  @helpers %{
    "json_decode" => "function",
    "json_encode" => "function",
    "null" => "userdata",
    "object" => "function",
    "text_split" => "function",
    "text_trim" => "function",
    "text_utf8_len" => "function",
    "time_iso8601" => "function",
    "time_parts" => "function",
    "time_unix_ms" => "function"
  }

  # name => type of the value
  defp expected_surface do
    core_surface()
    |> Map.put("helpers", "table")
    |> Map.merge(Map.new(@helpers, fn {name, type} -> {"helpers.#{name}", type} end))
  end

  # the names of the descriptor's `names` map: the libraries and the globals of version 1
  defp core_surface do
    functions =
      @globals ++
        Enum.map(@string, &"string.#{&1}") ++
        Enum.map(@table, &"table.#{&1}") ++ Enum.map(@math_functions, &"math.#{&1}")

    Map.new(functions, &{&1, "function"})
    |> Map.merge(Map.new(@libraries, &{&1, "table"}))
    |> Map.merge(Map.new(@math_constants, &{"math.#{&1}", "number"}))
  end

  # Everything the sandbox could expose by accident or that a caller might ask for.
  @upstream_base ~w(assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs
                    pcall print rawequal rawget rawlen rawset require select setmetatable tonumber
                    tostring type warn xpcall _G _VERSION)
  @upstream_string ~w(byte char dump find format gmatch gsub len lower match pack packsize rep
                      reverse sub unpack upper)
  @upstream_table ~w(concat insert move pack remove sort unpack)
  @upstream_math ~w(abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min
                    mininteger modf pi rad random randomseed sin sqrt tan tointeger type ult)
  @upstream_libraries ~w(coroutine debug io math os package string table utf8)
  @excluded_extra ~w(loadstring json text time clock now helper_echo bindings
                     helpers.x helpers.json helpers.now helpers.__index
                     json.encode json.decode text.upper time.now os.time os.clock os.getenv os.date
                     io.open io.write io.read debug.getinfo debug.sethook package.loaded
                     package.path coroutine.create coroutine.resume coroutine.wrap coroutine.yield
                     coroutine.status utf8.char utf8.len utf8.codepoint bindings.echo
                     string.nope table.nope math.nope string.len2 table.getn math.pow math.cosh
                     math.log10 string.gfind table.foreach unpack setfenv getfenv)

  defp universe do
    Enum.uniq(
      @upstream_base ++
        Enum.map(@upstream_string, &"string.#{&1}") ++
        Enum.map(@upstream_table, &"table.#{&1}") ++
        Enum.map(@upstream_math, &"math.#{&1}") ++
        @upstream_libraries ++
        ["helpers" | Enum.map(Map.keys(@helpers), &"helpers.#{&1}")] ++ @excluded_extra
    )
  end

  setup_all do
    {executable, directory} = Helper.build!("group4")
    %{executable: executable, directory: directory}
  end

  defp type_of(exe, name) do
    case Helper.run(exe, Helper.function_source("return type(#{name})")) do
      {:ok, %{value: type}} -> type
      {:refused, :unlisted_name} -> :unlisted
      other -> {:unexpected, other}
    end
  end

  defp audit!(exe) do
    {output, 0} = System.cmd(exe, ["--audit"])
    Helper.decode_frame!(output)
  end

  describe "exact_capability_surface: three sources agree" do
    test "(a) one process for each name of the universe", %{executable: exe} do
      expected = expected_surface()

      probed =
        for name <- universe(), type = type_of(exe, name), type != :unlisted, into: %{} do
          {name, type}
        end

      assert probed == expected

      # no name of the universe gave any other outcome than a type or `unlisted_name`
      for name <- universe() do
        assert type_of(exe, name) in [:unlisted, "function", "table", "number", "userdata"], name
      end
    end

    test "(b) the audit frame of the host", %{executable: exe} do
      audit = audit!(exe)
      expected = expected_surface()

      assert audit["names"] == expected

      assert Enum.sort(Map.keys(audit)) ==
               ~w(constants environment_metatable helpers_metatable library_metatable names string_metatable)

      # the audit constants are the declared constants, as exact decimal text
      assert audit["constants"] == %{
               "math.huge" => "inf",
               "math.maxinteger" => "9223372036854775807",
               "math.mininteger" => "-9223372036854775808",
               "math.pi" => "3.1415926535897931"
             }

      # the environment and the library tables answer a missing name with the host's refusal
      assert audit["environment_metatable"] == ["__index"]
      assert audit["helpers_metatable"] == ["__index"]
      assert audit["library_metatable"] == ["__index"]

      # the one shared string metatable: the strict method lookup and the operators
      assert audit["string_metatable"] == Enum.sort(["__index" | @operator_metamethods])
    end

    test "(c) the descriptor of policy/0 and the probes of constants", %{executable: exe} do
      %{descriptor: descriptor} = LuaSandbox.policy()
      expected = expected_surface()
      core = core_surface()
      names = descriptor["names"]

      functions = for {name, "function"} <- core, do: name
      constants = for {name, "number"} <- core, do: name

      assert names["functions"] == Enum.sort(functions)
      assert names["libraries"] == @libraries
      assert Enum.sort(Map.keys(names["constants"])) == Enum.sort(constants)

      assert descriptor["helpers"] ==
               for(name <- Enum.sort(Map.keys(@helpers)), do: %{"name" => name, "version" => 1})

      assert for({"helpers." <> name, _} <- expected, do: name) |> Enum.sort() ==
               Enum.sort(Map.keys(@helpers))

      assert descriptor["bindings"] == %{
               "mechanism_version" => 1,
               "max_names" => 64,
               "max_recorded" => 256
             }

      assert descriptor["string_metatable"]["keys"] ==
               Enum.sort(["__index" | @operator_metamethods])

      # the constants as the sandbox answers them
      assert {:ok, %{value: 3.141592653589793}} =
               Helper.run(exe, Helper.function_source("return math.pi"))

      assert {:ok, %{value: 9_223_372_036_854_775_807}} =
               Helper.run(exe, Helper.function_source("return math.maxinteger"))

      assert {:ok, %{value: -9_223_372_036_854_775_808}} =
               Helper.run(exe, Helper.function_source("return math.mininteger"))

      assert {:ok, %{value: true}} =
               Helper.run(
                 exe,
                 Helper.function_source("return math.huge == 1 / 0 and -math.huge == -1 / 0")
               )

      assert {:ok, %{value: ["float", "integer", "integer", "float"]}} =
               Helper.run(
                 exe,
                 Helper.function_source(
                   "return {math.type(math.huge), math.type(math.maxinteger), math.type(math.mininteger), math.type(math.pi)}"
                 )
               )

      # a constant is a number, not a function: calling it is an error of data, not a name
      assert {:refused, :lua_error} = Helper.run(exe, Helper.function_source("return math.pi()"))

      # the three agree: the audit is the probes is the descriptor
      audit = audit!(exe)
      assert audit["names"] == expected

      assert audit["names"]
             |> Enum.filter(&match?({_, "function"}, &1))
             |> Enum.map(&elem(&1, 0))
             |> Enum.reject(&String.starts_with?(&1, "helpers."))
             |> Enum.sort() ==
               names["functions"]
    end
  end

  describe "exact_capability_surface: names outside the policy" do
    test "each excluded name refuses, as a value, as a call and in the chunk", %{executable: exe} do
      excluded =
        ~w(load loadstring dofile require package os io debug _G _ENV._G getmetatable setmetatable
           rawget rawset rawequal rawlen pairs next print collectgarbage string.dump math.random
           math.randomseed utf8 coroutine xpcall json json.encode json.decode text time os.time
           os.clock clock now helper_echo bindings)

      for name <- excluded do
        assert Helper.run(exe, Helper.function_source("return #{name}")) ==
                 {:refused, :unlisted_name},
               name

        assert Helper.run(exe, Helper.function_source("return #{name}(1)")) ==
                 {:refused, :unlisted_name},
               name

        assert Helper.run(exe, Helper.function_source("return type(#{name})")) ==
                 {:refused, :unlisted_name},
               name

        assert Helper.run(exe, "local x = #{name} return function() return 1 end") ==
                 {:refused, :unlisted_name},
               name

        assert Helper.run(exe, "return function(x) return pcall(#{name}) end", 1) ==
                 {:refused, :unlisted_name},
               name
      end
    end

    test "indexed, computed and rawless lookups of the same names", %{executable: exe} do
      for source <- [
            "return _ENV.os",
            "return _ENV['os']",
            "local e = _ENV return e.io",
            "local k = 'de' .. 'bug' return _ENV[k]",
            "return string['dump']",
            "local k = 'du' .. 'mp' return string[k]",
            "return math['random']",
            "return select(1, os)",
            "return select('#', print)",
            "return tostring(print)",
            "return tonumber(load)",
            "return {os}",
            "return {os = 1, [1] = io}",
            "return (function() return debug end)()",
            "local t = {} t[1] = package return t"
          ] do
        assert Helper.run(exe, Helper.function_source(source)) == {:refused, :unlisted_name}, source
      end
    end

    test "string methods: a listed method works and any other name refuses", %{executable: exe} do
      assert {:ok, %{value: 1}} = Helper.run(exe, Helper.function_source("return ('x'):len()"))

      assert {:ok, %{value: "function"}} =
               Helper.run(exe, Helper.function_source("return type(('x').len)"))

      assert {:ok, %{value: "XY"}} =
               Helper.run(exe, Helper.function_source("return ('xy'):upper()"))

      assert {:ok, %{value: "ab"}} =
               Helper.run(exe, Helper.function_source("local s = 'a' return s:rep(1) .. 'b'"))

      for method <- ~w(dump nope xpcall load rawget metatable format2 getmetatable) do
        assert Helper.run(exe, Helper.function_source("return ('x'):#{method}()")) ==
                 {:refused, :unlisted_name},
               method

        assert Helper.run(exe, Helper.function_source("return ('x').#{method}")) ==
                 {:refused, :unlisted_name},
               method
      end

      # a method of a result of a method
      assert Helper.run(exe, Helper.function_source("return ('x'):upper():rep(2):nope()")) ==
               {:refused, :unlisted_name}

      # the `__index` of every other value type is not a capability either
      assert {:refused, :lua_error} = Helper.run(exe, Helper.function_source("return (1).len"))
      assert {:refused, :lua_error} = Helper.run(exe, Helper.function_source("return (true).len"))
      assert {:refused, :lua_error} = Helper.run(exe, Helper.function_source("return (nil).len"))
    end

    test "a missing field of each library table", %{executable: exe} do
      for library <- @libraries, field <- ~w(nope dump random getn len2 __index __metatable) do
        source = Helper.function_source("return #{library}.#{field}")
        result = Helper.run(exe, source)
        # a listed name is a value; anything else is the refusal
        listed? = Map.has_key?(expected_surface(), "#{library}.#{field}")

        assert if(listed?,
                 do: match?({:ok, _}, result) or match?({:refused, :invalid_result}, result),
                 else: result == {:refused, :unlisted_name}
               ),
               source
      end

      # a library table cannot gain a field that then looks like a capability
      assert {:ok, %{value: 5}} =
               Helper.run(exe, Helper.function_source("string.mine = 5 return string.mine"))

      # and its metatable is not reachable from Lua
      assert Helper.run(exe, Helper.function_source("return getmetatable(string)")) ==
               {:refused, :unlisted_name}
    end

    test "indirect use: an iterator, a method, select and type results", %{executable: exe} do
      # `ipairs` returns an iterator; it works and it grants no name
      assert {:ok, %{value: [1, 10]}} =
               Helper.run(
                 exe,
                 Helper.function_source(
                   "local f, s, i = ipairs({10, 20}) local k, v = f(s, i) return {k, v}"
                 )
               )

      assert {:ok, %{value: 30}} =
               Helper.run(
                 exe,
                 Helper.function_source(
                   "local n = 0 for _, v in ipairs({10, 20}) do n = n + v end return n"
                 )
               )

      assert {:ok, %{value: "function"}} =
               Helper.run(exe, Helper.function_source("local f = ipairs({}) return type(f)"))

      assert {:refused, :lua_error} =
               Helper.run(exe, Helper.function_source("local f = ipairs({}) return f.dump"))

      assert {:refused, :lua_error} =
               Helper.run(
                 exe,
                 Helper.function_source("local f = string.gmatch('a', '.') return f.nope")
               )

      # a name through a value: the type name is a string, and strings only have the listed methods
      assert {:ok, %{value: "NUMBER"}} =
               Helper.run(exe, Helper.function_source("return type(1):upper()"))

      assert Helper.run(exe, Helper.function_source("return type(1):dump()")) ==
               {:refused, :unlisted_name}

      assert Helper.run(exe, Helper.function_source("return type(string).nope")) ==
               {:refused, :unlisted_name}

      # `select` returns what it is given: the table of a library has no new field
      assert Helper.run(exe, Helper.function_source("return select(1, string).dump")) ==
               {:refused, :unlisted_name}

      assert Helper.run(exe, Helper.function_source("return (select(2, 1, table)).getn")) ==
               {:refused, :unlisted_name}

      assert {:ok, %{value: 2}} =
               Helper.run(exe, Helper.function_source("return select('#', 1, 2)"))

      # a function value cannot be used to find the environment
      assert Helper.run(exe, Helper.function_source("return (string.len).x")) ==
               {:refused, :lua_error}

      assert Helper.run(exe, Helper.function_source("return #pcall")) == {:refused, :lua_error}
    end

    test "missing fields of user data are data nil, not a capability lookup", %{executable: exe} do
      assert {:ok, %{value: nil}} =
               Helper.run(exe, Helper.function_source("local t = {} return t.x"))

      assert {:ok, %{value: nil}} =
               Helper.run(exe, Helper.function_source("local t = {a = 1} return t.b"))

      assert {:ok, %{value: nil}} =
               Helper.run(exe, Helper.function_source("local t = {{}} return t[1].k"))

      assert {:ok, %{value: nil}} = Helper.run(exe, Helper.function_source("return ({}).os"))

      assert {:ok, %{value: nil}} =
               Helper.run(exe, "return function(x) return x.os end", %{"a" => 1})

      assert {:ok, %{value: 1}} =
               Helper.run(exe, "return function(x) return x.os end", %{"os" => 1})

      # going one deeper into nil is an error of data
      assert {:refused, :lua_error} =
               Helper.run(exe, Helper.function_source("local t = {} return t.x.y"))
    end

    test "no diagnostic entry point is reachable through a request", %{executable: exe} do
      # the audit is an argument of the executable; a request cannot select it
      good = %{
        "source" => "return function() return 1 end",
        "input" => nil,
        "policy" => LuaSandbox.policy().identity,
        "limits" => Map.new(Helper.default_limits(), fn {k, v} -> {Atom.to_string(k), v} end),
        "calls" => %{"mode" => "none", "names" => [], "recorded" => []}
      }

      {output, 0} = Helper.raw_exchange(exe, Helper.frame(Jason.encode!(good)))
      assert %{"status" => "ok", "value" => 1} = Helper.decode_frame!(output)

      for extra <- [%{"audit" => true}, %{"mode" => "audit"}, %{"--audit" => 1}] do
        {output, 0} = Helper.raw_exchange(exe, Helper.frame(Jason.encode!(Map.merge(good, extra))))

        assert Helper.decode_frame!(output) == %{
                 "status" => "refused",
                 "reason" => "invalid_request"
               }
      end

      # an argument other than --audit is a host failure with no output, never an audit
      {output, status} = Helper.raw_exchange(exe, <<>>, ["--audit2"])
      assert output == <<>>
      assert status != 0
    end
  end

  describe "exact_capability_surface: identity is never exposed" do
    test "tostring of a table or a function is a lua_error, never an address", %{executable: exe} do
      for source <- [
            "return tostring({})",
            "return tostring(function() end)",
            "return tostring(string.len)",
            "return tostring(string)",
            "return tostring(ipairs({}))",
            "return tostring(math.huge)",
            "return tostring(-math.huge)",
            "return tostring(0 / 0)"
          ] do
        assert Helper.run(exe, Helper.function_source(source)) == {:refused, :lua_error}, source
      end
    end

    test "tostring of a scalar is the same text in fresh processes", %{executable: exe} do
      cases = [
        {"1", "1"},
        {"-1", "-1"},
        {"1.5", "1.5"},
        {"-0.0", "-0.0"},
        {"1e15", "1e+15"},
        {"2^53", "9.007199254741e+15"},
        {"100 / 2", "50.0"},
        {"0.1", "0.1"},
        {"math.maxinteger", "9223372036854775807"},
        {"true", "true"},
        {"false", "false"},
        {"nil", "nil"},
        {"'s'", "s"},
        {"''", ""}
      ]

      for {expression, text} <- cases do
        source = Helper.function_source("return tostring(#{expression})")
        results = for _ <- 1..3, do: Helper.run(exe, source)
        assert results |> Enum.uniq() |> length() == 1, expression
        assert {:ok, %{value: ^text}} = hd(results), expression
      end
    end

    test "string.format refuses %p and every non-scalar %s or %q", %{executable: exe} do
      for source <- [
            "return string.format('%p', {})",
            "return string.format('%p', function() end)",
            "return string.format('%p', 1)",
            "return string.format('%p', 'x')",
            "return string.format('%s', {})",
            "return string.format('%s', function() end)",
            "return string.format('%s', string.len)",
            "return string.format('%s', string)",
            "return string.format('%q', {})",
            "return string.format('%q', function() end)",
            "return string.format('a%%%s', {})",
            "return string.format('%d %s', 1, {})",
            "return ('%s'):format({})",
            "return ('%p'):format({})"
          ] do
        assert Helper.run(exe, Helper.function_source(source)) == {:refused, :lua_error}, source
      end

      # scalar conversions stay
      assert {:ok, %{value: "1 x nil true 2.5"}} =
               Helper.run(
                 exe,
                 Helper.function_source(
                   "return string.format('%s %s %s %s %s', 1, 'x', nil, true, 2.5)"
                 )
               )

      assert {:ok, %{value: "\"a\""}} =
               Helper.run(exe, Helper.function_source("return string.format('%q', 'a')"))

      assert {:ok, %{value: "5%"}} =
               Helper.run(exe, Helper.function_source("return string.format('%d%%', 5)"))
    end

    test "other conversions that could print a table or function are errors of data", %{
      executable: exe
    } do
      for source <- [
            "return {} .. ''",
            "return 'x' .. function() end",
            "return string.format('%d', {})",
            "return string.rep({}, 2)",
            "return table.concat({{}})",
            "return table.concat({function() end})",
            "return string.upper({})",
            "return error({})",
            "return assert(false, {})",
            "return tonumber({})"
          ] do
        result = Helper.run(exe, Helper.function_source(source))

        assert result in [
                 {:refused, :lua_error},
                 {:ok,
                  %{
                    value: nil,
                    identity: LuaSandbox.policy().identity,
                    runtime: LuaSandbox.Build.runtime_identity()
                  }}
               ],
               source
      end
    end
  end

  describe "exact_capability_surface: host-side probes of an input" do
    test "functions, pids, references, tuples, ports and other atoms never start a process" do
      missing = "/nonexistent/lua-sandbox-executable"
      port = Port.open({:spawn_executable, System.find_executable("cat")}, [])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      for input <- [
            fn -> 1 end,
            &Kernel.+/2,
            self(),
            make_ref(),
            {:a, 1},
            {},
            port,
            :atom,
            :nilx,
            [self()],
            %{"k" => make_ref()},
            %{"k" => [fn -> 1 end]},
            [[{1, 2}]],
            %{"k" => :ok}
          ] do
        request = Helper.request("return function(x) return 1 end", input)
        # a nonexistent executable would be `process_exit`: the refusal comes first
        assert LuaSandbox.run(missing, request) == {:refused, :invalid_request}, inspect(input)
      end

      # nil, true and false are the only atoms of plain data
      for input <- [nil, true, false] do
        request = Helper.request("return function(x) return 1 end", input)
        assert LuaSandbox.run(missing, request) == {:host_outcome, :process_exit}
      end
    end

    test "the accepted atoms and a thread, userdata or function never come back from Lua", %{
      executable: exe
    } do
      assert {:ok, %{value: [nil, true, false]}} = Helper.identity_function(exe, [nil, true, false])

      for body <- [
            "return print",
            "return os",
            "return string.len",
            "return ipairs",
            "return select"
          ] do
        result = Helper.run(exe, "return function() #{body} end")
        assert result == {:refused, :unlisted_name} or result == {:refused, :invalid_result}, body
      end

      assert {:refused, :invalid_result} =
               Helper.run(exe, Helper.function_source("return string.len"))

      assert {:refused, :invalid_result} =
               Helper.run(exe, Helper.function_source("return {string.len}"))

      assert {:refused, :invalid_result} =
               Helper.run(exe, Helper.function_source("return {a = type}"))
    end
  end
end
