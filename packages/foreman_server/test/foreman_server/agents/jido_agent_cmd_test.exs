defmodule ForemanServer.Agents.JidoAgentCmdTest do
  @moduledoc """
  Tests for the Jido agent cmd/2 loop (TRD-2026-4212be7e, JCR-T003).

  JCR-T003 is supplied by upstream `Jido.Agent.cmd/2,3` (the loop
  is `action in → updated agent struct + directives out` per
  `Jido.Agent.cmd_result :: {t(), [directive()]}`). The foreman-
  side work is to verify the contract holds under the Foreman
  test environment (the upstream Jido deps are vendored under
  `packages/foreman_server/deps/jido`).

  The test defines a `StubAgent` with `use Jido.Agent` (which
  generates the `cmd/2` function — `Jido.Agent` itself does not
  define `cmd/2`; it's generated per `use Jido.Agent`). It does
  NOT override `cmd/2` — the test exercises the real generated
  function with a real `Jido.Agent` struct.
  """

  use ExUnit.Case, async: true

  alias Jido.Actions.Noop

  defmodule StubAgent do
    use Jido.Agent,
      name: "stub",
      description: "stub agent for JCR-T003 cmd loop test",
      category: "test",
      tags: [],
      schema: []
  end

  describe "StubAgent.cmd/2 (JCR-T003 — generated, not overridden)" do
    test "StubAgent uses Jido.Agent and exposes the generated cmd/2" do
      # `use Jido.Agent` is what generates the `cmd/2` function
      # (per Jido.Agent.cmd/3). Verifying both halves of the
      # contract:
      # 1. The behaviour Jido.Agent is in the StubAgent attributes.
      # 2. The generated `cmd/2` is exported.
      behaviours =
        StubAgent.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Agent in behaviours
      assert function_exported?(StubAgent, :cmd, 2)
    end

    test "StubAgent.new/1 returns a Jido.Agent struct; StubAgent.cmd/2 returns {agent, directives}" do
      # Build the canonical cmd/2 input: a Jido.Agent struct.
      agent = StubAgent.new(actions: [Noop])
      assert %Jido.Agent{} = agent

      # Run the cmd/2 loop on the Noop action. The contract
      # is `{updated_agent, [directives]}` per `Jido.Agent.cmd_result`.
      # StubAgent.cmd/2 is the upstream-generated function (we did
      # not override it); Noop is a no-op action so the agent
      # struct comes back unchanged and the directive list is
      # empty.
      {updated_agent, directives} = StubAgent.cmd(agent, Noop)

      assert %Jido.Agent{} = updated_agent
      assert is_list(directives)
    end
  end
end
