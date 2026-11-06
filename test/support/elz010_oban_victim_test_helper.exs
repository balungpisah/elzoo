# SPDX-License-Identifier: Apache-2.0
# Run in a separate OS process by test/elz010_provider_probe_test.exs (O10).
Code.require_file("elz010_probe_test_helper.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:oban)
url = Elzoo.Elz010Probe.url!()
{:ok, _} = Elzoo.Elz010Probe.Repo.start_link(url: url, pool_size: 3, log: false)

{:ok, _} =
  Oban.start_link(
    name: Elz010Victim,
    repo: Elzoo.Elz010Probe.Repo,
    prefix: Elzoo.Elz010Probe.prefix(),
    queues: [probe: 1],
    stager: [interval: 50],
    notifier: Oban.Notifiers.PG
  )

{:ok, job} = Oban.insert(Elz010Victim, Elzoo.Elz010Probe.Victim.new(%{}))
IO.puts("VICTIM_JOB=#{job.id} OS_PID=#{System.pid()}")
Process.sleep(:infinity)
