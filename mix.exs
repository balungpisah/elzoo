defmodule Elzoo.MixProject do
  use Mix.Project

  @cure_revision "208248063d64e621782cd26dd30698ee42850a89"

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
      {:cure, git: "https://github.com/balungpisah/cure-lang.git", ref: @cure_revision, depth: 1},
      # Jason is deliberately an external implementation at the adapter edge.
      {:jason, "~> 1.4"},
      {:req, "== 0.7.5"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.4"},
      # ELZ-010 integration/jobs provider (also used by the test/elz010_* probes).
      {:oban, "== 2.24.2"},
      # ELZ-031 domain/money provider (already locked transitively at 3.2.0).
      {:decimal, "== 3.2.0"},
      # ELZ-029 runtime/os-isolation provider: OS-process spawn, group, deadline and reaping
      # through its port program (BSD-2-Clause). runtime: false because its port program refuses
      # to start as root without an effective user; Elzoo.OsProcess.Provider starts it with one.
      {:erlexec, "== 2.6.0", runtime: false},
      # ELZ-054 integration/notification provider (MIT). runtime: false: only Swoosh.Email and
      # Swoosh.Adapters.SMTP.deliver/2 are called; Swoosh's application (API client, local
      # storage) is never started, so no global :swoosh configuration is needed.
      {:swoosh, "== 1.29.3", runtime: false},
      # The SMTP transport Swoosh's SMTP adapter requires (BSD-2-Clause); its server is the
      # in-process test SMTP server of the notification tests.
      {:gen_smtp, "== 1.3.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile", "elzoo.ash_spike --setup"]
    ]
  end
end
