defmodule ForemanServer.Aggregates.JobsiteTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Jobsite
  alias ForemanServer.Aggregates.Jobsite.State

  defp default_state, do: Jobsite.initial_state()

  defp started_state(overrides \\ %{}) do
    base = %State{
      default_state()
      | exists?: true,
        jobsite_id: "js-1",
        status: "running",
        repo_path: "/tmp/repo",
        strategy: "head",
        worktree_path: "/tmp/repo"
    }

    struct!(base, overrides)
  end

  describe "initial_state/0" do
    test "returns a default State struct" do
      state = default_state()
      assert %State{} = state
      assert state.exists? == false
      assert state.jobsite_id == nil
      assert state.status == nil
      assert state.terminal? == false
      assert state.max_iterations == 1
      assert state.completion_signals == []
      assert state.iteration_index == 0
      assert state.iteration_open? == false
    end
  end

  describe "handle_command/2 — jobsite.start" do
    test "emits JobsiteStarted with the right stream_id and event_type" do
      cmd = %{
        type: "jobsite.start",
        payload: %{jobsite_id: "js-1", repo_path: "/tmp/repo", strategy: "head"}
      }

      assert {:ok, spec} = Jobsite.handle_command(default_state(), cmd)
      assert spec.event_type == "JobsiteStarted"
      assert spec.stream_id == "jobsite:js-1"
      assert spec.payload.jobsite_id == "js-1"
      assert spec.payload.repo_path == "/tmp/repo"
      assert spec.payload.strategy == "head"
    end

    test "rejects when jobsite_id is missing" do
      cmd = %{type: "jobsite.start", payload: %{repo_path: "/tmp/repo", strategy: "head"}}

      assert {:error, {:missing_or_invalid, :jobsite_id}} =
               Jobsite.handle_command(default_state(), cmd)
    end

    test "rejects a second jobsite.start for the same stream" do
      cmd = %{
        type: "jobsite.start",
        payload: %{jobsite_id: "js-1", repo_path: "/tmp/repo", strategy: "head"}
      }

      assert {:error, {:jobsite_exists, "js-1"}} =
               Jobsite.handle_command(started_state(), cmd)
    end
  end

  describe "handle_command/2 — jobsite.worktree.provision" do
    test "emits JobsiteWorktreeProvisioned" do
      state = %State{default_state() | exists?: true, jobsite_id: "js-1", status: "starting"}

      cmd = %{
        type: "jobsite.worktree.provision",
        payload: %{jobsite_id: "js-1", path: "/tmp/wt", branch: "agent/x", base_sha: "abc123"}
      }

      assert {:ok, spec} = Jobsite.handle_command(state, cmd)
      assert spec.event_type == "JobsiteWorktreeProvisioned"
      assert spec.payload.path == "/tmp/wt"
    end

    test "rejects when the jobsite does not exist" do
      cmd = %{
        type: "jobsite.worktree.provision",
        payload: %{jobsite_id: "js-1", path: "/tmp/wt", branch: "agent/x", base_sha: "abc123"}
      }

      assert {:error, {:jobsite_absent, "js-1"}} = Jobsite.handle_command(default_state(), cmd)
    end

    test "rejects a second provision once a worktree_path is set" do
      state = started_state(%{worktree_path: "/tmp/wt"})

      cmd = %{
        type: "jobsite.worktree.provision",
        payload: %{jobsite_id: "js-1", path: "/tmp/other", branch: "agent/x", base_sha: "abc"}
      }

      assert {:error, {:worktree_already_provisioned, "/tmp/wt"}} =
               Jobsite.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — jobsite.sandbox.provision" do
    test "emits JobsiteSandboxProvisioned with a derived attempt number" do
      state = started_state(%{sandbox_attempt: 1})

      cmd = %{
        type: "jobsite.sandbox.provision",
        payload: %{jobsite_id: "js-1", provider: "docker", sandbox_repo_path: "/workspace"}
      }

      assert {:ok, spec} = Jobsite.handle_command(state, cmd)
      assert spec.event_type == "JobsiteSandboxProvisioned"
      assert spec.payload.attempt == 2
    end

    test "rejects sandbox provisioning before a worktree exists" do
      state = %State{default_state() | exists?: true, jobsite_id: "js-1", status: "starting"}

      cmd = %{
        type: "jobsite.sandbox.provision",
        payload: %{jobsite_id: "js-1", provider: "docker", sandbox_repo_path: "/workspace"}
      }

      assert {:error, {:sandbox_before_worktree, "js-1"}} = Jobsite.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — jobsite.iteration.start" do
    test "rejects out-of-order indices" do
      state = started_state(%{iteration_index: 1, max_iterations: 5})

      cmd = %{type: "jobsite.iteration.start", payload: %{jobsite_id: "js-1", index: 3}}

      assert {:error, {:iteration_out_of_order, 2, 3}} = Jobsite.handle_command(state, cmd)
    end

    test "rejects when the iteration limit is exceeded" do
      state = started_state(%{iteration_index: 1, max_iterations: 1})

      cmd = %{type: "jobsite.iteration.start", payload: %{jobsite_id: "js-1", index: 2}}

      assert {:error, {:iteration_limit_exceeded, 1}} = Jobsite.handle_command(state, cmd)
    end

    test "rejects starting a new iteration while one is already open" do
      state = started_state(%{iteration_index: 1, iteration_open?: true, max_iterations: 5})

      cmd = %{type: "jobsite.iteration.start", payload: %{jobsite_id: "js-1", index: 2}}

      assert {:error, {:iteration_already_open, 1}} = Jobsite.handle_command(state, cmd)
    end

    test "accepts the first iteration in order" do
      state = started_state(%{iteration_index: 0, max_iterations: 3})

      cmd = %{type: "jobsite.iteration.start", payload: %{jobsite_id: "js-1", index: 1}}

      assert {:ok, spec} = Jobsite.handle_command(state, cmd)
      assert spec.event_type == "JobsiteIterationStarted"
    end
  end

  describe "handle_command/2 — jobsite.iteration.complete/.fail" do
    test "rejects completing an iteration that is not open" do
      state = started_state(%{iteration_index: 1, iteration_open?: false})

      cmd = %{
        type: "jobsite.iteration.complete",
        payload: %{jobsite_id: "js-1", index: 1, status: "completed"}
      }

      assert {:error, {:iteration_not_open, 1}} = Jobsite.handle_command(state, cmd)
    end

    test "accepts completing the currently open iteration" do
      state = started_state(%{iteration_index: 1, iteration_open?: true})

      cmd = %{
        type: "jobsite.iteration.complete",
        payload: %{jobsite_id: "js-1", index: 1, status: "completed"}
      }

      assert {:ok, spec} = Jobsite.handle_command(state, cmd)
      assert spec.event_type == "JobsiteIterationCompleted"
    end

    test "accepts failing the currently open iteration" do
      state = started_state(%{iteration_index: 1, iteration_open?: true})

      cmd = %{
        type: "jobsite.iteration.fail",
        payload: %{jobsite_id: "js-1", index: 1, code: "agent_failed", message: "boom"}
      }

      assert {:ok, spec} = Jobsite.handle_command(state, cmd)
      assert spec.event_type == "JobsiteIterationFailed"
    end
  end

  describe "terminal rejection" do
    test "any command after JobsiteCompleted is rejected" do
      state = started_state(%{status: "completed", terminal?: true})

      cmd = %{type: "jobsite.pause", payload: %{jobsite_id: "js-1", reason: "operator"}}

      assert {:error, {:jobsite_terminal, "completed"}} = Jobsite.handle_command(state, cmd)
    end
  end

  describe "apply_event/2 — JobsitePaused" do
    test "leaves terminal? false so a resumed jobsite still accepts commands" do
      state = started_state(%{iteration_index: 1})

      event = %ForemanServer.Events.JobsitePaused{
        jobsite_id: "js-1",
        reason: "operator",
        iteration_index: 1
      }

      new_state = Jobsite.apply_event(state, event)
      assert new_state.status == "paused"
      assert new_state.terminal? == false
    end
  end

  describe "unrecognized commands" do
    test "returns :unhandled" do
      assert :unhandled =
               Jobsite.handle_command(default_state(), %{type: "jobsite.nope", payload: %{}})
    end
  end
end
