# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/durable_job_test_helper.exs", __DIR__)

defmodule Elzoo.DurableJobRestartTest do
  use ExUnit.Case, async: false
  import Elzoo.DurableJob.TestHelper
  alias Elzoo.DurableJob.Run

  setup_all do
    prefix = setup_database!()
    on_exit(fn -> drop!(prefix) end)
    %{prefix: prefix}
  end

  @tag timeout: 120_000
  test "DJ9 SIGKILL of the OS process executing attempt 1; Lifeline rescue resumes at attempt 2",
       %{prefix: prefix} do
    queue = "djkill" <> Integer.to_string(System.unique_integer([:positive]))
    victim = Path.expand("../support/durable_job_victim_test_helper.exs", __DIR__)
    args = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++ [victim]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: args,
        env: [
          {~c"ELZOO_DJ_PREFIX", String.to_charlist(prefix)},
          {~c"ELZOO_DJ_QUEUE", String.to_charlist(queue)}
        ]
      ])

    [_, os_pid] = Regex.run(~r/VICTIM_OS_PID=(\d+)/, read_port(port, ""))
    store = store(:postgres, prefix)
    stream = Run.run_stream(queue, "k9")
    poll(fn -> kinds(store, stream) == ~w(accepted attempt_started) end)
    {_, 0} = System.cmd("kill", ["-9", os_pid])
    assert_receive {^port, {:exit_status, 137}}, 10_000

    oban = String.to_atom("Elzoo.DurableJob.TestOban." <> queue)
    start_oban(oban, prefix, queue, lifeline: [interval: 200, rescue_after: 500])
    start_job(queue, store, oban, [])
    poll(fn -> List.last(kinds(store, stream)) == "succeeded" end)
    records = records(store, stream)

    IO.puts(
      "ELZ-010 DJ9: victim #{os_pid} killed (137); records=#{inspect(Enum.map(records, &elem(&1, 0)))}"
    )

    assert [
             {"accepted", _},
             {"attempt_started", %{"attempt" => 1, "oban_attempt" => 1}},
             {"attempt_started", %{"attempt" => 2, "oban_attempt" => 2}},
             {"succeeded", %{"attempt" => 2, "result" => 5}}
           ] = records
  end

  defp read_port(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if acc =~ ~r/VICTIM_OS_PID=\d+/, do: acc, else: read_port(port, acc)
    after
      90_000 -> raise "victim did not start: #{acc}"
    end
  end
end
