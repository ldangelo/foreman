defmodule ForemanServer.Notifier.Mapping do
  @moduledoc """
  The table that turns projected events into notifications.

  `rules/0` is the built-in table followed by `config :foreman_server,
  :notifier, rules: [...]` (maps or keywords, see `ForemanServer.Notifier.Rule`).
  Configured rules come FIRST so a deployment can override a built-in mapping
  for the same event type. `lookup/3` returns the first rule whose
  `event_type` matches and whose `match` accepts the payload.

  Classes of event covered:

    * run / jobsite failure -> `:failure` (`:blocked`)
    * run stall -> `:stall` (`:blocked`)
    * run completed -> `:run_update` (`:progress`)
    * review verdict: `not_met` -> `:action_needed` (`:blocked`), any other
      verdict -> `:run_update` (`:progress`)
    * agent needs input (`QuestionOpened`, `QuestionExpired`) and approval
      requested (`ToolCallRequested`, `ToolCallExpired`) -> `:action_needed`
    * PR created -> `:run_update`; CI failing -> `:failure`; changes requested
      or exhausted PR fix attempts -> `:action_needed`

  The needs-input, approval and PR rows name events defined by the approvals
  and PR-watch epics. The mapping is by event NAME only: where Foreman does not
  produce an event type, its row simply never matches, so the rows are inert
  until the producing epic is present and need no feature flag.
  """

  alias ForemanServer.Notifier.Rule

  @builtin [
    %{
      event_type: "RunFailed",
      class: :failure,
      severity: :critical,
      level: :blocked,
      subject: "Run failed",
      body_fields: ~w(run_id reason),
      key_fields: ~w(run_id)
    },
    %{
      event_type: "JobsiteFailed",
      class: :failure,
      severity: :critical,
      level: :blocked,
      subject: "Jobsite failed",
      body_fields: ~w(jobsite_id code message),
      key_fields: ~w(jobsite_id)
    },
    %{
      event_type: "RunStallReported",
      class: :stall,
      severity: :warning,
      level: :blocked,
      subject: "Run stalled",
      body_fields: ~w(run_id phase_name reason),
      key_fields: ~w(idempotency_key)
    },
    %{
      event_type: "RunCompleted",
      class: :run_update,
      severity: :info,
      level: :progress,
      subject: "Run completed",
      body_fields: ~w(run_id status),
      key_fields: ~w(run_id)
    },
    %{
      event_type: "ReviewRecorded",
      match: %{"verdict" => ["not_met"]},
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "Review verdict: not met",
      body_fields: ~w(subject_kind subject_id summary),
      key_fields: ~w(subject_kind subject_id)
    },
    %{
      event_type: "ReviewRecorded",
      class: :run_update,
      severity: :info,
      level: :progress,
      subject: "Review recorded",
      body_fields: ~w(subject_kind subject_id verdict summary),
      key_fields: ~w(subject_kind subject_id)
    },
    %{
      event_type: "QuestionOpened",
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "Agent needs input",
      body_fields: ~w(run_id text),
      key_fields: ~w(question_id)
    },
    %{
      event_type: "QuestionExpired",
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "Question expired unanswered",
      body_fields: ~w(run_id reason),
      key_fields: ~w(question_id)
    },
    %{
      event_type: "ToolCallRequested",
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "Approval requested",
      body_fields: ~w(run_id tool_name input_summary),
      key_fields: ~w(tool_call_id)
    },
    %{
      event_type: "ToolCallExpired",
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "Approval request expired",
      body_fields: ~w(run_id reason),
      key_fields: ~w(tool_call_id)
    },
    %{
      event_type: "PrCreated",
      class: :run_update,
      severity: :info,
      level: :progress,
      subject: "PR ready for review",
      body_fields: ~w(run_id pr_url head_branch base_branch),
      key_fields: ~w(pr_url),
      url_field: "pr_url"
    },
    %{
      event_type: "PrChecksChanged",
      match: %{"checks_state" => ["failing"]},
      class: :failure,
      severity: :warning,
      level: :blocked,
      subject: "CI failed",
      body_fields: ~w(run_id pr_url head_sha),
      key_fields: ~w(pr_url digest),
      url_field: "pr_url"
    },
    %{
      event_type: "PrReviewChanged",
      match: %{"review_decision" => ["changes_requested"]},
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "PR changes requested",
      body_fields: ~w(run_id pr_url new_comment_count),
      key_fields: ~w(pr_url digest),
      url_field: "pr_url"
    },
    %{
      event_type: "PrFixExhausted",
      class: :action_needed,
      severity: :warning,
      level: :blocked,
      subject: "PR fix attempts exhausted",
      body_fields: ~w(run_id pr_url kind reason attempts),
      key_fields: ~w(pr_url head_sha kind),
      url_field: "pr_url"
    }
  ]

  @doc "Every rule in lookup order (configured rules first). Raises on a malformed configured rule."
  @spec rules() :: [Rule.t()]
  def rules do
    configured =
      :foreman_server |> Application.get_env(:notifier, []) |> Keyword.get(:rules, [])

    Enum.map(configured ++ @builtin, &Rule.new!/1)
  end

  @doc "The first rule of `rules` that applies to the event, or `:ignore`."
  @spec lookup([Rule.t()], String.t(), map()) :: {:ok, Rule.t()} | :ignore
  def lookup(rules, event_type, payload) when is_list(rules) and is_binary(event_type) do
    case Enum.find(rules, &(&1.event_type == event_type and Rule.matches?(&1, payload))) do
      nil -> :ignore
      rule -> {:ok, rule}
    end
  end

  @doc "Event types the table reacts to."
  @spec event_types([Rule.t()]) :: [String.t()]
  def event_types(rules), do: rules |> Enum.map(& &1.event_type) |> Enum.uniq()
end
