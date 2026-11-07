defmodule Elzoo.CiRunnerGuardTest do
  use ExUnit.Case, async: true
  @script Path.expand("scripts/check-ci-runners.py")

  test "CI rejects hosted, missing, unknown and swapped-role workflows" do
    root = Path.join(System.tmp_dir!(), "elzoo-runner-guard-#{System.unique_integer([:positive])}")
    workflows = Path.join(root, ".github/workflows")
    File.mkdir_p!(workflows)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {_, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)

    for {file, role} <- [{"symbolic-check.yml", "backend"}, {"symbolic-gleam.yml", "gleam"}] do
      File.write!(Path.join(workflows, file), workflow(role))
    end

    assert {_, 0} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)

    for selector <- [
          "ubuntu-24.04",
          "${{ matrix.runner }}",
          "[self-hosted, linux]",
          "[self-hosted, linux, x64, symbolic, elzoo]",
          "[self-hosted, linux, x64, symbolic, elzoo, backend, gleam]"
        ] do
      File.write!(
        Path.join(workflows, "symbolic-check.yml"),
        replace_selector(workflow("backend"), "    runs-on: #{selector}")
      )

      assert {output, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
      assert output =~ "every job must use"
    end

    File.write!(Path.join(workflows, "symbolic-check.yml"), workflow("backend"))

    for {file, correct, wrong} <- [
          {"symbolic-check.yml", "backend", "gleam"},
          {"symbolic-gleam.yml", "gleam", "backend"}
        ] do
      [wrong_selector] = Regex.run(~r/^    runs-on:.*$/m, workflow(wrong))
      File.write!(Path.join(workflows, file), replace_selector(workflow(correct), wrong_selector))
      assert {output, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
      assert output =~ "every job must use"
      File.write!(Path.join(workflows, file), workflow(correct))
      assert {_, 0} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    end

    File.write!(Path.join(workflows, "unknown.yml"), workflow("backend"))
    assert {_, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
    File.rm!(Path.join(workflows, "unknown.yml"))
    File.rm!(Path.join(workflows, "symbolic-gleam.yml"))
    assert {_, 1} = System.cmd("python3", [@script], cd: root, stderr_to_stdout: true)
  end

  defp workflow("backend"), do: File.read!(Path.expand(".github/workflows/symbolic-check.yml"))
  defp workflow("gleam"), do: File.read!(Path.expand(".github/workflows/symbolic-gleam.yml"))

  defp replace_selector(workflow, selector),
    do: Regex.replace(~r/^    runs-on:.*$/m, workflow, selector, global: false)
end
