defmodule ForemanServer.Jobsite.SandboxProvider do
  @moduledoc """
  Behaviour every Jobsite sandbox provider implements: where an agent's
  commands actually run, relative to the worktree on disk.

  `kind/0` is `:bind_mount` when the sandbox's filesystem is the worktree
  itself (host execution, or a container with the worktree bind-mounted in)
  and `:isolated` for a provider whose filesystem is NOT backed by the
  worktree — the `:head` branch strategy is incompatible with an `:isolated`
  provider because there would be nothing to bind the agent's work back into.
  """

  alias ForemanServer.Jobsite.{Error, ExecResult, Worktree}

  @callback name() :: String.t()
  @callback kind() :: :bind_mount | :isolated

  @callback create(config :: map(), worktree :: Worktree.t()) ::
              {:ok, state :: term(), sandbox_repo_path :: String.t(), container_id :: String.t() | nil}
              | {:error, Error.t()}

  @callback exec(state :: term(), command :: String.t(), opts :: keyword()) ::
              {:ok, ExecResult.t()} | {:error, Error.t()}

  @callback agent_cli_path(state :: term(), agent_binary :: String.t(), env :: map()) ::
              {:ok, String.t() | nil} | {:error, Error.t()}

  @callback copy_file_in(state :: term(), host_path :: String.t(), sandbox_path :: String.t()) ::
              :ok | {:error, Error.t()}

  @callback copy_file_out(state :: term(), sandbox_path :: String.t(), host_path :: String.t()) ::
              :ok | {:error, Error.t()}

  @callback close(state :: term()) :: :ok | {:error, Error.t()}
end
