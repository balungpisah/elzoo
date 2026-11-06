# SPDX-License-Identifier: Apache-2.0
# ELZ-010 job-provider comparison (exploration evidence for docs/work/ELZ-010.md).
defmodule ElzooAshSpike.JobRepo do
  use AshPostgres.Repo, otp_app: :elzoo_ash_spike, warn_on_missing_ash_functions?: false
  def installed_extensions, do: []
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule ElzooAshSpike.JobDomain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ElzooAshSpike.Ticket)
  end
end

defmodule ElzooAshSpike.Ticket.MaybeFail do
  use Ash.Resource.Change

  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn cs ->
      if cs.data.fail_mode == :always, do: Ash.Changeset.add_error(cs, "probe failure"), else: cs
    end)
  end
end

defmodule ElzooAshSpike.Ticket do
  use Ash.Resource,
    domain: ElzooAshSpike.JobDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban]

  postgres do
    table("probe_tickets")
    schema("elz010_ash_jobs")
    repo(ElzooAshSpike.JobRepo)
  end

  oban do
    triggers do
      trigger :process do
        action(:process)
        where(expr(state == :pending))
        max_attempts(2)
        backoff(1)
        scheduler_cron("@yearly")
        queue(:ticket_process)
        worker_module_name(ElzooAshSpike.Ticket.ProcessWorker)
        scheduler_module_name(ElzooAshSpike.Ticket.ProcessScheduler)
      end

      trigger :process_guarded do
        action(:process)
        where(expr(state == :pending_guarded))
        max_attempts(2)
        backoff(1)
        on_error(:fail)
        scheduler_cron("@yearly")
        queue(:ticket_process)
        worker_module_name(ElzooAshSpike.Ticket.GuardedWorker)
        scheduler_module_name(ElzooAshSpike.Ticket.GuardedScheduler)
      end
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :state, :atom do
      constraints(one_of: [:pending, :pending_guarded, :done, :failed, :cancelled])
      allow_nil?(false)
      public?(true)
    end

    attribute :fail_mode, :atom do
      constraints(one_of: [:never, :always])
      default(:never)
      public?(true)
    end
  end

  actions do
    defaults([:read])
    create(:create, accept: [:state, :fail_mode])

    update :process do
      require_atomic?(false)
      change(ElzooAshSpike.Ticket.MaybeFail)
      change(set_attribute(:state, :done))
    end

    update :fail do
      require_atomic?(false)
      argument(:error, :term)
      change(set_attribute(:state, :failed))
    end

    update :cancel do
      require_atomic?(false)
      change(set_attribute(:state, :cancelled))
    end
  end
end

defmodule ElzooAshSpike.ReactorEffectProbe do
  use Reactor
  input(:job)

  step :effect do
    argument(:job, input(:job))

    run(fn %{job: job}, _ ->
      ElzooAshSpike.JobRepo.query!(
        "insert into elz010_ash_jobs.probe_effects (job_id, attempt) values ($1, $2)",
        [job.id, job.attempt],
        log: false
      )

      {:ok, :done}
    end)
  end

  step :fails_first do
    argument(:prior, result(:effect))
    argument(:job, input(:job))
    run(fn %{job: job}, _ -> if job.attempt < 2, do: {:error, :boom}, else: {:ok, :fine} end)
  end

  return(:fails_first)
end

defmodule ElzooAshSpike.ReactorJob do
  use Oban.Worker, queue: :reactor_probe, max_attempts: 3

  @impl true
  def perform(job) do
    case Reactor.run(ElzooAshSpike.ReactorEffectProbe, %{job: job}) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :reactor_failed}
    end
  end

  @impl true
  def backoff(_), do: 0
end
