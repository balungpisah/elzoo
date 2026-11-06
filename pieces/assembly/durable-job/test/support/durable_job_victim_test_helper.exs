# SPDX-License-Identifier: Apache-2.0
# Run in a separate OS process by durable_job_restart_test.exs (DJ9). It owns
# attempt 1 of one Run and blocks in the handler until it is SIGKILLed.
Code.require_file("durable_job_test_helper.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:oban)
prefix = System.fetch_env!("ELZOO_DJ_PREFIX")
queue = System.fetch_env!("ELZOO_DJ_QUEUE")
alias Elzoo.DurableJob.{TestHelper, TestRepo}
{:ok, _} = TestRepo.start_link(url: TestHelper.url!(), pool_size: 5, log: false)
store = TestHelper.store(:postgres, prefix)

{:ok, _} =
  Oban.start_link(
    name: VictimOban,
    repo: TestRepo,
    prefix: prefix,
    queues: [{String.to_atom(queue), 1}],
    stager: [interval: 50],
    notifier: Oban.Notifiers.PG,
    log: false
  )

{:ok, _} =
  Elzoo.DurableJob.start_link(
    queue: queue,
    store: store,
    repo: TestRepo,
    oban: VictimOban,
    relay_interval_ms: :manual,
    handler: fn _ -> Process.sleep(:infinity) end
  )

{:ok, _} =
  Elzoo.DurableJob.submit(
    queue,
    "k9",
    [2, 3],
    [max_attempts: 3],
    System.os_time(:millisecond) + 3_600_000
  )

{:ok, _} = TestHelper.relay!(queue)
IO.puts("VICTIM_OS_PID=#{System.pid()}")
Process.sleep(:infinity)
