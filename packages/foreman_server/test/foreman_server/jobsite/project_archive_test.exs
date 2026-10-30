defmodule ForemanServer.Jobsite.ProjectArchiveTest do
  # What archiving a project does to a jobsite that is running.
  #
  # `project.archive` is refused only while WORKFLOW runs hold a reservation
  # (`Aggregates.Project.validate_archive/1` reads `active_run_reservations`, see the
  # parity audit row C11 and docs/decisions/project-delete.md). A jobsite holds none: it only
  # counts against the daily thread cap (`project.reserve_thread`). So archiving is accepted,
  # in-flight work continues exactly as it does for a pause, and only NEW work is refused.
  #
  # Real project aggregate (registered, archived and reactivated through `POST /api/commands`,
  # the endpoint `foreman project delete|reactivate` uses), a real jobsite held open by a
  # recording provider adapter in place of the agent CLI.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @moduletag :tmp_dir

  alias ForemanServer.{EventStore, ProjectStore}
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Executor, Sandboxes}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  @endpoint ForemanServerWeb.Endpoint
  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defmodule Recorder do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "jobsite archive recorder",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [:system_prompt, :model, :provider_session_id],
        provider_options: [:cli_path]
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    # A prompt of "hold" keeps the iteration open until the test sends `:release`.
    @impl true
    def run(request, _context) do
      pid = Application.fetch_env!(:jido_harness, :jobsite_archive_test_pid)

      send(pid, {:ran, request.prompt})

      # "hold-first" holds only the first run, so a later iteration passes straight through.
      first? =
        request.prompt == "hold-first" and
          :counters.get(Application.fetch_env!(:jido_harness, :jobsite_archive_test_counter), 1) ==
            0

      if request.prompt == "hold" or first? do
        if first?,
          do:
            :counters.add(
              Application.fetch_env!(:jido_harness, :jobsite_archive_test_counter),
              1,
              1
            )

        send(pid, {:held, self()})

        receive do
          :release -> :ok
        end
      end

      {:ok,
       [
         Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "worked"}),
         Event.new!(provider: :pi, type: :run_completed, payload: %{})
       ]}
    end
  end

  def held_counter, do: Application.fetch_env!(:jido_harness, :jobsite_archive_test_counter)

  setup %{tmp_dir: tmp_dir} do
    ProjectionStoreReset.reset!()
    Application.put_env(:jido_harness, :jobsite_archive_test_counter, :counters.new(1, []))
    providers = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, %{pi: Recorder})
    Application.put_env(:jido_harness, :jobsite_archive_test_pid, self())

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, providers)
      Application.delete_env(:jido_harness, :jobsite_archive_test_pid)
      Application.delete_env(:jido_harness, :jobsite_archive_test_counter)
      ProjectionStoreReset.reset!()
    end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

    project_id = "archive-js-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: project_id,
               path: repo,
               name: "Archive",
               config: %{}
             })

    {:ok, repo: repo, project_id: project_id}
  end

  defp jobsite_opts(ctx, prompt) do
    [
      repo_path: ctx.repo,
      strategy: :merge_to_head,
      sandbox: Sandboxes.host(),
      agent: Agents.pi("x", binary: @fake_agent),
      prompt: prompt,
      project_id: ctx.project_id,
      completion_signal: "NEVER"
    ]
  end

  # `POST /api/commands`: what the CLI sends for `project delete` / `project reactivate`.
  defp command(type, project_id) do
    build_conn()
    |> post("/api/commands", %{type: type, payload: %{project_id: project_id}})
    |> json_response(201)
  end

  defp await(message, fun) do
    ForemanServer.TestSupport.Eventually.await(fun, timeout: 10_000, message: message)
  end

  defp project_event_count(project_id, type) do
    {:ok, events} = EventStore.read_stream_forward("project:" <> project_id, 0, 99_999)
    Enum.count(events, &(&1.event_type == type))
  end

  test "archive is accepted while a jobsite runs; it keeps running and only new jobsites are refused",
       ctx do
    {:ok, id} = Jobsite.run_async(jobsite_opts(ctx, "hold"))
    assert_receive {:held, held_pid}, 5_000
    assert Jobsite.get(id).status == "running"
    assert project_event_count(ctx.project_id, "ProjectThreadStarted") == 1

    # Accepted: no workflow run holds a reservation, and the jobsite holds none.
    assert %{"status" => "accepted"} = command("project.archive", ctx.project_id)
    assert ProjectStore.get(ctx.project_id).status == "archived"

    # In-flight work continues: the executor is the same live process and the jobsite is
    # still running.
    pid = Executor.pid_for(id)
    assert is_pid(pid) and Process.alive?(pid)
    assert Jobsite.get(id).status == "running"

    # New work is refused with the typed error, from both entry points, and leaves nothing
    # behind: no second jobsite, no thread counted against the project.
    for start <- [&Jobsite.run/1, &Jobsite.run_async/1] do
      assert {:error, %Error{code: :spec_project_unavailable, details: details} = error} =
               start.(jobsite_opts(ctx, "refused"))

      assert details == %{project_id: ctx.project_id}
      assert error.message == "project #{inspect(ctx.project_id)} is archived"
    end

    assert Enum.map(Jobsite.list(), & &1.jobsite_id) == [id]
    assert project_event_count(ctx.project_id, "ProjectThreadStarted") == 1

    # Releasing the held iteration lets the jobsite finish normally inside the archived project.
    send(held_pid, :release)
    await("the jobsite completes", fn -> Jobsite.get(id).status == "completed" end)
    await("its executor exits", fn -> Executor.pid_for(id) == nil end)
  end

  test "a jobsite can start again once the project is reactivated", ctx do
    assert %{"status" => "accepted"} = command("project.archive", ctx.project_id)

    assert {:error, %Error{code: :spec_project_unavailable}} =
             Jobsite.run(jobsite_opts(ctx, "while archived"))

    assert %{"status" => "accepted"} = command("project.reactivate", ctx.project_id)
    assert ProjectStore.get(ctx.project_id).status == "active"

    assert {:ok, %{jobsite_id: id}} = Jobsite.run(jobsite_opts(ctx, "after reactivation"))
    assert Jobsite.get(id).status == "completed"
    assert Jobsite.get(id).project_id == ctx.project_id
  end

  # foreman-7p068. "In-flight work continues" (docs/decisions/project-delete.md, CLAUDE.md
  # section 26) is pinned to cover later iterations of a running jobsite: the iteration loop
  # does not re-read the project, so archive or pause between iterations changes nothing for it.
  # Only NEW jobsites are refused. If the policy ever becomes "a new iteration is new work",
  # this test must change together with an iteration-boundary check in the engine.
  for action <- ["project.archive", "project.pause"] do
    test "#{action} between iterations does not stop a multi-iteration jobsite", ctx do
      {:ok, id} =
        Jobsite.run_async(jobsite_opts(ctx, "hold-first") ++ [max_iterations: 3])

      assert_receive {:held, held_pid}, 5_000
      assert_receive {:ran, "hold-first"}, 1_000

      assert %{"status" => "accepted"} = command(unquote(action), ctx.project_id)

      send(held_pid, :release)
      await("the jobsite completes", fn -> Jobsite.get(id).status == "completed" end)

      # All three iterations ran after the project left the active state.
      assert_receive {:ran, "hold-first"}, 1_000
      assert_receive {:ran, "hold-first"}, 1_000
      assert length(Jobsite.get(id).iterations) == 3

      assert {:error, %Error{code: :spec_project_unavailable}} =
               Jobsite.run(jobsite_opts(ctx, "refused"))
    end
  end
end
