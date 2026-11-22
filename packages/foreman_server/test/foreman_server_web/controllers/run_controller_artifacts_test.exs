defmodule ForemanServerWeb.RunControllerArtifactsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Events.{PhaseCompleted, PhaseStarted}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunArtifacts
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Workflow.RunExecutor

  @endpoint ForemanServerWeb.Endpoint
  @token "run-artifacts-token"

  # Every test gets a scratch directory and HOME points into it: the root the server resolves a
  # run's archive under (`RunExecutor.artifact_base/0`, `~/.foreman/runs`) is scratch space too,
  # so no test reads or writes the real one.
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    previous_home = System.get_env("HOME")
    System.put_env("HOME", Path.join(dir, "home"))

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)

      if previous_home == nil,
        do: System.delete_env("HOME"),
        else: System.put_env("HOME", previous_home)
    end)

    :ok
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  defp apply!(type, event),
    do: :ok = ProjectionStore.apply_events([%{event_type: type, payload: Map.from_struct(event)}])

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp start_phase!(run_id, index, name) do
    phase_id = "#{run_id}-p00#{index}"

    apply!("PhaseStarted", %PhaseStarted{
      phase_id: phase_id,
      run_id: run_id,
      index: index,
      name: name,
      attempt: 1,
      artifact_template: "{task.projectReportsDir}/#{name}.md",
      input_artifacts: []
    })

    phase_id
  end

  defp complete_phase!(run_id, index, path, sha256, bytes) do
    apply!("PhaseCompleted", %PhaseCompleted{
      phase_id: "#{run_id}-p00#{index}",
      run_id: run_id,
      index: index,
      artifact_path: path,
      artifact_sha256: sha256,
      artifact_bytes: bytes
    })
  end

  # One run with a single completed phase whose recorded artifact is `path`.
  defp run_with_artifact!(path, sha256, bytes) do
    %{run_id: run_id} = Support.start_run!()
    phase_id = start_phase!(run_id, 1, "fix")
    complete_phase!(run_id, 1, path, sha256, bytes)
    {run_id, phase_id}
  end

  defp write_fixture!(dir, content) do
    path = Path.join(dir, "phase-1.md")
    File.write!(path, content)
    path
  end

  test "lists only the phases that recorded an artifact, in workflow order, with only the contract keys" do
    %{run_id: run_id} = Support.start_run!()
    start_phase!(run_id, 2, "review")
    start_phase!(run_id, 1, "fix")
    start_phase!(run_id, 3, "merge")
    complete_phase!(run_id, 2, "reports/review.md", "bbb", 7)
    complete_phase!(run_id, 1, "reports/fix.md", "aaa", 3)

    assert %{"run_id" => ^run_id, "artifacts" => [fix, review]} =
             get_json("/api/runs/#{run_id}/artifacts", 200)

    assert %{
             "name" => "fix",
             "index" => 1,
             "attempt" => 1,
             "status" => "completed",
             "path" => "reports/fix.md",
             "sha256" => "aaa",
             "bytes" => 3
           } = fix

    assert fix["phase_id"] == "#{run_id}-p001"
    assert %{"name" => "review", "index" => 2} = review

    assert Enum.sort(Map.keys(fix)) ==
             Enum.sort(~w(phase_id index name attempt status path sha256 bytes))
  end

  test "a run with no recorded artifact lists none, an unknown run is a 404" do
    %{run_id: run_id} = Support.start_run!()

    assert %{"run_id" => ^run_id, "artifacts" => []} =
             get_json("/api/runs/#{run_id}/artifacts", 200)

    start_phase!(run_id, 1, "fix")

    assert %{"artifacts" => []} = get_json("/api/runs/#{run_id}/artifacts", 200)

    assert %{"error" => "run_not_found", "run_id" => "run-nope"} =
             get_json("/api/runs/run-nope/artifacts", 404)

    assert %{"error" => "run_not_found", "run_id" => "run-nope"} =
             get_json("/api/runs/run-nope/artifacts/p1", 404)
  end

  @tag :tmp_dir
  test "reads the recorded file; sha_matches is true for the recorded hash", %{tmp_dir: dir} do
    content = "# Fix report\n\nall good ✓\n"
    path = write_fixture!(dir, content)
    {run_id, phase_id} = run_with_artifact!(path, sha(content), byte_size(content))

    body = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

    assert %{
             "run_id" => ^run_id,
             "phase_id" => ^phase_id,
             "index" => 1,
             "name" => "fix",
             "path" => ^path,
             "bytes" => bytes,
             "state" => "ok",
             "source" => "recorded",
             "content" => ^content,
             "truncated" => false,
             "sha_matches" => true,
             "error" => nil
           } = body

    assert bytes == byte_size(content)
    assert body["content_bytes"] == byte_size(content)
    assert body["sha256"] == sha(content)

    assert Enum.sort(Map.keys(body)) ==
             Enum.sort(
               ~w(run_id phase_id index name path sha256 bytes state source content content_bytes truncated sha_matches error)
             )
  end

  @tag :tmp_dir
  test "sha_matches is false when the file no longer hashes to the recorded value", %{
    tmp_dir: dir
  } do
    path = write_fixture!(dir, "edited after the phase finished")
    {run_id, phase_id} = run_with_artifact!(path, sha("what the phase wrote"), 20)

    assert %{
             "state" => "ok",
             "content" => "edited after the phase finished",
             "sha_matches" => false
           } =
             get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
  end

  @tag :tmp_dir
  test "invalid UTF-8 bytes are replaced", %{tmp_dir: dir} do
    raw = "ab" <> <<0xFF>> <> "cd"
    path = write_fixture!(dir, raw)
    {run_id, phase_id} = run_with_artifact!(path, sha(raw), byte_size(raw))

    assert %{"state" => "ok", "content" => "ab\uFFFDcd", "sha_matches" => true} =
             get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
  end

  @tag :tmp_dir
  test "a file at the cap is whole, a longer one is cut on a UTF-8 boundary and hashed in full",
       %{tmp_dir: dir} do
    cap = RunArtifacts.max_content_bytes()
    assert cap == 262_144

    exact = String.duplicate("a", cap)
    path = write_fixture!(dir, exact)
    {run_id, phase_id} = run_with_artifact!(path, sha(exact), cap)

    assert %{"truncated" => false, "content_bytes" => ^cap, "sha_matches" => true} =
             get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

    # "é" is two bytes and straddles the cap: its first byte is byte `cap`.
    straddling = String.duplicate("a", cap - 1) <> "é" <> "tail"
    path = write_fixture!(dir, straddling)
    {run_id, phase_id} = run_with_artifact!(path, sha(straddling), byte_size(straddling))

    body = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

    assert body["state"] == "ok"
    assert body["truncated"] == true
    assert body["content"] == String.duplicate("a", cap - 1)
    assert body["content_bytes"] == cap - 1
    assert String.valid?(body["content"])
    # The hash covers the whole file, not the returned part.
    assert body["sha_matches"] == true
    assert body["bytes"] == byte_size(straddling)

    # A character that ends exactly at the cap is kept.
    fits = String.duplicate("a", cap - 2) <> "é" <> "tail"
    path = write_fixture!(dir, fits)
    {run_id, phase_id} = run_with_artifact!(path, sha(fits), byte_size(fits))

    body = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    assert body["truncated"] == true
    assert body["content"] == String.duplicate("a", cap - 2) <> "é"
    assert body["content_bytes"] == cap
  end

  @tag :tmp_dir
  test "invalid bytes that grow past the cap are cut back to the cap", %{tmp_dir: dir} do
    cap = RunArtifacts.max_content_bytes()
    raw = String.duplicate(<<0xFF>>, cap)
    path = write_fixture!(dir, raw)
    {run_id, phase_id} = run_with_artifact!(path, sha(raw), cap)

    body = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

    assert body["truncated"] == true
    assert body["content_bytes"] <= cap
    assert String.valid?(body["content"])
    assert String.starts_with?(body["content"], "\uFFFD")
  end

  @tag :tmp_dir
  test "a file that is gone is state missing, still a 200", %{tmp_dir: dir} do
    path = Path.join(dir, "cleaned-up.md")
    {run_id, phase_id} = run_with_artifact!(path, sha("x"), 1)

    assert %{
             "state" => "missing",
             "source" => "recorded",
             "content" => nil,
             "content_bytes" => 0,
             "truncated" => false,
             "sha_matches" => nil,
             "error" => error,
             "path" => ^path
           } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

    assert is_binary(error) and error != ""
  end

  @tag :tmp_dir
  test "a path that cannot be read is state unreadable with the posix reason", %{tmp_dir: dir} do
    {run_id, phase_id} = run_with_artifact!(dir, sha("x"), 1)

    assert %{
             "state" => "unreadable",
             "source" => "recorded",
             "content" => nil,
             "sha_matches" => nil,
             "error" => "eisdir"
           } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
  end

  test "an unknown phase and a phase without an artifact are 404s" do
    %{run_id: run_id} = Support.start_run!()
    phase_id = start_phase!(run_id, 1, "fix")

    assert %{"error" => "artifact_not_found", "run_id" => ^run_id, "phase_id" => ^phase_id} =
             get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 404)

    assert %{"error" => "phase_not_found", "run_id" => ^run_id, "phase_id" => "nope"} =
             get_json("/api/runs/#{run_id}/artifacts/nope", 404)
  end

  @tag :tmp_dir
  test "a phase_id is only matched against the run's phases, never turned into a path", %{
    tmp_dir: dir
  } do
    secret = Path.join(dir, "secret.txt")
    File.write!(secret, "do not serve")
    reports = Path.join(dir, "reports")
    File.mkdir_p!(reports)
    path = Path.join(reports, "phase-1.md")
    File.write!(path, "the report")
    {run_id, phase_id} = run_with_artifact!(path, sha("the report"), 10)

    for hostile <- [
          "..%2Fsecret.txt",
          "..%2F..%2Fsecret.txt",
          URI.encode_www_form(secret),
          URI.encode_www_form(Path.join(["..", "secret.txt"])),
          "#{phase_id}%2F..%2Fsecret.txt"
        ] do
      assert %{"error" => "phase_not_found"} =
               get_json("/api/runs/#{run_id}/artifacts/#{hostile}", 404)
    end

    assert %{"content" => "the report", "path" => ^path} =
             get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
  end

  test "a recorded artifact without a path is a broken projection, not an empty artifact" do
    assert_raise CaseClauseError, fn ->
      RunArtifacts.list("run-x", [
        %{
          phase_id: "p1",
          index: 1,
          name: "fix",
          attempt: 1,
          status: "completed",
          artifact: %{path: nil, sha256: "a", bytes: 1}
        }
      ])
    end
  end

  describe "the archive copy, when the recorded file is gone" do
    # Written by the function the executor uses, at the root the server's reader resolves.
    defp archive!(run_id, index, recorded_path, sha256) do
      assert {:ok, archived} =
               RunArtifacts.archive(
                 RunExecutor.artifact_base(),
                 run_id,
                 index,
                 recorded_path,
                 sha256
               )

      archived
    end

    # One completed phase (index 1) whose report was archived from `content` and then removed, as
    # a reclaimed worktree removes it.
    defp reclaimed_report!(dir, content) do
      path = write_fixture!(dir, content)
      {run_id, phase_id} = run_with_artifact!(path, sha(content), byte_size(content))
      archive!(run_id, 1, path, sha(content))
      File.rm!(path)
      {run_id, phase_id, path}
    end

    test "is served, judged against the recorded digest", %{tmp_dir: dir} do
      content = "# Fix report\n\nwritten in a worktree that is gone ✓\n"
      {run_id, phase_id, path} = reclaimed_report!(dir, content)
      refute File.exists?(path)

      body = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)

      assert %{
               "state" => "ok",
               "source" => "archive",
               "content" => ^content,
               "content_bytes" => content_bytes,
               "truncated" => false,
               "sha_matches" => true,
               "error" => nil,
               "path" => ^path
             } = body

      assert content_bytes == byte_size(content)
      assert body["sha256"] == sha(content)
    end

    test "never beats the recorded file: when both exist the recorded one is read", %{
      tmp_dir: dir
    } do
      recorded = "the report the phase recorded"
      path = write_fixture!(dir, "the report of an earlier attempt")
      {run_id, phase_id} = run_with_artifact!(path, sha(recorded), byte_size(recorded))
      archive!(run_id, 1, path, sha("the report of an earlier attempt"))
      File.write!(path, recorded)

      assert %{
               "state" => "ok",
               "source" => "recorded",
               "content" => ^recorded,
               "sha_matches" => true
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "replaces a recorded file that changed since the phase with the verified copy", %{
      tmp_dir: dir
    } do
      written = "what the phase wrote"
      path = write_fixture!(dir, written)
      {run_id, phase_id} = run_with_artifact!(path, sha(written), byte_size(written))
      archive!(run_id, 1, path, sha(written))
      File.write!(path, "overwritten by a later run of the task")

      assert %{
               "state" => "ok",
               "source" => "archive",
               "content" => ^written,
               "sha_matches" => true
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "shows a changed recorded file with its digest saying so when no verified copy exists",
         %{
           tmp_dir: dir
         } do
      written = "what the phase wrote"
      path = write_fixture!(dir, "overwritten by a later run of the task")
      {run_id, phase_id} = run_with_artifact!(path, sha(written), byte_size(written))

      assert %{
               "state" => "ok",
               "source" => "recorded",
               "content" => "overwritten by a later run of the task",
               "sha_matches" => false
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "is judged against the recorded digest, so a copy of another attempt says it differs",
         %{tmp_dir: dir} do
      path = write_fixture!(dir, "attempt one")
      {run_id, phase_id} = run_with_artifact!(path, sha("attempt two"), 11)
      archive!(run_id, 1, path, sha("attempt one"))
      File.rm!(path)

      assert %{
               "state" => "ok",
               "source" => "archive",
               "content" => "attempt one",
               "sha_matches" => false
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "that cannot be read is state unreadable from the archive, not missing", %{tmp_dir: dir} do
      path = Path.join(dir, "cleaned-up.md")
      {run_id, phase_id} = run_with_artifact!(path, sha("x"), 1)
      # A directory where the copy should be.
      File.mkdir_p!(RunArtifacts.archive_path(RunExecutor.artifact_base(), run_id, 1))

      assert %{
               "state" => "unreadable",
               "source" => "archive",
               "content" => nil,
               "sha_matches" => nil,
               "error" => "eisdir"
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "is cut at the cap like a recorded file and still hashed whole", %{tmp_dir: dir} do
      cap = RunArtifacts.max_content_bytes()
      {run_id, phase_id, _path} = reclaimed_report!(dir, String.duplicate("a", cap + 10))

      assert %{
               "source" => "archive",
               "truncated" => true,
               "content_bytes" => ^cap,
               "sha_matches" => true
             } = get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end

    test "is only ever found through the run's own phases, never through a phase_id", %{
      tmp_dir: dir
    } do
      {run_id, phase_id, _path} = reclaimed_report!(dir, "the archived report")
      archived = RunArtifacts.archive_path(RunExecutor.artifact_base(), run_id, 1)
      secret = Path.join(dir, "secret.txt")
      File.write!(secret, "do not serve")

      for hostile <- [
            "phase-1.md",
            "archive%2Fphase-1.md",
            "#{run_id}%2Farchive%2Fphase-1.md",
            "..%2F#{run_id}%2Farchive%2Fphase-1.md",
            URI.encode_www_form(archived),
            URI.encode_www_form(secret)
          ] do
        assert %{"error" => "phase_not_found"} =
                 get_json("/api/runs/#{run_id}/artifacts/#{hostile}", 404)
      end

      assert %{"content" => "the archived report", "source" => "archive"} =
               get_json("/api/runs/#{run_id}/artifacts/#{phase_id}", 200)
    end
  end
end
