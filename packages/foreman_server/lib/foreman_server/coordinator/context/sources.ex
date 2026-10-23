defmodule ForemanServer.Coordinator.Context.Sources do
  @moduledoc """
  Where `Coordinator.Context` reads project facts from. The default is
  `Sources.Live`; tests pass a fixture module through `build/2`'s `:sources`
  option so budget behaviour can be exercised with thousands of cards without
  creating runs.
  """

  alias ForemanServer.Coordinator.{Conversation, Tuning}
  alias ForemanServer.Threads.Thread

  @type project :: %{
          name: String.t() | nil,
          goal: String.t() | nil,
          instructions: String.t() | nil,
          memory_index: String.t() | nil,
          repositories: [String.t()]
        }

  @callback conversation(String.t()) :: {:ok, Conversation.t()} | {:error, :project_not_found}
  @callback project(String.t()) :: {:ok, project()} | {:error, :project_not_found}
  @callback threads(String.t()) :: [Thread.t()]
  @callback workflows() :: [%{name: String.t(), description: String.t() | nil}]
  @callback invalid_workflows() :: [%{name: String.t(), reason: String.t()}]
  @callback tuning(String.t()) :: Tuning.t()
  @callback status_counts(String.t()) :: %{
              ForemanServer.Overview.Group.group() => non_neg_integer()
            }
  @callback limits(String.t()) :: %{
              optional(:max_concurrent_runs) => pos_integer(),
              optional(:active_runs) => non_neg_integer(),
              optional(:daily_thread_cap) => pos_integer() | nil,
              optional(:remaining_today) => non_neg_integer() | nil
            }
end
