defmodule ForemanServer.Threads.ThreadTitleTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Threads.Thread

  describe "title/2" do
    test "task title wins" do
      task = %{title: "  Fix login  ", prompt: "prompt", description: "desc", task_id: "T-1"}
      assert Thread.title(task, "run-1") == "Fix login"
    end

    test "blank title falls to the first non-blank prompt line" do
      task = %{title: "   ", prompt: "\n  \nFirst real line\nsecond", description: "desc"}
      assert Thread.title(task, "run-1") == "First real line"
    end

    test "blank prompt falls to the first non-blank description line" do
      task = %{
        title: nil,
        prompt: " \n ",
        description: "\r\nDescribed here\nmore",
        task_id: "T-1"
      }

      assert Thread.title(task, "run-1") == "Described here"
    end

    test "no text falls to task_id" do
      task = %{title: "", prompt: nil, description: "", task_id: "T-1"}
      assert Thread.title(task, "run-1") == "T-1"
    end

    test "nil task yields the fallback id" do
      assert Thread.title(nil, "run-1") == "run-1"
    end

    test "task without task_id yields the fallback id" do
      assert Thread.title(%{title: nil}, "run-1") == "run-1"
    end
  end

  describe "shared derivation" do
    test "from_run/6 and from_jobsite/3 use the same title as title/2" do
      for task <- [
            %{task_id: "T-1", title: "Named", prompt: "p"},
            %{task_id: "T-2", title: " ", prompt: "\nPrompt line\nx"},
            %{task_id: "T-3", title: nil, prompt: nil, description: "Desc line"},
            %{task_id: "T-4"},
            nil
          ] do
        run = %{run_id: "r1", project_id: "p", task_id: "T", status: "running"}
        jobsite = %{jobsite_id: "j1", project_id: "p", status: "running"}

        assert Thread.from_run(run, task, [], {:error, :not_found}, nil, ["r1"]).title ==
                 Thread.title(task, "r1")

        assert Thread.from_jobsite(jobsite, task, nil).title == Thread.title(task, "j1")
      end
    end
  end
end
