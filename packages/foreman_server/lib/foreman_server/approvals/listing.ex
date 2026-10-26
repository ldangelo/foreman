defmodule ForemanServer.Approvals.Listing do
  @moduledoc """
  The result of listing tool-call approvals: the ONE payload that
  `GET /api/projects/:id/approvals`, `GET /api/runs/:run_id/approvals` and the
  `foreman_approvals_list` MCP tool return, built here from the projection so both
  transports share one shape (AGENTS.md 5.1, 5.7).

  The struct field is the wire name: `Jason.Encoder` emits `{"approvals": [...]}`,
  each entry a `ForemanServer.Approvals.DTO`.
  """

  alias ForemanServer.Approvals.DTO
  alias ForemanServer.ProjectionStore

  @enforce_keys [:approvals]
  @type t :: %__MODULE__{approvals: [DTO.t()]}
  @derive Jason.Encoder
  defstruct [:approvals]

  @doc "The listing of projected tool calls."
  @spec build([ProjectionStore.tool_call()]) :: t()
  def build(calls) when is_list(calls), do: %__MODULE__{approvals: DTO.list(calls)}
end
