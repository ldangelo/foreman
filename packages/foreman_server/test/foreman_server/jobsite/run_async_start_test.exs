defmodule ForemanServer.Jobsite.RunAsyncStartTest do
  # `run_async/1` answers with an id only when that id is readable. An Executor that dies before it
  # records `jobsite.start` leaves an id that would 404 forever, so that is an error, not an id.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error}

  test "an Executor that crashes before jobsite.start is an error, not an unreadable id" do
    before = Jobsite.list() |> length()

    # `build_spec/2` calls `provider.name()` on the sandbox provider; a module that does not exist
    # makes the Executor raise before any event is appended.
    opts = [
      sandbox: {ForemanServer.NoSuchSandboxProvider, %{}},
      agent: Agents.pi("x"),
      prompt: "go",
      max_iterations: 1
    ]

    capture_log(fn ->
      assert {:error, %Error{code: :jobsite_start_failed, details: %{reason: reason}}} =
               Jobsite.run_async(opts)

      assert {:executor_exited_before_start, _} = reason
    end)

    assert length(Jobsite.list()) == before
  end
end
