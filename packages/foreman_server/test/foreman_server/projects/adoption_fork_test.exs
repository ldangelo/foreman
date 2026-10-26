defmodule ForemanServer.Projects.AdoptionForkTest do
  # `AdoptionService.continue/5` with `fork: true`: the new thread's task carries the source's provider
  # session (`ForkSource`), its prompt is the operator's instruction (no archive replay), the result's
  # mode says `forked`, and whatever cannot be forked is refused with a typed error, never degraded.
  use ExUnit.Case, async: false

  import ForemanServer.TestSupport.AdoptionFixtures

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.{AdoptionService, ForkSource}

  @moduletag :tmp_dir
  @uuid "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"

  setup %{tmp_dir: tmp} do
    # `continue` approves the new task: keep the app-level Dispatcher from starting a real run.
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

    id = uid()
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    a = "a-#{id}"
    b = "b-#{id}"
    register!(a, repo)
    register!(b, repo)

    %{a: a, b: b, repo: repo, run: "run-#{id}", task: "task-#{id}", id: id}
  end

  defp bind_session!(run, provider, session_id) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "WorkerSessionBound",
          payload: %{
            worker_id: "w-#{run}",
            run_id: run,
            provider: provider,
            model: "haiku",
            provider_session_id: session_id
          }
        }
      ])
  end

  test "a forked continue carries the session on the new task and replays nothing", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})
    dir = archive!(ctx.repo, ctx.run, ctx.a)
    bind_session!(ctx.run, "claude", @uuid)
    manifest_before = File.read!(Path.join(dir, "manifest.json"))

    assert {:ok, %{mode: "forked", new_task_id: new_task}} =
             AdoptionService.continue("run", ctx.run, ctx.b, "also add /readyz", fork: true)

    assert %{
             project_id: project,
             prompt: prompt,
             fork_provider: "claude",
             fork_session_id: @uuid
           } = ProjectionStore.task_projection(new_task)

    assert project == ctx.b
    assert prompt =~ "also add /readyz"
    assert prompt =~ "fork of the earlier session"
    # The earlier branch is named, because the new worktree does not start from it.
    assert prompt =~ "agent/x"
    # Nothing of the archive is replayed: the forked agent remembers the conversation.
    refute prompt =~ "UNTRUSTED"
    refute prompt =~ "lib/healthz.ex"

    # The source is untouched.
    assert File.read!(Path.join(dir, "manifest.json")) == manifest_before
    assert %{project_id: still} = ProjectionStore.run(ctx.run)
    assert still == ctx.a
  end

  test "the default stays context-seeded and carries no session", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})
    archive!(ctx.repo, ctx.run, ctx.a)
    bind_session!(ctx.run, "claude", @uuid)

    assert {:ok, %{mode: "context_seeded", new_task_id: new_task}} =
             AdoptionService.continue("run", ctx.run, ctx.b, "go")

    task = ProjectionStore.task_projection(new_task)
    assert task.prompt =~ "UNTRUSTED"
    refute Map.has_key?(task, :fork_provider)
    refute Map.has_key?(task, :fork_session_id)
  end

  test "a task subject forks the session of its latest run that has one", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})
    bind_session!(ctx.run, "claude", @uuid)

    assert {:ok, %{provider: "claude", session_id: @uuid}} = ForkSource.resolve("task", ctx.task)
    assert {:ok, %{provider: "claude", session_id: @uuid}} = ForkSource.resolve("run", ctx.run)
  end

  test "a run with no recorded session is refused, naming it, and no thread is created", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: false})
    before = Enum.count(ProjectionStore.list_tasks())

    assert {:error, {:fork_no_session, "run", run}} =
             AdoptionService.continue("run", ctx.run, ctx.b, "go", fork: true)

    assert run == ctx.run
    assert Enum.count(ProjectionStore.list_tasks()) == before
  end

  test "a session of a provider that cannot fork is refused", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})
    bind_session!(ctx.run, "gemini", @uuid)

    assert {:error, {:fork_provider_unsupported, "gemini"}} =
             AdoptionService.continue("run", ctx.run, ctx.b, "go", fork: true)
  end

  test "a jobsite forks the session its agent reported (bound while it is still running)", ctx do
    js = "js-#{ctx.id}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{
            jobsite_id: js,
            repo_path: ctx.repo,
            strategy: "head",
            project_id: ctx.a,
            agent: %{provider: "claude", model: "haiku"}
          }
        },
        %{
          event_type: "JobsiteSessionBound",
          payload: %{jobsite_id: js, session_id: @uuid, index: 1}
        }
      ])

    assert {:ok, %{provider: "claude", session_id: @uuid}} = ForkSource.resolve("jobsite", js)

    assert {:ok, %{mode: "forked", new_task_id: new_task}} =
             AdoptionService.continue("jobsite", js, ctx.b, "go on", fork: true)

    assert %{fork_provider: "claude", fork_session_id: @uuid} =
             ProjectionStore.task_projection(new_task)
  end

  test "a non-boolean :fork is a programming error, not a maybe", ctx do
    seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})

    assert_raise ArgumentError, ~r/:fork must be a boolean/, fn ->
      AdoptionService.continue("run", ctx.run, ctx.b, "go", fork: "yes")
    end
  end
end
