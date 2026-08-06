defmodule ForemanServer.TaskProviders.BrRunner do
  @moduledoc """
  Behaviour contract for the `br` subprocess boundary.

  Implementations translate a tagged request tuple into the concrete `br`
  invocation used by the Beads task provider. Production uses
  `ForemanServer.TaskProviders.SystemBrRunner` (TRD-004); tests bind
  `ForemanServer.TaskProviders.BrRunnerMock` (TRD-030).

  `request` is a tagged tuple of action atom plus payload map. Example actions
  include `:ready`, `:show`, `:update`, `:close`, and `:where`.

  `project_config` carries the resolved per-project `database_path` established
  at registration time by the Project aggregate.

  `opts` is a keyword list for Mox expectation options, telemetry options, and
  other call-scoped runner metadata.
  """

  @typedoc "Tagged runner request: action atom plus action-specific payload map."
  @type request :: {atom(), map()}

  @typedoc "Resolved per-project Beads adapter configuration."
  @type project_config :: %{database_path: String.t()}

  @typedoc "Optional call-scoped runner options."
  @type opts :: keyword()

  @doc "Execute a `br` request against the resolved project configuration."
  @callback cmd(request :: request(), project_config :: project_config(), opts :: opts()) ::
              {:ok, term()} | {:error, term()}
end
