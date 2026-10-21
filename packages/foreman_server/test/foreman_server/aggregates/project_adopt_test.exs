defmodule ForemanServer.Aggregates.ProjectAdoptTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project

  defp state(events) do
    Enum.reduce(events, Project.initial_state(), &Project.apply_event(&2, &1))
  end

  defp registered(id \\ "b"),
    do: %{event_type: "ProjectRegistered", payload: %{project_id: id, path: "/r"}}

  defp command(overrides) do
    payload =
      Map.merge(
        %{
          project_id: "b",
          subject_kind: "run",
          subject_id: "r1",
          mode: "move",
          from_project_id: "a",
          subject_active: false,
          subject_status: "completed",
          moved: %{task_ids: ["t1"], run_ids: ["r1"], jobsite_ids: []}
        },
        overrides
      )

    %{type: "project.adopt", payload: payload}
  end

  defp handle(state, overrides \\ %{}),
    do: Project.handle_command(state, command(overrides))

  test "an inactive subject is adopted: event carries the move" do
    assert {:ok, %{stream_id: "project:b", event_type: "ProjectSubjectAdopted", payload: event}} =
             handle(state([registered()]))

    assert %{project_id: "b", subject_kind: "run", from_project_id: "a", mode: "move"} = event
    assert event.moved.run_ids == ["r1"]
  end

  test "each refusal is a distinct tuple" do
    live = state([registered()])

    assert {:error, {:not_found, :project, "b"}} = handle(state([]))

    archived = state([registered(), %{event_type: "ProjectArchived", payload: %{}}])
    assert {:error, {:project_archived, "b"}} = handle(archived)

    paused = state([registered(), %{event_type: "ProjectPaused", payload: %{}}])
    assert {:error, {:project_paused, "b"}} = handle(paused)

    assert {:error, {:subject_active, "in_progress"}} =
             handle(live, %{subject_active: true, subject_status: "in_progress"})

    assert {:error, {:invalid_subject_kind, "bogus"}} = handle(live, %{subject_kind: "bogus"})
    assert {:error, {:missing_or_invalid, :subject_kind}} = handle(live, %{subject_kind: nil})
    assert {:error, {:invalid_adopt_mode, "copy"}} = handle(live, %{mode: "copy"})
    assert {:error, {:missing_or_invalid, :moved}} = handle(live, %{moved: "x"})
  end

  test "adopting a subject already in the target is an idempotent no-op, even if it looks active" do
    assert {:ok, nil} =
             handle(state([registered()]), %{
               from_project_id: "b",
               subject_active: true,
               subject_status: "in_progress"
             })
  end

  test "continue is allowed while the source is active and needs the new thread id" do
    live = state([registered()])

    assert {:error, {:missing_or_invalid, :new_task_id}} =
             handle(live, %{mode: "continue", subject_active: true})

    assert {:ok, %{payload: %{new_task_id: "n1", mode: "continue"}}} =
             handle(live, %{mode: "continue", subject_active: true, new_task_id: "n1"})
  end

  test "a recorded continuation is not recorded twice" do
    live = state([registered()])
    {:ok, %{payload: payload}} = handle(live, %{mode: "continue", new_task_id: "n1"})

    adopted =
      state([registered(), %{event_type: "ProjectSubjectAdopted", payload: Map.from_struct(payload)}])

    assert {:ok, nil} = handle(adopted, %{mode: "continue", new_task_id: "n1"})
    assert {:ok, %{}} = handle(adopted, %{mode: "continue", new_task_id: "n2"})
  end
end
