defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      ecto_repos: [ForemanServer.Repo],
      post_compile: :copy_bundled_workflows
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ecto_sql],
      mod: {ForemanServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:ecto_sql, "~> 3.12"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:postgrex, ">= 0.0.0"},
      {:jido, "~> 2.3.3"},
      {:jido_action, "~> 2.3.2"},
      {:jido_signal, "~> 2.2.2"},
      {:jido_shell, github: "agentjido/jido_shell", ref: "a180289345e3f2c5b659ed0ea2c4f20fabeeef2f"},
      {:jido_vfs, "~> 1.0.1"},
      {:jido_ai, "~> 2.3.0"},
      {:jido_harness, github: "agentjido/jido_harness", ref: "e41fc1651282469f2db4219a48d9f7feef1b0dbc"},
      {:jido_ecto, "~> 1.0.0"},
      {:req_llm, "~> 1.20"},
      {:jido_otel, "~> 1.0.0"},
      {:opentelemetry_exporter, "~> 1.10.0"}
    ]
  end

  # Post-compile hook: copy bundled workflows to priv/defaults/workflows/
  # so scheduler.ex can find them at runtime via Application.app_dir(:foreman_server, "priv").
  # Source: <monorepo>/src/defaults/workflows/ (3 levels up from packages/foreman_server/)
  def copy_bundled_workflows(_env) do
    if Mix.env() != :test do
      dest = Application.app_dir(:foreman_server, "priv/defaults/workflows")
      # packages/foreman_server/../../../src/defaults/workflows -> monorepo root
      src = Path.expand("../../../src/defaults/workflows", __DIR__)

      if File.dir?(src) do
        File.mkdir_p!(dest)

        count =
          for file <- File.ls!(src) do
            dest_file = Path.join(dest, file)
            src_file = Path.join(src, file)
            if File.regular?(src_file), do: File.cp!(src_file, dest_file)
            file
          end
          |> length()

        Mix.shell().info("[foreman_server] copied #{count} bundled workflows to priv/")
      else
        Mix.shell().warn("[foreman_server] bundled workflow source not found: #{src}")
      end
    end
  end
end
