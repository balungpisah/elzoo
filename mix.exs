defmodule Elzoo.MixProject do
  use Mix.Project

  @cure_revision "a004c335cc4e9f2203ba6f51fc31e8540b66378d"

  def project do
    [
      app: :elzoo,
      version: "0.1.0",
      elixir: "== 1.20.4",
      start_permanent: Mix.env() == :prod,
      # The Cure task module is compiled with the Elixir sources, then Cure
      # runs before Mix's :app compiler so Cure BEAMs are listed in elzoo.app.
      compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app],
      deps: deps(),
      aliases: aliases(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Elzoo.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  defp deps do
    [
      # Keep Cure on the exact release commit. The release also has a branch
      # with the same name, so a tag/version-only ref is not reproducible.
      {:cure, git: "https://github.com/cure-lang/cure-lang.git", ref: @cure_revision, depth: 1},
      # Jason is deliberately an external implementation at the adapter edge.
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"]
    ]
  end
end
