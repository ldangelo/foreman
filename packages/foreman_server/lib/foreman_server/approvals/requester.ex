defmodule ForemanServer.Approvals.Requester do
  @moduledoc """
  Records "this agent needs permission to use tool X" as a `tool.request`
  (`ForemanServer.Aggregates.ToolCall`).

  The request is idempotent: its `command_id` is derived from the run and tool
  call ids, so the same permission need reported twice appends one
  `ToolCallRequested`. The raw tool input is never stored: `input` is rendered to
  a string, redacted with the project's secret VALUES (`ForemanServer.Coordinator.Redact`,
  whatever the secret's name), cut to 2000 characters here, and redacted by name
  pattern again and cut to 500 characters by the aggregate.
  """

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Capability, Dispatch}
  alias ForemanServer.Coordinator.Redact

  @type context :: %{
          required(:run_id) => String.t(),
          optional(:project_id) => String.t() | nil,
          optional(:provider) => atom() | String.t() | nil
        }

  @raw_input_limit 2_000

  @doc """
  Request permission. `opts`: `:tool_call_id` (default: derived from `run_id`,
  `tool_name` and `:phase_index`), `:phase_index`, `:delivery` (a `Capability.mode/1` result; default: the
  provider's mode, `:inflight` for a blocked in-flight permission prompt), `:gateway` (test seam).

  Returns `{:ok, tool_call_id}`; the call is `requested` afterwards (also when it
  already was), or `{:error, reason}` from the gateway.
  """
  @spec request(context(), String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def request(%{run_id: run_id} = context, tool_name, input, opts \\ [])
      when is_binary(run_id) and run_id != "" and is_binary(tool_name) do
    tool_call_id = Keyword.get(opts, :tool_call_id) || derived_id(tool_name, opts)
    provider = context |> Map.get(:provider) |> provider_name()
    project_id = Map.get(context, :project_id)

    command = %{
      type: "tool.request",
      command_id: "tool-request:#{run_id}:#{tool_call_id}",
      aggregate_id: ToolCall.stream_id(run_id, tool_call_id),
      payload: %{
        run_id: run_id,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        input_summary: summarize(input, project_id),
        project_id: project_id,
        provider: provider,
        requested_by: "agent",
        delivery:
          opts
          |> Keyword.get_lazy(:delivery, fn -> Capability.mode(provider) end)
          |> Capability.delivery_name()
      }
    }

    case Dispatch.system(command, Keyword.get(opts, :gateway, ForemanServer.CommandGateway)) do
      {:ok, _} -> {:ok, tool_call_id}
      {:error, :tool_call_already_requested} -> {:ok, tool_call_id}
      {:error, reason} -> {:error, reason}
      {:error, reason, _detail} -> {:error, reason}
    end
  end

  defp derived_id(tool_name, opts) do
    case Keyword.get(opts, :phase_index) do
      nil -> "perm-#{tool_name}"
      phase_index -> "perm-#{phase_index}-#{tool_name}"
    end
  end

  defp provider_name(nil), do: nil
  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_name(provider) when is_binary(provider), do: provider

  # The input as text, redacted with the project's secret values and only THEN bounded: a cut
  # first could leave half of a secret behind. The list is resolved once, for this one input.
  defp summarize(nil, _project_id), do: nil

  defp summarize(input, project_id) do
    input
    |> render()
    |> then(&Redact.text(project_id, &1, secrets: Redact.secrets(project_id)))
    |> String.slice(0, @raw_input_limit)
  end

  defp render(input) when is_binary(input), do: input

  # JSON first: the aggregate's redaction understands `"key": "value"` pairs.
  defp render(input) do
    case Jason.encode(input) do
      {:ok, json} -> json
      {:error, _} -> inspect(input, limit: 20, printable_limit: @raw_input_limit)
    end
  end
end
