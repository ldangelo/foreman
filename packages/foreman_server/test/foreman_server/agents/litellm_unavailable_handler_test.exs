defmodule ForemanServer.Agents.LitellmUnavailableHandlerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.LitellmUnavailableHandler

  test "handle returns blocked tuple" do
    assert {:blocked, info} = LitellmUnavailableHandler.handle(:connection_refused)
    assert info.reason == :litellm_unavailable
  end
end
