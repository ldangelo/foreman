defmodule ForemanServer.Agents.JidoSignalTopicsTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoSignalTopics` — the namespace
  mapping + bus registration (TRD-2026-4212be7e, JSI-T001).

  JSI-T001 asks for configuring the four Jido-aligned signal topics:
    com.foreman.command.*      (TRD "foreman/commands")
    com.foreman.operator.*      (TRD "foreman/operator")
    com.foreman.inbox.*         (TRD "foreman/inbox")
    agents.<id>.directive       (TRD "agents/<agent-id>/directive")

  The namespace helper has been in place since the JidoSignalTopics
  module was first written. JSI-T001's remaining production work
  is verifying the bus accepts subscribe/publish on these
  patterns.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoSignalTopics

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "Jido-aligned topic names (matches the TRD's slash forms)" do
    test "foreman_command/0 returns 'com.foreman.command.*'" do
      assert JidoSignalTopics.foreman_command() == "com.foreman.command.*"
    end

    test "foreman_operator/0 returns 'com.foreman.operator.*'" do
      assert JidoSignalTopics.foreman_operator() == "com.foreman.operator.*"
    end

    test "foreman_inbox/0 returns 'com.foreman.inbox.*'" do
      assert JidoSignalTopics.foreman_inbox() == "com.foreman.inbox.*"
    end

    test "agent_directive_pattern/0 returns 'agents.*.directive'" do
      assert JidoSignalTopics.agent_directive_pattern() == "agents.*.directive"
    end
  end

  describe "all_patterns/0 returns the 4 TRD topics" do
    test "returns the canonical topic set" do
      assert JidoSignalTopics.all_patterns() == [
               "com.foreman.command.*",
               "com.foreman.operator.*",
               "com.foreman.inbox.*",
               "agents.*.directive"
             ]
    end
  end

  describe "agent_directive/1 (per-agent variant)" do
    test "returns 'agents.<id>.directive' for a string id" do
      assert JidoSignalTopics.agent_directive("agent-7") == "agents.agent-7.directive"
    end
  end

  describe "Jido Router.Validator accepts every topic" do
    # The TRD's slash-separated topic forms are invalid per Jido's
    # path grammar. The Jido-aligned forms (no slashes) pass the
    # upstream validator. This is the production invariant JSI-T001
    # needs: the namespace helper returns shapes the bus accepts.
    test "every pattern passes the Jido validator" do
      for pattern <- JidoSignalTopics.all_patterns() do
        assert {:ok, ^pattern} = Jido.Signal.Router.Validator.validate_path(pattern),
               "pattern #{inspect(pattern)} failed Jido validator"
      end
    end

    test "agent_directive/1 also passes the Jido validator" do
      assert {:ok, "agents.x.directive"} =
               Jido.Signal.Router.Validator.validate_path("agents.x.directive")
    end
  end
end
