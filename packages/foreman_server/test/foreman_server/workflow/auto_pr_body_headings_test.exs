defmodule ForemanServer.Workflow.AutoPRBodyHeadingsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AutoPR

  @headings ["## Summary", "## Testing"]

  test "keeps the task body when the project requires no headings" do
    context = %{run_id: "run-1", base_branch: "main", task_title: "T", task_description: "D"}

    assert {:ok, %AutoPR.PrContent{title: "T", body: "D"}} =
             AutoPR.__pr_content_for_test__(context)
  end

  test "carries the required headings with the task and the run's commits under them" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      task_description: "D",
      pr_body_headings: @headings,
      command_runner: fn
        "git", ["log", "--format=%H%x09%s", "main..foreman/run-1/implement"], _opts ->
          {"abc1234567890def\tfeat: the change\ndef4567890abc\tdocs: the readme\n", 0}
      end
    }

    assert {:ok, %AutoPR.PrContent{title: "T", body: body}} =
             AutoPR.__pr_content_for_test__(context)

    assert body =~ "## Summary\n\nT\n\nD"
    assert body =~ "## Testing\n\n- `abc1234` feat: the change\n- `def4567` docs: the readme"
  end

  test "says so under a heading when the run's commits cannot be listed" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      pr_body_headings: @headings,
      command_runner: fn "git", _args, _opts -> {"fatal: bad revision", 128} end
    }

    assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

    assert body =~
             "## Testing\n\nForeman could not list the run's commits: " <>
               "git log exited with 128: fatal: bad revision"
  end

  test "refuses a heading list the server does not accept" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      task_title: "T",
      pr_body_headings: ["Summary"]
    }

    assert {:error, %ForemanServer.Workflow.PrBody{reason: :invalid_headings}} =
             AutoPR.__pr_content_for_test__(context)
  end

  test "refuses a heading value that is not a list instead of ignoring it" do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      task_title: "T",
      pr_body_headings: "## Summary"
    }

    assert {:error, %ForemanServer.Workflow.PrBody{reason: :invalid_headings}} =
             AutoPR.__pr_content_for_test__(context)
  end

  @tag :tmp_dir
  test "lists the commits of the head branch the artifact names, not the run's own", %{
    tmp_dir: tmp_dir
  } do
    context = %{
      run_id: "run-1",
      base_branch: "main",
      head_branch: "foreman/run-1/implement",
      task_title: "T",
      pr_body_headings: @headings
    }

    agent = self()

    command_runner = fn
      "git", ["log", "--format=%H%x09%s", "main..skill/own-branch"], _opts ->
        send(agent, {:listed, "main..skill/own-branch"})
        {"abc1234567890def\tfeat: the change\n", 0}

      "git", _args, _opts ->
        flunk("listed the run's own branch instead of the artifact's")
    end

    artifact = Path.join(tmp_dir, "artifact.md")
    File.write!(artifact, "done\nFOREMAN_BRANCH=skill/own-branch\n")

    context = Map.merge(context, %{artifact_path: artifact, command_runner: command_runner})

    assert {:ok, %AutoPR.PrContent{body: body}} = AutoPR.__pr_content_for_test__(context)

    assert_received {:listed, "main..skill/own-branch"}
    assert body =~ "## Testing\n\n- `abc1234` feat: the change"
  end
end
