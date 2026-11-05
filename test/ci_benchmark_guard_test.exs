defmodule Elzoo.CiBenchmarkGuardTest do
  use ExUnit.Case, async: true
  @script Path.expand("scripts/benchmark-ci.py")

  test "benchmark provenance rejects untracked source, tracked edits and a different revision" do
    root =
      Path.join(System.tmp_dir!(), "elzoo-benchmark-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    File.write!(Path.join(root, ".gitignore"), "/_build/\n")
    {_, 0} = System.cmd("git", ["add", ".gitignore"], cd: root)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "commit",
          "--quiet",
          "-m",
          "fixture"
        ], cd: root)

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    revision = String.trim(revision)
    assert {_, 0} = validate(root, revision)
    assert {message, 1} = validate(root, String.duplicate("0", 40))
    assert message =~ "must match the checkout HEAD"

    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "_build/cache"), "ignored build output")
    assert {_, 0} = validate(root, revision)
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/extra_test.exs"), "# changes the measured workload")
    assert {message, 1} = validate(root, revision)
    assert message =~ "including untracked files"
    File.rm!(Path.join(root, "test/extra_test.exs"))
    File.write!(Path.join(root, ".gitignore"), "/_build/\n/another/\n")
    assert {message, 1} = validate(root, revision)
    assert message =~ "clean checkout"
  end

  defp validate(root, revision) do
    System.cmd(
      "python3",
      [
        "-B",
        "-c",
        "import runpy, sys; runpy.run_path(sys.argv[1])['validate_revision'](sys.argv[2])",
        @script,
        revision
      ], cd: root, stderr_to_stdout: true)
  end
end
