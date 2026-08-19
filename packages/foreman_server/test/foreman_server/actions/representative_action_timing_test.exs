defmodule ForemanServer.Actions.RepresentativeActionTimingTest do
  use ExUnit.Case, async: false
  @moduletag :timing

  test "representative action development time scaffolding artifacts exist" do
    assert File.exists?("docs/ADT/representative-action.md")
    assert File.exists?("docs/ADT/representative-action-run.md")
    assert File.exists?("docs/ADT/representative-action-timing.md")
  end
end
