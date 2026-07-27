defmodule ForemanServer.Aggregates.ArtifactReport do
  @moduledoc "Artifact/report aggregate: validates report and phase verdict publication per phase."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule Report do
    @moduledoc "A single phase report, keyed by report_id."
    @enforce_keys [:report_id]
    defstruct [:report_id, :phase_id, :run_id, metadata: %{}]
  end

  defmodule State do
    @enforce_keys [:reports, :final_verdict?, :verdict, :run_id, :phase_id]
    defstruct [:reports, :run_id, :phase_id, final_verdict?: false, verdict: nil]
  end

  @impl true
  def initial_state do
    %State{
      reports: %{},
      final_verdict?: false,
      verdict: nil,
      run_id: nil,
      phase_id: nil
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseReportProduced" ->
        report = %Report{
          report_id: report_id(payload),
          phase_id: Aggregate.get(payload, :phase_id),
          run_id: Aggregate.get(payload, :run_id),
          metadata: Map.drop(payload, [:report_id, :phase_id, :run_id])
        }

        new_reports = Map.put(state.reports, report.report_id, report)

        %State{
          state
          | reports: new_reports,
            run_id: Aggregate.get(payload, :run_id),
            phase_id: Aggregate.get(payload, :phase_id)
        }

      "PhaseVerdict" ->
        %State{
          state
          | final_verdict?: final_verdict?(payload),
            verdict: Aggregate.get(payload, :verdict) || Aggregate.get(payload, :status),
            run_id: Aggregate.get(payload, :run_id),
            phase_id: Aggregate.get(payload, :phase_id)
        }

      _ ->
        state
    end
  end

  @impl true
  def handle_command(_state, %{type: "phase.report.produce", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id) do
      {:ok,
       %{
         stream_id: "artifact_report:#{escape(run_id)}:#{escape(phase_id)}",
         event_type: "PhaseReportProduced",
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  def handle_command(state, %{type: "phase.verdict", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- reject_duplicate_final_verdict(state, payload) do
      {:ok,
       %{
         stream_id: "artifact_report:#{escape(run_id)}:#{escape(phase_id)}",
         event_type: "PhaseVerdict",
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp report_id(payload) do
    Aggregate.get(payload, :report_id) || Aggregate.get(payload, :artifact_path) ||
      Aggregate.get(payload, :path) || "report"
  end

  defp final_verdict?(payload) do
    Aggregate.get(payload, :final, true) != false
  end

  defp reject_duplicate_final_verdict(%State{final_verdict?: true}, payload) do
    if Aggregate.get(payload, :supersedes) || Aggregate.get(payload, :revision) do
      :ok
    else
      {:error, :phase_verdict_already_recorded}
    end
  end

  defp reject_duplicate_final_verdict(_state, _payload), do: :ok

  defp escape(value), do: String.replace(value, ":", "%3A")
end
