defmodule ForemanServer.Approvals.Capability do
  @moduledoc """
  How a tool-call decision reaches an agent, per provider (spike S2,
  `docs/spikes/S2.md`).

    * `:live` - the provider session itself asks for approval
      (`Jido.Harness.Session` `:approval_requested`) and the decision is answered
      with `Session.respond_approval/3`. Measured only on ACP transports
      (opencode, kimi).
    * `:inflight` - a claude phase with `approval_mode: prompt` whose permission
      prompts are routed to Foreman's permission MCP tool
      (`ForemanServerWeb.AgentPermissionController`, `claude --permission-prompt-tool`).
      The call is blocked inside the live session and the decision wakes it
      (`ForemanServer.Approvals.Inflight.respond/5`); no phase re-run. Chosen per
      request by the controller, never derived from the provider alone.
    * `:resume_with_override` - the provider has no live approval channel (pi
      rejects `approval_mode: :prompt` at session start; headless claude has no
      interactive channel through the one-shot transport). The run is paused, and a
      decision resumes it through E6 steering with the approved tool's
      one-phase `approval_mode` override.

  An unknown provider gets `:resume_with_override`, the mode that needs nothing
  from the provider. Clients see the mode as `approval_delivery` so a UI never
  promises a live prompt it cannot deliver.
  """

  alias ForemanServer.Jobsite.Agent

  @type mode :: :live | :inflight | :resume_with_override

  @live_providers ~w(opencode kimi)
  @edit_tools ~w(Write Edit MultiEdit NotebookEdit write edit apply_patch str_replace_editor)

  @doc "Delivery mode for a provider (atom, string or nil)."
  @spec mode(atom() | String.t() | nil) :: mode()
  def mode(provider) when is_atom(provider) and not is_nil(provider),
    do: mode(Atom.to_string(provider))

  def mode(provider) when is_binary(provider) do
    if provider in @live_providers, do: :live, else: :resume_with_override
  end

  def mode(_provider), do: :resume_with_override

  @doc "Wire name of a mode (`approval_delivery`)."
  @spec delivery_name(mode()) :: String.t()
  def delivery_name(:live), do: "live"
  def delivery_name(:inflight), do: "inflight"
  def delivery_name(:resume_with_override), do: "resume_with_override"

  @doc "Parse a stored delivery name; anything unknown is the safe `:resume_with_override`."
  @spec parse_delivery(term()) :: mode()
  def parse_delivery("live"), do: :live
  def parse_delivery("inflight"), do: :inflight
  def parse_delivery(_), do: :resume_with_override

  @doc """
  The minimal `approval_mode` name that lets an approved tool run for one phase:
  `"auto_edit"` for edit-class tools, `"auto_approve"` otherwise. Always a name
  `ForemanServer.Jobsite.Agent.parse_approval_mode/1` accepts.
  """
  @spec override_for(String.t()) :: String.t()
  def override_for(tool_name) when is_binary(tool_name) do
    name = if tool_name in @edit_tools, do: "auto_edit", else: "auto_approve"
    {:ok, _mode} = Agent.parse_approval_mode(name)
    name
  end
end
