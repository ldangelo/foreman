defmodule ForemanServer.Jobsite.FailedAgentTest do
  # A harness run that FAILS is reported as `{:ok, %RunResult{status: :failed}}`
  # with the failure in `result.error`, not as an `{:error, _}` return. The
  # runner must still surface it as a failure; otherwise the jobsite completes
  # with an empty "completed" iteration and no commits (found by running a
  # real agent whose credentials were rejected).
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-failed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "T"])
    File.write!(Path.join(path, "README.md"), "hi\n")
    {_, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "an agent that dies fails the jobsite instead of completing it" do
    repo = tmp_repo!()

    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: %{"FAKE_AGENT_FAIL_WITH" => "Credit balance is too low"}
      )

    assert {:error, %Error{code: :agent_failed}} =
             Jobsite.run(
               repo_path: repo,
               strategy: :merge_to_head,
               sandbox: Sandboxes.host(),
               agent: agent,
               prompt: "go"
             )

    [%{jobsite_id: id} | _] = Enum.filter(Jobsite.list(), &(&1.status == "failed"))
    assert Jobsite.get(id).status == "failed"
  end

  test "commits the agent made itself are reported even though the tree is clean at the commit step" do
    repo = tmp_repo!()

    # The fake agent writes a file but does not commit. A wrapper that commits
    # it reproduces what real agents do.
    wrapper =
      Path.join(
        System.tmp_dir!(),
        "self-committing-agent-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(wrapper, """
    #!/bin/sh
    #{@fake_agent} "$@" || exit $?
    git add -A && git -c user.name=A -c user.email=a@example.com commit -q -m "agent's own commit"
    """)

    File.chmod!(wrapper, 0o755)
    on_exit(fn -> File.rm(wrapper) end)

    assert {:ok, result} =
             Jobsite.run(
               repo_path: repo,
               strategy: {:branch, "agent/self-commit"},
               sandbox: Sandboxes.host(),
               agent: Agents.pi("x", binary: wrapper),
               prompt: "go"
             )

    assert [%{subject: "agent's own commit"}] = result.commits
    assert [%{subject: "agent's own commit"}] = Jobsite.get(result.jobsite_id).commits
  end
end
