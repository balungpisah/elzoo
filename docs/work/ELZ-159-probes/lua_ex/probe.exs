defmodule LuaFit do
  alias Lua.VM.{State, Table, Value}
  @cases Path.expand("../cases", __DIR__)
  @libraries %{
    "string" =>
      ~w(byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper),
    "table" => ~w(concat insert move pack remove sort unpack),
    "math" =>
      ~w(abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger modf pi rad sin sqrt tan tointeger type ult)
  }
  @globals ~w(pairs ipairs next select type tostring tonumber error assert)
  @bytes 1_048_576

  def emit(name, result) do
    result
    |> Map.merge(%{"candidate" => "lua-1.0.2", "case" => name})
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> IO.puts()
  end

  def environment(mode) do
    full =
      Lua.new(
        sandboxed: [],
        max_instructions: 1_000_000,
        max_call_depth: 200,
        max_string_bytes: @bytes
      )

    if mode == :default do
      Lua.new(max_instructions: 1_000_000, max_call_depth: 200, max_string_bytes: @bytes)
    else
      state = %{
        State.new()
        | max_instructions: full.state.max_instructions,
          max_call_depth: full.state.max_call_depth,
          max_string_bytes: full.state.max_string_bytes
      }

      state =
        Enum.reduce(@libraries, state, fn {name, allowed}, state ->
          original =
            full.state
            |> State.get_global(name)
            |> then(&State.get_table(full.state, &1))
            |> Table.to_map()

          {ref, state} = State.alloc_table(state, Map.take(original, allowed))
          state = State.set_global(state, name, ref)

          if name == "string" do
            {mt, state} = State.alloc_table(state, %{"__index" => ref})
            %{state | metatables: %{"string" => mt}}
          else
            state
          end
        end)

      allowed =
        @globals ++
          if(mode in [:pcall, :xpcall, :wall], do: ["pcall"], else: []) ++
          if(mode == :xpcall, do: ["xpcall"], else: [])

      state =
        Enum.reduce(allowed, state, fn name, state ->
          State.set_global(state, name, State.get_global(full.state, name))
        end)

      helper =
        {:native_func,
         fn args, state ->
           value = List.first(args)
           if value == "continued", do: Process.put(:continued, true)
           if mode == :wall and value == "block", do: Process.sleep(10_000)
           {[value], state}
         end}

      state = State.set_global(state, "helper_echo", helper)

      state =
        if mode == nil do
          state
        else
          index =
            {:native_func,
             fn [_table, key], state ->
               raise Lua.VM.RuntimeError,
                 value: "unlisted name: " <> Value.to_string(key),
                 state: state
             end}

          {mt, state} = State.alloc_table(state, %{"__index" => index})
          State.update_table(state, State.g_ref(state), &%{&1 | metatable: mt})
        end

      %{full | state: state}
    end
  end

  defp plain(value, state, depth \\ 0, seen \\ MapSet.new()) do
    value = Lua.unwrap(value)
    if depth > 200, do: throw({:refusal, "depth_exceeded"})

    result =
      case value do
        nil ->
          :null

        v when is_binary(v) or is_number(v) or is_boolean(v) ->
          v

        {:tref, _} = ref ->
          if MapSet.member?(seen, ref), do: throw({:refusal, "cyclic_value"})
          seen = MapSet.put(seen, ref)

          state
          |> State.get_table(ref)
          |> Table.to_map()
          |> Enum.map(fn {k, v} ->
            [plain(k, state, depth + 1, seen), plain(v, state, depth + 1, seen)]
          end)
          |> Enum.sort_by(&IO.iodata_to_binary(:json.encode(&1)))

        _ ->
          throw({:refusal, "non_plain_value"})
      end

    if IO.iodata_length(:json.encode(result)) > @bytes,
      do: throw({:refusal, "value_size_exceeded"})

    result
  end

  defp names(value, state, seen \\ MapSet.new()) do
    case value do
      {:tref, _} = ref ->
        if MapSet.member?(seen, ref) do
          "<cycle>"
        else
          seen = MapSet.put(seen, ref)

          state
          |> State.get_table(ref)
          |> Table.to_map()
          |> Map.new(fn {k, v} -> {Value.to_string(k), names(v, state, seen)} end)
        end

      _ ->
        Value.type_name(value)
    end
  end

  defp audit(lua) do
    state = lua.state
    env = State.g_ref(state)
    mt = State.get_table(state, env).metatable

    %{
      "environment" => names(env, state),
      "environment_metatable" => names(mt, state),
      "shared_metatables" =>
        Map.new(state.metatables, fn {name, ref} -> {name, names(ref, state)} end)
    }
  end

  defp classify(message) do
    cond do
      String.contains?(message, "instruction budget exceeded") -> "steps_exceeded"
      String.contains?(message, "stack overflow") -> "depth_exceeded"
      String.contains?(message, "resulting string too large") -> "value_size_exceeded"
      String.contains?(message, "unlisted name:") -> "unlisted_name"
      true -> "error"
    end
  end

  defp sanitize(text) do
    {:ok, hostname} = :inet.gethostname()

    text
    |> String.replace(List.to_string(hostname), "<host>")
    |> String.replace(~r{/(?:home|tmp)/[^\s\)\]:]+}, "<scratch>")
    |> String.replace(~r/#PID<[^>]+>/, "<process>")
  end

  defp evaluation(source, mode, audit?) do
    Process.put(:continued, false)

    try do
      lua = environment(mode)

      if audit? do
        %{"outcome" => "ok", "detail" => audit(lua), "steps" => :null}
      else
        {values, lua} = Lua.eval!(lua, source, decode: false, source: "probe")

        %{
          "outcome" => "ok",
          "detail" => plain(List.first(values), lua.state),
          "steps" => lua.state.instruction_count
        }
      end
    rescue
      e ->
        message = e |> Exception.message() |> sanitize()

        steps =
          case Map.get(e, :original) do
            %{value: "instruction budget exceeded", state: %State{instruction_count: count}} ->
              count

            _ ->
              :null
          end

        %{"outcome" => classify(message), "detail" => message, "steps" => steps}
    catch
      {:refusal, reason} ->
        %{
          "outcome" =>
            if(reason in ["depth_exceeded", "value_size_exceeded"], do: reason, else: "error"),
          "detail" => reason,
          "steps" => :null
        }
    end
    |> Map.put("continued", Process.get(:continued))
  end

  def once(source, mode \\ :policy, audit? \\ false) do
    task =
      Task.Supervisor.async_nolink(LuaFit.Supervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: div(16_777_216, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        evaluation(source, mode, audit?)
      end)

    result =
      case Task.yield(task, 2_000) do
        {:ok, result} ->
          result

        {:exit, :killed} ->
          %{
            "outcome" => "memory_exceeded",
            "detail" => "host max_heap_size GC-time kill (16 MiB target)",
            "steps" => :null
          }

        {:exit, _} ->
          %{"outcome" => "error", "detail" => "worker exit", "steps" => :null}

        nil ->
          Task.shutdown(task, :brutal_kill)

          %{
            "outcome" => "wall_time_exceeded",
            "detail" => "host Task killed at 2000 ms",
            "steps" => :null
          }
      end

    Map.put(result, "beam_survived", Process.alive?(self()))
  end

  def source(name), do: File.read!(Path.join(@cases, name <> ".lua"))

  def main do
    {:ok, _} = Task.Supervisor.start_link(name: LuaFit.Supervisor)
    {start, result} = :timer.tc(fn -> once("return 42") end)
    emit("first_evaluation", Map.put(result, "elapsed_us", start))

    emit("bounds", %{
      "outcome" => "ok",
      "steps" => :null,
      "detail" => %{
        "steps" => 1_000_000,
        "depth" => 200,
        "string_bytes" => @bytes,
        "result_bytes" => @bytes,
        "heap_target_bytes" => 16_777_216,
        "wall_ms" => 2000,
        "memory_is_host_outcome" => true
      }
    })

    for path <- Path.wildcard(Path.join(@cases, "*.lua")) do
      name = Path.basename(path, ".lua")
      emit(name, once(File.read!(path)))
    end

    emit("host_allowlist_audit", once("", :policy, true))
    emit("host_allowlist_audit:with_pcall", once("", :pcall, true))
    emit("host_default_blocklist_audit", once("", :default, true))
    emit("lua_version:default", once("return _VERSION", :default))
    emit("blocked_loader:default", once("return load('return 1')", :default))
    emit("unlisted:nil", once(source("unlisted"), nil))

    for name <- ["fixed_names", "determinism", "plain_function", "plain_nested_function"] do
      emit(name <> ":with_pcall", once(source(name), :pcall))
    end

    for catcher <- [:pcall, :xpcall], limit <- ~w(steps depth value memory) do
      name = "catch_#{catcher}_#{limit}"
      emit(name <> ":diagnostic", once(source(name), catcher))
      body = source("limit_" <> limit)

      call =
        if catcher == :pcall,
          do: "pcall(function() #{body} end)",
          else: "xpcall(function() #{body} end,function(e) return e end)"

      emit(
        name <> ":diagnostic_literal_return",
        once("local ok,e=#{call}; return {'continued',ok,e}", catcher)
      )
    end

    emit("wall:diagnostic_blocking_helper", once(source("wall"), :wall))

    emit(
      "catch_pcall_wall:diagnostic_blocking_helper",
      once("pcall(function() " <> source("wall") <> " end); return 'continued'", :wall)
    )

    emit("default_blocklist:enumeration", once(source("enumeration"), :default))
    emit("default_blocklist:fixed_names", once(source("fixed_names"), :default))

    for {name, src} <- [
          {"table_concat",
           "local s=string.rep('x',1024); local t={}; for i=1,2048 do t[i]=s end; return #table.concat(t)"},
          {"string_gsub", "return #(string.gsub(string.rep('x',2048),'.',string.rep('y',1024)))"},
          {"string_format",
           "local s=string.rep('x',1024); local t={}; for i=1,2048 do t[i]=s end; return #string.format(string.rep('%s',2048),table.unpack(t))"},
          {"string_pack", "return #string.pack('c2097152','')"}
        ] do
      emit("value_bypass:" <> name, once(src))
    end

    for name <- ~w(determinism determinism_pure limit_steps limit_depth limit_value limit_memory) do
      mode = if name == "determinism", do: :pcall, else: :policy
      a = once(source(name), mode)
      b = once(source(name), mode)

      emit(name <> ":repeat", %{
        "outcome" => "ok",
        "steps" => :null,
        "detail" => %{"equal" => a == b, "first" => a, "second" => b}
      })
    end

    for name <- ~w(cost_recipe cost_pure) do
      src = source(name)
      {first, result} = :timer.tc(fn -> once(src) end)

      times =
        for _ <- 1..200 do
          {us, result} = :timer.tc(fn -> once(src) end)
          if result["outcome"] != "ok", do: raise("cost request failed")
          us
        end
        |> Enum.sort()

      emit(name <> ":cost", %{
        "outcome" => result["outcome"],
        "steps" => result["steps"],
        "detail" => %{
          "runs" => 200,
          "median_us" => Enum.at(times, 100),
          "p95_us" => Enum.at(times, 189),
          "first_evaluation_us" => first
        }
      })
    end

    emit("machine", %{
      "outcome" => "ok",
      "steps" => :null,
      "detail" => %{
        "schedulers_online" => System.schedulers_online(),
        "logical_processors_available" => :erlang.system_info(:logical_processors_available),
        "memory" => File.read!("/proc/meminfo") |> String.split("\n") |> hd() |> String.trim()
      }
    })

    emit("driver_completed", %{
      "outcome" => "ok",
      "steps" => :null,
      "detail" => "all cases emitted; BEAM alive"
    })
  end
end

LuaFit.main()
