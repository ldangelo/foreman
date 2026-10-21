defmodule ForemanServer.Approvals.PhasePause do
  @moduledoc """
  The `:resume_with_override` producer (spike S2 NO-GO path): a phase's agent
  finished but reported permission denials (`{:permission_denied, tools}`, see
  `ForemanServer.AgentRuntime.JidoHarness.RunResult`), meaning it was blocked on
  tools it was not allowed to use.

  Instead of failing the phase, `request_and_pause/3` records one `tool.request`
  per denied tool and pauses the run (`run.pause`, reason `"awaiting_approval"`),
  so the thread shows up as "Waiting on you" with the pending approvals. A later
  `tool.approve` / `tool.deny` resumes the run through
  `ForemanServer.Approvals.Deliverer`.

  Idempotent: a tool of the same phase that already has a pending request reuses
  it, so a repeated report never stacks a second request; once a request was
  decided the next denial of that tool is a new request.
  """

  alias ForemanServer.Approvals.{Config, Dispatch, Requester}
  alias ForemanServer.ProjectionStore

  @pause_reason "awaiting_approval"

  @type context :: %{
          required(:run_id) => String.t(),
          optional(:project_id) => String.t() | nil,
          optional(:provider) => atom() | String.t() | nil
        }

  @doc "The `run.pause` reason this module uses."
  @spec pause_reason() :: String.t()
  def pause_reason, do: @pause_reason

  @doc """
  Record a request for each denied tool and pause the run. `:ok` only when every
  request and the pause were recorded; otherwise `{:error, reason}` and the caller
  keeps the phase-failure path (a denied run is never silently left running).
  `opts[:gateway]` is a test seam.
  """
  @spec request_and_pause(context(), non_neg_integer(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def request_and_pause(%{run_id: run_id} = context, phase_index, tools, opts \\ [])
      when is_list(tools) and tools != [] do
    gateway = Keyword.get(opts, :gateway, ForemanServer.CommandGateway)

    with {:ok, ids} <- request_all(context, phase_index, tools, gateway) do
      pause(run_id, hd(ids), gateway)
    end
  end

  @doc "Whether permission-denied phases pause for approval (`Approvals.Config`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.pause_on_permission_denied?()

  defp request_all(context, phase_index, tools, gateway) do
    tools
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case request_one(context, phase_index, tool, gateway) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp request_one(%{run_id: run_id} = context, phase_index, tool, gateway) do
    prefix = "perm-#{phase_index}-#{tool}-"

    existing =
      Enum.filter(
        ProjectionStore.run_approvals(run_id, status: :all),
        &String.starts_with?(&1.tool_call_id, prefix)
      )

    case Enum.find(existing, &(&1.status == "requested")) do
      %{tool_call_id: id} ->
        {:ok, id}

      nil ->
        Requester.request(
          context,
          tool,
          "phase #{phase_index} was denied permission to use #{tool}",
          tool_call_id: prefix <> Integer.to_string(length(existing) + 1),
          gateway: gateway
        )
    end
  end

  defp pause(run_id, first_tool_call_id, gateway) do
    command = %{
      type: "run.pause",
      command_id: "approval-pause:#{run_id}:#{first_tool_call_id}",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id, reason: @pause_reason}
    }

    case Dispatch.system(command, gateway) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, _detail} -> {:error, reason}
    end
  end
end
