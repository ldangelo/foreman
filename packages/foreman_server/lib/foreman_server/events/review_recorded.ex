defmodule ForemanServer.Events.ReviewRecorded do
  @moduledoc """
  Typed event appended to `review:<subject_kind>:<subject_id>` when the
  automated analysis of a finished run or jobsite has produced a verdict. A
  failed evaluation is recorded too, with verdict `"undetermined"` and a
  non-nil `error_code`, so an unreviewed run is never indistinguishable from
  one whose review did not happen.
  """
  @enforce_keys [:subject_kind, :subject_id, :verdict, :at]
  @type t :: %__MODULE__{
          subject_kind: String.t(),
          subject_id: String.t(),
          project_id: String.t() | nil,
          bead_id: String.t() | nil,
          verdict: String.t(),
          scores: map() | nil,
          summary: String.t(),
          gap_bead_ids: [String.t()],
          archive_path: String.t() | nil,
          analysis_path: String.t() | nil,
          evaluator: String.t() | nil,
          error_code: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :subject_kind,
    :subject_id,
    :project_id,
    :bead_id,
    :verdict,
    :scores,
    :summary,
    :archive_path,
    :analysis_path,
    :evaluator,
    :error_code,
    :at,
    gap_bead_ids: []
  ]
end
