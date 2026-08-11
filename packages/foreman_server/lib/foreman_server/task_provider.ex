defmodule ForemanServer.TaskProvider do
  @moduledoc """
  TRD-2026-48f7b420 §PR 1a: behaviour for task provider integrations.

  Providers expose three metadata callbacks (`name/0`, `capabilities/0`,
  `available?/0`) plus nine operational callbacks (`create/2`, `list_ready/2`,
  `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, and
  `add_dependency/3`). The `@callback` declarations define the contract and
  provide the `behaviour_info(:callbacks)` reflection used by TRD-001-TEST.
  """

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.ProviderError

  @typedoc "Provider-specific project configuration resolved from application config."
  @type project_config :: term()

  @typedoc "Optional provider-specific options for listing ready issues."
  @type list_opts :: keyword() | map()

  @typedoc "Opaque provider issue identifier."
  @type issue_id :: term()

  @typedoc "Opaque provider claim token."
  @type claim_token :: term()

  @typedoc "Opaque provider completion token."
  @type completion_token :: term()

  @typedoc "Opaque provider failure token."
  @type failure_token :: term()

  @typedoc "Free-form transition note supplied when reopening an issue."
  @type transition_comment :: String.t()

  @typedoc "Provider-specific priority payload."
  @type priority :: term()

  @typedoc "Single-issue lookup result."
  @type issue_result :: {:ok, Issue.t()} | {:error, ProviderError.t()}

  @typedoc "Ready-issue listing result."
  @type list_ready_result :: {:ok, [Issue.t()]} | {:error, ProviderError.t()}

  @doc "Stable provider name used for registration and routing."
  @callback name() :: String.t()
  @doc """
  Create a new issue in the upstream provider, returning a
  `ForemanServer.TaskProvider.Issue{}` carrying the provider-side identifier.

  The canonical seven-key `attrs` map (see TRD-2026-81315f37 Architecture
  Decision #12) carries the two correlation handles (`task_id`, `command_id`)
  that link the new provider issue back to the dispatching Foreman command,
  plus the five data fields (`title`, `description`, `priority`, `task_type`,
  `dedupe_key`) that drive the provider-side argv flags.

  `task_id` and `command_id` are required — the provider MUST populate them
  into the linkage envelope (e.g. `--agent-context`) so the bead record can
  be correlated back to the Foreman task that created it (REQ-020 / REQ-021).
  """
  @callback create(project_id :: String.t(), attrs :: map()) ::
              {:ok, Issue.t()} | {:error, ProviderError.t()}

  @doc "Provider capability map advertised at registration time."
  @callback capabilities() :: map()

  @doc "Whether the provider is currently available for use."
  @callback available?() :: boolean()

  @doc "List issues that are ready to run for the given project config."
  @callback list_ready(project_config(), list_opts()) :: list_ready_result()

  @doc "Fetch a single issue by provider identifier."
  @callback get(issue_id(), project_config()) :: issue_result()

  @doc "Claim the issue in the upstream provider."
  @callback claim(issue_id(), claim_token(), project_config()) :: :ok | {:error, term()}

  @doc "Mark the issue completed in the upstream provider."
  @callback complete(issue_id(), completion_token(), project_config()) :: :ok | {:error, term()}

  @doc "Mark the issue failed in the upstream provider."
  @callback fail(issue_id(), failure_token(), project_config()) :: :ok | {:error, term()}

  @doc "Reopen an issue with an optional transition comment."
  @callback reopen(issue_id(), transition_comment(), project_config()) :: :ok | {:error, term()}

  @doc "Update issue priority in the upstream provider."
  @callback set_priority(issue_id(), priority(), project_config()) :: :ok | {:error, term()}

  @doc "Add a dependency edge between two provider issues."
  @callback add_dependency(issue_id(), issue_id(), project_config()) :: :ok | {:error, term()}
end
