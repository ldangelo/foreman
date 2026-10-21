defmodule ForemanServer.Coordinator.AgentHarnessTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.Agent.Harness

  test "the run is read-only, outside the repository, with a timeout, and pi's user setup is switched off" do
    assert {:ok, request} =
             Harness.build_request("prompt",
               provider: :pi,
               model: "minimax/MiniMax-M2.7-highspeed",
               effort: "low",
               timeout_ms: 42_000,
               project_id: "p/../x"
             )

    assert request.sandbox_mode == :read_only
    assert request.approval_mode == :default
    assert request.runtime_timeout_ms == 42_000 and request.idle_timeout_ms == 42_000

    assert {request.model, request.reasoning_effort, request.provider} ==
             {"minimax/MiniMax-M2.7-highspeed", :low, :pi}

    # scratch directory, project id sanitised: never a path the project controls
    assert String.starts_with?(request.cwd, Path.join(System.tmp_dir!(), "foreman-coordinator"))
    assert Path.dirname(request.cwd) == Path.join(System.tmp_dir!(), "foreman-coordinator")
    assert File.dir?(request.cwd)

    {:ok, dotdot} = Harness.build_request("prompt", provider: :pi, project_id: "..")
    assert Path.dirname(dotdot.cwd) == Path.join(System.tmp_dir!(), "foreman-coordinator")

    assert %{
             no_extensions: true,
             no_skills: true,
             no_context_files: true,
             no_session: true,
             extra_args: ["--no-mcp"]
           } = request.provider_options
  end

  test "the pi argv carries the isolation flags and read-only tools only" do
    {:ok, request} = Harness.build_request("prompt", provider: :pi, project_id: "p")
    {:ok, argv} = Jido.Harness.Adapters.Pi.build_argv(request, request.provider_options)

    assert "--no-mcp" in argv and "--no-extensions" in argv and "--no-skills" in argv and
             "--no-context-files" in argv and "--no-session" in argv

    tools = Enum.at(argv, Enum.find_index(argv, &(&1 == "--tools")) + 1)
    assert tools == "read,grep,find,ls"
    refute "bash" in String.split(tools, ",")
  end

  test "an unset or unknown effort leaves the request's effort unset" do
    for effort <- [nil, "extreme", 3] do
      assert {:ok, %{reasoning_effort: nil}} =
               Harness.build_request("p", provider: :pi, effort: effort, project_id: "p")
    end
  end

  test "other providers get no pi-only options" do
    assert {:ok, %{provider_options: opts}} =
             Harness.build_request("prompt", provider: :claude, project_id: "p")

    assert opts == %{}
  end
end
