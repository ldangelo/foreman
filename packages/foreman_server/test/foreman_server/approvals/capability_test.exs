defmodule ForemanServer.Approvals.CapabilityTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Approvals.Capability
  alias ForemanServer.Jobsite.Agent
  alias Jido.Harness.Adapters.Claude
  alias Jido.Harness.RunRequest

  # docs/spikes/S2.md: only ACP transports (opencode, kimi) have live approvals;
  # pi has none and headless claude has no interactive channel.
  test "live only for ACP providers; pi, claude and unknown providers resume with an override" do
    assert Capability.mode(:opencode) == :live
    assert Capability.mode("kimi") == :live
    assert Capability.mode(:pi) == :resume_with_override
    assert Capability.mode(:claude) == :resume_with_override
    assert Capability.mode("claude") == :resume_with_override
    assert Capability.mode(:something_new) == :resume_with_override
    assert Capability.mode(nil) == :resume_with_override
  end

  test "delivery names round-trip and an unknown stored name is the safe floor" do
    for mode <- [:live, :resume_with_override] do
      assert mode |> Capability.delivery_name() |> Capability.parse_delivery() == mode
    end

    assert Capability.parse_delivery(nil) == :resume_with_override
    assert Capability.parse_delivery("telepathy") == :resume_with_override
  end

  test "the override is an approval mode name: auto_edit for edit tools, auto_approve otherwise, always one the harness accepts" do
    assert Capability.override_for("Write") == "auto_edit"
    assert Capability.override_for("Edit") == "auto_edit"
    assert Capability.override_for("Bash") == "auto_approve"
    assert Capability.override_for("WebFetch") == "auto_approve"

    for tool <- ["Write", "Bash", "anything"] do
      assert {:ok, _} = Agent.parse_approval_mode(Capability.override_for(tool))
    end
  end

  # The scope of an approval on the post-hoc path, pinned against the harness Foreman launches
  # with (a path dependency: this is the code that builds the resumed claude command line).
  # The override is a permission MODE for the whole next phase, not a grant for one tool, and
  # an `allowed_tools` list cannot narrow it. The documentation and CLI help say exactly this.
  describe "what the resumed Claude launch carries" do
    test "approving a non-edit tool launches the next phase with bypassPermissions" do
      assert flag_values(claude_argv("Bash"), "--permission-mode") == ["bypassPermissions"]
    end

    test "approving an edit tool launches the next phase with acceptEdits" do
      assert flag_values(claude_argv("Write"), "--permission-mode") == ["acceptEdits"]
    end

    test "an allowed_tools list rides along but does not replace the mode: bypassPermissions stays" do
      argv = claude_argv("Bash", %{allowed_tools: ["Bash"]})

      assert flag_values(argv, "--allowedTools") == ["Bash"]
      assert flag_values(argv, "--permission-mode") == ["bypassPermissions"]
    end
  end

  defp claude_argv(tool, extra \\ %{}) do
    {:ok, mode} = Agent.parse_approval_mode(Capability.override_for(tool))
    request = RunRequest.new!(Map.merge(%{prompt: "retry", approval_mode: mode}, extra))
    {:ok, argv} = Claude.build_argv(request, %{})
    argv
  end

  defp flag_values(argv, flag) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [^flag, value] -> [value]
      _other -> []
    end)
  end
end
