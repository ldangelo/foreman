defmodule ForemanServer.Jobsite.SessionArchiveTest do
  # A real jobsite run (real git repo, host sandbox, fake Pi-shaped agent CLI)
  # with capture on must leave a session archive on disk: the verbatim request,
  # the agent's events, the delivered diff and a manifest naming the provider
  # session. `bead_id` must reach the JobsiteStarted projection.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  setup %{tmp_dir: tmp_dir} do
    original = Application.get_env(:foreman_server, :review, [])

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: true, archive_root: Path.join(tmp_dir, "archive"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :review, original) end)

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

  defp run(repo, extra) do
    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{"FAKE_AGENT_TEXT" => "did some work", "FAKE_AGENT_SESSION_ID" => "sess-archive-1"}
      )

    Jobsite.run(
      [
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "Implement the thing"
      ] ++ extra
    )
  end

  defp wait_until(fun, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(25)
        do_wait_until(fun, deadline)
    end
  end

  test "a captured run writes request, transcript, diff and a manifest with the session id",
       %{repo: repo, archive_root: root} do
    assert {:ok, %{jobsite_id: id}} =
             run(repo, bead_id: "bd-42", name: "archived", project_id: "proj-x")

    dir = Path.join([root, "jobsite", id])

    assert File.read!(Path.join(dir, "request.md")) == "Implement the thing"

    transcript =
      dir
      |> Path.join("transcript.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert transcript != []
    assert Enum.any?(transcript, &(&1["text"] == "did some work"))

    assert File.read!(Path.join(dir, "diff.patch")) =~ "agent-log.txt"
    assert File.read!(Path.join(dir, "changed-files.txt")) =~ "agent-log.txt"

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["kind"] == "jobsite"
    assert manifest["subject_id"] == id
    assert manifest["bead_id"] == "bd-42"
    assert manifest["project_id"] == "proj-x"
    assert manifest["provider_session_ids"] == ["sess-archive-1"]
    assert manifest["diff_status"] == "captured"
    assert manifest["request"]["prompt"] == "Implement the thing"

    assert %{bead_id: "bd-42", project_id: "proj-x", repo_path: ^repo} = Jobsite.get(id)
  end

  test "capture off writes nothing", %{repo: repo, archive_root: root} do
    original = Application.get_env(:foreman_server, :review)
    Application.put_env(:foreman_server, :review, Keyword.put(original, :capture, false))

    assert {:ok, %{jobsite_id: id}} = run(repo, [])

    refute File.exists?(Path.join([root, "jobsite", id]))
  end

  test "cancel archives the working-tree diff before the worktree is discarded", %{
    repo: repo,
    archive_root: root
  } do
    # The fake agent appends to `agent-log.txt` before it sleeps. Committing that
    # file in the base makes the append an UNCOMMITTED edit of a TRACKED file.
    # Its `agent-invocations.count` is a NEW untracked file and is included too.
    File.write!(Path.join(repo, "agent-log.txt"), "base log\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "track log"])

    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{"FAKE_AGENT_SLEEP_ON_RUN" => "1", "FAKE_AGENT_SLEEP_SECS" => "30"}
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "Original request",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    dir = Path.join([root, "jobsite", id])

    # The agent is mid-iteration once it has written into the jobsite's worktree.
    wait_until(fn -> worktree_with_agent_log(repo) != nil end)
    worktree = worktree_with_agent_log(repo)
    refute File.exists?(Path.join(dir, "diff.patch"))

    assert :ok = Jobsite.cancel(id, "stop")
    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "cancelled" end, 25_000)

    refute File.exists?(worktree)

    patch = File.read!(Path.join(dir, "diff.patch"))
    assert patch =~ "agent-log.txt"
    assert patch =~ "+fake agent ran (invocation 1)"
    assert patch =~ "agent-invocations.count"
    assert File.read!(Path.join(dir, "changed-files.txt")) =~ "agent-log.txt"

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["diff_status"] == "captured"
    assert manifest["request"]["prompt"] == "Original request"
  end

  test "a failed run archives the working-tree diff before the worktree is discarded", %{
    repo: repo,
    archive_root: root
  } do
    # The fake agent writes `agent-log.txt` into its worktree, then dies. Nothing
    # was committed (merge_to_head discards the worktree and its branch on
    # failure), so only a working-tree diff taken before the discard has it.
    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{"FAKE_AGENT_FAIL_WITH" => "Credit balance is too low"}
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "Original request"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "failed" end, 25_000)

    dir = Path.join([root, "jobsite", id])
    patch = File.read!(Path.join(dir, "diff.patch"))
    assert patch =~ "+fake agent ran (invocation 1)"
    assert File.read!(Path.join(dir, "changed-files.txt")) =~ "agent-log.txt"

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["diff_status"] == "captured"
    assert manifest["capture_errors"] == []
  end

  # The linked worktree (not the main checkout) holding the fake agent's log, if any.
  defp worktree_with_agent_log(repo) do
    {out, 0} = System.cmd("git", ["-C", repo, "worktree", "list", "--porcelain"])

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _ -> []
    end)
    |> Enum.reject(&(&1 == repo or Path.expand(&1) == Path.expand(repo)))
    |> Enum.find(fn path ->
      case File.read(Path.join(path, "agent-log.txt")) do
        {:ok, log} -> log =~ "invocation 1"
        _ -> false
      end
    end)
  end

  test "resume appends to the same archive without reopening it", %{
    repo: repo,
    archive_root: root
  } do
    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{
          "FAKE_AGENT_SESSION_ID" => "sess-first",
          "FAKE_AGENT_SLEEP_ON_RUN" => "2",
          "FAKE_AGENT_SLEEP_SECS" => "30"
        }
      )

    {:ok, id} =
      Jobsite.run_async(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "Original request",
        max_iterations: 3,
        completion_signal: "NEVER"
      )

    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 2 end)
    assert :ok = Jobsite.pause(id, "pause for resume")
    wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)
    # `paused` is projected before the executor process exits: resuming in that
    # gap is correctly refused as :already_running, so wait for it to be gone.
    wait_until(fn -> ForemanServer.Jobsite.Executor.pid_for(id) == nil end)

    dir = Path.join([root, "jobsite", id])
    request_before = File.read!(Path.join(dir, "request.md"))
    assert request_before == "Original request"
    transcript_before = File.read!(Path.join(dir, "transcript.jsonl"))
    refute File.exists?(Path.join(dir, "diff.patch"))

    assert {:ok, _result} = Jobsite.resume(id)

    assert File.read!(Path.join(dir, "request.md")) == request_before

    transcript_after = File.read!(Path.join(dir, "transcript.jsonl"))
    assert String.starts_with?(transcript_after, transcript_before)
    assert byte_size(transcript_after) > byte_size(transcript_before)

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert "sess-first" in manifest["provider_session_ids"]
    assert "fake-session-stable-1" in manifest["provider_session_ids"]
    assert manifest["request"]["prompt"] == "Original request"
    assert File.read!(Path.join(dir, "diff.patch")) =~ "agent-log.txt"
  end
end
