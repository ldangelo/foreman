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
      {:postgrex, ">= 0.0.0"}
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
