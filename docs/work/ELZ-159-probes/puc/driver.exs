defmodule Probe do
  @host Path.expand("host", __DIR__)
  @cases Path.expand("../cases", __DIR__)
  def emit(case_name, result) do
    if String.starts_with?(case_name, "catch_") and result["continued"] == true,
      do: raise("limit continuation sentinel reached")
    if result["outcome"] == "error" do
      {:ok, hostname} = :inet.gethostname()
      text = inspect(result["detail"])
      if String.contains?(text, List.to_string(hostname)) or Regex.match?(~r{/(?:home|tmp|proc|etc)/|pid[=: ]+[0-9]+}, text),
        do: raise("error hygiene check failed")
    end
    result
    |> Map.merge(%{"candidate" => "puc-5.4.9", "case" => case_name})
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> IO.puts()
  end
  def open(mode) do
    port = Port.open({:spawn_executable, System.find_executable("prlimit")}, [
      :binary, :exit_status, :use_stdio, {:line, 2_100_000},
      {:args, ["--as=268435456", "--", @host, mode]}
    ])
    receive do
      {^port, {:data, {:eol, "{\"ready\":true}"}}} -> port
      {^port, {:exit_status, status}} -> raise("host startup exit #{status}")
    after
      2_000 ->
        {:os_pid, pid} = Port.info(port, :os_pid)
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        close(port)
        raise("host readiness timeout")
    end
  end
  def request(port, source) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    Port.command(port, <<byte_size(source)::32, source::binary>>)
    receive do
      {^port, {:data, {:eol, line}}} -> :json.decode(line)
      {^port, {:exit_status, status}} -> %{"outcome" => "error", "detail" => "host exit #{status}", "steps" => :null}
    after
      2_000 ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        close(port)
        %{"outcome" => "wall_time_exceeded", "detail" => "Port killed at 2000 ms", "steps" => :null}
    end
  end
  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
  def once(source, mode \\ "policy") do
    port = open(mode)
    result = request(port, source)
    close(port)
    Map.put(result, "beam_survived", Process.alive?(self()))
  end
  def source(name), do: File.read!(Path.join(@cases, name <> ".lua"))
  def timed(f) do
    {microseconds, result} = :timer.tc(f)
    {microseconds, result}
  end
  def stats(values) do
    sorted = Enum.sort(values)
    %{"median_us" => Enum.at(sorted, div(length(sorted), 2)), "p95_us" => Enum.at(sorted, ceil(length(sorted) * 0.95) - 1)}
  end
  def main do
    emit("bounds", %{"outcome" => "ok", "detail" => %{"steps" => 1_000_000, "memory_bytes" => 16_777_216, "depth" => 200, "value_bytes" => 1_048_576, "wall_ms" => 2000, "os_address_bytes" => 268_435_456}, "steps" => :null})
    for path <- Path.wildcard(Path.join(@cases, "*.lua")) do
      name = Path.basename(path, ".lua")
      unless name == "wall" do
        emit(name, once(File.read!(path)))
      end
    end
    emit("host_allowlist_audit", once("", "audit"))
    emit("continuation_control", once("return helper_echo('continued')"))
    emit("unlisted_nil", once(source("unlisted"), "nil"))
    for name <- ["helper", "limit_steps", "limit_depth", "limit_memory", "limit_value", "catch_pcall_steps", "catch_pcall_depth", "catch_pcall_memory", "catch_pcall_value"] do
      emit(name <> ":without_pcall", once(source(name), "no_pcall"))
    end
    emit("plain_thread:diagnostic_coroutine", once(source("plain_thread"), "coroutine"))
    emit("coroutine_hook:diagnostic_coroutine", once(source("coroutine_hook"), "coroutine"))
    emit("wall:diagnostic_blocking_helper", once(source("wall"), "block"))
    emit("catch_pcall_wall:diagnostic_blocking_helper", once("pcall(function() " <> source("wall") <> " end); return helper_echo('continued')", "block"))
    for name <- ["determinism", "determinism_pure", "limit_steps", "limit_depth", "limit_value", "limit_memory"] do
      a = once(source(name))
      b = once(source(name))
      emit(name <> ":fresh_process_comparison", %{"outcome" => "ok", "detail" => %{"equal" => a == b, "first" => a, "second" => b}, "steps" => :null})
    end
    for name <- ["cost_recipe", "cost_pure"] do
      src = source(name)
      {cold, first} = timed(fn -> once(src) end)
      port = open("policy")
      {start, initial} = timed(fn -> request(port, src) end)
      samples = for _ <- 1..200 do
        {us, result} = timed(fn -> request(port, src) end)
        if result["outcome"] != "ok", do: raise("cost request failed")
        us
      end
      close(port)
      emit(name <> ":cost", %{"outcome" => first["outcome"], "detail" => Map.merge(stats(samples), %{"runs" => 200, "fresh_process_evaluation_us" => cold, "first_request_us" => start, "first_outcome" => initial["outcome"]}), "steps" => first["steps"]})
    end
    starts = for _ <- 1..200 do
      {us, :ok} = timed(fn -> port = open("policy"); close(port) end)
      us
    end
    emit("os_process_start", %{"outcome" => "ok", "detail" => Map.put(stats(starts), "command", "prlimit exec host through readiness line; no Lua state yet; 200 runs"), "steps" => :null})
    memory = File.read!("/proc/meminfo") |> String.split("\n") |> hd() |> String.trim()
    emit("machine", %{"outcome" => "ok", "detail" => %{"cpu_count" => System.schedulers_online(), "memory" => memory}, "steps" => :null})
    emit("driver_completed", %{"outcome" => "ok", "detail" => "all cases emitted; no catch continuation; error hygiene checks passed; BEAM alive", "steps" => :null})
  end
end

Probe.main()
