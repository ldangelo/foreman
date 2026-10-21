defmodule ForemanServer.Aggregates.Review do
  @moduledoc """
  Aggregate recording the automated review verdict of one finished run or
  jobsite.

  Stream id is `"review:" <> subject_kind <> ":" <> subject_id`, so each
  subject has exactly one stream and at most one verdict. Routed by
  `CommandRouter.aggregate_module_for/1`.

  Command `review.record` is system-only (dispatched through
  `CommandGateway.dispatch_system/2`, not in the operator allowlist) and emits
  `ReviewRecorded`. Replaying the same `command_id` is made idempotent by
  `CommandRouter`'s deterministic event id; a *different* command for a
  subject that already has a verdict is rejected rather than silently
  appending a second verdict.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.ReviewRecorded

  @subject_kinds ~w(run jobsite)
  @verdicts ~w(met partially_met not_met undetermined)

  @doc "Stream id for a review subject."
  @spec stream_id(String.t(), String.t()) :: String.t()
  def stream_id(subject_kind, subject_id), do: "review:" <> subject_kind <> ":" <> subject_id

  defmodule State do
    @moduledoc "Whether a verdict has been recorded, and which."
    @enforce_keys [:recorded, :verdict]
    @type t :: %__MODULE__{recorded: boolean(), verdict: String.t() | nil}
    defstruct recorded: false, verdict: nil
  end

  @impl true
  def initial_state, do: %State{recorded: false, verdict: nil}

  # ---------------------------------------------------------------------------
  # apply_event/2 - must tolerate unknown event types (no crash on replay)
  # ---------------------------------------------------------------------------

  @impl true
  def apply_event(%State{} = state, %ReviewRecorded{verdict: verdict}),
    do: %State{state | recorded: true, verdict: verdict}

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "ReviewRecorded" ->
        payload = event |> Aggregate.event_payload() |> Map.delete("event_type")
        %ReviewRecorded{verdict: verdict} = EventCodec.decode!("ReviewRecorded", payload)
        %State{state | recorded: true, verdict: verdict}

      _ ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # handle_command/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_command(state, %{type: "review.record", payload: payload}) do
    with {:ok, kind} <- validate_subject_kind(Aggregate.get(payload, :subject_kind)),
         {:ok, subject_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :subject_id), :subject_id),
         :ok <- optional_binary(payload, :project_id),
         {:ok, verdict} <- validate_verdict(Aggregate.get(payload, :verdict)),
         {:ok, summary} <- Aggregate.required_binary(Aggregate.get(payload, :summary), :summary),
         :ok <- optional_binary(payload, :bead_id),
         :ok <- optional_binary(payload, :archive_path),
         :ok <- optional_binary(payload, :analysis_path),
         :ok <- optional_binary(payload, :evaluator),
         :ok <- optional_binary(payload, :error_code),
         {:ok, scores} <- validate_scores(Aggregate.get(payload, :scores)),
         {:ok, gap_bead_ids} <- validate_gap_bead_ids(Aggregate.get(payload, :gap_bead_ids)),
         :ok <- ensure_not_recorded(state, kind, subject_id) do
      {:ok,
       %{
         stream_id: stream_id(kind, subject_id),
         event_type: "ReviewRecorded",
         payload: %{
           subject_kind: kind,
           subject_id: subject_id,
           project_id: Aggregate.get(payload, :project_id),
           bead_id: Aggregate.get(payload, :bead_id),
           verdict: verdict,
           scores: scores,
           summary: summary,
           gap_bead_ids: gap_bead_ids,
           archive_path: Aggregate.get(payload, :archive_path),
           analysis_path: Aggregate.get(payload, :analysis_path),
           evaluator: Aggregate.get(payload, :evaluator),
           error_code: Aggregate.get(payload, :error_code),
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now())
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # Validation - each rejection is distinct (AGENTS.md §5.3)
  # ---------------------------------------------------------------------------

  defp validate_subject_kind(value) when value in @subject_kinds, do: {:ok, value}

  defp validate_subject_kind(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_subject_kind, value}}

  defp validate_subject_kind(_), do: {:error, {:missing_or_invalid, :subject_kind}}

  defp validate_verdict(value) when value in @verdicts, do: {:ok, value}

  defp validate_verdict(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_verdict, value}}

  defp validate_verdict(_), do: {:error, {:missing_or_invalid, :verdict}}

  defp optional_binary(payload, key),
    do: Aggregate.optional_binary(Aggregate.get(payload, key), key)

  defp validate_scores(nil), do: {:ok, nil}
  defp validate_scores(value) when is_map(value), do: {:ok, value}
  defp validate_scores(_), do: {:error, {:missing_or_invalid, :scores}}

  defp validate_gap_bead_ids(nil), do: {:ok, []}

  defp validate_gap_bead_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: {:ok, ids},
      else: {:error, {:missing_or_invalid, :gap_bead_ids}}
  end

  defp validate_gap_bead_ids(_), do: {:error, {:missing_or_invalid, :gap_bead_ids}}

  defp ensure_not_recorded(%State{recorded: false}, _kind, _subject_id), do: :ok

  defp ensure_not_recorded(%State{recorded: true}, kind, subject_id),
    do: {:error, {:already_recorded, kind, subject_id}}
end
