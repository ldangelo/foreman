defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Ecto + Postgres for the Jido checkpoint store Repo
      # (TRD-2026-4212be7e, JCR-T004). Both are also pulled in
      # transitively via eventstore and jido_ecto; we declare them
      # explicitly here so the supervision tree doesn't have to
      # rely on transitive resolution.
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19"},

      # EventStore persistence
      {:eventstore, "~> 1.3"},

      # Phoenix HTTP boundary
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug_cowboy, "~> 2.6"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:meck, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      # JSON serialization for EventStore
      {:jason, "~> 1.4"},

      # OpenTelemetry OTLP/HTTP exporter (TRD-2026-4212be7e / JOT-T001).
      # Pairs with :opentelemetry 1.7.0; without this dep, the SDK's batch
      # processor logs `OTLP exporter module opentelemetry_exporter not found`
      {:opentelemetry_exporter, "~> 1.10.0"},

      # Anubis MCP server (TRD-036)
      {:anubis_mcp, "~> 1.10"},

      # Jido ecosystem — Sunstone-Partners forks (TRD-2026-4212be7e, JCR-T001)
      # See ../../JIDO_FORKS.md for fork URLs and pinned commit SHAs.
      # All packages sourced from a Sunstone-Partners fork to give Foreman
      # deterministic, auditable pins and CI-controlled upgrade gating (JRM-T003).
      # `override: true` forces the fork across the entire transitive closure
      # (jido_ai pulls jido+req_llm from Hex, jido_shell pulls jido_vfs from Hex;
      # we deliberately replace every one with our Sunstone-Partners fork).
      {:jido,            git: "https://github.com/Sunstone-Partners/jido.git",            ref: "accea666713bda68e3d6802024584bfbd95aea2b", override: true},
      {:jido_action,     git: "https://github.com/Sunstone-Partners/jido_action.git",     ref: "2b6dfb57441454d290cfc3552767fb177ea14a2d", override: true},
      {:jido_signal,     git: "https://github.com/Sunstone-Partners/jido_signal.git",     ref: "e3f8a34184dfee60f765695d9ca65ac56426ef8a", override: true},
      {:jido_shell,      git: "https://github.com/Sunstone-Partners/jido_shell.git",      ref: "a180289345e3f2c5b659ed0ea2c4f20fabeeef2f", override: true},
      {:jido_vfs,        git: "https://github.com/Sunstone-Partners/jido_vfs.git",        ref: "ca34ffb5a303313cf9b878fecb78e6d8bf7d7538", override: true},
      {:jido_ai,         git: "https://github.com/Sunstone-Partners/jido_ai.git",         ref: "7da2579d32e5ad8e946c06890ac50a793867b0f7", override: true},
      {:jido_harness,    git: "https://github.com/Sunstone-Partners/jido_harness.git",    ref: "e41fc1651282469f2db4219a48d9f7feef1b0dbc", override: true},
      {:jido_ecto,       git: "https://github.com/Sunstone-Partners/jido_ecto.git",       ref: "d5993d93be7885f62336251b4b7eb95aa88eef52", override: true},
      {:req_llm,         git: "https://github.com/Sunstone-Partners/req_llm.git",         ref: "e8d51edd24cf7bc08c3785f25f6bff95846f23e0", override: true},
      {:jido_otel,       git: "https://github.com/Sunstone-Partners/jido_otel.git",       ref: "e7b1c67ed841da642c38efdb62e884ff9a6c7588", override: true},
      {:jido_mcp,        git: "https://github.com/Sunstone-Partners/jido_mcp.git",        ref: "8986c4cbf4f5e89d9f9a7a4c096d45e45a514863", override: true},

      # Dev/Test quality tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ],
      test: ["test --cover --color"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :jido_signal, :jido],
      mod: {ForemanServer.Application, []},
      env: [
        event_stores: [ForemanServer.EventStore]
      ]
    ]
  end

  defp releases do
    [
      foreman_server: [
        config_providers: [
          {ForemanServer.ConfigProviders.Secrets, []}
        ]
      ]
    ]
  end
end
