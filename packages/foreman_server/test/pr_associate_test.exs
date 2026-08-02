defmodule ForemanServer.PrAssociateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, PrAssociate}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-pr-assoc-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.ensure_all_started(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)
  end

  # ─── extract_pr_number ───────────────────────────────────────────────────────

  describe "extract_pr_number/1" do
    test "parses GitHub PR URL" do
      assert PrAssociate.extract_pr_number(
               "https://github.com/owner/repo/pull/123"
             ) == "123"
    end

    test "parses GitHub PR URL with trailing slash" do
      assert PrAssociate.extract_pr_number(
               "https://github.com/owner/repo/pull/456/"
             ) == "456"
    end

    test "returns bare numeric identity as-is" do
      assert PrAssociate.extract_pr_number("789") == "789"
    end

    test "returns nil for unparseable URL" do
      assert PrAssociate.extract_pr_number("not-a-pr-url") == nil
    end
  end

  # ─── store ──────────────────────────────────────────────────────────────────

  describe "store/2" do
    test "emits PrAssociated event via CommandRouter and stores in ProjectionStore" do
      run_id = "run-pr-assoc-#{System.unique_integer([:positive])}"
      task_id = "task-pr-assoc-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/owner/repo/pull/42"

      # Seed: start run, complete it (required: status == "completed")
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: task_id, project_id: "proj-#{run_id}"}
               })

      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}:complete",
                 command_type: "run.complete",
                 payload: %{run_id: run_id}
               })

      # Store PR association
      assert {:ok, association_id} = PrAssociate.store(run_id, pr_url)
      assert association_id == "#{run_id}:#{pr_url}"

      # Verify PrAssociated event was appended to the run stream
      run_events = EventStore.stream("run:#{run_id}")
      assert Enum.any?(run_events, &(&1.event_type == "PrAssociated"))

      # Verify projection has pr_url and pr_number
      assert %{pr_url: ^pr_url, pr_number: "42"} = ProjectionStore.snapshot().runs[run_id]
    end

    test "accepts explicit pr_number" do
      run_id = "run-pr-assoc-num-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/owner/repo/pull/99"
      explicit_number = "99"

      # Seed run
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: "task-num", project_id: "proj-#{run_id}"}
               })

      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}:complete",
                 command_type: "run.complete",
                 payload: %{run_id: run_id}
               })

      assert {:ok, _} = PrAssociate.store(run_id, pr_url, explicit_number)
      assert %{pr_number: "99"} = ProjectionStore.snapshot().runs[run_id]
    end

    test "accepts bare numeric identity as pr_url" do
      run_id = "run-pr-assoc-bare-#{System.unique_integer([:positive])}"
      bare_id = "777"

      # Seed run
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: "task-bare", project_id: "proj-#{run_id}"}
               })

      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}:complete",
                 command_type: "run.complete",
                 payload: %{run_id: run_id}
               })

      assert {:ok, _} = PrAssociate.store(run_id, bare_id)
      assert %{pr_url: "777", pr_number: "777"} = ProjectionStore.snapshot().runs[run_id]
    end

    test "returns error for unparseable pr_url with no fallback" do
      run_id = "run-pr-assoc-bad-#{System.unique_integer([:positive])}"

      # Seed run
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: "task-bad", project_id: "proj-#{run_id}"}
               })

      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}:complete",
                 command_type: "run.complete",
                 payload: %{run_id: run_id}
               })

      assert {:error, {:invalid_pr_url, "not-a-pr"}} = PrAssociate.store(run_id, "not-a-pr")
    end

    test "rejects pr.associate on non-completed run" do
      run_id = "run-pr-assoc-incomplete-#{System.unique_integer([:positive])}"

      # Seed run in-progress (don't complete it)
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: "task-incomplete", project_id: "proj-#{run_id}"}
               })

      assert {:error, {:invalid_run_status, "completed", "in_progress"}} =
               PrAssociate.store(run_id, "https://github.com/owner/repo/pull/1")
    end

    test "idempotent: duplicate command is translated to success" do
      run_id = "run-pr-assoc-idemp-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/owner/repo/pull/55"

      # Seed run
      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}",
                 command_type: "run.start",
                 payload: %{run_id: run_id, task_id: "task-idemp", project_id: "proj-#{run_id}"}
               })

      assert {:ok, _} =
               CommandRouter.handle(%{
                 command_id: "seed:#{run_id}:complete",
                 command_type: "run.complete",
                 payload: %{run_id: run_id}
               })

      # First call succeeds
      assert {:ok, _} = PrAssociate.store(run_id, pr_url)

      # Second call: EventStore returns {:error, {:duplicate_idempotency_key, _}}.
      # PrAssociate.store/3 translates it to {:ok, association_id} for idempotency.
      expected = "#{run_id}:#{pr_url}"
      assert {:ok, ^expected} = PrAssociate.store(run_id, pr_url)
    end
  end
end
