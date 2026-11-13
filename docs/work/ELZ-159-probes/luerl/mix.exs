defmodule LuerlFit.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :luerl_fit,
      version: "0.0.0",
      erlc_options: [{:i, "deps/luerl/include"}],
      deps: [{:luerl, "== 1.5.1"}]
    ]

  def application, do: [extra_applications: [:logger]]
end
