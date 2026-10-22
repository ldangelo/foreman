defmodule ForemanServer.Review.CaptureTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.Review.Error

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:foreman_server, :review, [])
    on_exit(fn -> Application.put_env(:foreman_server, :review, original) end)

    root = Path.join(tmp, "archive")

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: true, archive_root: root)
    )

    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "first"])
    base = git!(repo, ["rev-parse", "HEAD"])

    {:ok, repo: repo, base: base, original: original, root: root}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp spec(repo, extra \\ %{}) do
    Map.merge(
      %{
        repo_path: repo,
        strategy: {:branch, "feature/x"},
        agent: %{provider: :claude, model: "opus"},
        opts: [name: "my-jobsite"],
        bead_id: "bd-42"
      },
      extra
    )
  end

  defp run_result(session_id, texts) do
    events =
      for t <- texts do
        Jido.Harness.Event.new!(%{
          type: :output_text_final,
          provider: :claude,
          timestamp: "2026-01-01T00:00:00Z",
          payload: %{"text" => t}
        })
      end

    Jido.Harness.RunResult.new!(%{
      run_id: "r",
      provider: :claude,
      provider_session_id: session_id,
      status: :completed,
      events: events
    })
  end

  describe "open_jobsite/3" do
    test "writes verbatim request.md and a fully-keyed manifest", %{repo: repo, root: root} do
      prompt = "Do the thing\n\n  with   odd whitespace\n"
      assert :ok = Capture.open_jobsite("j-1", spec(repo), prompt)

      dir = Path.join([root, "jobsite", "j-1"])
      assert File.read!(Path.join(dir, "request.md")) == prompt

      {:ok, m} = Archive.read_manifest(dir)
      assert m["kind"] == "jobsite"
      assert m["subject_id"] == "j-1"
      assert m["repo_path"] == repo
      assert m["bead_id"] == "bd-42"

      assert m["request"] == %{
               "source" => "jobsite",
               "title" => "my-jobsite",
               "prompt" => prompt,
               "workflow_name" => nil
             }

      assert m["agent"] == %{"provider" => "claude", "model" => "opus"}
      assert m["strategy"] == "branch:feature/x"
      assert m["transcript_source"] == "harness_events"
      assert m["status"] == "running"
      assert {:ok, _, _} = DateTime.from_iso8601(m["started_at"])
      assert m["finished_at"] == nil
      assert m["provider_session_ids"] == []
      assert m["project_id"] == nil
    end

    test "bead_id is an explicit null when the spec has none", %{repo: repo, root: root} do
      spec = repo |> spec() |> Map.delete(:bead_id)
      assert :ok = Capture.open_jobsite("j-2", spec, "p")
      {:ok, m} = Archive.read_manifest(Path.join([root, "jobsite", "j-2"]))
      assert Map.has_key?(m, "bead_id") and m["bead_id"] == nil
    end

    test "is a no-op when capture is disabled", %{repo: repo, root: root, original: original} do
      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: false, archive_root: root)
      )

      assert :ok = Capture.open_jobsite("j-3", spec(repo), "p")
      refute File.exists?(root)
    end

    test "returns archive_write_failed when the archive cannot be created", %{
      repo: repo,
      tmp_dir: tmp,
      original: original
    } do
      blocker = Path.join(tmp, "blocker")
      File.write!(blocker, "i am a file")

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: true, archive_root: Path.join(blocker, "root"))
      )

      assert {:error, %Error{code: :archive_write_failed}} =
               Capture.open_jobsite("j-4", spec(repo), "p")
    end
  end

  describe "put_iteration/2" do
    setup %{repo: repo, root: root} do
      :ok = Capture.open_jobsite("j-it", spec(repo), "p")
      {:ok, dir: Path.join([root, "jobsite", "j-it"])}
    end

    test "appends events across iterations and de-duplicates session ids", %{dir: dir} do
      assert :ok = Capture.put_iteration(dir, run_result("sess-1", ["a", "b"]))
      assert :ok = Capture.put_iteration(dir, run_result("sess-1", ["c"]))
      assert :ok = Capture.put_iteration(dir, run_result("sess-2", ["d"]))
      assert :ok = Capture.put_iteration(dir, run_result(nil, ["e"]))

      texts =
        dir
        |> Path.join("transcript.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> Jason.decode!() |> Map.fetch!("text")))

      assert texts == ["a", "b", "c", "d", "e"]
      assert {:ok, %{"provider_session_ids" => ["sess-1", "sess-2"]}} = Archive.read_manifest(dir)
    end

    test "nil archive_dir is a no-op" do
      assert :ok = Capture.put_iteration(nil, run_result("s", ["x"]))
    end

    test "disabled capture writes nothing", %{dir: dir, original: original, root: root} do
      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: false, archive_root: root)
      )

      assert :ok = Capture.put_iteration(dir, run_result("s", ["x"]))
      refute File.exists?(Path.join(dir, "transcript.jsonl"))
      assert {:ok, %{"provider_session_ids" => []}} = Archive.read_manifest(dir)
    end

    test "a missing manifest is surfaced, not swallowed", %{tmp_dir: tmp} do
      assert {:error, %Error{code: :archive_missing}} =
               Capture.put_iteration(Path.join(tmp, "never-opened"), run_result("s", []))
    end
  end

  describe "put_diff/4" do
    setup %{repo: repo, root: root} do
      :ok = Capture.open_jobsite("j-diff", spec(repo), "p")
      {:ok, dir: Path.join([root, "jobsite", "j-diff"])}
    end

    test "captures diff and changed files", %{dir: dir, repo: repo, base: base} do
      File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
      git!(repo, ["commit", "-qam", "second"])

      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")
      assert File.read!(Path.join(dir, "diff.patch")) =~ "+two"
      assert File.read!(Path.join(dir, "changed-files.txt")) == "M\ta.txt\n"

      {:ok, m} = Archive.read_manifest(dir)
      assert m["diff_status"] == "captured"
      assert m["base_ref"] == base
      assert m["worktree_path"] == repo
      assert m["capture_errors"] == []
    end

    test "a committed env-derived secret is absent from diff.patch and changed-files.txt", %{
      dir: dir,
      repo: repo,
      base: base
    } do
      secret = "s3cr3t-Value-" <> Integer.to_string(System.unique_integer([:positive]))
      System.put_env("FOREMAN_REDACT_TEST_TOKEN", secret)
      on_exit(fn -> System.delete_env("FOREMAN_REDACT_TEST_TOKEN") end)

      File.write!(Path.join(repo, "a.txt"), "one\nTOKEN=#{secret}\n")
      File.write!(Path.join(repo, "leak-#{secret}.txt"), "x\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-qm", "agent commits the secret"])

      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")

      patch = File.read!(Path.join(dir, "diff.patch"))
      files = File.read!(Path.join(dir, "changed-files.txt"))
      assert patch =~ "+TOKEN=[REDACTED]"
      refute patch =~ secret
      assert files =~ "leak-[REDACTED].txt"
      refute files =~ secret
    end

    test "truncation never leaves a prefix of a secret: redaction runs before the cut", %{
      dir: dir,
      repo: repo,
      base: base,
      original: original,
      root: root
    } do
      secret = "pfx-secret-Value-" <> Integer.to_string(System.unique_integer([:positive]))
      System.put_env("FOREMAN_REDACT_TEST_TOKEN", secret)
      on_exit(fn -> System.delete_env("FOREMAN_REDACT_TEST_TOKEN") end)

      File.write!(Path.join(repo, "a.txt"), "one\nTOKEN=#{secret}\n")
      git!(repo, ["commit", "-qam", "secret"])

      {full, 0} = System.cmd("git", ["-C", repo, "diff", "#{base}..HEAD"])
      cut = :binary.match(full, secret) |> elem(0) |> Kernel.+(12)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: true, archive_root: root, max_diff_bytes: cut)
      )

      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")
      refute File.read!(Path.join(dir, "diff.patch")) =~ "pfx-secret"
    end

    test "an empty diff is recorded as empty, with files written", %{
      dir: dir,
      repo: repo,
      base: base
    } do
      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")
      assert File.read!(Path.join(dir, "diff.patch")) == ""
      assert {:ok, %{"diff_status" => "empty"}} = Archive.read_manifest(dir)
    end

    test "oversized diffs are truncated and the truncation is recorded", %{
      dir: dir,
      repo: repo,
      base: base,
      original: original,
      root: root
    } do
      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: true, archive_root: root, max_diff_bytes: 50)
      )

      File.write!(Path.join(repo, "a.txt"), String.duplicate("line\n", 100))
      git!(repo, ["commit", "-qam", "big"])

      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")
      assert byte_size(File.read!(Path.join(dir, "diff.patch"))) == 50

      {:ok, m} = Archive.read_manifest(dir)
      assert m["diff_status"] == "captured"

      assert [%{"stage" => "diff", "message" => "diff truncated at 50 bytes" <> _}] =
               m["capture_errors"]
    end

    test "git failure marks diff unavailable and records the error", %{dir: dir, repo: repo} do
      assert {:error, %Error{code: :diff_failed}} =
               Capture.put_diff(dir, repo, "nonexistent-ref", "HEAD")

      {:ok, m} = Archive.read_manifest(dir)
      assert m["diff_status"] == "unavailable"
      assert [%{"stage" => "diff", "code" => "diff_failed"}] = m["capture_errors"]
      refute File.exists?(Path.join(dir, "diff.patch"))
    end

    test "a failed capture with no archive yet still leaves a manifest explaining it", %{
      root: root,
      repo: repo
    } do
      dir = Path.join([root, "jobsite", "never-opened"])
      refute File.exists?(dir)

      assert {:error, %Error{}} = Capture.put_diff(dir, repo, "nonexistent-ref", "HEAD")

      {:ok, m} = Archive.read_manifest(dir)
      assert m["schema"] == "foreman.review.manifest.v1"
      assert m["kind"] == "jobsite"
      assert m["subject_id"] == "never-opened"
      assert m["diff_status"] == "unavailable"

      assert [%{"stage" => "diff", "code" => code, "message" => message}] = m["capture_errors"]
      assert code != "" and message != ""
    end

    test ":worktree head captures new files and records no error when they can be marked", %{
      dir: dir,
      repo: repo,
      base: base
    } do
      File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
      File.write!(Path.join(repo, "new.txt"), "brand new\n")

      assert :ok = Capture.put_diff(dir, repo, base, :worktree)

      patch = File.read!(Path.join(dir, "diff.patch"))
      assert patch =~ "+two"
      assert patch =~ "+brand new"

      assert dir
             |> Path.join("changed-files.txt")
             |> File.read!()
             |> String.split("\n", trim: true) ==
               ["M\ta.txt", "A\tnew.txt"]

      {:ok, m} = Archive.read_manifest(dir)
      assert m["diff_status"] == "captured"
      assert m["capture_errors"] == []
    end

    test "a failed intent-to-add is recorded and the tracked-file diff is still captured", %{
      dir: dir,
      repo: repo,
      base: base
    } do
      File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
      File.write!(Path.join(repo, "new.txt"), "brand new\n")
      # A held index lock makes `git add --intent-to-add` fail; `git diff` still reads.
      File.write!(Path.join([repo, ".git", "index.lock"]), "")

      assert :ok = Capture.put_diff(dir, repo, base, :worktree)

      # The tracked edit is archived; the new file the agent created cannot be.
      patch = File.read!(Path.join(dir, "diff.patch"))
      assert patch =~ "+two"
      refute patch =~ "new.txt"
      assert File.read!(Path.join(dir, "changed-files.txt")) == "M\ta.txt\n"

      # The manifest says the diff is partial instead of presenting it as complete.
      {:ok, m} = Archive.read_manifest(dir)
      assert m["diff_status"] == "captured"

      assert [%{"stage" => "intent_to_add", "code" => "diff_failed", "message" => message}] =
               m["capture_errors"]

      assert message =~ "new files are missing from the diff"
    end

    test "an option-like base never reaches git", %{dir: dir, repo: repo, tmp_dir: tmp} do
      target = Path.join(tmp, "pwned")

      assert {:error, %Error{code: :diff_failed}} =
               Capture.put_diff(dir, repo, "--output=" <> target, "HEAD")

      refute File.exists?(target)
    end

    test "nil archive_dir and disabled capture are no-ops", %{
      repo: repo,
      base: base,
      dir: dir,
      original: original,
      root: root
    } do
      assert :ok = Capture.put_diff(nil, repo, base, "HEAD")

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.merge(original, capture: false, archive_root: root)
      )

      assert :ok = Capture.put_diff(dir, repo, base, "HEAD")
      refute File.exists?(Path.join(dir, "diff.patch"))
    end
  end

  describe "request redaction" do
    test "an env-derived secret in the prompt is absent from request.md and the manifest", %{
      repo: repo,
      root: root
    } do
      secret = "req-secret-" <> Integer.to_string(System.unique_integer([:positive]))
      System.put_env("FOREMAN_REDACT_TEST_TOKEN", secret)
      on_exit(fn -> System.delete_env("FOREMAN_REDACT_TEST_TOKEN") end)

      assert :ok = Capture.open_jobsite("j-redact", spec(repo), "deploy with #{secret} now")
      dir = Path.join([root, "jobsite", "j-redact"])

      assert File.read!(Path.join(dir, "request.md")) == "deploy with [REDACTED] now"
      refute File.read!(Path.join(dir, "manifest.json")) =~ secret

      assert {:ok, %{"request" => %{"prompt" => "deploy with [REDACTED] now"}}} =
               Archive.read_manifest(dir)
    end
  end
end
