defmodule ForemanServer.Agents.JidoSignalTopicsTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoSignalTopics` — the Jido-aligned
  topic namespace mapping for Foreman signal-bus subscribers
  (TRD-2026-4212be7e, JSI-T001).

  The TRD names four slash-separated topics. Jido's path grammar
  rejects `/`, so we publish them as `com.foreman.command.*`,
  `com.foreman.operator.*`, `com.foreman.inbox.*`, and
  `agents.<id>.directive`. These tests pin the mapping.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Agents.JidoSignalTopics

  describe "fixed topic patterns" do
    test "foreman_command/0 returns the Jido-aligned command topic" do
      assert JidoSignalTopics.foreman_command() == "com.foreman.command.*"
    end

    test "foreman_operator/0 returns the Jido-aligned operator topic" do
      assert JidoSignalTopics.foreman_operator() == "com.foreman.operator.*"
    end

    test "foreman_inbox/0 returns the Jido-aligned inbox topic" do
      assert JidoSignalTopics.foreman_inbox() == "com.foreman.inbox.*"
    end

    test "agent_directive_pattern/0 returns the agents.*.directive pattern" do
      assert JidoSignalTopics.agent_directive_pattern() == "agents.*.directive"
    end
  end

  describe "agent_directive/1" do
    test "expands to a concrete agents.<id>.directive topic" do
      assert JidoSignalTopics.agent_directive("agent-7") == "agents.agent-7.directive"
    end

    test "raises on non-binary id" do
      assert_raise FunctionClauseError, fn ->
        JidoSignalTopics.agent_directive(123)
      end
    end
  end

  describe "all_patterns/0" do
    test "returns all four TRD topic patterns" do
      assert JidoSignalTopics.all_patterns() == [
               "com.foreman.command.*",
               "com.foreman.operator.*",
               "com.foreman.inbox.*",
               "agents.*.directive"
             ]
    end
  end

  describe "Jido router path-grammar compliance" do
    test "every topic passes Jido.Signal.Router.Validator.validate_path/1" do
      # Per-segment regex is [a-zA-Z0-9_-]+ (and * / ** for
      # wildcards); segments are dot-separated. The foreman/commands
      # slash-separated form is INVALID per Jido. Assert the
      # Jido-aligned form passes the upstream validator.
      for topic <- JidoSignalTopics.all_patterns() do
        assert {:ok, ^topic} = Jido.Signal.Router.Validator.validate_path(topic),
               "topic #{inspect(topic)} failed Jido validator"
      end
    end

    test "the TRD's slash-separated form would NOT validate" do
      # This documents *why* we have the Jido-aligned form at all:
      # the TRD's "foreman/commands" path is invalid per Jido's path
      # grammar (slashes are not in the segment regex).
      assert {:error, _} =
               Jido.Signal.Router.Validator.validate_path("foreman/commands")
    end
  end
end
