defmodule Elzoo.CiRunnerGuardTest do
  use ExUnit.Case, async: true
  @script Path.expand("scripts/check-ci-runners.py")

  test "CI rejects a hosted selector, fallback matrix or missing workflow" do
    root = Path.join(System.tmp_dir!(), "elzoo-runner-guard-#{System.unique_integer([:positive])}")
    workflows = Path.join(root, ".github/workflows")
    File.mkdir_p!(workflows)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {_, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)

    for selector <- [
          "ubuntu-24.04",
          "${{ matrix.runner }}",
          "[self-hosted, linux]",
          "[self-hosted, linux, x64, symbolic, elzoo]",
          "[self-hosted, linux, x64, symbolic, elzoo, backend, gleam]"
        ] do
      File.write!(Path.join(workflows, "check.yml"), "jobs:\n  check:\n    runs-on: #{selector}\n")
      assert {_, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    end

    for role <- ["backend", "gleam"] do
      File.write!(
        Path.join(workflows, "check.yml"),
        "jobs:\n  check:\n    runs-on: [self-hosted, linux, x64, symbolic, elzoo, #{role}]\n"
      )

      assert {_, 0} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    end
  end
end
