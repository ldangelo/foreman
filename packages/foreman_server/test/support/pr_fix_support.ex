defmodule ForemanServer.TestSupport.PrFixSupport do
  @moduledoc """
  Fixtures for the E9 PR-fix tests: a real temporary git repository registered as a
  project, a completed run with a watched PR observed through the real `Observer`
  (so the watch record carries the PR head branch like production), plus helpers
  for the run's worktree and provider-session facts.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.{PrAssociate, ProjectionStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @type ctx :: %{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo: String.t(),
          status: PrStatus.t()
        }

  @doc "Run `git` in `dir`, asserting success; returns trimmed output."
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(output)
  end

  @doc "A fresh git repository on `main` with one commit; removed on exit."
  @spec git_repo!(String.t()) :: String.t()
  def git_repo!(prefix \\ "prfix") do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    File.mkdir_p!(path)
    git!(path, ["init", "-q", "-b", "main"])
    path = git!(path, ["rev-parse", "--show-toplevel"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    on_exit(fn -> File.rm_rf(path) end)
    git!(path, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    git!(path, ["add", "-A"])
    git!(path, ["commit", "-q", "-m", "init"])
    path
  end

  @doc "Commit a file in the git checkout at `dir`; returns the new HEAD sha."
  @spec commit_file!(String.t(), String.t(), String.t()) :: String.t()
  def commit_file!(dir, name, content) do
    File.write!(Path.join(dir, name), content)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "change #{name}"])
    git!(dir, ["rev-parse", "HEAD"])
  end

  @doc """
  A completed run whose PR is associated and observed once. Options: `:status`
  (the observed `PrStatus`, default one failing check), `:settings` (typed project
  settings put on `ProjectRegistered`; default a `thread_model`, the model a fix falls back to), `observe: false` (the
  watch exists but no observation recorded the PR head yet).
  """
  @spec watched!(keyword()) :: ctx()
  def watched!(opts \\ []) do
    repo = Keyword.get_lazy(opts, :repo, &git_repo!/0)
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    project_id = "project-prfix-#{token}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload:
            Map.merge(
              %{project_id: project_id, path: repo},
              Keyword.get(opts, :settings, %{thread_model: "sonnet"})
            )
        }
      ])

    run = Support.start_run!(project_id: project_id, complete: true)

    status =
      Keyword.get_lazy(opts, :status, fn ->
        Support.status(
          checks: [Support.failing_check("unit")],
          checks_state: :failing,
          head_branch: "foreman/#{run.run_id}/implement"
        )
      end)

    {:ok, _} = PrAssociate.store(run.run_id, run.pr_url)

    if Keyword.get(opts, :observe, true) do
      {:ok, _result} =
        Observer.observe(run.pr_url, fetch_fun: fn _ -> {:ok, status} end, auto_fix: false)
    end

    Map.merge(run, %{repo: repo, status: status})
  end

  @doc "Project a `WorktreeCreated` fact for the run's phase (operation id derived like production)."
  @spec worktree_created!(ctx(), String.t(), String.t()) :: :ok
  def worktree_created!(ctx, path, branch) do
    ProjectionStore.apply_events([
      %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "wt-#{ctx.run_id}-implement",
          project_id: ctx.project_id,
          run_id: ctx.run_id,
          phase_id: "implement",
          repo_path: ctx.repo,
          worktree_path: path,
          branch: branch,
          base_ref: "main",
          cleanup: "remove"
        }
      }
    ])
  end

  @doc "Project the provider session the run's worker persisted (`WorkerSessionBound`)."
  @spec session_bound!(ctx(), String.t(), String.t() | nil, String.t()) :: :ok
  def session_bound!(ctx, provider, model, session_id) do
    ProjectionStore.apply_events([
      %{
        event_type: "WorkerSessionBound",
        payload: %{
          worker_id: "worker-#{ctx.run_id}",
          run_id: ctx.run_id,
          provider: provider,
          provider_session_id: session_id,
          model: model
        }
      }
    ])
  end
end
