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
      # ELZ-053 integration/object-store provider: S3 URL handling and SigV4 presign on the pinned
      # Req (Apache-2.0). Multipart is not used, so ex_aws_s3 is not added.
      {:req_s3, "== 0.2.5"},
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
      {:gen_smtp, "== 1.3.0"},
      # ELZ-052 runtime/telemetry provider (already locked transitively at 1.4.2
      # through Oban, Ecto and Req); a direct dependency of the Piece.
      {:telemetry, "== 1.4.2"},
      # ELZ-055 state/audit-log provider (Apache-2.0): trigger-based change capture.
      {:carbonite, "== 0.17.0"},
      # ELZ-079 integration/ai-text-anthropic provider (Apache-2.0), locked at 1.30.0 with
      # llm_db 2026.11.0; used through its documented provider-callback API. Not runtime: false:
      # its application initializes the provider registry. Its .env loading is switched off in
      # config/config.exs (load_dotenv: false).
      {:req_llm, "~> 1.30"},
      # Req.Test stubs for the ELZ-079 provider tests (Apache-2.0), an ordinary provider of the
      # exported Anthropic Piece because the exporter has no test-only form. Not test-only: the
      # ELZ-083 ex_mcp closure (plug_cowboy) needs plug at runtime, so one pin serves both.
      {:plug, "== 1.20.3"},
      # ELZ-081 integration/text-chunking provider (MIT): the recursive splitter and its byte
      # ranges; its one requirement nimble_options is already locked at 1.2.0.
      {:text_chunker, "== 1.0.1"},
      # ELZ-083 integration/mcp-client provider (MIT): MCP protocol, era negotiation and the
      # Streamable HTTP client transport. Its application starts its own supervisors, so it is
      # not runtime: false; its server-side plug_cowboy/cowboy closure is required by the package.
      {:ex_mcp, "== 1.8.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile", "elzoo.ash_spike --setup"]
    ]
  end
end
