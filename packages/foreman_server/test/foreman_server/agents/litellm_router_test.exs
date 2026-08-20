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
  # REQ-020 AC-020-2: Verify that routing decisions change when LiteLLM
  # configuration changes at runtime. This ensures operators can change
  # model selection without restarting Foreman.
  describe "dynamic config changes" do
    @tag :litellm_routing_config
    test "route/2 reflects model change when :litellm :model env is updated" do
      # Store original value
      original_model = Application.get_env(:litellm, :model, "auto")

      on_exit(fn ->
        Application.put_env(:litellm, :model, original_model)
      end)

      # Default: model=auto
      default_route = LitellmRouter.route(:chat)
      assert default_route.model == "auto"

      # Switch to explicit model — route/2 should reflect immediately
      Application.put_env(:litellm, :model, "openai:gpt-4o")
      explicit_route = LitellmRouter.route(:chat)
      assert explicit_route.model == "openai:gpt-4o"

      # Switch back to auto
      Application.put_env(:litellm, :model, "auto")
      restored_route = LitellmRouter.route(:chat)
      assert restored_route.model == "auto"
    end

    @tag :litellm_routing_config
    test "route/2 reflects endpoint change when :litellm :endpoint env is updated" do
      original_endpoint = Application.get_env(:litellm, :endpoint, "http://localhost:4000")

      on_exit(fn ->
        Application.put_env(:litellm, :endpoint, original_endpoint)
      end)

      default_route = LitellmRouter.route(:chat)
      assert default_route.endpoint == "http://localhost:4000"

      Application.put_env(:litellm, :endpoint, "https://litellm.internal.example.com")
      updated_route = LitellmRouter.route(:chat)
      assert updated_route.endpoint == "https://litellm.internal.example.com"
    end
  end
end