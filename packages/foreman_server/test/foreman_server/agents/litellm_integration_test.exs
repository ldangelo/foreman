defmodule ForemanServer.Agents.LitellmIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias ForemanServer.Agents.{LitellmRouter, ZeroCandidatesHandler, LitellmUnavailableHandler}

  test "auto-routing returns model=auto" do
    assert LitellmRouter.model() == "auto"
  end

  test "zero-candidates handler formats error" do
    err = ZeroCandidatesHandler.format_error([%{reason: "no provider"}])
    assert err.kind == :zero_candidates
  end

  test "unavailable handler marks blocked" do
    assert {:blocked, _} = LitellmUnavailableHandler.handle(:connection_refused)
  end
end