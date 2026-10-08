defmodule ForemanServer.Jobsite.Sandboxes do
  @moduledoc "Constructors for the bundled `ForemanServer.Jobsite.SandboxProvider` implementations."

  alias ForemanServer.Jobsite.Sandboxes.{Docker, Host}

  @doc "The host sandbox provider: commands run directly on the host, in the worktree."
  @spec host(keyword()) :: {module(), map()}
  def host(opts \\ []), do: {Host, Map.new(opts)}

  @doc """
  The Docker (or Podman, via `:binary`) sandbox provider.

  Options: `:image` (default `"foreman-jobsite:" <> basename(repo_path)`),
  `:sandbox_path` (default `"/workspace"`), `:uid`/`:gid` (default the host
  user), `:mounts` (default `[]`, each `%{host_path:, sandbox_path:,
  readonly?: false}`), `:network` (default none), `:env` (default `%{}`),
  `:binary` (default `"docker"`).
  """
  @spec docker(keyword()) :: {module(), map()}
  def docker(opts \\ []), do: {Docker, Map.new(opts)}

  @doc """
  Resolves a provider's `name/0` string (as persisted on `JobsiteStarted`)
  back to its module, for `Jobsite.resume/1` rebuilding a sandbox without
  the caller re-supplying `:sandbox`.
  """
  @spec resolve(String.t()) :: {:ok, module()} | {:error, ForemanServer.Jobsite.Error.t()}
  def resolve("host"), do: {:ok, Host}
  def resolve("docker"), do: {:ok, Docker}

  def resolve(name) do
    {:error, ForemanServer.Jobsite.Error.new(:sandbox_create_failed, "unknown sandbox provider #{name}", %{name: name})}
  end
end
