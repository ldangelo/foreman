defmodule ForemanServer.TaskProviders.UnexpectedBrRunnerStub do
  @moduledoc """
  A stub `BrRunner` implementation that raises on any call.
  Used in tests that only exercise validation/preparation logic but never
  reach the point of invoking the runner.
  """
  @behaviour ForemanServer.TaskProviders.BrRunner

  @impl true
  def cmd(request, project_config, opts) do
    raise "unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}"
  end
end
