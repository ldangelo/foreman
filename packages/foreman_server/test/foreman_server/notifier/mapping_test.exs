defmodule ForemanServer.Notifier.MappingTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Notifier.{Mapping, Rule}

  setup do
    original = Application.get_env(:foreman_server, :notifier)

    on_exit(fn ->
      if original,
        do: Application.put_env(:foreman_server, :notifier, original),
        else: Application.delete_env(:foreman_server, :notifier)
    end)
  end

  # The Notifier hands the table a payload it normalised once (`Rule.normalize_payload!/1`).
  defp lookup(type, payload),
    do: Mapping.lookup(Mapping.rules(), type, Rule.normalize_payload!(payload))

  defp class_level(type, payload) do
    assert {:ok, %Rule{class: class, level: level}} = lookup(type, payload)
    {class, level}
  end

  test "each notification-worthy event maps to the documented class and level" do
    assert {:failure, :blocked} = class_level("RunFailed", %{run_id: "r"})
    assert {:failure, :blocked} = class_level("JobsiteFailed", %{jobsite_id: "j"})
    assert {:stall, :blocked} = class_level("RunStallReported", %{run_id: "r"})
    assert {:run_update, :progress} = class_level("RunCompleted", %{run_id: "r"})
    assert {:action_needed, :blocked} = class_level("QuestionOpened", %{question_id: "q"})
    assert {:action_needed, :blocked} = class_level("ToolCallRequested", %{tool_call_id: "t"})
    assert {:run_update, :progress} = class_level("PrReady", %{pr_url: "u"})
  end

  # foreman-ireii: the crash-loop detector blocks a run and the stuck detector flags one; both
  # put the thread in "Waiting on you", so both must reach the operator. A finished jobsite is the
  # jobsite door's RunCompleted.
  test "a blocked or stuck run needs you, a finished jobsite is a routine update" do
    assert {:action_needed, :blocked} = class_level("RunBlocked", %{run_id: "r"})
    assert {:stall, :blocked} = class_level("RunFlaggedStuck", %{run_id: "r"})
    assert {:run_update, :progress} = class_level("JobsiteCompleted", %{jobsite_id: "j"})
  end

  # foreman-ehz7l: AutoPR, a stacked phase PR, another repository's PR and the Create PR button
  # all record `PrReady`; the button then also records `PrCreated`. One PR, one notification.
  test "a PR is announced by PrReady only, never also by PrCreated" do
    assert {:ok, %Rule{subject: "PR ready for review", url_field: "pr_url"}} =
             lookup("PrReady", %{pr_url: "https://github.com/acme/repo/pull/1"})

    assert :ignore = lookup("PrCreated", %{pr_url: "https://github.com/acme/repo/pull/1"})
  end

  # Cancelling is always an explicit stop by an operator or the coordinator, who already knows.
  test "an explicit cancel is not announced back" do
    assert :ignore = lookup("RunCancelled", %{run_id: "r"})
    assert :ignore = lookup("JobsiteCancelled", %{jobsite_id: "j"})
  end

  test "review verdict not_met needs you; every other verdict is a routine update" do
    assert {:action_needed, :blocked} = class_level("ReviewRecorded", %{"verdict" => "not_met"})

    for verdict <- ~w(met partially_met undetermined) do
      assert {:run_update, :progress} = class_level("ReviewRecorded", %{verdict: verdict})
    end
  end

  test "CI notifies only when failing and review only when changes are requested" do
    assert {:failure, :blocked} = class_level("PrChecksChanged", %{checks_state: "failing"})

    for state <- ~w(none pending passing) do
      assert :ignore = lookup("PrChecksChanged", %{checks_state: state})
    end

    assert {:action_needed, :blocked} =
             class_level("PrReviewChanged", %{"review_decision" => "changes_requested"})

    assert :ignore = lookup("PrReviewChanged", %{review_decision: "approved"})
    assert :ignore = lookup("PrReviewChanged", %{review_decision: nil})
  end

  # foreman-q9zzo C12: the rows nothing pinned. All three are `:blocked`: a thread is waiting on
  # you, so `blocked_only` (the default) delivers them and only `off` drops them.
  test "an expired question, an expired approval and an exhausted PR fix are warnings that block the thread" do
    assert {:ok,
            %Rule{
              class: :action_needed,
              severity: :warning,
              level: :blocked,
              subject: "Question expired unanswered",
              body_fields: ["run_id", "reason"],
              key_fields: ["question_id"],
              url_field: nil,
              match: match
            }} = lookup("QuestionExpired", %{question_id: "q", run_id: "r"})

    assert match == %{}

    assert {:ok,
            %Rule{
              class: :action_needed,
              severity: :warning,
              level: :blocked,
              subject: "Approval request expired",
              body_fields: ["run_id", "reason"],
              key_fields: ["tool_call_id"],
              url_field: nil,
              match: match
            }} = lookup("ToolCallExpired", %{tool_call_id: "t", run_id: "r"})

    assert match == %{}

    assert {:ok,
            %Rule{
              class: :action_needed,
              severity: :warning,
              level: :blocked,
              subject: "PR fix attempts exhausted",
              body_fields: ["run_id", "pr_url", "kind", "reason", "attempts"],
              key_fields: ["pr_url", "head_sha", "kind"],
              url_field: "pr_url",
              match: match
            }} =
             lookup("PrFixExhausted", %{
               pr_url: "https://github.com/acme/repo/pull/1",
               head_sha: "s",
               kind: "ci"
             })

    assert match == %{}
  end

  # foreman-a7i30: an answer recorded before the answer limit existed that no steer can carry is
  # marked undelivered; the operator is told, because the run is still waiting for it.
  test "an answer that can never be delivered is a warning that blocks the thread" do
    assert {:ok,
            %Rule{
              class: :action_needed,
              severity: :warning,
              level: :blocked,
              subject: "Answer could not be delivered",
              body_fields: ["run_id", "reason"],
              key_fields: ["question_id"],
              url_field: nil,
              match: match
            }} = lookup("QuestionAnswerUndelivered", %{question_id: "q", run_id: "r"})

    assert match == %{}
  end

  test "an event the table does not know is ignored" do
    assert :ignore = lookup("RunStarted", %{run_id: "r"})
    assert :ignore = lookup("WorkerStdout", %{})
  end

  test "a configured rule extends the table and wins over a built-in for the same event" do
    Application.put_env(:foreman_server, :notifier,
      rules: [
        %{
          event_type: "ScheduleFired",
          class: :run_update,
          severity: :info,
          level: :progress,
          subject: "Schedule fired",
          key_fields: [:schedule_id]
        },
        [
          event_type: "RunCompleted",
          class: :action_needed,
          level: :blocked,
          subject: "Look at this run",
          key_fields: [:run_id]
        ]
      ]
    )

    assert {:run_update, :progress} = class_level("ScheduleFired", %{schedule_id: "s"})
    assert {:action_needed, :blocked} = class_level("RunCompleted", %{run_id: "r"})
  end

  test "a malformed configured rule fails loudly instead of silently dropping notifications" do
    Application.put_env(:foreman_server, :notifier,
      rules: [
        %{event_type: "X", class: :not_a_class, level: :blocked, subject: "s", key_fields: []}
      ]
    )

    assert_raise ArgumentError, ~r/invalid :class/, &Mapping.rules/0

    Application.put_env(:foreman_server, :notifier, rules: [%{event_type: "X"}])
    assert_raise ArgumentError, ~r/missing :class/, &Mapping.rules/0
  end

  # A rule's `key_fields` ARE its dedupe key: with none, every event of the type hashes to the
  # same correlation id and `Messaging.notify/2` suppresses distinct notifications as replays.
  test "a rule with an empty key_fields list is rejected, a missing one stays missing" do
    rule = %{event_type: "X", class: :failure, level: :blocked, subject: "s"}

    assert_raise ArgumentError, ~r/invalid :key_fields/, fn ->
      Rule.new!(Map.put(rule, :key_fields, []))
    end

    assert_raise ArgumentError, ~r/missing :key_fields/, fn -> Rule.new!(rule) end

    Application.put_env(:foreman_server, :notifier, rules: [Map.put(rule, :key_fields, [])])
    assert_raise ArgumentError, ~r/invalid :key_fields/, &Mapping.rules/0

    assert %Rule{key_fields: ["run_id"]} = Rule.new!(Map.put(rule, :key_fields, [:run_id]))
  end

  # AGENTS.md 5.4: events carry atom keys when freshly appended and string keys when they came
  # from JSON, so the payload is normalised to strings ONCE (the Notifier does it on entry) and
  # the rule reads that one convention instead of probing both forms per field.
  describe "payload normalisation" do
    test "every key becomes a string, equal duplicates collapse, conflicting ones raise" do
      assert Rule.normalize_payload!(%{"project_id" => "p", run_id: "a"}) ==
               %{"run_id" => "a", "project_id" => "p"}

      # what `run.block` stores: its string-keyed payload plus the atom-keyed ids the aggregate adds
      assert Rule.normalize_payload!(%{:run_id => "a", "run_id" => "a"}) == %{"run_id" => "a"}

      error =
        assert_raise ArgumentError, ~r/conflicting run_id keys/, fn ->
          Rule.normalize_payload!(%{:run_id => "secret-a", "run_id" => "secret-b"})
        end

      refute error.message =~ "secret"
    end

    test "field_value reads the normalised convention only" do
      assert Rule.field_value(%{"run_id" => "a"}, "run_id") == "a"
      assert Rule.field_value(%{}, "run_id") == nil
      # An atom key is NOT probed: handing the rule an un-normalised payload is the caller's bug.
      assert Rule.field_value(%{run_id: "a"}, "run_id") == nil
    end

    test "the Notifier normalises on entry: a mixed-form payload with equal values matches the rule" do
      payload = %{:run_id => "r", "run_id" => "r", "project_id" => "p"}
      assert {:ok, %Rule{event_type: "RunFailed"}} = lookup("RunFailed", payload)

      assert_raise ArgumentError, ~r/conflicting run_id keys/, fn ->
        ForemanServer.Notifier.process(ForemanServer.Notifier.new_state(), "RunFailed", %{
          :run_id => "r1",
          "run_id" => "r2"
        })
      end
    end

    # A freshly appended typed event reaches the Notifier with a STRUCT as its data. The first
    # cut of the normaliser refused structs and crash-looped the live Notifier on the first typed
    # event (`ProjectRepositoryAdded`), because it ran for every event; only a mapped type is
    # normalised now, and a struct is read through its fields.
    test "a typed event struct is read through its fields; an unmapped event is never touched" do
      alias ForemanServer.Events.{ProjectRepositoryAdded, RunBlocked}

      blocked = %RunBlocked{run_id: "r", project_id: "p", reason: "max_attempts_exceeded"}

      assert %{"run_id" => "r", "project_id" => "p", "reason" => "max_attempts_exceeded"} =
               normalised = Rule.normalize_payload!(blocked)

      refute Map.has_key?(normalised, "__struct__")

      added = %ProjectRepositoryAdded{
        project_id: "p",
        repo_id: "r",
        path: "/repo",
        added_by: "operator",
        at: "2026-01-01T00:00:00Z"
      }

      state = ForemanServer.Notifier.new_state()

      assert {_, {:skipped, :unmapped}} =
               ForemanServer.Notifier.process(state, "ProjectRepositoryAdded", added)

      # A payload the normaliser would refuse (a key that is neither an atom nor a string) is
      # never reached for an event type the table does not map.
      assert {_, {:skipped, :unmapped}} =
               ForemanServer.Notifier.process(state, "WorkerStdout", %{1 => "x"})

      assert Mapping.mapped?(Mapping.rules(), "RunBlocked")
      refute Mapping.mapped?(Mapping.rules(), "ProjectRepositoryAdded")
    end
  end
end
