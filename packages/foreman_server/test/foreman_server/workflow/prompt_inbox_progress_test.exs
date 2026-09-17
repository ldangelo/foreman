defmodule ForemanServer.Workflow.PromptInboxProgressTest do
  use ExUnit.Case, async: true

  @prompt_dir Path.expand("../../../priv/defaults/workflows/prompts", __DIR__)

  test "bundled prompts include non-blocking inbox progress guidance" do
    prompts = Path.wildcard(Path.join(@prompt_dir, "*.md"))
    assert prompts != []

    for path <- prompts do
      body = File.read!(path)

      assert body =~ "foreman_inbox_send", "#{path} must mention foreman_inbox_send"
      assert body =~ "phase start", "#{path} must mention phase start progress"
      assert body =~ "material milestones", "#{path} must mention material milestone progress"
      assert body =~ "blockers", "#{path} must mention blocker progress"
      assert body =~ "phase completion", "#{path} must mention phase completion progress"
      assert body =~ "Do not send timer-only chatter", "#{path} must avoid timer-only chatter"
      assert body =~ "secrets", "#{path} must prohibit secrets"
      assert body =~ "large logs", "#{path} must prohibit large logs"
      assert body =~ "continue the phase", "#{path} must be non-blocking on send failures"
    end
  end
end
