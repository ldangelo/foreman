defmodule ForemanServer.Jobsite.CapacityTest do
  # The cap is enforced where executors start, under one lock, so simultaneous
  # starts cannot both pass at max-1. Real executors held open by a sleeping
  # fake agent; no mocks.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Supervisor, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-cap-#{System.unique_integer([:positive])}")
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

  defp slow_opts(repo) do
    [
      repo_path: repo,
      strategy: :merge_to_head,
      sandbox: Sandboxes.host(),
      agent:
        Agents.pi("x",
          binary: @fake_agent,
          env: %{"FAKE_AGENT_SLEEP_ON_RUN" => "1", "FAKE_AGENT_SLEEP_SECS" => "4"}
        ),
      prompt: "go",
      max_iterations: 1
    ]
  end

  defp wait_for_executors_gone(0), do: :ok

  defp wait_for_executors_gone(n) do
    if Registry.count(ForemanServer.Jobsite.Registry) > 0 do
      Process.sleep(100)
      wait_for_executors_gone(n - 1)
    end
  end

  test "simultaneous starts at cap 1 admit exactly one" do
    repo = tmp_repo!()

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> Jobsite.run_async(Keyword.put(slow_opts(repo), :max_concurrent, 1)) end)
      end)
      |> Task.await_many(15_000)

    admitted = for {:ok, id} <- results, do: id
    rejected = for {:error, %Error{code: code}} <- results, do: code

    on_exit(fn ->
      Enum.each(admitted, &Jobsite.cancel(&1, "test over"))
      wait_for_executors_gone(50)
    end)

    assert length(admitted) == 1
    assert rejected == List.duplicate(:jobsite_capacity_reached, 7)
    assert Registry.count(ForemanServer.Jobsite.Registry) == 1
  end

  test "a resume is held to the same cap" do
    assert {:error, {:capacity_reached, _running, 0}} =
             Supervisor.resume_jobsite("js-any", max_concurrent: 0)
  end
end
