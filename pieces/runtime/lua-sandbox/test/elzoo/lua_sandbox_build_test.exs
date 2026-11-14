# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxBuildTest do
  @moduledoc """
  Group `native_build_and_copy`: a fresh native build from the installed pinned
  checkout, with the missing-tool, wrong-revision and failed-compile refusals.
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Build

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000

  setup_all do
    {executable, directory} = Helper.build!("group1")
    %{executable: executable, directory: directory}
  end

  test "pure function returns 42 from a fresh build of the installed sources", %{
    executable: executable,
    directory: directory
  } do
    assert {:ok, %{value: 42, identity: identity, runtime: runtime}} =
             Helper.run(executable, "return function(x) return x + 2 end", 40)

    assert identity == LuaSandbox.policy().identity
    # the host reports the runtime identity of this very build
    assert runtime == Build.runtime_identity()
    assert runtime.upstream_revision == "312b9efaa1061c2c4cad08554dbc1351c3270eef"
    assert runtime.lua_release == "Lua 5.4.9"

    # the owned C bytes are the bytes the build compiled: copied C bytes and receipt
    owned = Path.expand("../../lib/elzoo/lua_sandbox/native/lua_sandbox_host.c", __DIR__)
    copied = File.read!(Path.join(directory, "lua_sandbox_host.c"))
    assert copied == File.read!(owned)
    assert runtime.host_sha256 == Base.encode16(:crypto.hash(:sha256, copied), case: :lower)

    # a fresh static library and no prebuilt host or catalogue root involved
    assert File.regular?(Path.join(directory, "liblua.a"))
    assert Path.dirname(executable) == directory
  end

  test "the output directory is removed with its contents" do
    {_executable, directory} = Helper.build!("removable")
    assert File.dir?(directory)
    File.rm_rf!(directory)
    refute File.exists?(directory)
  end

  test "build never writes into the source checkout" do
    source = Helper.source_directory()
    before = git_status(source)
    {_executable, _directory} = Helper.build!("pristine")
    assert git_status(source) == before

    # an output directory inside the source is refused, and nothing is written
    inside = Path.join(source, "elz163-must-not-exist")
    assert LuaSandbox.build(source, inside) == {:error, :build_failed}
    refute File.exists?(inside)
    assert LuaSandbox.build(source, source) == {:error, :build_failed}
    assert git_status(source) == before
  end

  test "a missing compiler or archiver refuses and never skips" do
    source = Helper.source_directory()
    empty = Helper.tmp_dir!("empty-path")
    only_cc = Helper.tmp_dir!("only-cc")
    File.ln_s!(System.find_executable("cc"), Path.join(only_cc, "cc"))

    with_path(empty, fn ->
      assert LuaSandbox.build(source, Helper.tmp_dir!("no-tools")) == {:error, :build_failed}
    end)

    with_path(only_cc, fn ->
      assert LuaSandbox.build(source, Helper.tmp_dir!("no-ar")) == {:error, :build_failed}
    end)
  end

  test "a wrong source revision refuses before any compiler runs" do
    source = Helper.source_directory()
    copy = Helper.tmp_dir!("wrong-revision")

    for path <- Path.wildcard(Path.join(source, "*.{c,h}"), match_dot: true) do
      File.cp!(path, Path.join(copy, Path.basename(path)))
    end

    # a compiler that would record any use proves the identity check comes first
    marker = Path.join(Helper.tmp_dir!("marker"), "cc-used")
    bin = Helper.tmp_dir!("recording-bin")
    File.ln_s!(System.find_executable("ar"), Path.join(bin, "ar"))
    Helper.fake!(bin, "cc", "echo used >> '#{marker}'\nexit 0")

    # control: the unmodified copy passes the identity check, so the compiler is reached
    with_path(bin, fn ->
      assert LuaSandbox.build(copy, Helper.tmp_dir!("copy-control")) == {:error, :build_failed}
    end)

    assert File.exists?(marker)
    File.rm!(marker)

    path = Path.join(copy, "lvm.c")
    File.write!(path, File.read!(path) <> " ")

    with_path(bin, fn ->
      assert LuaSandbox.build(copy, Helper.tmp_dir!("wrong-rev")) == {:error, :build_failed}
    end)

    refute File.exists?(marker)

    # an extra header (and so any header or source set that differs) is the same refusal
    File.write!(path, File.read!(path) |> binary_part(0, byte_size(File.read!(path)) - 1))
    File.write!(Path.join(copy, "extra.h"), "")

    with_path(bin, fn ->
      assert LuaSandbox.build(copy, Helper.tmp_dir!("extra-header")) == {:error, :build_failed}
    end)

    refute File.exists?(marker)
  end

  test "a failed compile refuses with no compiler output" do
    # the identity check passes on the real checkout; the compiler then fails
    bin = Helper.tmp_dir!("failing-bin")
    File.ln_s!(System.find_executable("ar"), Path.join(bin, "ar"))
    Helper.fake!(bin, "cc", "echo 'private diagnostic marker' >&2\nexit 1")

    with_path(bin, fn ->
      assert LuaSandbox.build(Helper.source_directory(), Helper.tmp_dir!("failed-compile")) ==
               {:error, :build_failed}
    end)
  end

  defp git_status(directory) do
    case System.cmd("git", ["-C", directory, "status", "--porcelain", "--untracked-files=all"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {output, status} -> flunk("git status exited #{status}: #{output}")
    end
  end

  # PATH is restored in `after`, whatever the test did.
  defp with_path(directory, fun) do
    saved = System.get_env("PATH")

    try do
      System.put_env("PATH", directory)
      fun.()
    after
      System.put_env("PATH", saved)
    end
  end
end
