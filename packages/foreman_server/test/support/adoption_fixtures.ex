defmodule ForemanServer.TestSupport.AdoptionFixtures do
  @moduledoc """
  Fixtures for `project.adopt` tests: projects registered through the real command
  gateway, runs and jobsites folded into the process-wide `ForemanServer.ProjectionStore`,
  and a session archive on disk.

  The store outlives every test, so callers build every id from `uid/0` (never a typed
  literal): a run that stays non-terminal in the store is read by id from later tests (see
  `ForemanServer.TestSupport.ProjectionLeakGuard`).
  """

  import ExUnit.Assertions

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Review.Archive

  @doc "A short random suffix no other test shares."
  @spec uid() :: String.t()
  def uid, do: Elixir.EventStore.UUID.uuid4() |> String.slice(0, 8)

  @doc "Register project `id` at `path` through the gateway and fold the event for the read side."
  @spec register!(String.t(), String.t()) :: :ok
  def register!(id, path) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               type: "project.register",
               command_id: "reg-#{id}",
               aggregate_id: "project:" <> id,
               payload: %{project_id: id, path: path}
             })

    # apply_events for the read side too: the projection subscription is async.
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: path}}
      ])
  end

  @doc """
  A task with one run and one worktree in `repo`, in `project`. `terminal?: true` completes
  the run, otherwise it stays in progress.
  """
  @spec seed_run!(%{
          project: String.t(),
          run: String.t(),
          task: String.t(),
          repo: String.t(),
          terminal?: boolean()
        }) :: :ok
  def seed_run!(%{project: project, run: run, task: task, repo: repo, terminal?: terminal?}) do
    events =
      [
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: task,
            project_id: project,
            title: "Add healthz",
            status: "in_progress",
            task_type: "task",
            prompt: "Add a /healthz route"
          }
        },
        %{
          event_type: "RunStarted",
          payload: %{run_id: run, task_id: task, project_id: project, workflow_name: "implement"}
        },
        %{
          event_type: "WorktreeCreated",
          payload: %{
            operation_id: "wt-#{run}-p1",
            project_id: project,
            run_id: run,
            phase_id: "p1",
            repo_path: repo,
            worktree_path: repo <> "/wt",
            branch: "agent/x",
            base_ref: "abc"
          }
        }
      ] ++
        if(terminal?,
          do: [
            %{
              event_type: "RunCompleted",
              payload: %{run_id: run, project_id: project, sequence: 1}
            }
          ],
          else: []
        )

    :ok = ProjectionStore.apply_events(events)
  end

  @doc "A jobsite of `project` on `repo`; `terminal?: true` completes it."
  @spec seed_jobsite!(%{
          project: String.t(),
          jobsite: String.t(),
          repo: String.t(),
          terminal?: boolean()
        }) :: :ok
  def seed_jobsite!(%{project: project, jobsite: jobsite, repo: repo, terminal?: terminal?}) do
    events =
      [
        %{
          event_type: "JobsiteStarted",
          payload: %{
            jobsite_id: jobsite,
            repo_path: repo,
            strategy: "head",
            project_id: project
          }
        }
      ] ++
        if(terminal?,
          do: [%{event_type: "JobsiteCompleted", payload: %{jobsite_id: jobsite}}],
          else: []
        )

    :ok = ProjectionStore.apply_events(events)
  end

  @doc "A session archive for run `run` under `repo`, with a request and a changed file. Returns its directory."
  @spec archive!(String.t(), String.t(), String.t()) :: String.t()
  def archive!(repo, run, project), do: archive!(:run, repo, run, project)

  @doc "Like `archive!/3` for a `:run` or a `:jobsite` subject."
  @spec archive!(:run | :jobsite, String.t(), String.t(), String.t()) :: String.t()
  def archive!(kind, repo, subject, project) do
    dir = Archive.dir(kind, subject, repo)

    :ok =
      Archive.init(dir, %{
        "kind" => Atom.to_string(kind),
        "subject_id" => subject,
        "project_id" => project,
        "repo_path" => repo,
        "branch" => "agent/x",
        "request" => %{"title" => "Add healthz", "prompt" => "Add a /healthz route"}
      })

    File.write!(Path.join(dir, "request.md"), "Add a /healthz route")
    File.write!(Path.join(dir, "changed-files.txt"), "A\tlib/healthz.ex\n")
    dir
  end
end
