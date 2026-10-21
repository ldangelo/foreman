defmodule ForemanServer.Approvals.CapabilityTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Approvals.Capability
  alias ForemanServer.Jobsite.Agent

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

  test "override is the minimal mode and always one the harness accepts" do
    assert Capability.override_for("Write") == "auto_edit"
    assert Capability.override_for("Edit") == "auto_edit"
    assert Capability.override_for("Bash") == "auto_approve"
    assert Capability.override_for("WebFetch") == "auto_approve"

    for tool <- ["Write", "Bash", "anything"] do
      assert {:ok, _} = Agent.parse_approval_mode(Capability.override_for(tool))
    end
  end
end
