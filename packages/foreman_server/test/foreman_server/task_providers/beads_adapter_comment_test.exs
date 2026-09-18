defmodule ForemanServer.TaskProviders.BeadsAdapterCommentTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Comment
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemBrRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_with(BrRunnerMock, ForemanServer.TaskProviders.UnexpectedBrRunnerStub)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "beads_adapter_comment_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "comment/3 writes through SystemBrRunner and returns typed comment", %{temp_dir: temp_dir} do
    db_path = "/abs/path/beads.db"
    body = "Work Log: Workflow fix - Phase develop - Work performed: Done"

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:comments_add, %{id: "task-1", body: body}}
      assert project_config == %{database_path: db_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        project_config,
        ["comments", "add", "task-1", "--message", body, "--json", "--db", db_path]
      )

      {:ok, %{stdout: Jason.encode!(%{"id" => "comment-1"}), stderr: "", exit_code: 0}}
    end)

    assert {:ok, %Comment{provider_issue_id: "task-1", status: "comment_added"}} =
             BeadsAdapter.annotate("task-1", body, %{database_path: db_path})
  end

  test "comment/3 rejects invalid id/body before invoking br" do
    assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
             BeadsAdapter.annotate("", "body", :ignored)

    assert {:error, %ProviderError{code: "INVALID_TRANSITION_COMMENT"}} =
             BeadsAdapter.annotate("task-1", "", :ignored)
  end

  test "comment/3 maps br error envelopes safely" do
    stderr =
      Jason.encode!(%{
        "code" => "BR_DATABASE_LOCKED",
        "message" => "raw message",
        "hint" => "raw hint",
        "retryable" => true
      })

    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:comments_add, %{id: "task-1", body: "body"}}
      assert project_config == %{database_path: "/abs/path.db"}
      assert opts == [timeout_ms: 30_000]
      {:error, %{stdout: "", stderr: stderr, exit_code: 73}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.annotate("task-1", "body", %{database_path: "/abs/path.db"})

    assert provider_error.code == "BR_DATABASE_LOCKED"
    assert provider_error.context.command == "br comments add"
    assert provider_error.context.exit_code == 73
    assert provider_error.context.stderr_byte_count == byte_size(stderr)
  end

  defp assert_translated_argv(temp_dir, request, project_config, expected_argv) do
    with_fake_br(temp_dir, "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n", fn ->
      assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
               SystemBrRunner.cmd(request, project_config)

      assert String.split(stdout, "\n", trim: true) == expected_argv
    end)
  end

  defp with_fake_br(temp_dir, script_body, fun) do
    fake_br = Path.join(temp_dir, "br")
    File.write!(fake_br, "#!/bin/sh\n" <> script_body)
    File.chmod!(fake_br, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> (System.get_env("PATH") || ""))
    fun.()
  end
end
