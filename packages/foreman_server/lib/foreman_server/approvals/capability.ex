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
      decision resumes it through E6 steering with a next-phase `approval_mode`
      override. That override is an approval MODE, not a per-tool grant: it relaxes
      the permission mode of the run's NEXT PHASE as a whole, so every tool of that
      phase is allowed, not only the approved one. Only `:inflight` decides one call.

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
  The `approval_mode` name an approval resumes the run's next phase with:
  `"auto_edit"` for edit-class tools, `"auto_approve"` otherwise (for Claude
  `--permission-mode acceptEdits` / `bypassPermissions`). It covers the WHOLE phase,
  not only the approved tool: there is no per-tool grant on this path (`bypassPermissions`
  skips every permission check, so an `allowed_tools` list cannot narrow it, and a
  per-tool grant would need a new steer field through every layer of the resume path).
  Always a name `ForemanServer.Jobsite.Agent.parse_approval_mode/1` accepts.
  """
  @spec override_for(String.t()) :: String.t()
  def override_for(tool_name) when is_binary(tool_name) do
    name = if tool_name in @edit_tools, do: "auto_edit", else: "auto_approve"
    {:ok, _mode} = Agent.parse_approval_mode(name)
    name
  end
end
