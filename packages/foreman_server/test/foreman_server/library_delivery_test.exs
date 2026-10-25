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

  describe "docker sandbox argv" do
    test "the library mount reaches `docker run` as a read-only bind mount at /library", ctx do
      add!(ctx)
      # The test's tmp_dir name contains backticks, which a shell script would
      # execute, so the fake binary lives under a plain temp path.
      work = Path.join(System.tmp_dir!(), "e5-docker-#{System.unique_integer([:positive])}")
      File.mkdir_p!(work)
      on_exit(fn -> File.rm_rf!(work) end)
      log = Path.join(work, "args.log")
      fake = Path.join(work, "fake-docker")

      File.write!(fake, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> "#{log}"; done
      echo fake-container
      """)

      File.chmod!(fake, 0o755)
      %{mounts: mounts} = Library.delivery(ctx.project_id, :docker)

      worktree = %{path: ctx.repo, repo_path: ctx.repo}

      assert {:ok, _state, _sandbox_path, _container} =
               ForemanServer.Jobsite.Sandboxes.Docker.create(
                 %{binary: fake, image: "img", mounts: mounts, uid: "1", gid: "1"},
                 worktree
               )

      args = log |> File.read!() |> String.split("\n", trim: true)
      assert "#{host_dir(ctx)}:/library:ro" in args
    end
  end

  describe "jobsite resume" do
    test "a resumed docker-less jobsite still gets FOREMAN_LIBRARY_PATH", ctx do
      add!(ctx)
      # The agent env is not persisted across a pause, so the resumed agent only sees
      # the library variable if resume re-derives it. This agent reports it on every
      # run after the first (the first one holds long enough to be paused).
      script = Path.join(ctx.tmp_dir, "env-agent.sh")

      File.write!(script, """
      #!/bin/sh
      n=0
      [ -f agent-count ] && n=$(cat agent-count)
      n=$((n + 1))
      echo $n > agent-count
      printf '{"type":"session","id":"s1"}\\n'
      [ "$n" = "1" ] && sleep 20
      T="lib=$(printenv FOREMAN_LIBRARY_PATH || true)"
      printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"%s"}}\\n' "$T"
      printf '{"type":"message_end","message":{"role":"assistant","content":"%s","usage":{"input_tokens":1,"output_tokens":1}}}\\n' "$T"
      """)

      File.chmod!(script, 0o755)

      {:ok, id} =
        Jobsite.run_async(
          repo_path: ctx.repo,
          strategy: :merge_to_head,
          sandbox: Sandboxes.host(),
          agent: Agents.pi("x", binary: script),
          prompt: "go",
          project_id: ctx.project_id,
          max_iterations: 3,
          completion_signal: "NEVER"
        )

      await_until(fn -> (Jobsite.get(id) || %{})[:status] == "running" end)
      # A resume needs the provider session the agent reported (foreman-cm8nv).
      ForemanServer.TestSupport.JobsiteSession.await!(id)
      assert :ok = Jobsite.pause(id, "for resume")
      await_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)
      await_until(fn -> ForemanServer.Jobsite.Executor.pid_for(id) == nil end)

      assert {:ok, _} = Jobsite.resume(id)

      transcript = File.read!(Path.join([ctx.archive_root, "jobsite", id, "transcript.jsonl"]))
      assert transcript =~ "lib=#{host_dir(ctx)}"
    end

    defp await_until(fun, tries \\ 400) do
      cond do
        fun.() ->
          :ok

        tries == 0 ->
          flunk("condition never became true")

        true ->
          receive do
          after
            25 -> await_until(fun, tries - 1)
          end
      end
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
