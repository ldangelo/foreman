defmodule ForemanServer.LibraryDeliveryTest do
  # What an agent actually receives: the env var on the workflow door's launch, the
  # sandbox view for jobsites, the standing-context section, and (real jobsite run
  # with a fake agent that echoes one env var) the host path on the jobsite door.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, Library, ProjectContext}
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}
  alias ForemanServer.ProjectContext.Library, as: LibrarySection
  alias ForemanServer.Workflow.RunExecutor

  @fake_agent Path.join(__DIR__, "jobsite/support/fake_agent.sh")
  @operator %{kind: :operator, ref: "op"}

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", tmp_dir]) end)

    review = Application.get_env(:foreman_server, :review, [])

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(review, capture: true, archive_root: Path.join(tmp_dir, "archive"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :review, review) end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

    project_id = "libdel-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: repo, config: %{}}
      })

    src = Path.join(tmp_dir, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "spec.md"), "LIBRARY-SECRET-CONTENT")

    %{project_id: project_id, repo: repo, src: src, archive_root: Path.join(tmp_dir, "archive")}
  end

  defp add!(ctx) do
    {:ok, _} = Library.add(ctx.project_id, {:folder, ctx.src}, %{name: "specs"}, @operator)
  end

  defp host_dir(ctx), do: Path.expand(Path.join(ctx.repo, ".foreman/library"))

  describe "delivery/2" do
    test "an empty library delivers nothing", ctx do
      assert %{env: env, mounts: []} = Library.delivery(ctx.project_id, :docker)
      assert env == %{}
      assert Library.delivery(ctx.project_id, :host) == %{env: %{}, mounts: []}
      assert Library.delivery(nil, :docker) == %{env: %{}, mounts: []}
    end

    test "docker gets a read-only mount at /library; host gets the absolute path", ctx do
      add!(ctx)

      assert %{
               env: %{"FOREMAN_LIBRARY_PATH" => "/library"},
               mounts: [%{host_path: host, sandbox_path: "/library", readonly?: true}]
             } = Library.delivery(ctx.project_id, :docker)

      assert host == host_dir(ctx)

      assert %{env: %{"FOREMAN_LIBRARY_PATH" => path}, mounts: []} =
               Library.delivery(ctx.project_id, :host)

      assert path == host_dir(ctx)
    end
  end

  describe "workflow door" do
    defp launch_env(project_id) do
      state = %{
        run_id: "run-lib",
        plan_context: %{},
        task: %{task_id: "t1", project_id: project_id},
        completed: [],
        phase_specs: [],
        artifact_base: System.tmp_dir!()
      }

      {:ok, launch} =
        RunExecutor.__prepare_agent_launch_for_test__(state, %{name: :implement}, 0, 1, nil)

      Keyword.fetch!(launch.launch_opts, :env_map)
    end

    test "the launch env has FOREMAN_LIBRARY_PATH only when the library is non-empty", ctx do
      refute Map.has_key?(launch_env(ctx.project_id), "FOREMAN_LIBRARY_PATH")

      {:ok, %{entry: entry}} = add!(ctx)
      assert launch_env(ctx.project_id)["FOREMAN_LIBRARY_PATH"] == host_dir(ctx)

      {:ok, _} = Library.remove(ctx.project_id, entry.entry_id, @operator)
      refute Map.has_key?(launch_env(ctx.project_id), "FOREMAN_LIBRARY_PATH")
    end
  end

  describe "standing context" do
    test "the library section lists entries and never inlines file content", ctx do
      assert :skip = LibrarySection.section(ctx.project_id)
      add!(ctx)

      assert {:ok, %{id: :library, title: "Project library", body: body}} =
               LibrarySection.section(ctx.project_id)

      assert body =~ "specs"
      assert body =~ "spec.md"
      assert body =~ "read-only"
      refute body =~ "LIBRARY-SECRET-CONTENT"
    end

    test "ProjectContext.build includes the section by default and omits it when empty", ctx do
      assert {:ok, %{system_text: nil}} = ProjectContext.build(ctx.project_id)

      add!(ctx)
      assert {:ok, %{system_text: text}} = ProjectContext.build(ctx.project_id)
      assert text =~ "Project library"
      assert text =~ "$FOREMAN_LIBRARY_PATH"
    end
  end

  describe "jobsite door (host sandbox, real run)" do
    defp run_echo(ctx) do
      agent =
        Agents.pi("x",
          binary: @fake_agent,
          env: %{"FAKE_AGENT_ECHO_ENV" => "FOREMAN_LIBRARY_PATH"}
        )

      {:ok, %{jobsite_id: id}} =
        Jobsite.run(
          repo_path: ctx.repo,
          strategy: :merge_to_head,
          sandbox: Sandboxes.host(),
          agent: agent,
          prompt: "go",
          project_id: ctx.project_id
        )

      Path.join([ctx.archive_root, "jobsite", id])
    end

    test "the agent sees the library path and nothing is written into the worktree", ctx do
      add!(ctx)
      archive = run_echo(ctx)

      transcript = File.read!(Path.join(archive, "transcript.jsonl"))
      assert transcript =~ "env:FOREMAN_LIBRARY_PATH=#{host_dir(ctx)}"

      diff = File.read!(Path.join(archive, "diff.patch"))
      refute diff =~ "LIBRARY-SECRET-CONTENT"
      refute diff =~ "spec.md"
    end

    test "an empty library leaves the variable unset", ctx do
      archive = run_echo(ctx)
      transcript = File.read!(Path.join(archive, "transcript.jsonl"))
      assert transcript =~ "env:FOREMAN_LIBRARY_PATH="
      refute transcript =~ host_dir(ctx)
    end
  end
end
