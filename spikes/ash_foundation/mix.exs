defmodule ElzooAshSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :elzoo_ash_spike,
      version: "0.1.0",
      elixir: "== 1.20.4",
      elixirc_options: [warnings_as_errors: true],
      deps: [
        {:ash, "== 3.37.3"},
        {:ash_ai, "== 1.5.0"},
        {:simple_sat, "== 0.1.4"},
        {:telemetry, "== 1.4.2"},
        {:ash_state_machine, "== 0.3.0"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
