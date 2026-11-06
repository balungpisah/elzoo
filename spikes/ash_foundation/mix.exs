defmodule ElzooAshSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :elzoo_ash_spike,
      version: "0.1.0",
      elixir: "== 1.20.4",
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      test_ignore_filters: [~r/test_helper.exs$/, ~r{/support/}],
      deps: [
        {:ash, "== 3.37.3"},
        {:ash_postgres, "== 2.15.2"},
        {:ash_ai, "== 1.5.0"},
        {:simple_sat, "== 0.1.4"},
        {:telemetry, "== 1.4.2"},
        {:ash_state_machine, "== 0.3.0"},
        # ELZ-010 job-provider comparison (AshOban triggers, Reactor inside Oban).
        {:ash_oban, "== 0.10.3"},
        {:oban, "== 2.24.2"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
