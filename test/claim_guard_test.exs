defmodule Elzoo.ClaimGuardTest do
  use ExUnit.Case, async: true
  @script Path.expand("scripts/check-claims.py")

  test "CI rejects tracked claim files, including hidden files; untracked local markers are allowed" do
    root = Path.join(System.tmp_dir!(), "elzoo-claim-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    File.mkdir_p!(Path.join(root, ".claims"))
    File.write!(Path.join(root, ".claims/.hidden"), "claim")
    assert {_, 0} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["add", ".claims/.hidden"], cd: root)
    assert {message, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    assert message =~ ".claims/.hidden"
    {_, 0} = System.cmd("git", ["rm", "--cached", ".claims/.hidden"], cd: root)
    assert {_, 0} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
  end
end
