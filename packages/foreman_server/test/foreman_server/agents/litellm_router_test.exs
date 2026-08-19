defmodule ForemanServer.Agents.LitellmRouterTest do
  @moduledoc """
  Tests for ForemanServer.Agents.LitellmRouter.
  TRD-2026-4212be7e / LGL-T001 / TRD-042.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.LitellmRouter

  test "endpoint defaults to http://localhost:4000" do
    assert LitellmRouter.endpoint() == "http://localhost:4000"
  end

  test "model defaults to auto" do
    assert LitellmRouter.model() == "auto"
  end

  test "langfuse_endpoint defaults to http://localhost:3000" do
    assert LitellmRouter.langfuse_endpoint() == "http://localhost:3000"
  end

  test "route/2 returns a map with the expected shape" do
    route = LitellmRouter.route(:code_generation, max_tokens: 2048)

    assert route.endpoint == "http://localhost:4000"
    assert route.langfuse_endpoint == "http://localhost:3000"
    assert route.model == "auto"
    assert route.capability == :code_generation
    assert route.max_tokens == 2048
    assert route.temperature == nil
  end

  test "route/2 default max_tokens is 1024" do
    route = LitellmRouter.route(:chat)
    assert route.max_tokens == 1024
    assert route.capability == :chat
  end

  test "route/2 respects explicit temperature" do
    route = LitellmRouter.route(:chat, max_tokens: 256, temperature: 0.2)
    assert route.temperature == 0.2
    assert route.max_tokens == 256
  end
end