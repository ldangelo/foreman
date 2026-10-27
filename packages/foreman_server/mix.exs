Code.require_file("../../scripts/patch_erlexec.exs", __DIR__)

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
      {:eventstore, "~> 1.4"},

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

      # Filesystem watch for BeadsWatcher's primary (<1s) JSONL-change
      # detection (TRD-011). Resolved transitively via credo's
      # dev/test-only dependency graph already; declared explicitly
      # here so it is present at runtime in every environment,
      # including prod releases.
      {:file_system, "~> 1.0"},

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
      {:jido,
       git: "https://github.com/Sunstone-Partners/jido.git",
       ref: "accea666713bda68e3d6802024584bfbd95aea2b",
       override: true},
      {:jido_action,
       git: "https://github.com/Sunstone-Partners/jido_action.git",
       ref: "2b6dfb57441454d290cfc3552767fb177ea14a2d",
       override: true},
      {:jido_signal,
       git: "https://github.com/Sunstone-Partners/jido_signal.git",
       ref: "e3f8a34184dfee60f765695d9ca65ac56426ef8a",
       override: true},
      {:jido_shell,
       git: "https://github.com/Sunstone-Partners/jido_shell.git",
       ref: "a180289345e3f2c5b659ed0ea2c4f20fabeeef2f",
       override: true},
      {:jido_vfs,
       git: "https://github.com/Sunstone-Partners/jido_vfs.git",
       ref: "ca34ffb5a303313cf9b878fecb78e6d8bf7d7538",
       override: true},
      {:jido_ai,
       git: "https://github.com/Sunstone-Partners/jido_ai.git",
       ref: "7da2579d32e5ad8e946c06890ac50a793867b0f7",
       override: true},
      # Vendored in this monorepo (synced from the Sunstone-Partners fork, see
      # packages/jido_harness/UPSTREAM_PIN.md) so Foreman-specific harness
      # changes land in ldangelo/foreman.
      {:jido_harness, path: "../jido_harness", override: true},
      {:jido_ecto,
       git: "https://github.com/Sunstone-Partners/jido_ecto.git",
       ref: "d5993d93be7885f62336251b4b7eb95aa88eef52",
       override: true},
      {:req_llm,
       git: "https://github.com/Sunstone-Partners/req_llm.git",
       ref: "e8d51edd24cf7bc08c3785f25f6bff95846f23e0",
       override: true},
      {:jido_otel,
       git: "https://github.com/Sunstone-Partners/jido_otel.git",
       ref: "e7b1c67ed841da642c38efdb62e884ff9a6c7588",
       override: true},
      {:jido_mcp,
       git: "https://github.com/Sunstone-Partners/jido_mcp.git",
       ref: "8986c4cbf4f5e89d9f9a7a4c096d45e45a514863",
       override: true},

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
      "deps.get": ["deps.get", &ErlexecPatch.apply/1],
      "deps.loadpaths": [&ErlexecPatch.apply/1, "deps.loadpaths"],
      "deps.compile": [&ErlexecPatch.apply/1, "deps.compile"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ],
      # `mix test` starts the app before it requires test_helper.exs, so the event store is emptied
      # first; see `run_tests/1`.
      test: &run_tests/1
    ]
  end

  # ProjectionLeakGuard rides along as a formatter (see its moduledoc). It has to be a task
  # option: `mix test --formatter X` replaces whatever test_helper.exs configured, and
  # options given twice add up. Naming ExUnit.CLIFormatter keeps the default output.
  #
  # No `--cover`: ExCoveralls made each CI partition's test step 69-84% slower (92-98 s ->
  # 161-180 s, same files, same seed) and nothing reads or gates on its table (no threshold, no
  # coveralls.json). `mix test --cover` still works for whoever wants the numbers.
  @test_args ~w(--color --formatter ExUnit.CLIFormatter
                --formatter ForemanServer.TestSupport.ProjectionLeakGuard)

  defp run_tests(args) do
    reset_event_store(args)
    Mix.Task.run("test", @test_args ++ args)
  end

  # `mix test` boots the application before it requires test_helper.exs. ProjectionStore rebuilds
  # its read model from the event log on boot and the Dispatcher re-admits every run the log says is
  # in flight, so a log left by the previous run has to be emptied BEFORE that boot: emptied
  # afterwards (as test_helper.exs used to) the in-memory projection, the aggregate actors and the
  # boot-time run executors still carry the previous run (foreman-a4ec2). Needs only the deps
  # (`loadpaths`), so the project is still compiled by `mix test` itself with its own flags.
  defp reset_event_store(args) do
    if Mix.env() != :test do
      Mix.raise(
        "refusing to empty the event store in MIX_ENV=#{Mix.env()}; mix test runs in :test"
      )
    end

    Mix.Task.run("loadpaths", args)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    config = EventStore.Config.parsed(ForemanServer.EventStore, :foreman_server)
    opts = config |> EventStore.Config.default_postgrex_opts() |> Keyword.put(:pool_size, 1)
    {:ok, conn} = Postgrex.start_link(opts)
    EventStore.Storage.Initializer.reset!(conn, config)
    GenServer.stop(conn)
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
