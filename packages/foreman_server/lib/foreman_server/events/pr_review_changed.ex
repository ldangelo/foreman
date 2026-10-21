defmodule ForemanServer.Events.PrReviewChanged do
  @moduledoc """
  Typed event on `run:<run_id>` recording that the review state of a watched PR
  changed (spike S4, E9-S1): the review decision, the set of conversation
  comments, or the set of unresolved review threads. `digest` hashes
  (decision, sorted comment ids, sorted unresolved thread ids, review ids and
  states); `observation_seq` keeps an A -> B -> A flip distinct.

  `comment_ids` / `thread_ids` carry identifiers only: comment text is fetched
  fresh by the fix thread, never persisted on the event stream.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :head_sha, :digest]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          pr_status: String.t() | nil,
          review_decision: String.t() | nil,
          comment_ids: [String.t()],
          thread_ids: [String.t()],
          new_comment_count: non_neg_integer(),
          digest: String.t(),
          observation_seq: non_neg_integer(),
          observed_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :repo_id,
    :head_sha,
    :pr_status,
    :review_decision,
    :digest,
    :observed_at,
    comment_ids: [],
    thread_ids: [],
    new_comment_count: 0,
    observation_seq: 0
  ]
end
