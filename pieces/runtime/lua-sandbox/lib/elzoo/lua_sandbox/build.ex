# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox.Build do
  @moduledoc false
  # Fresh native build: verify the exact upstream bytes, compile each library
  # source with the explicit recipe, archive them, compile the owned host.
  # Argument lists only: no shell, no expansion, no build helper.

  alias Elzoo.LuaSandbox.{Descriptor, SourceIdentity}

  @host_path Path.join([__DIR__, "native", "lua_sandbox_host.c"])
  @external_resource @host_path
  @host_source File.read!(@host_path)
  @host_sha256 Base.encode16(:crypto.hash(:sha256, @host_source), case: :lower)

  @seed "0x4c5a5eed"
  @library_flags [
    "-std=gnu99",
    "-O2",
    "-Wall",
    "-Wextra",
    "-DLUA_USE_LINUX",
    "-Dluai_makeseed(L)=#{@seed}u",
    "-Dl_randomizePivot()=0u"
  ]
  @scrub ~w(CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH COMPILER_PATH GCC_EXEC_PREFIX)

  # Computed from the descriptor module (no dependency on the public module).
  def policy_identity, do: Descriptor.identity(Descriptor.descriptor())

  def host_sha256, do: @host_sha256
  def seed, do: @seed
  def build_options, do: Enum.join(@library_flags, " ")

  @doc "Runtime identity the host reports for a successful run."
  def runtime_identity do
    %{
      build_options: build_options(),
      host_sha256: @host_sha256,
      lua_release: SourceIdentity.release(),
      seed: @seed,
      upstream_revision: SourceIdentity.revision()
    }
  end

  def build(source_directory, build_directory)
      when is_binary(source_directory) and is_binary(build_directory) do
    do_build(Path.expand(source_directory), Path.expand(build_directory))
  rescue
    _ -> {:error, :build_failed}
  catch
    _, _ -> {:error, :build_failed}
  end

  def build(_, _), do: {:error, :build_failed}

  defp do_build(source, build) do
    with cc when is_binary(cc) <- System.find_executable("cc"),
         ar when is_binary(ar) <- System.find_executable("ar"),
         false <- source == build or String.starts_with?(build, source <> "/"),
         true <- SourceIdentity.verify(source),
         :ok <- File.mkdir_p(build),
         host_c = Path.join(build, "lua_sandbox_host.c"),
         archive = Path.join(build, "liblua.a"),
         executable = Path.join(build, "lua_sandbox_host"),
         _ = File.rm(archive),
         _ = File.rm(executable),
         :ok <- File.write(host_c, @host_source),
         {:ok, objects} <- compile_library(cc, source, build),
         :ok <- run(ar, ["rcs", archive | objects]),
         :ok <- compile_host(cc, source, host_c, archive, executable) do
      {:ok, executable}
    else
      _ -> {:error, :build_failed}
    end
  end

  defp compile_library(cc, source, build) do
    flags = @library_flags ++ ["-I", source]

    outcomes =
      SourceIdentity.library_names()
      |> Task.async_stream(
        fn name ->
          object = Path.join(build, name <> ".o")

          case run(cc, flags ++ ["-c", Path.join(source, name <> ".c"), "-o", object]) do
            :ok -> {:ok, object}
            :error -> :error
          end
        end,
        max_concurrency: min(4, System.schedulers_online()),
        timeout: 180_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, {:ok, object}} -> {:ok, object}
        _ -> :error
      end)

    if Enum.all?(outcomes, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(outcomes, &elem(&1, 1))}
    else
      :error
    end
  end

  defp compile_host(cc, source, host_c, archive, executable) do
    defines = [
      ~s(-DELZ_LUA_RELEASE="#{SourceIdentity.release()}"),
      ~s(-DELZ_LUA_REVISION="#{SourceIdentity.revision()}"),
      ~s(-DELZ_HOST_SHA256="#{@host_sha256}"),
      ~s(-DELZ_BUILD_OPTIONS="#{build_options()}"),
      ~s(-DELZ_SEED="#{@seed}"),
      ~s(-DELZ_POLICY_IDENTITY="#{policy_identity()}")
    ]

    run(
      cc,
      @library_flags ++
        ["-I", source, "-Werror"] ++
        defines ++ [host_c, archive, "-lm", "-ldl", "-o", executable]
    )
  end

  defp run(command, args) do
    env = Enum.map(@scrub, &{&1, nil})

    case System.cmd(command, args, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      _ -> :error
    end
  end
end
