defmodule ForemanServer.Agents.JidoSignalTopics do
  @moduledoc """
  Jido-aligned topic names for Foreman signal-bus subscribers
  (TRD-2026-4212be7e, JSI-T001).

  The TRD's PR 2 names four topics with slash separators:

      foreman/commands        — Jido agent → Foreman command ingestion
      foreman/operator        — operator UI → Jido agent questions
      foreman/inbox           — Foreman → operator notifications
      agents/<agent-id>/directive  — Foreman → Jido agent directives

  Jido's `Jido.Signal.Bus.subscribe/3` `path` argument is matched
  against `signal.type` via `Jido.Signal.Router.Validator`, whose
  regex only accepts `[a-zA-Z0-9_-]` plus `*`/`**` (no slash). Foreman
  therefore publishes its topics in Jido-aligned form:

      com.foreman.command.*       (TRD "foreman/commands")
      com.foreman.operator.*       (TRD "foreman/operator")
      com.foreman.inbox.*          (TRD "foreman/inbox")
      agents.<agent-id>.directive  (TRD "agents/<agent-id>/directive")

  The exact namespace mapping is documented in this module so that
  every other JSI/JSH/JOT module that publishes or subscribes to
  Jido signals uses a single source of truth for the topic name.
  """

  @topic_foreman_command "com.foreman.command.*"
  @topic_foreman_operator "com.foreman.operator.*"
  @topic_foreman_inbox "com.foreman.inbox.*"

  @doc """
  Topic pattern for the foreman command ingestion bus (TRD
  `foreman/commands`). Jido agents publish CloudEvents on this
  topic pattern; the `ForemanServer.Agents.SignalToCommandAdapter`
  subscribes to it.
  """
  @spec foreman_command() :: String.t()
  def foreman_command, do: @topic_foreman_command

  @doc """
  Topic pattern for the operator-to-agent bus (TRD `foreman/operator`).
  The operator UI / `ensemble:fix-issue` skill publishes here when
  an operator answers a blocking agent question.
  """
  @spec foreman_operator() :: String.t()
  def foreman_operator, do: @topic_foreman_operator

  @doc """
  Topic pattern for the agent-to-operator inbox bus (TRD
  `foreman/inbox`). The agent publishes human-facing notifications
  here; the LiveDashboard (JLD) and operator inbox API subscribe.
  """
  @spec foreman_inbox() :: String.t()
  def foreman_inbox, do: @topic_foreman_inbox

  @doc """
  Topic pattern for the Foreman-to-agent directive bus (TRD
  `agents/<agent-id>/directive`). The `<agent-id>` slot is filled
  in by the caller — see `agent_directive/1` for the helper.
  """
  @spec agent_directive_pattern() :: String.t()
  def agent_directive_pattern, do: "agents.*.directive"

  @doc """
  Concrete topic for a specific agent id (TRD
  `agents/<agent-id>/directive`).
  """
  @spec agent_directive(String.t()) :: String.t()
  def agent_directive(agent_id) when is_binary(agent_id),
    do: "agents.#{agent_id}.directive"

  @doc """
  All four topic patterns as a list, for supervisors / config docs.
  """
  @spec all_patterns() :: [String.t()]
  def all_patterns do
    [
      foreman_command(),
      foreman_operator(),
      foreman_inbox(),
      agent_directive_pattern()
    ]
  end
end
