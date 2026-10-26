defmodule ForemanServerWeb.Workspace.ProjectViewTest do
  # CodeRabbit PR #591 [2] and [4] (bead foreman-27ayh): the two workspace pages no longer
  # hedge between atom and string config keys themselves; `ProjectView` reads the project's
  # display facts and normalises the projection's mixed key shapes ONCE (an Elixir caller's
  # config has atom keys, an HTTP/JSON client's or a replayed one's string keys).
  use ExUnit.Case, async: true

  alias ForemanServerWeb.Workspace.ProjectView

  test "the name of an atom-keyed config" do
    assert %{name: "Atom Keyed"} = ProjectView.build(%{config: %{name: "Atom Keyed"}}, "p-1")
  end

  test "the name of a string-keyed config" do
    assert %{name: "String Keyed"} =
             ProjectView.build(%{config: %{"name" => "String Keyed"}}, "p-1")
  end

  test "the project id when the config names none" do
    assert %{name: "p-1"} = ProjectView.build(%{config: %{}}, "p-1")
    assert %{name: "p-1"} = ProjectView.build(%{config: %{name: nil}}, "p-1")
    assert %{name: "p-1"} = ProjectView.build(%{config: nil}, "p-1")
    assert %{name: "p-1"} = ProjectView.build(%{}, "p-1")
  end

  test "keys that are not the name are not mistaken for it" do
    assert %{name: "p-1"} =
             ProjectView.build(%{config: %{"names" => "x", task_provider: "beads"}}, "p-1")
  end

  test "the status is the projection's own" do
    assert %{status: "paused"} = ProjectView.build(%{status: "paused", config: %{}}, "p-1")
    assert %{status: nil} = ProjectView.build(%{config: %{}}, "p-1")
  end
end
