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
      elixirc_paths: ["lib"] ++ Path.wildcard("pieces/**/lib"),
      test_paths: ["test", "pieces"],
      test_ignore_filters: [~r/test_helper.exs$/, ~r/\/examples\//],
      cure_paths: Path.wildcard("pieces/**/cure"),
      deps: deps(),
      aliases: aliases(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Elzoo.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [setup: :test, check: :test, "elzoo.ledger": :test, "elzoo.take": :test]]
  end

  defp deps do
    [
      # Keep Cure on the exact release commit. The release also has a branch
      # with the same name, so a tag/version-only ref is not reproducible.
      {:cure, git: "https://github.com/cure-lang/cure-lang.git", ref: @cure_revision, depth: 1},
      # Jason is deliberately an external implementation at the adapter edge.
      {:jason, "~> 1.4"},
      {:req, "== 0.7.5"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.4"},
      # ELZ-010 pre-implementation provider probes only (test/elz010_*); becomes a
      # registry provider when integration/jobs is implemented.
      {:oban, "== 2.24.2", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile", "elzoo.ash_spike --setup"]
    ]
  end
end
