defmodule ForemanServer.TaskProviders.BeadsWatcherGapBeadTest do
  @moduledoc """
  Regression pin for the review gap-bead feature.

  `Review.BeadSink` creates follow-up beads through `br create`, which stores
  `agent_context` as a JSON *string* (see `BeadsAdapter.build_create_payload/1`
  and the `br` JSONL export). `BeadsWatcher.foreman_tag?/1` only suppresses a
  map-shaped `agent_context`, so a Foreman-created gap bead is dispatched like
  any operator bead — which is exactly what makes gap beads get picked up and
  closed by Foreman. If `foreman_tag?/1` ever starts parsing string contexts,
  this test fails loudly instead of silently disabling the feature.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.BeadsWatcher

  defmodule FakeCommandGateway do
    @moduledoc false
    def reset, do: :persistent_term.put({__MODULE__, :calls}, [])
    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])

    def dispatch_system(command, timeout) do
      :persistent_term.put({__MODULE__, :calls}, calls() ++ [{command, timeout}])
      {:ok, nil}
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)
  end

  defmodule FakeProjectionStore do
    @moduledoc false
    def get_task(_opts), do: nil
  end

  defmodule FakeWorkflowCatalog do
    @moduledoc false
    def type_to_workflow(_issue_type), do: {:ok, "generic"}
  end

  setup do
    originals =
      for key <- [:command_gateway_module, :projection_store_module, :workflow_catalog_module],
          do: {key, Application.fetch_env(:foreman_server, key)}

    Application.put_env(:foreman_server, :command_gateway_module, FakeCommandGateway)
    Application.put_env(:foreman_server, :projection_store_module, FakeProjectionStore)
    Application.put_env(:foreman_server, :workflow_catalog_module, FakeWorkflowCatalog)
    FakeCommandGateway.reset()

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:foreman_server, key, value)
        {key, :error} -> Application.delete_env(:foreman_server, key)
      end)

      FakeCommandGateway.reset()
    end)

    :ok
  end

  defp gap_bead_line(overrides \\ %{}) do
    agent_context =
      Jason.encode!(%{
        foreman: %{
          task_id: "review:run:run-1",
          command_id: "review:run-1:gap:0",
          origin: "foreman",
          linked_at: "2026-01-01T00:00:00Z"
        }
      })

    %{
      "id" => "gap-bead-1",
      "title" => "Add missing test for retry path",
      "description" => "Gap found by review of run-1.",
      "status" => "open",
      "priority" => 1,
      "issue_type" => "bug",
      "labels" => ["foreman-exec", "foreman-gap"],
      "agent_context" => agent_context
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  test "a Foreman-created gap bead (agent_context as JSON string) is dispatched, not skipped" do
    state = %BeadsWatcher{project_id: "proj-gap"}

    assert BeadsWatcher.process_line(state, gap_bead_line()) == :imported

    assert [{create, _timeout}, {approve, _}] = FakeCommandGateway.calls()
    assert create.type == "task.create"
    assert create.payload.external_id == "gap-bead-1"
    assert create.payload.task_type == "bug"
    assert approve.type == "task.approve"
  end

  test "premise: a map-shaped agent_context with a foreman key IS suppressed" do
    state = %BeadsWatcher{project_id: "proj-gap"}

    line = gap_bead_line(%{"agent_context" => %{"foreman" => %{"task_id" => "t1"}}})

    assert BeadsWatcher.process_line(state, line) == :skipped
    assert FakeCommandGateway.calls() == []
  end

  test "a gap bead without the foreman-exec label is not dispatched" do
    state = %BeadsWatcher{project_id: "proj-gap"}

    line = gap_bead_line(%{"labels" => ["foreman-gap"]})

    assert BeadsWatcher.process_line(state, line) == :skipped
    assert FakeCommandGateway.calls() == []
  end
end
