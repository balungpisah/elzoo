defmodule LuerlFit do
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
  @heap %{
    size: div(16_777_216, :erlang.system_info(:wordsize)),
    kill: true,
    error_logger: false,
    include_shared_binaries: System.get_env("LUERL_FIT_SHARED_BINARIES", "true") == "true"
  }

  def selected?(name) do
    case System.get_env("LUERL_FIT_CASE") do
      "list" ->
        IO.puts(name)
        false

      "costs" ->
        name in ["cost_recipe:cost", "cost_pure:cost"]

      nil ->
        true

      selected ->
        selected == name
    end
  end

  defmacrop emit(name, result) do
    quote do
      if LuerlFit.selected?(unquote(name)),
        do: LuerlFit.write(unquote(name), unquote(result))
    end
  end

  def write(name, result) do
    result
    |> Map.merge(%{"candidate" => "luerl-1.5.1", "case" => name})
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> IO.puts()
  end

  def source(name), do: File.read!(Path.join(@cases, name <> ".lua"))

  defp get(state, path) do
    {:ok, value, _} = :luerl.get_table_keys(path, state)
    value
  end

  def environment(mode, owner, tag) do
    full = :luerl.init()

    if mode == :public_g_swap do
      {env, state} = :luerl.encode([], full)
      {:ok, state} = :luerl.set_table_keys(["_G"], env, state)
      state
    else
      if mode == :default do
        :luerl_sandbox.init(full)
      else
        {entries, state} =
          Enum.map_reduce(@libraries, full, fn {name, allowed}, state ->
            original = get(full, [name])

            fields =
              :luerl_fit_host.pairs(original, full) |> Enum.filter(fn {k, _} -> k in allowed end)

            {ref, state} = :luerl.encode([], state)

            state =
              Enum.reduce(fields, state, fn {k, v}, state ->
                {:ok, state} = :luerl.set_table_key(ref, k, v, state)
                state
              end)

            {{name, ref}, state}
          end)

        {env, state} = :luerl.encode([], state)

        names =
          @globals ++
            if(mode in [:diagnostic, :wall], do: ["pcall", "xpcall", "coroutine"], else: [])

        globals = for name <- names, value = get(full, [name]), value != nil, do: {name, value}

        helper = fn args, state ->
          value = List.first(args)
          send(owner, {tag, :runner, self()})

          if value == "reductions",
            do:
              send(owner, {tag, :sampled_reductions, elem(Process.info(self(), :reductions), 1)})

          if value == "continued", do: send(owner, {tag, :continued})
          if value == "block" and mode == :wall, do: Process.sleep(10_000)
          {[value], state}
        end

        {helper, state} = :luerl.encode(helper, state)

        state =
          Enum.reduce(
            entries ++ globals ++ [{"helper_echo", helper}, {"_ENV", env}],
            state,
            fn {k, v}, state ->
              {:ok, state} = :luerl.set_table_key(env, k, v, state)
              state
            end
          )

        string = entries |> Map.new() |> Map.fetch!("string")
        {mt, state} = :luerl_heap.alloc_table([{"__index", string}], state)

        state =
          if mode == nil do
            state
          else
            index = fn [_table, key], state ->
              :erlang.error({:lua_error, {:error_call, ["unlisted name: " <> key]}, state})
            end

            {index, state} = :luerl.encode(index, state)
            {env_mt, state} = :luerl_heap.alloc_table([{"__index", index}], state)
            :luerl_heap.set_metatable(env, env_mt, state)
          end

        :luerl_fit_host.replace_environment(env, mt, state)
      end
    end
  end

  defp plain(value, state, depth \\ 0, seen \\ MapSet.new()) do
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

          :luerl_fit_host.pairs(ref, state)
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

          Map.new(:luerl_fit_host.pairs(ref, state), fn {k, v} ->
            {to_string(k), names(v, state, seen)}
          end)
        end

      _ ->
        :luerl_fit_host.type(value)
    end
  end

  defp audit(state) do
    env = :luerl_fit_host.global(state)

    %{
      "environment" => names(env, state),
      "environment_metatable" => names(:luerl_heap.get_metatable(env, state), state),
      "shared_metatables" =>
        Map.new(:luerl_fit_host.metatables(state), fn {k, v} -> {k, names(v, state)} end)
    }
  end

  defp sanitize(text) do
    {:ok, host} = :inet.gethostname()

    text
    |> String.replace(List.to_string(host), "<host>")
    |> String.replace(~r{/(?:home|tmp|Users)/[^\s\)\]:]+}, "<scratch>")
    |> String.replace(~r/#PID<[^>]+>/, "<process>")
  end

  defp result({:ok, values, state}) do
    %{"outcome" => "ok", "detail" => plain(List.first(values), state), "steps" => :null}
  end

  defp result({:error, {:reductions, count}}),
    do: %{
      "outcome" => "steps_exceeded",
      "detail" => "host BEAM reductions poll killed runner (not runtime steps)",
      "steps" => :null,
      "reductions" => count
    }

  defp result({:error, :timeout}),
    do: %{
      "outcome" => "wall_time_exceeded",
      "detail" => "luerl_sandbox timeout",
      "steps" => :null
    }

  defp result({:lua_error, reason, _state}) do
    message = :luerl_lib.format_error(reason) |> IO.iodata_to_binary() |> sanitize()

    %{
      "outcome" =>
        if(String.contains?(message, "unlisted name:"), do: "unlisted_name", else: "error"),
      "detail" => message,
      "steps" => :null
    }
  end

  defp result({:error, reason}) when is_atom(reason),
    do: %{
      "outcome" => "error",
      "detail" => "package system error: " <> Atom.to_string(reason),
      "steps" => :null
    }

  defp result({:error, _}),
    do: %{"outcome" => "error", "detail" => "package error (raw term omitted)", "steps" => :null}

  defp result({:error, _, _}),
    do: %{"outcome" => "error", "detail" => "compile error", "steps" => :null}

  defp evaluation(source, mode, owner, tag, audit?) do
    Process.flag(:trap_exit, true)
    Process.flag(:max_heap_size, @heap)

    try do
      state = environment(mode, owner, tag)

      state =
        if mode == :trace do
          :luerl.set_trace_func(
            fn event, state ->
              count = Process.get(:fit_trace_events, 0) + 1
              Process.put(:fit_trace_events, count)
              if count <= 20, do: send(owner, {tag, :trace, elem(event, 0)})
              state
            end,
            state
          )
        else
          state
        end

      if audit? do
        %{"outcome" => "ok", "detail" => audit(state), "steps" => :null}
      else
        :luerl_sandbox.run(
          source,
          [
            {:max_reductions, 1_000_000},
            {:max_time, 2_000},
            {:spawn_opts, [:link, {:max_heap_size, @heap}]}
          ],
          state
        )
        |> result()
      end
    rescue
      _ ->
        %{
          "outcome" => "error",
          "detail" => "probe host exception",
          "host_exception" => true,
          "steps" => :null
        }
    catch
      {:refusal, reason} ->
        %{
          "outcome" =>
            if(reason in ["depth_exceeded", "value_size_exceeded"], do: reason, else: "error"),
          "detail" => reason,
          "steps" => :null
        }
    end
  end

  defp telemetry(
         tag,
         acc \\ %{
           "continued" => false,
           "trace_events" => [],
           "runners" => [],
           "sampled_reductions" => :null
         }
       ) do
    receive do
      {^tag, :continued} ->
        telemetry(tag, %{acc | "continued" => true})

      {^tag, :runner, pid} ->
        telemetry(tag, Map.update!(acc, "runners", &[pid | &1]))

      {^tag, :trace, event} ->
        telemetry(tag, Map.update!(acc, "trace_events", &[Atom.to_string(event) | &1]))

      {^tag, :sampled_reductions, count} ->
        telemetry(tag, Map.put(acc, "sampled_reductions", count))
    after
      0 -> acc
    end
  end

  def once(source, mode \\ :policy, audit? \\ false) do
    tag = make_ref()
    owner = self()

    task =
      Task.Supervisor.async_nolink(LuerlFit.Supervisor, fn ->
        evaluation(source, mode, owner, tag, audit?)
      end)

    result =
      case Task.yield(task, 2_000) do
        {:ok, value} ->
          value

        {:exit, :killed} ->
          %{
            "outcome" => "memory_exceeded",
            "detail" => "host controller max_heap_size GC-time kill",
            "steps" => :null
          }

        {:exit, _} ->
          %{"outcome" => "error", "detail" => "controller exit", "steps" => :null}

        nil ->
          killed? =
            case Process.info(task.pid, :messages) do
              {:messages, messages} -> Enum.any?(messages, &match?({:EXIT, _, :killed}, &1))
              _ -> false
            end

          Task.shutdown(task, :brutal_kill)

          %{
            "outcome" => if(killed?, do: "memory_exceeded", else: "wall_time_exceeded"),
            "detail" =>
              if(killed?,
                do: "host runner max_heap_size GC-time kill",
                else: "host Task killed at 2000 ms (linked runner too)"
              ),
            "steps" => :null
          }
      end

    info = telemetry(tag)
    alive = info["runners"] |> Enum.uniq() |> Enum.count(&Process.alive?/1)

    result
    |> Map.merge(Map.drop(info, ["runners"]))
    |> Map.put("observed_runners_alive", alive)
    |> Map.put("beam_survived", true)
  end

  def main do
    {:ok, _} = Task.Supervisor.start_link(name: LuerlFit.Supervisor)
    {start, result} = :timer.tc(fn -> once("return 42") end)
    emit("first_evaluation", Map.put(result, "elapsed_us", start))

    emit("bounds", %{
      "outcome" => "ok",
      "steps" => :null,
      "detail" => %{
        "native_step_depth_value_limits" => false,
        "host_reductions_target" => 1_000_000,
        "heap_target_bytes" => 16_777_216,
        "result_bytes" => @bytes,
        "result_depth" => 200,
        "wall_ms" => 2000
      }
    })

    for path <- Path.wildcard(Path.join(@cases, "*.lua")) do
      emit(Path.basename(path, ".lua"), once(File.read!(path)))
    end

    for mode <- [:policy, :diagnostic, :default],
        do: emit("host_audit:#{mode}", once("", mode, true))

    emit("lua_version:default", once("return _VERSION", :default))
    emit("public_G_swap", once("return {type(io),type(_G.io)}", :public_g_swap))

    emit(
      "recursive_sugar:default",
      once(
        "local function f(n) if n==0 then return 0 end; return 1+f(n-1) end; return f(250)",
        :default
      )
    )

    emit(
      "enumeration:explicit_local",
      once(
        String.replace(source("enumeration"), "local function walk", "local walk; walk=function")
      )
    )

    emit(
      "enumeration:default_explicit_local_via_G",
      once(
        source("enumeration")
        |> String.replace("_ENV", "_G")
        |> String.replace("local function walk", "local walk; walk=function"),
        :default
      )
    )

    emit("unlisted:nil", once(source("unlisted"), nil))

    for name <- ~w(fixed_names determinism pcall_empty pcall_nested_empty coroutine_hook),
        do: emit(name <> ":diagnostic", once(source(name), :diagnostic))

    for name <- ~w(enumeration fixed_names string_methods),
        do: emit(name <> ":default", once(source(name), :default))

    for name <- ~w(enumeration fixed_names),
        do:
          emit(
            name <> ":default_via_G",
            once(String.replace(source(name), "_ENV", "_G"), :default)
          )

    for catcher <- ~w(pcall xpcall resume wrap), limit <- ~w(steps depth memory value) do
      name = "catch_#{catcher}_#{limit}"
      emit(name <> ":diagnostic", once(source(name), :diagnostic))
    end

    emit("wall:diagnostic_blocking_helper", once(source("wall"), :wall))

    emit(
      "catch_pcall_wall:diagnostic_blocking_helper",
      once("pcall(function() " <> source("wall") <> " end); return 'continued'", :wall)
    )

    emit("empty_loop:trace", once(source("limit_steps"), :trace))

    emit(
      "native_depth_250",
      once("local f; f=function(n) if n==0 then return 0 end; return 1+f(n-1) end; return f(250)")
    )

    emit(
      "native_value_2m",
      once("local s=string.rep('x',2097152); helper_echo('continued'); return #s")
    )

    emit("returned_value_2m", once("return string.rep('x',2097152)"))
    emit("limit_value:default_binary_accounting", once(source("limit_value")))
    emit("limit_value:shared_binary_accounting", once(source("limit_value")))
    explicit_depth = "local f; f=function(n) return 1+f(n+1) end; return f(0)"
    emit("limit_depth:explicit_local", once(explicit_depth))

    emit(
      "catch_pcall_depth:explicit_local",
      once(
        "pcall(function() " <> explicit_depth <> " end); return helper_echo('continued')",
        :diagnostic
      )
    )

    for {name, src} <- [
          {"traversal",
           "local t={a=1,z=2,[2]=3,[7]=4,[false]=5}; local p={}; for k,v in pairs(t) do p[#p+1]=tostring(k)..'='..v end; local n={}; local k=nil; repeat k=next(t,k); if k~=nil then n[#n+1]=tostring(k) end until k==nil; return {pairs=table.concat(p,','),next=table.concat(n,',')}"},
          {"identities", "return {object=tostring({}),func=tostring(function() end)}"},
          {"holes", "return \#{[1]=1,[3]=3,[8]=8}"},
          {"numbers",
           "return {tostring(1e15),tostring(2^53),tostring(1/3),tostring(3/2),tostring(7//2),type(math.maxinteger)}"},
          {"integer_overflow", "return math.maxinteger+1"},
          {"patterns",
           "return {format=string.format('%.17g',1/3),gsub=string.gsub('a12b34','%d+','X'),find={string.find('a12b','(%d+)')}}"},
          {"errors",
           "local out={}; for _,f in ipairs({function() return 1+{} end,function() return ('x'):sub({}) end,function() error('fixed') end}) do local ok,e=pcall(f); out[#out+1]=e end; return out"}
        ] do
      emit("determinism_component:" <> name, once(src, :diagnostic))
    end

    emit(
      "reduction_poll_short_overshoot",
      once("local x=0; for i=1,50000 do x=x+i end; helper_echo('reductions'); return x")
    )

    for i <- 1..3, do: emit("limit_steps:repeat:#{i}", once(source("limit_steps")))

    for name <- ~w(determinism_pure determinism) do
      mode = if name == "determinism", do: :diagnostic, else: :policy
      a = once(source(name), mode)
      b = once(source(name), mode)

      emit(name <> ":repeat", %{
        "outcome" => "ok",
        "steps" => :null,
        "detail" => %{"equal" => a == b, "first" => a, "second" => b}
      })
    end

    for name <- ~w(cost_recipe cost_pure), selected?(name <> ":cost") do
      src = source(name)
      {first, _} = :timer.tc(fn -> once(src) end)

      times =
        for _ <- 1..200 do
          {us, r} = :timer.tc(fn -> once(src) end)
          if r["outcome"] != "ok", do: raise("cost request failed")
          us
        end
        |> Enum.sort()

      emit(name <> ":cost", %{
        "outcome" => "ok",
        "steps" => :null,
        "detail" => %{
          "runs" => 200,
          "median_us" => Enum.at(times, 100),
          "p95_us" => Enum.at(times, 189),
          "first_evaluation_us" => first
        }
      })
    end

    emit("driver_completed", %{
      "outcome" => "ok",
      "detail" => "all shared cases emitted; BEAM alive",
      "steps" => :null
    })
  end
end

if System.get_env("LUERL_FIT_LIBRARY_ONLY") != "1", do: LuerlFit.main()
