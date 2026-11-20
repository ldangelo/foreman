defmodule ForemanServer.Workflow.WorktreeDiscardTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.WorktreeDiscard

  describe "from_event/1" do
    test "reads an atom-keyed record from a live dispatch" do
      assert %WorktreeDiscard{name: "wt-1", path: "/gone"} =
               WorktreeDiscard.from_event(%{name: "wt-1", path: "/gone"})
    end

    test "reads a string-keyed record from a replayed event" do
      assert %WorktreeDiscard{name: "wt-1", path: "/gone"} =
               WorktreeDiscard.from_event(%{"name" => "wt-1", "path" => "/gone"})
    end

    test "the path is optional" do
      assert %WorktreeDiscard{name: "wt-1", path: nil} =
               WorktreeDiscard.from_event(%{name: "wt-1", path: nil})

      assert %WorktreeDiscard{name: "wt-1", path: nil} =
               WorktreeDiscard.from_event(%{"name" => "wt-1"})
    end

    test "a record without a name is refused" do
      assert_raise FunctionClauseError, fn -> WorktreeDiscard.from_event(%{path: "/gone"}) end
      assert_raise ArgumentError, fn -> struct!(WorktreeDiscard, path: "/gone") end
    end
  end
end
