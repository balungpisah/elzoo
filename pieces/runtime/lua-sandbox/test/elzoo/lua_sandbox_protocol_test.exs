# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxProtocolTest do
  @moduledoc """
  Group `plain_data_and_protocol`, plus one smoke test for each other mechanism.

  Outcome chosen for a budget below what initialization needs, per limit:

    * `steps`: initialization runs no Lua instruction, so there is no budget below it;
      the minimum 1 is tested: a chunk needs two counted instructions, `{:refused, :steps}`.
    * `call_depth`: likewise no budget below initialization; the minimum 1 runs a chunk
      plus one function call, and a nested Lua call is `{:refused, :call_depth}`.
    * `value_bytes`: loading any source creates the four-byte name `_ENV`, so a limit
      below 4 is `{:refused, :value_size}` before user code runs; 4 works.
    * `memory_bytes`: below the state baseline the outcome is `{:host_outcome, :memory}`
      and no user code runs.
    * `wall_ms`: the minimum 1 is `{:host_outcome, :wall_time}` when the deadline
      passes before the reply, otherwise an ordinary result; both leave no child.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elzoo.LuaSandbox

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000
  @identity "return function(x) return x end"

  setup_all do
    {executable, directory} = Helper.build!("group5")
    %{executable: executable, directory: directory}
  end

  describe "plain data round trips" do
    test "every scalar type", %{executable: exe} do
      scalars = [
        nil,
        true,
        false,
        0,
        -1,
        42,
        Helper.default_limits().steps,
        9_223_372_036_854_775_807,
        -9_223_372_036_854_775_808,
        0.0,
        -0.0,
        1.5,
        -2.25,
        3.0,
        1.0e22,
        1.0e-7,
        5.0e-324,
        1.7976931348623157e308,
        0.1,
        "",
        "plain",
        "héllo ✓ 𝄞",
        "quote \" slash \\ tab \t newline \n nul \0 bell \a",
        "\u007f \u0001"
      ]

      for value <- scalars do
        assert {:ok, %{value: back}} = Helper.identity_function(exe, value)
        assert back === value, "round trip of #{inspect(value)} returned #{inspect(back)}"
      end
    end

    test "empty array and empty object stay distinct, and containers nest", %{executable: exe} do
      assert {:ok, %{value: []}} = Helper.identity_function(exe, [])
      assert {:ok, %{value: %{}}} = Helper.identity_function(exe, %{})

      input = %{
        "empty_list" => [],
        "empty_map" => %{},
        "list" => [1, [2, [3]], %{"k" => nil}],
        "z" => "last"
      }

      assert {:ok, %{value: ^input}} = Helper.identity_function(exe, input)

      assert {:ok, %{value: %{"b" => 2, "a" => 1}}} =
               Helper.run(exe, "return function() return {b = 2, a = 1} end")

      assert {:ok, %{value: [1, 2, 3]}} = Helper.run(exe, "return function() return {1, 2, 3} end")
      assert {:ok, %{value: []}} = Helper.run(exe, "return function() return {} end")
    end

    test "null is one sentinel that compares equal and cannot be printed", %{executable: exe} do
      assert {:ok, %{value: [false, "userdata"]}} =
               Helper.run(exe, "return function(x) return {x == nil, type(x)} end", nil)

      assert {:ok, %{value: true}} =
               Helper.run(exe, "return function(l) return l[1] == l[2] end", [nil, nil])

      assert {:ok, %{value: [nil, 1]}} =
               Helper.run(exe, "return function(l) return {l[1], 1} end", [nil, 2])

      assert {:refused, :lua_error} =
               Helper.run(exe, "return function(x) return tostring(x) end", nil)

      assert {:refused, :lua_error} = Helper.run(exe, "return function(x) return x.field end", nil)
      assert {:ok, %{value: nil}} = Helper.run(exe, "return function() return nil end")
    end

    test "depth 32 passes and depth 33 refuses", %{executable: exe} do
      # `deep.(n)` holds n containers
      deep = fn n -> Enum.reduce(2..n, [], fn _, acc -> [acc] end) end
      assert {:ok, %{value: value}} = Helper.identity_function(exe, deep.(32))
      assert value == deep.(32)
      assert {:refused, :invalid_request} = Helper.identity_function(exe, deep.(33))

      # decoded containers nest as the same bound allows on the Lua side
      assert {:ok, %{value: _}} =
               Helper.run(
                 exe,
                 "return function() local t = {} for _ = 1, 31 do t = {t} end return t end"
               )

      assert {:refused, :invalid_result} =
               Helper.run(
                 exe,
                 "return function() local t = {} for _ = 1, 32 do t = {t} end return t end"
               )

      deep_map = Enum.reduce(2..32, %{}, fn _, acc -> %{"k" => acc} end)
      assert {:ok, %{value: ^deep_map}} = Helper.identity_function(exe, deep_map)
      assert {:refused, :invalid_request} = Helper.identity_function(exe, %{"k" => deep_map})
    end

    test "byte limits at the cap and cap + 1", %{executable: exe} do
      # `"` plus `"` make the encoding two bytes longer than the string
      limits = %{value_bytes: 100}

      assert {:ok, %{value: at_cap}} =
               Helper.identity_function(exe, String.duplicate("a", 98), limits)

      assert byte_size(at_cap) == 98

      assert {:refused, :value_size} =
               Helper.identity_function(exe, String.duplicate("a", 99), limits)

      assert {:refused, :value_size} =
               Helper.identity_function(exe, String.duplicate("a", 1_000), limits)

      # an encoded container at and over the cap: 48 ones and a last member of 2 or 3 digits
      at_cap_list = List.duplicate(1, 48) ++ [10]
      over_list = List.duplicate(1, 48) ++ [100]
      assert byte_size(Jason.encode!(at_cap_list)) == 100
      assert {:ok, %{value: ^at_cap_list}} = Helper.identity_function(exe, at_cap_list, limits)
      assert {:refused, :value_size} = Helper.identity_function(exe, over_list, limits)

      # results use the same measure
      assert {:ok, %{value: ok}} =
               Helper.run(exe, "return function() return string.rep('a', 98) end", nil, limits)

      assert byte_size(ok) == 98

      assert {:refused, :value_size} =
               Helper.run(exe, "return function() return string.rep('a', 99) end", nil, limits)

      assert {:refused, :value_size} =
               Helper.run(exe, "return function() return string.rep('a', 100) end", nil, limits)

      build = "local t = {} for i = 1, 48 do t[i] = 1 end t[49] = "

      assert {:ok, %{value: ^at_cap_list}} =
               Helper.run(exe, "return function() #{build}10 return t end", nil, limits)

      assert {:refused, :value_size} =
               Helper.run(exe, "return function() #{build}100 return t end", nil, limits)

      # the largest configured value
      big = String.duplicate("x", 65_534)
      assert {:ok, %{value: ^big}} = Helper.identity_function(exe, big)
      assert {:refused, :value_size} = Helper.identity_function(exe, big <> "x")
    end

    test "results that are not plain data refuse", %{executable: exe} do
      for body <- [
            "local t = {} t[1] = t return t",
            "local t = {} t.self = t return t",
            "local a, b = {}, {} a.x = b b.x = a return a",
            "return function() end",
            "return type",
            "return {1, nil, 3}",
            "return {[1] = 1, [3] = 3}",
            "return {1, a = 2}",
            "return {[1.5] = 1}",
            "return {[true] = 1}",
            "return {[{}] = 1}",
            "return {[0] = 1}",
            "return {[-1] = 1}",
            "return math.huge",
            "return -math.huge",
            "return 0 / 0",
            "return {math.huge}",
            "return {a = 0 / 0}",
            "return string.char(255)",
            "return \"\\xC3\\x28\"",
            "return {k = string.char(255)}"
          ] do
        assert Helper.run(exe, "return function() #{body} end") == {:refused, :invalid_result}, body
      end
    end

    test "chunks that do not return exactly one function refuse", %{executable: exe} do
      for source <- [
            "",
            "return",
            "return 1",
            "return nil",
            "return 1, function() end",
            "return function() end, 2",
            "local x = 1"
          ] do
        assert Helper.run(exe, source) == {:refused, :invalid_result}, source
      end

      assert {:refused, :invalid_result} = Helper.run(exe, "return function() return end")
      assert {:refused, :invalid_result} = Helper.run(exe, "return function() return 1, 2 end")
      assert {:refused, :lua_error} = Helper.run(exe, "return (")
      assert {:refused, :lua_error} = Helper.run(exe, "error('boom')")
      assert {:refused, :lua_error} = Helper.run(exe, "return function() error({}) end")
      # never bytecode
      assert {:refused, :lua_error} = Helper.run(exe, "\x1bLua")
    end

    test "inputs that are not plain data are an invalid request", %{executable: exe} do
      for input <- [
            :atom,
            {:tuple},
            self(),
            make_ref(),
            fn -> 1 end,
            <<255, 254>>,
            %{atom: 1},
            %{1 => 1},
            %{<<255>> => 1},
            9_223_372_036_854_775_808,
            -9_223_372_036_854_775_809,
            [1 | 2],
            [<<255>>],
            %URI{}
          ] do
        assert Helper.identity_function(exe, input) == {:refused, :invalid_request}, inspect(input)
      end
    end

    test "request shape and policy are checked before any process starts" do
      missing = "/nonexistent/lua-sandbox-executable"
      good = Helper.request(@identity)
      mismatch = %{good | policy: "policy-v1:sha256:" <> String.duplicate("0", 64)}
      assert LuaSandbox.run(missing, mismatch) == {:refused, :policy_mismatch}
      assert LuaSandbox.run(missing, %{good | policy: "other"}) == {:refused, :policy_mismatch}
      assert LuaSandbox.run(missing, %{good | policy: 1}) == {:refused, :invalid_request}

      for bad <- [
            %{},
            Map.delete(good, :input),
            Map.delete(good, :calls),
            Map.put(good, :extra, 1),
            Map.put(good, "source", "x"),
            %{good | source: 1},
            %{good | source: <<255>>},
            %{good | source: String.duplicate("a", 65_537)},
            %{good | limits: Map.delete(good.limits, :steps)},
            %{good | limits: Map.put(good.limits, :extra, 1)},
            %{good | limits: %{good.limits | steps: 0}},
            %{good | limits: %{good.limits | steps: -1}},
            %{good | limits: %{good.limits | steps: 1_000_001}},
            %{good | limits: %{good.limits | call_depth: 65}},
            %{good | limits: %{good.limits | value_bytes: 65_537}},
            %{good | limits: %{good.limits | memory_bytes: 16_777_217}},
            %{good | limits: %{good.limits | wall_ms: 1_001}},
            %{good | limits: %{good.limits | wall_ms: 1.0}},
            %{good | limits: []},
            [],
            nil
          ] do
        assert LuaSandbox.run(missing, bad) == {:refused, :invalid_request}, inspect(bad, limit: 5)
      end

      # an unreachable executable is a host outcome, not a crash
      assert LuaSandbox.run(missing, good) == {:host_outcome, :process_exit}
    end

    test "source and input never appear in a return value", %{executable: exe} do
      secret_source =
        "-- PRIVATE-SOURCE-MARKER\nreturn function(x) error('PRIVATE-ERROR-MARKER') end"

      results = [
        Helper.run(exe, secret_source, "PRIVATE-INPUT-MARKER"),
        Helper.run(exe, "return function(x) return os end", "PRIVATE-INPUT-MARKER"),
        Helper.run(
          exe,
          "return function(x) return 1, 2 end -- PRIVATE-SOURCE-MARKER",
          "PRIVATE-INPUT-MARKER"
        ),
        Helper.run(exe, "return (PRIVATE-SOURCE-MARKER", "PRIVATE-INPUT-MARKER")
      ]

      for result <- results do
        text = inspect(result)
        refute text =~ "PRIVATE-SOURCE-MARKER"
        refute text =~ "PRIVATE-INPUT-MARKER"
        refute text =~ "PRIVATE-ERROR-MARKER"
        refute text =~ exe
      end

      assert {:refused, :lua_error} = hd(results)
    end
  end

  describe "malformed frames from a fake child" do
    setup do
      %{fake: Helper.tmp_dir!("fake")}
    end

    defp reply_frame(value \\ 42), do: Helper.frame(Helper.reply(value))

    defp run_fake(dir, name, body, limits \\ %{}) do
      path = Helper.fake!(dir, name, body)
      LuaSandbox.run(path, Helper.request(@identity, 1, limits))
    end

    test "a well-formed reply passes through, for the fake as for the real host", %{fake: dir} do
      assert {:ok, %{value: 42, runtime: runtime}} =
               run_fake(dir, "good", Helper.printf(reply_frame()))

      assert runtime == LuaSandbox.Build.runtime_identity()

      other = Helper.frame(Jason.encode!(%{"status" => "refused", "reason" => "steps"}))
      assert run_fake(dir, "refused", Helper.printf(other)) == {:refused, :steps}
      memory = Helper.frame(~s({"status":"memory"}))
      assert run_fake(dir, "memory", Helper.printf(memory)) == {:host_outcome, :memory}
    end

    test "zero and overbound lengths are decided before the body", %{fake: dir} do
      zero = Helper.printf(<<0, 0, 0, 0>>) <> "\nexec sleep 5"
      started = System.monotonic_time(:millisecond)
      assert run_fake(dir, "zero", zero) == {:host_outcome, :protocol_error}

      # 1_048_577 = 0x100001, then no body; the caller does not wait for one
      overbound = Helper.printf(<<1, 0, 16, 0>>) <> "\nexec sleep 5"
      assert run_fake(dir, "overbound", overbound) == {:host_outcome, :protocol_error}
      huge = Helper.printf(<<255, 255, 255, 255>>) <> "\nexec sleep 5"
      assert run_fake(dir, "huge", huge) == {:host_outcome, :protocol_error}
      assert System.monotonic_time(:millisecond) - started < 4_000
    end

    test "partial header, partial body and EOF", %{fake: dir} do
      assert run_fake(dir, "partial-header", Helper.printf(<<7, 0>>)) ==
               {:host_outcome, :protocol_error}

      partial_body = Helper.printf(<<10, 0, 0, 0, ?{, ?", ?a>>)
      assert run_fake(dir, "partial-body", partial_body) == {:host_outcome, :protocol_error}

      # exit with nothing written: no reply
      assert run_fake(dir, "eof", "exit 0") == {:host_outcome, :process_exit}
    end

    test "invalid JSON, duplicate keys, wrong shape", %{fake: dir} do
      valid = Helper.reply(1)

      cases = [
        {"not-json", "{not json"},
        {"truncated", String.slice(valid, 0, 20)},
        {"invalid-utf8",
         ~s({"status":"refused","reason":"steps"})
         |> binary_part(0, 14)
         |> Kernel.<>(<<255>>)
         |> Kernel.<>("\"}")},
        {"array", "[1,2]"},
        {"scalar", "42"},
        {"duplicate-keys", ~s({"status":"ok","status":"ok","value":1,"runtime":{}})},
        {"duplicate-nested", String.replace(valid, ~s("value":1), ~s("value":{"a":1,"a":2}))},
        {"missing-status", ~s({"value":1})},
        {"unknown-reason", ~s({"status":"refused","reason":"no_such_reason"})},
        {"extra-key", String.replace(valid, ~s("status":"ok"), ~s("status":"ok","extra":1))},
        {"runtime-missing-key", ~s({"status":"ok","value":1,"runtime":{}})},
        {"value-not-plain-int",
         String.replace(valid, ~s("value":1), ~s("value":9223372036854775808))},
        {"value-over-bound",
         String.replace(valid, ~s("value":1), ~s("value":"#{String.duplicate("a", 70_000)}"))}
      ]

      for {name, body} <- cases do
        assert run_fake(dir, name, Helper.printf(Helper.frame(body))) ==
                 {:host_outcome, :protocol_error},
               name
      end
    end

    test "trailing bytes and a second reply", %{fake: dir} do
      frame = reply_frame()

      assert run_fake(dir, "trailing", Helper.printf(frame <> "x")) ==
               {:host_outcome, :protocol_error}

      assert run_fake(dir, "two-replies", Helper.printf(frame <> frame)) ==
               {:host_outcome, :protocol_error}

      late = Helper.printf(frame) <> "\nsleep 0.2\n" <> Helper.printf(frame)
      assert run_fake(dir, "late-second-reply", late) == {:host_outcome, :protocol_error}
    end

    test "oversize output is a protocol error", %{fake: dir} do
      # a full frame of the largest legal length that is not a reply
      body = Helper.printf(<<0, 0, 16, 0>>) <> "\nhead -c 1048576 /dev/zero | tr '\\000' 'a'"
      assert run_fake(dir, "max-frame", body) == {:host_outcome, :protocol_error}

      # more than the maximum, streamed without a pause
      streamed = "head -c 3000000 /dev/zero"
      assert run_fake(dir, "streamed", streamed) == {:host_outcome, :protocol_error}
    end

    test "a crashing child", %{fake: dir} do
      assert run_fake(dir, "exit3", "exit 3") == {:host_outcome, :process_exit}
      assert run_fake(dir, "killed", "kill -KILL $$") == {:host_outcome, :process_exit}
      assert run_fake(dir, "segv", "kill -SEGV $$") == {:host_outcome, :process_exit}

      assert run_fake(dir, "reply-then-fail", Helper.printf(reply_frame()) <> "\nexit 1") ==
               {:host_outcome, :process_exit}

      assert run_fake(dir, "partial-then-fail", Helper.printf(<<9, 0, 0, 0, ?{>>) <> "\nexit 2") ==
               {:host_outcome, :process_exit}
    end

    test "private text on stderr is in no return value and no log", %{fake: dir} do
      marker = "SYNTHETIC-PRIVATE-MARKER-7731"

      log =
        capture_log(fn ->
          results = [
            run_fake(dir, "stderr-only", "echo #{marker} >&2\nexit 0"),
            run_fake(
              dir,
              "stderr-then-reply",
              "echo #{marker} >&2\n" <> Helper.printf(reply_frame())
            ),
            run_fake(dir, "stderr-crash", "echo #{marker} >&2\nexit 9"),
            run_fake(dir, "stdout-text", "echo #{marker}")
          ]

          # stderr is merged into the byte stream, so any text breaks the framing
          assert results == List.duplicate({:host_outcome, :protocol_error}, 4)

          refute inspect(results) =~ marker
        end)

      refute log =~ marker
      refute log =~ "PRIVATE"
    end
  end

  describe "early_exit_is_a_host_outcome" do
    # A child that ends before the request is written must give a host outcome and must
    # never end the process that called `run/2`. The request is the largest one that the
    # Piece accepts, so the write cannot complete into the pipe buffer.
    @exchanges 200

    setup do
      %{dir: Helper.tmp_dir!("early-exit")}
    end

    test "the largest request is exactly the frame maximum, and one more byte is refused",
         %{executable: exe} do
      request = largest_request(0)
      assert request_body(request) |> byte_size() == Elzoo.LuaSandbox.Json.frame_max()
      assert Elzoo.LuaSandbox.Json.frame_max() == 1_048_576

      assert LuaSandbox.run(exe, largest_request(1)) == {:refused, :invalid_request}
    end

    @tag timeout: 300_000
    test "a child that exits at once never ends the caller: 200 exchanges", %{dir: dir} do
      fake = Helper.fake!(dir, "exit-at-once", "exit 0")
      request = largest_request(0)

      for _ <- 1..@exchanges do
        assert LuaSandbox.run(fake, request) == {:host_outcome, :process_exit}
        assert Process.alive?(self())
      end
    end

    @tag timeout: 300_000
    test "a child that closes its input never ends the caller and is reaped: 200 exchanges",
         %{dir: dir} do
      request = largest_request(0)

      for index <- 1..@exchanges do
        pidfile = Path.join(dir, "closed-#{index}.pid")

        fake =
          Helper.fake!(dir, "closed-#{index}", "echo $$ > #{pidfile}\nexec 0<&-\nexec sleep 30")

        assert LuaSandbox.run(fake, request) == {:host_outcome, :process_exit}
        assert Process.alive?(self())
        assert Helper.gone?(read_pid!(pidfile))
      end
    end

    @tag timeout: 300_000
    test "a child killed from outside while the request is written: 200 exchanges",
         %{dir: dir} do
      request = largest_request(0)

      for index <- 1..@exchanges do
        pidfile = Path.join(dir, "killed-#{index}.pid")
        fake = Helper.fake!(dir, "killed-#{index}", "echo $$ > #{pidfile}\nexec sleep 30")
        spawn(fn -> kill_when_started(pidfile, 5_000) end)

        assert LuaSandbox.run(fake, request) == {:host_outcome, :process_exit}
        assert Process.alive?(self())
        assert Helper.gone?(read_pid!(pidfile))
      end
    end

    # The same string-keyed map that `LuaSandbox.run/2` encodes.
    defp request_body(%{source: source, input: input, policy: policy, limits: limits, calls: calls}) do
      Elzoo.LuaSandbox.Json.encode(%{
        "source" => source,
        "input" => input,
        "policy" => policy,
        "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end),
        "calls" => %{
          "mode" => calls.mode,
          "names" => calls.names,
          "recorded" =>
            for record <- calls.recorded do
              %{
                "name" => record.name,
                "arguments" => record.arguments,
                "result" => record.result
              }
            end
        }
      })
    end

    # `extra` bytes are added to the last argument. With 0, the encoded body is exactly the
    # frame maximum: each argument stays within `value_bytes`, and the last one is tuned.
    defp largest_request(extra) do
      per_argument = Helper.default_limits().value_bytes - 2
      frame_max = Elzoo.LuaSandbox.Json.frame_max()

      count =
        Enum.find(1..256, fn count ->
          frame_max - byte_size(request_body(padded_request(List.duplicate(0, count)))) <=
            count * per_argument
        end)

      empty = byte_size(request_body(padded_request(List.duplicate(0, count))))

      {sizes, _} =
        Enum.map_reduce(1..count, frame_max - empty, fn _, rest ->
          size = min(rest, per_argument)
          {size, rest - size}
        end)

      {last, others} = List.pop_at(sizes, -1)
      padded_request(others ++ [last + extra])
    end

    defp padded_request(sizes) do
      recorded =
        for size <- sizes,
            do: %{name: "pad", arguments: String.duplicate("a", size), result: nil}

      Helper.request(@identity, 1, %{}, %{mode: "replay", names: ["pad"], recorded: recorded})
    end

    defp read_pid!(pidfile), do: pidfile |> File.read!() |> String.trim() |> String.to_integer()

    # Polls for the child's pid file, then kills the child: it never reads its input.
    defp kill_when_started(pidfile, wait_ms) do
      pid =
        with {:ok, text} <- File.read(pidfile),
             {pid, ""} <- Integer.parse(String.trim(text)) do
          pid
        else
          _ -> nil
        end

      cond do
        pid != nil ->
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        wait_ms <= 0 ->
          :gave_up

        true ->
          Process.sleep(2)
          kill_when_started(pidfile, wait_ms - 2)
      end
    end
  end

  describe "one smoke test for each other mechanism" do
    test "steps: an infinite loop", %{executable: exe} do
      assert {:refused, :steps} = Helper.run(exe, "return function() while true do end end")
      # the minimum budget: a chunk alone needs more than one counted instruction
      assert {:refused, :steps} = Helper.run(exe, "return function(x) return x end", 1, %{steps: 1})
    end

    test "call_depth: ordinary recursion", %{executable: exe} do
      source = "local function f(n) return 1 + f(n + 1) end return function() return f(1) end"
      assert {:refused, :call_depth} = Helper.run(exe, source)
      # tail calls do not accumulate depth
      tail =
        "local function f(n) if n == 0 then return 7 end return f(n - 1) end return function() return f(5000) end"

      assert {:ok, %{value: 7}} = Helper.run(exe, tail, nil, %{steps: 1_000_000, call_depth: 2})
      # the minimum depth runs a plain function; one nested call is over it
      assert {:ok, %{value: 1}} =
               Helper.run(exe, "return function() return 1 end", nil, %{call_depth: 1})

      nested = "local function g() return 1 end return function() return g() + 1 end"
      assert {:refused, :call_depth} = Helper.run(exe, nested, nil, %{call_depth: 1})
    end

    test "value_size: a string bomb ends before a large buffer", %{executable: exe} do
      assert {:refused, :value_size} =
               Helper.run(exe, "return function() return string.rep('x', 100000) end", nil, %{
                 value_bytes: 1_000
               })

      # loading any source needs a four-byte name: below that, nothing runs
      for limit <- 1..3 do
        assert {:refused, :value_size} =
                 Helper.run(exe, "return function(x) return 1 end", 0, %{value_bytes: limit})
      end

      assert {:ok, %{value: 1}} =
               Helper.run(exe, "return function(x) return 1 end", 0, %{value_bytes: 4})
    end

    test "unlisted_name: a name outside the policy", %{executable: exe} do
      assert {:refused, :unlisted_name} = Helper.run(exe, "return function() return os end")

      assert {:refused, :unlisted_name} =
               Helper.run(exe, "return function() return ('x'):nope() end")

      assert {:refused, :unlisted_name} =
               Helper.run(exe, "return function() return string.dump end")
    end

    test "sticky stop: pcall never returns a caught stop", %{executable: exe} do
      source = """
      pcall(function() while true do end end)
      return function() return 1 end
      """

      assert {:refused, :steps} = Helper.run(exe, source)

      inside = "return function() local ok = pcall(function() while true do end end) return 1 end"
      assert {:refused, :steps} = Helper.run(exe, inside)

      # a stop that does not use up the step budget must not be continued either
      assert {:refused, :unlisted_name} =
               Helper.run(exe, "pcall(function() return os end) return function() return 1 end")

      assert {:refused, :call_depth} =
               Helper.run(
                 exe,
                 "local function f() return 1 + f() end pcall(f) return function() return 1 end"
               )

      assert {:refused, :value_size} =
               Helper.run(
                 exe,
                 "pcall(string.rep, 'x', 5000) return function() return 1 end",
                 nil,
                 %{value_bytes: 100}
               )
    end

    test "memory: a table allocation loop under a small budget", %{executable: exe} do
      source = "return function() local t = {} for i = 1, 100000 do t[i] = {} end return 1 end"
      assert {:host_outcome, :memory} = Helper.run(exe, source, nil, %{memory_bytes: 200_000})
      # below the state baseline nothing runs at all
      assert {:host_outcome, :memory} = Helper.run(exe, @identity, 1, %{memory_bytes: 1})
      assert {:host_outcome, :memory} = Helper.run(exe, @identity, 1, %{memory_bytes: 5_000})
    end

    test "wall_time: a child stopped with SIGSTOP is killed and reaped" do
      dir = Helper.tmp_dir!("sigstop")
      path = Helper.fake!(dir, "stopped-child.sh", "kill -STOP $$")

      task =
        Task.async(fn -> LuaSandbox.run(path, Helper.request(@identity, 1, %{wall_ms: 400})) end)

      pid = wait_for_pid(path)
      assert File.exists?("/proc/#{pid}")

      assert Task.await(task, 10_000) == {:host_outcome, :wall_time}
      assert Helper.pids(path) == []
      refute File.exists?("/proc/#{pid}")
    end

    test "wall_ms 1 is a wall_time outcome or an ordinary result, with no child left", %{
      executable: exe,
      directory: directory
    } do
      unique = Path.join(directory, "wall-one-host")
      File.cp!(exe, unique)
      File.chmod!(unique, 0o755)
      result = LuaSandbox.run(unique, Helper.request(@identity, 1, %{wall_ms: 1}))

      assert result in [
               {:host_outcome, :wall_time},
               {:ok,
                %{
                  value: 1,
                  identity: LuaSandbox.policy().identity,
                  runtime: LuaSandbox.Build.runtime_identity()
                }}
             ]

      assert Helper.pids(unique) == []
    end
  end

  defp wait_for_pid(path, attempts \\ 200) do
    case Helper.pids(path) do
      [pid | _] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(10)
        wait_for_pid(path, attempts - 1)

      [] ->
        flunk("the stopped child never appeared")
    end
  end
end
