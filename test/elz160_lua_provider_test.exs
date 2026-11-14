# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Elz160LuaProviderTest do
  use ExUnit.Case, async: false

  @revision "312b9efaa1061c2c4cad08554dbc1351c3270eef"
  @sources ~w(lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject
    lopcodes lparser lstate lstring ltable ltm lundump lvm lzio lauxlib lbaselib
    lcorolib ldblib liolib lmathlib loadlib loslib lstrlib ltablib lutf8lib linit)
  @moduletag timeout: 125_000

  setup do
    source = Mix.Project.deps_paths()[:lua_source]
    %{source: source, deadline: System.monotonic_time(:millisecond) + 120_000}
  end

  test "pinned_source_and_license", %{source: source, deadline: deadline} do
    assert run("git", ["-C", source, "rev-parse", "HEAD"], deadline) == @revision <> "\n"
    header = File.read!(Path.join(source, "lua.h"))
    assert header =~ "Permission is hereby granted, free of charge"
    assert header =~ "THE SOFTWARE IS PROVIDED"
    assert header =~ ~s(#define LUA_VERSION_RELEASE\t"9")
    lock = Mix.Dep.Lock.read()
    assert {:git, "https://github.com/lua/lua.git", @revision, _} = lock.lua_source
    provider = Jason.decode!(File.read!("registry/providers.json"))["providers"]["lua_source"]
    assert provider["revision"] == @revision
    assert provider["url"] == "https://github.com/lua/lua.git"
    assert provider["license"] == "MIT"
  end

  test "static_library_and_port_success", context do
    host = build(context)

    assert run(host, ["return 42"], context.deadline) ==
             "Lua 5.4.9\nok 1 results\ninteger 42\n"

    IO.puts("ELZ-160: Lua 5.4.9 static archive and Port integer 42 passed")
  end

  test "empty_and_failed_chunk", context do
    host = build(context)

    for {chunk, outcome} <- [
          {"", "ok 0 results"},
          {"return (", "load_error"},
          {"error('probe')", "call_error"}
        ] do
      assert run(host, [chunk], context.deadline) == "Lua 5.4.9\n#{outcome}\n"
    end
  end

  defp build(%{source: source, deadline: deadline}) do
    directory = Path.join(System.tmp_dir!(), "elz160-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    flags = ["-std=gnu99", "-O2", "-Wall", "-Wextra", "-DLUA_USE_LINUX", "-I", source]

    objects =
      for name <- @sources do
        object = Path.join(directory, name <> ".o")
        run("cc", flags ++ ["-c", Path.join(source, name <> ".c"), "-o", object], deadline)
        object
      end

    archive = Path.join(directory, "liblua.a")
    run("ar", ["rcs", archive | objects], deadline)
    host = Path.join(directory, "lua_host")

    run(
      "cc",
      flags ++
        [
          "-Werror",
          Path.expand("support/elz160_lua_provider_host.c", __DIR__),
          archive,
          "-lm",
          "-ldl",
          "-o",
          host
        ],
      deadline
    )

    IO.puts(
      "ELZ-160 build: cc -std=gnu99 -O2 -Wall -Wextra -DLUA_USE_LINUX -I SOURCE -c SOURCE/NAME.c -o BUILD/NAME.o; ar rcs BUILD/liblua.a OBJECTS; cc FLAGS -Werror test/support/elz160_lua_provider_host.c BUILD/liblua.a -lm -ldl -o BUILD/lua_host"
    )

    host
  end

  defp run(command, args, deadline) do
    executable = System.find_executable(command)
    assert executable, "required tool unavailable: #{command}"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      collect(port, "", deadline)
    after
      if Port.info(port) do
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          1_000 -> if Port.info(port), do: Port.close(port)
        end
      end
    end
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, output <> bytes, deadline)

      {^port, {:exit_status, status}} ->
        assert status == 0, output
        output
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("Lua provider build/run exceeded 120 seconds")
    end
  end
end
