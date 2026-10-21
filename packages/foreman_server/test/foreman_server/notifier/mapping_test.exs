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

  defp lookup(type, payload), do: Mapping.lookup(Mapping.rules(), type, payload)

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
    assert {:run_update, :progress} = class_level("PrCreated", %{pr_url: "u"})
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

  test "field lookup accepts atom or string keys and rejects a conflicting pair" do
    assert Rule.field_value(%{run_id: "a"}, "run_id") == "a"
    assert Rule.field_value(%{"run_id" => "a"}, "run_id") == "a"
    assert Rule.field_value(%{}, "run_id") == nil

    assert_raise ArgumentError, ~r/conflicting/, fn ->
      Rule.field_value(%{:run_id => "a", "run_id" => "b"}, "run_id")
    end
  end
end
