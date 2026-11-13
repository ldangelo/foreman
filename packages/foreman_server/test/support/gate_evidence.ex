defmodule ForemanServer.TestSupport.GateEvidence do
  @moduledoc """
  The `evidence` a `merge_approve` payload carries when a test dispatches it straight at the Run
  aggregate (TRD-036). `CommandGateway` stamps it in production (TRD-022); a test that bypasses the
  gateway stamps it by hand, and the aggregate refuses an approval that has none.

    * `off/0` - the stamp of a project whose gate is off: nothing is refused on evidence.
    * `gated/2` - the stamp of a gated project: the `policy` (`required` entries, `version` computed
      like `PrEvidence.project_policy/1` does) and the `checks_ref` of the observation the
      decision names.
  """

  alias ForemanServer.PrEvidence

  @now_ms 1_800_000_000_000

  @doc "The evidence stamp of a project with the gate off."
  @spec off() :: map()
  def off, do: %{policy: nil, checks_ref: nil, now_ms: @now_ms}

  @doc "The evidence stamp of a gated project: `required` is the policy list, `checks_ref` the observation named."
  @spec gated([map()], String.t() | nil) :: map()
  def gated(required, checks_ref),
    do: %{
      policy: %{required: required, version: PrEvidence.policy_version(required)},
      checks_ref: checks_ref,
      now_ms: @now_ms
    }

  @doc "Merge `evidence` (default: gate off) into a `merge_approve` payload."
  @spec stamp(map(), map()) :: map()
  def stamp(payload, evidence \\ off()), do: Map.put(payload, :evidence, evidence)

  @doc """
  Record a clean review-findings block (`status: "recorded"`, no findings) for `head_sha` of `pr_url`
  through the system command `run.pr.findings` the finalising executor sends, so an approval of that
  head is not refused `findings_absent`. `opts` override payload fields (`:status`, `:findings`, ...).
  """
  @spec record_findings!(map(), String.t(), keyword()) :: :ok
  def record_findings!(
        %{run_id: run_id, project_id: project_id, task_id: task_id} = run,
        head_sha,
        opts \\ []
      ) do
    payload =
      Map.merge(
        %{
          run_id: run_id,
          project_id: project_id,
          task_id: task_id,
          pr_url: run.pr_url,
          head_sha: head_sha,
          status: "recorded",
          findings: [],
          defect: nil,
          defect_detail: nil,
          artifact_path: "/w/review.md",
          artifact_sha256: String.duplicate("c", 64),
          recorded_at: 1_800_000_000_000
        },
        Map.new(opts)
      )

    {:ok, _} =
      ForemanServer.CommandGateway.dispatch_system(%{
        type: "run.pr.findings",
        command_id: "findings-#{run_id}-#{head_sha}-#{payload.status}",
        aggregate_id: "run:#{run_id}",
        payload: payload
      })

    :ok
  end
end
