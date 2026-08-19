defmodule ForemanServer.Agents.JidoAiLitellmRoutingTest do
  use ExUnit.Case, async: true

  test "LitellmRouter returns model=auto" do
    assert ForemanServer.Agents.LitellmRouter.model() == "auto"
  end

  test "route includes LiteLLM endpoint" do
    route = ForemanServer.Agents.LitellmRouter.route(:chat)
    assert route.endpoint =~ "localhost:4000"
  end
end
