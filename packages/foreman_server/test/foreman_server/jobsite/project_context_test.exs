defmodule ForemanServer.Jobsite.ProjectContextTest do
  # Standing project context reaches the REAL `Jido.Harness.RunRequest` of a
  # jobsite agent iteration (real git repo, host sandbox, recording provider
  # adapter in place of the CLI), and is archived next to the request.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Identity
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defmodule Recorder do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "jobsite project-context recorder",
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

    @impl true
    def run(request, context) do
      send(Application.fetch_env!(:jido_harness, :jobsite_context_test_pid), {:request, request})

      # A prompt of "hold" keeps the run open until the test releases it: the
      # stub reports its pid, then blocks on an explicit release message.
      if request.prompt == "hold" do
        send(Application.fetch_env!(:jido_harness, :jobsite_context_test_pid), {:held, self()})

        # What a real agent does as its first event: report the provider session. A jobsite can
        # only be resumed once that is on record (foreman-cm8nv); the harness folds a
        # `run_started` carrying the id into the run's own state, where the executor reads it.
        send(
          context.run_owner,
          {:adapter_event,
           Event.new!(
             provider: :pi,
             type: :run_started,
             provider_session_id: "context-test-session",
             payload: %{}
           )}
        )

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

  defmodule Unsupported do
    @behaviour Adapter

    @impl true
    def spec, do: %{Recorder.spec() | normalized_options: [:model]}
    @impl true
    defdelegate status(config), to: Recorder
    @impl true
    defdelegate run(request, context), to: Recorder
  end

  setup %{tmp_dir: tmp_dir} do
    ProjectionStoreReset.reset!()

    review = Application.get_env(:foreman_server, :review, [])
    providers = Application.get_env(:jido_harness, :providers, %{})

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(review, capture: true, archive_root: Path.join(tmp_dir, "archive"))
    )

    Application.put_env(:jido_harness, :providers, %{pi: Recorder})
    Application.put_env(:jido_harness, :jobsite_context_test_pid, self())

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, review)
      Application.put_env(:jido_harness, :providers, providers)
      Application.delete_env(:jido_harness, :jobsite_context_test_pid)
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

    {:ok, repo: repo, archive_root: Path.join(tmp_dir, "archive")}
  end

  defp register(id, config, path) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: id, path: path, config: config}
        }
      ])
  end

  defp await(fun, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.reduce_while(nil, fn
      true, _ ->
        {:halt, :ok}

      false, _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("await timed out"),
          else:
            (
              Process.sleep(25)
              {:cont, nil}
            )
    end)
  end

  defp run(repo, extra) do
    Jobsite.run(
      [
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: Agents.pi("x", binary: @fake_agent),
        prompt: "Implement the thing"
      ] ++ extra
    )
  end

  test "instructions reach RunRequest.system_prompt and are archived verbatim", %{
    repo: repo,
    archive_root: root
  } do
    register("jc-1", %{instructions: "Never touch vendor/"}, repo)

    assert {:ok, %{jobsite_id: id}} = run(repo, project_id: "jc-1")
    assert_receive {:request, request}

    assert request.system_prompt =~ "Never touch vendor/"
    assert request.prompt == "Implement the thing"

    dir = Path.join([root, "jobsite", id])
    assert File.read!(Path.join(dir, "project-context.md")) == request.system_prompt

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    assert %{"sha256" => sha, "bytes" => bytes, "truncated" => []} = manifest["project_context"]
    assert sha == Identity.sha256(request.system_prompt)
    assert bytes == byte_size(request.system_prompt)
  end

  test "a project without context sends no system_prompt and archives no context file", %{
    repo: repo,
    archive_root: root
  } do
    register("jc-2", %{}, repo)

    assert {:ok, %{jobsite_id: id}} = run(repo, project_id: "jc-2")
    assert_receive {:request, request}

    assert request.system_prompt == nil
    refute File.exists?(Path.join([root, "jobsite", id, "project-context.md"]))
  end

  test "an unregistered or absent project runs normally without context", %{repo: repo} do
    assert {:ok, _} = run(repo, project_id: "never-registered")
    assert_receive {:request, %{system_prompt: nil}}

    assert {:ok, _} = run(repo, [])
    assert_receive {:request, %{system_prompt: nil}}
  end

  test "every iteration of one jobsite carries the same system_prompt", %{repo: repo} do
    register("jc-3", %{instructions: "Stable rules"}, repo)

    assert {:ok, _} = run(repo, project_id: "jc-3", max_iterations: 2)
    assert_receive {:request, first}
    assert_receive {:request, second}

    assert first.system_prompt =~ "Stable rules"
    assert second.system_prompt == first.system_prompt
  end

  test "a resumed jobsite re-sends the project context", %{repo: repo} do
    register("jc-6", %{instructions: "Resume rules"}, repo)

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: Agents.pi("x", binary: @fake_agent),
        prompt: "hold",
        project_id: "jc-6",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    assert_receive {:request, %{system_prompt: first}}, 5_000
    assert_receive {:held, held_pid}, 5_000
    ForemanServer.TestSupport.JobsiteSession.await!(id)
    assert first =~ "Resume rules"

    assert :ok = Jobsite.pause(id, "pause for resume")
    await(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)
    await(fn -> ForemanServer.Jobsite.Executor.pid_for(id) == nil end)

    assert {:ok, _result} = Jobsite.resume(id)
    send(held_pid, :release)
    assert_receive {:request, %{system_prompt: resumed, prompt: "Continue."}}, 5_000
    assert resumed == first
  end

  test "capture off still delivers context but writes no archive", %{
    repo: repo,
    archive_root: root
  } do
    original = Application.get_env(:foreman_server, :review)
    Application.put_env(:foreman_server, :review, Keyword.put(original, :capture, false))
    register("jc-4", %{instructions: "Rules"}, repo)

    assert {:ok, %{jobsite_id: id}} = run(repo, project_id: "jc-4")
    assert_receive {:request, %{system_prompt: prompt}}
    assert prompt =~ "Rules"
    refute File.exists?(Path.join([root, "jobsite", id]))
  end

  test "a provider without system_prompt support gets the context prefixed to the prompt", %{
    repo: repo
  } do
    Application.put_env(:jido_harness, :providers, %{pi: Unsupported})
    register("jc-5", %{instructions: "Rules"}, repo)

    assert {:ok, _} = run(repo, project_id: "jc-5")
    assert_receive {:request, request}

    assert request.system_prompt == nil
    assert request.prompt =~ "Rules"
    assert String.ends_with?(request.prompt, "Implement the thing")
  end
end
