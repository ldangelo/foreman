defmodule ForemanServer.Projects.ForkSource do
  @moduledoc """
  The provider session a forked continuation (`adopt --continue --fork`) copies, read from the
  projections of the subject being continued:

    * a `run`: the LAST session its workers bound (`WorkerSessionBound`). A workflow run binds one when
      a worker ends, so a run still on its first phase has none yet;
    * a `task`: the same, for its most recently started run that has one;
    * a `jobsite`: the session its agent reported (`JobsiteSessionBound` while an iteration runs, so a
      running jobsite has one as soon as its agent has started).

  Nothing is guessed and nothing falls back to a context-seeded thread: the operator asked for a fork.
  Refusals are typed and say what is missing.

    * `{:fork_no_session, kind, id}` - no provider session was recorded for the subject (still on its
      first worker, or older than the provider-session record);
    * `{:fork_provider_unsupported, provider}` - the session belongs to a provider that cannot fork
      (`ForemanServer.AgentRuntime.JidoHarness.ForkSession.providers/0`).
  """

  alias ForemanServer.AgentRuntime.JidoHarness.ForkSession
  alias ForemanServer.ProjectionStore

  @enforce_keys [:provider, :session_id]
  defstruct [:provider, :session_id]

  @type t :: %__MODULE__{provider: String.t(), session_id: String.t()}

  @spec resolve(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def resolve("run", id) when is_binary(id) do
    case ProjectionStore.run(id) do
      nil -> {:error, {:subject_not_found, "run", id}}
      run -> run |> from_run() |> checked("run", id)
    end
  end

  def resolve("task", id) when is_binary(id) do
    ProjectionStore.list_runs()
    |> Enum.filter(&(&1.task_id == id))
    |> Enum.sort_by(& &1.started_at_ms, :desc)
    |> Enum.find_value(&from_run/1)
    |> checked("task", id)
  end

  def resolve("jobsite", id) when is_binary(id) do
    case ProjectionStore.jobsite(id) do
      nil -> {:error, {:subject_not_found, "jobsite", id}}
      jobsite -> jobsite |> from_jobsite() |> checked("jobsite", id)
    end
  end

  defp from_run(run) do
    run
    |> Map.get(:provider_sessions, [])
    |> Enum.filter(&(is_binary(&1[:provider]) and is_binary(&1[:provider_session_id])))
    |> List.last()
    |> case do
      nil ->
        nil

      %{provider: provider, provider_session_id: id} ->
        %__MODULE__{provider: provider, session_id: id}
    end
  end

  # `agent.provider` is the string `Jobsite.Executor.start_payload/2` recorded.
  defp from_jobsite(%{session_id: session_id, agent: agent}) when is_binary(session_id) do
    %__MODULE__{provider: Map.get(agent, :provider), session_id: session_id}
  end

  defp from_jobsite(_no_session), do: nil

  defp checked(nil, kind, id), do: {:error, {:fork_no_session, kind, id}}

  defp checked(%__MODULE__{provider: provider} = source, _kind, _id) do
    if provider in ForkSession.providers(),
      do: {:ok, source},
      else: {:error, {:fork_provider_unsupported, provider}}
  end
end
