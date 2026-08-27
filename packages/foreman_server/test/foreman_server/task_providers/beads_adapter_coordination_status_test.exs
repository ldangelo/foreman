defmodule ForemanServer.TaskProviders.BeadsAdapterCoordinationStatusTest do
  @moduledoc """
  Pins `BeadsAdapter.coordination_status/2` against the real `br.coordination.v1`
  payload captured from `br coordination status --db <path> --json`.

  The envelope nests each issue under `claims[].issue`; the adapter previously
  looked for a top-level `issues` array only, treated the whole envelope as a
  single issue payload, and rejected every real response with
  `BR_CONTRACT_MISMATCH` (which made `BootReconciliation` skip beads-backed
  projects on every boot). The unknown-`schema_version` test keeps the mismatch
  loud so a future `br` schema bump cannot be parsed by accident.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  @database_path "/abs/projects/foreman/.beads/beads.db"

  # Verbatim shape of `br coordination status --json` (br.coordination.v1),
  # captured 2026-08-27 against /Users/.../foreman/.beads/beads.db.
  @coordination_v1_payload ~S"""
  {"schema_version":"br.coordination.v1","generated_at":"2026-08-27T17:25:53.090390Z","summary":{"total_claims":2,"workspace":{"open":39,"ready":15,"blocked":26,"in_progress":8,"deferred":0,"closed":659},"unassigned":2,"fresh":0,"blocked_by_active_reservation":0,"stale_candidate":0,"abandoned_likely":0,"no_mail_snapshot":6,"ambiguous":0},"claims":[{"issue":{"id":"foreman-w81","title":"Verify ADT-T001-T004 action dev speed benchmark (REQ-019)","status":"in_progress","priority":3,"issue_type":"task","labels":[],"dependency_count":0,"dependent_count":0,"latest_comments":[]},"assessment":{"owner_kind":"swarm_agent","updated_at":"2026-08-21T17:35:51.830340Z","updated_age_minutes":8630,"stale_threshold_minutes":120,"abandoned_threshold_minutes":480,"reservation":{"state":"no_snapshot"},"classification":"unassigned","recommended_action":"observe","evidence_sources":["issue_metadata","policy_threshold","no_agent_mail_snapshot"]},"reclaim_allowed_by_policy":false,"required_human_confirmation":false,"evidence_summary":"updated_at=2026-08-21 17:35:51.830340 UTC, assignee=(unassigned), owner_kind=swarm_agent","suggested_commands":[]},{"issue":{"id":"foreman-k0e5.3.1","title":"TRD-003: Create prd.yaml curated manifest","status":"in_progress","priority":2,"issue_type":"task","labels":["planning"],"dependency_count":1,"dependent_count":0,"latest_comments":[{"author":"ldangelo","text":"BLOCKED: Requires PlanContext.build support for work-submit projections.","created_at":"2026-08-17T18:12:13Z"}]},"assessment":{"owner_kind":"swarm_agent","updated_at":"2026-08-17T18:12:13.694359Z","updated_age_minutes":14353,"stale_threshold_minutes":120,"abandoned_threshold_minutes":480,"reservation":{"state":"no_snapshot"},"classification":"no_mail_snapshot","recommended_action":"observe","evidence_sources":["issue_metadata"]},"reclaim_allowed_by_policy":false,"required_human_confirmation":false,"evidence_summary":"updated_at=2026-08-17 18:12:13.694359 UTC, owner_kind=swarm_agent","suggested_commands":[]}]}
  """

  # Verbatim shape for a workspace with no active claims (captured from a fresh
  # `br init` database): `claims` is always present, as an empty array.
  @coordination_v1_empty_payload ~s({"schema_version":"br.coordination.v1","generated_at":"2026-08-27T17:27:50.901862Z","summary":{"total_claims":0,"workspace":{"open":0,"ready":0,"blocked":0,"in_progress":0,"deferred":0,"closed":0},"unassigned":0,"fresh":0,"blocked_by_active_reservation":0,"stale_candidate":0,"abandoned_likely":0,"no_mail_snapshot":0,"ambiguous":0},"claims":[]})

  setup_all do
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
    {:ok, _telemetry_apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    :ok
  end

  test "parses the real br.coordination.v1 claims envelope into normalized Issue structs" do
    expect_coordination_status(@coordination_v1_payload)

    assert {:ok, [first, second]} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})

    assert %Issue{
             id: "foreman-w81",
             title: "Verify ADT-T001-T004 action dev speed benchmark (REQ-019)",
             status: "in_progress",
             priority: 3,
             dependencies: [],
             dependents: [],
             assignee: nil,
             description: nil,
             notes: nil,
             design: nil,
             labels: []
           } = first

    assert first.metadata == %{"dependency_count" => 0, "dependent_count" => 0}

    assert %Issue{
             id: "foreman-k0e5.3.1",
             title: "TRD-003: Create prd.yaml curated manifest",
             status: "in_progress",
             priority: 2,
             labels: ["planning"]
           } = second

    # br.coordination.v1 carries cardinality only, never the linked ids, so the
    # counts must survive in metadata rather than becoming empty id lists.
    assert second.metadata == %{"dependency_count" => 1, "dependent_count" => 0}
    assert second.dependencies == []
    assert second.dependents == []
  end

  test "returns {:ok, []} for a br.coordination.v1 envelope with no claims" do
    expect_coordination_status(@coordination_v1_empty_payload)

    assert {:ok, []} = BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "rejects an unrecognized schema_version with BR_CONTRACT_MISMATCH" do
    payload =
      ~s({"schema_version":"br.coordination.v2","generated_at":"2026-08-27T17:25:53.090390Z","claims":[{"issue":{"id":"foreman-w81","title":"t","status":"in_progress","priority":3,"labels":[],"dependency_count":0,"dependent_count":0}}]})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{} = error} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})

    assert error.code == "BR_CONTRACT_MISMATCH"
    assert error.retryable? == false
    assert error.context.exit_code == nil
    assert error.context.stderr_byte_count == 0
    assert error.context.command =~ "br coordination status"
  end

  test "rejects a br.coordination.v1 envelope whose claims array is absent" do
    payload =
      ~s({"schema_version":"br.coordination.v1","generated_at":"2026-08-27T17:25:53.090390Z","summary":{"total_claims":0}})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH"}} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "rejects a br.coordination.v1 envelope whose claims field is malformed" do
    payload = ~s({"schema_version":"br.coordination.v1","claims":{"issue":{"id":"foreman-w81"}}})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH"}} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "rejects a claim entry that omits the nested issue object" do
    payload =
      ~s({"schema_version":"br.coordination.v1","claims":[{"assessment":{"classification":"unassigned"}}]})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH"}} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "rejects a claim whose nested issue is not a JSON object" do
    payload = ~s({"schema_version":"br.coordination.v1","claims":[{"issue":"foreman-w81"}]})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH"}} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "rejects a claim issue whose dependency_count is not a non-negative integer" do
    payload =
      ~s({"schema_version":"br.coordination.v1","claims":[{"issue":{"id":"foreman-w81","title":"t","status":"in_progress","priority":3,"labels":[],"dependency_count":"1","dependent_count":0}}]})

    expect_coordination_status(payload)

    assert {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH"}} =
             BeadsAdapter.coordination_status(%{database_path: @database_path})
  end

  test "still parses the legacy schema-less issue array consumed by BootReconciliation" do
    payload =
      Jason.encode!([
        %{
          "id" => "foreman-legacy-1",
          "title" => "Legacy coordination issue",
          "status" => "in_progress",
          "priority" => 2,
          "dependencies" => ["foreman-legacy-0"],
          "dependents" => [],
          "assignee" => nil,
          "description" => "legacy payload",
          "notes" => nil,
          "design" => nil,
          "labels" => ["workflow"],
          "metadata" => %{"provider_id" => "beads"}
        }
      ])

    expect_coordination_status(payload)

    assert {:ok, [issue]} = BeadsAdapter.coordination_status(%{database_path: @database_path})
    assert issue.id == "foreman-legacy-1"
    assert issue.dependencies == ["foreman-legacy-0"]
    assert issue.metadata == %{"provider_id" => "beads"}
  end

  defp expect_coordination_status(stdout) do
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert project_config == %{database_path: @database_path}
      assert opts == [timeout_ms: 30_000]

      {:ok, %{stdout: stdout, stderr: "", exit_code: 0}}
    end)
  end
end
