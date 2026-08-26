defmodule ForemanServer.Agents.MissingSubscriberPolicyTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.MissingSubscriberPolicy` — the
  Foreman-side policy for what to do when a Jido signal is published
  to a topic with no subscribers (TRD-2026-4212be7e, JSI-T003).

  Per the TRD:
    "Implement missing-subscriber configurable policy (silent/warn/
     error, default warn) in Foreman config."

  The policy is a per-topic call: `apply/3` returns `:ok | :warn | :error`
  based on the configured policy and the matched topic pattern. The
  default is `:warn` (log a warning but do not crash or escalate).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.MissingSubscriberPolicy

  describe "default policy (warn)" do
    test "default is :warn when no policy is configured" do
      assert MissingSubscriberPolicy.default() == :warn
    end

    test "apply/3 with no policy returns :warn and logs a warning" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert :warn = MissingSubscriberPolicy.apply("com.foreman.test", nil, %{})
        end)

      assert log =~ "no subscribers"
    end
  end

  describe "configured policy" do
    setup do
      original = Application.get_env(:foreman_server, MissingSubscriberPolicy, [])

      on_exit(fn ->
        Application.put_env(:foreman_server, MissingSubscriberPolicy, original)
      end)

      :ok
    end

    test ":silent policy returns :ok and does not log" do
      import ExUnit.CaptureLog
      Application.put_env(:foreman_server, MissingSubscriberPolicy, default: :silent)

      log =
        capture_log(fn ->
          assert :ok = MissingSubscriberPolicy.apply("com.foreman.test", nil, %{})
        end)

      refute log =~ "no subscribers"
    end

    test ":warn policy returns :warn and logs a warning" do
      import ExUnit.CaptureLog
      Application.put_env(:foreman_server, MissingSubscriberPolicy, default: :warn)

      log =
        capture_log(fn ->
          assert :warn = MissingSubscriberPolicy.apply("com.foreman.test", nil, %{})
        end)

      assert log =~ "no subscribers"
    end

    test ":error policy returns :error and logs an error" do
      import ExUnit.CaptureLog
      Application.put_env(:foreman_server, MissingSubscriberPolicy, default: :error)

      log =
        capture_log(fn ->
          assert :error = MissingSubscriberPolicy.apply("com.foreman.test", nil, %{})
        end)

      assert log =~ "no subscribers"
    end

    test "per-topic override beats the default" do
      Application.put_env(
        :foreman_server,
        MissingSubscriberPolicy,
        default: :warn,
        per_topic: %{"com.foreman.critical" => :error}
      )

      assert :error = MissingSubscriberPolicy.apply("com.foreman.critical", nil, %{})
      # non-overridden topic falls back to default
      assert :warn = MissingSubscriberPolicy.apply("com.foreman.normal", nil, %{})
    end
  end
end
