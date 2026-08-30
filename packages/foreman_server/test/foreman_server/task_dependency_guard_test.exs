defmodule ForemanServer.TaskDependencyGuardTest do
  @moduledoc """
  `task.create` has always accepted a `dependencies` list, the aggregate has
  always stored it, and `TaskCreated` has always carried it — but nothing ever
  read it. `Task.require_dispatchable/1` (`task.ex:461-470`) matches only
  `status`, `run_id` and `approval_id`, so a task declaring dependencies
  approved and dispatched immediately regardless of whether any dependency had
  finished. The field was inert for its entire life while reading, to anyone
  grepping for it, as a working feature.

  `ProjectionStore` compounded it by dropping the field on `TaskCreated`, so no
  cross-task reader could have seen it even had one existed.

  These tests pin the guard at the approval boundary — the transition that
  triggers dispatch, and therefore the last point a declared dependency can
  change the outcome. They deliberately do NOT pin a dependency DAG: there is no
  ordering, no cycle detection, and no automatic dispatch when the final
  dependency closes. An operator re-approves once the dependencies are closed.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore

  setup do
    # `TaskApproved` projections trigger a real run through the Dispatcher,
    # which races fixture cleanup. Same isolation the existing approval tests in
    # command_gateway_test.exs use.
    assert :ok =
             Supervisor.terminate_child(
               ForemanServer.Application,
               ForemanServer.Workflow.Dispatcher
             )

    on_exit(fn ->
      Supervisor.restart_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    end)

    :ok
  end

  defp seed_task(task_id, status, opts \\ []) do
    payload =
      %{
        task_id: task_id,
        project_id: "project-dep",
        title: task_id,
        status: status,
        task_type: "task"
      }
      |> then(fn p ->
        case Keyword.fetch(opts, :dependencies) do
          {:ok, deps} -> Map.put(p, :dependencies, deps)
          :error -> p
        end
      end)

    assert :ok = ProjectionStore.apply_events([%{event_type: "TaskCreated", payload: payload}])
  end

  defp approve(task_id) do
    CommandGateway.dispatch_operator(%{
      command_id: "cid-#{System.unique_integer([:positive])}",
      aggregate_id: "task:#{task_id}",
      type: "task.approve",
      payload: %{task_id: task_id}
    })
  end

  describe "the projection carries dependencies" do
    test "a dependency list survives TaskCreated into the read model" do
      # The guard cannot work at all if this regresses, and it regressed by
      # OMISSION once already — the field was on the event and simply not
      # copied, which no test noticed because nothing read it.
      seed_task("dep-carrier", "open", dependencies: ["dep-a", "dep-b"])

      assert %{dependencies: ["dep-a", "dep-b"]} = ProjectionStore.task_projection("dep-carrier")
    end

    test "a task declaring no dependencies projects an empty list, not nil" do
      seed_task("dep-none", "open")

      assert %{dependencies: []} = ProjectionStore.task_projection("dep-none")
    end
  end

  describe "approval is refused while a dependency is unfinished" do
    test "an in_progress dependency blocks approval and is named" do
      seed_task("dep-running", "in_progress")
      seed_task("dep-waiter", "open", dependencies: ["dep-running"])

      assert {:error, {:task_dependencies_unsatisfied, [{"dep-running", "in_progress"}]}} =
               approve("dep-waiter")
    end

    test "an open dependency blocks approval" do
      seed_task("dep-open", "open")
      seed_task("dep-waiter-2", "open", dependencies: ["dep-open"])

      assert {:error, {:task_dependencies_unsatisfied, [{"dep-open", "open"}]}} =
               approve("dep-waiter-2")
    end

    test "a FAILED dependency blocks approval" do
      # `failed` is terminal but did not produce the work this task depends on.
      # Treating "terminal" as "satisfied" would dispatch against a dependency
      # that never delivered — the plausible-looking success this repo forbids.
      seed_task("dep-failed", "failed")
      seed_task("dep-waiter-3", "open", dependencies: ["dep-failed"])

      assert {:error, {:task_dependencies_unsatisfied, [{"dep-failed", "failed"}]}} =
               approve("dep-waiter-3")
    end

    test "a blocked dependency blocks approval" do
      seed_task("dep-blocked", "blocked")
      seed_task("dep-waiter-4", "open", dependencies: ["dep-blocked"])

      assert {:error, {:task_dependencies_unsatisfied, [{"dep-blocked", "blocked"}]}} =
               approve("dep-waiter-4")
    end

    test "every unsatisfied dependency is reported, in declaration order" do
      # Reporting only the first would make the operator re-approve once per
      # dependency to discover them all.
      seed_task("dep-m1", "open")
      seed_task("dep-m2", "closed")
      seed_task("dep-m3", "in_progress")
      seed_task("dep-waiter-5", "open", dependencies: ["dep-m1", "dep-m2", "dep-m3"])

      assert {:error,
              {:task_dependencies_unsatisfied,
               [{"dep-m1", "open"}, {"dep-m3", "in_progress"}]}} = approve("dep-waiter-5")
    end
  end

  describe "absent versus malformed, distinguished" do
    test "an unknown dependency id reports :not_found, not a status" do
      # AGENTS.md §5.3: a missing id is a typo or a task never created, which
      # needs a different operator action from "present but unfinished".
      seed_task("dep-waiter-6", "open", dependencies: ["never-created"])

      assert {:error, {:task_dependencies_unsatisfied, [{"never-created", :not_found}]}} =
               approve("dep-waiter-6")
    end

    test "a malformed dependency id is reported, never skipped" do
      # Skipping it would make `dependencies: [nil]` approve as though nothing
      # were declared — reintroducing the exact silent inertness this guard
      # closes, but only for malformed input.
      seed_task("dep-waiter-7", "open", dependencies: [nil, ""])

      assert {:error, {:task_dependencies_unsatisfied, [{nil, :malformed}, {"", :malformed}]}} =
               approve("dep-waiter-7")
    end
  end

  describe "approval proceeds when the declaration is satisfiable" do
    test "a closed dependency does not block approval" do
      seed_task("dep-done", "closed")
      seed_task("dep-waiter-8", "open", dependencies: ["dep-done"])

      refute match?({:error, {:task_dependencies_unsatisfied, _}}, approve("dep-waiter-8"))
    end

    test "all-closed dependencies do not block approval" do
      seed_task("dep-c1", "closed")
      seed_task("dep-c2", "closed")
      seed_task("dep-waiter-9", "open", dependencies: ["dep-c1", "dep-c2"])

      refute match?({:error, {:task_dependencies_unsatisfied, _}}, approve("dep-waiter-9"))
    end

    test "a task declaring no dependencies is unaffected" do
      # The guard must be inert for the overwhelmingly common case. Every
      # existing approval test in command_gateway_test.exs is this case, so a
      # regression here would break approval outright.
      seed_task("dep-waiter-10", "open")

      refute match?({:error, {:task_dependencies_unsatisfied, _}}, approve("dep-waiter-10"))
    end
  end

  describe "the guard runs after envelope validation, not before" do
    test "a nonexistent task still reports :task_not_found" do
      # Ordering matters: dependency state is meaningless for a task that does
      # not exist, and reporting unsatisfied dependencies there would mask a
      # typo in the task id itself.
      assert {:error, {:task_not_found, "no-such-task"}} = approve("no-such-task")
    end

    test "a mismatched aggregate_id still reports the envelope error" do
      seed_task("dep-waiter-11", "open", dependencies: ["dep-open"])

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-env",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "dep-waiter-11"}
               })
    end
  end
end
