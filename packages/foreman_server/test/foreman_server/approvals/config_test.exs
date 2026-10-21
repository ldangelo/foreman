defmodule ForemanServer.Approvals.ConfigTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Approvals.Config

  setup do
    previous = Application.get_env(:foreman_server, :approvals, [])
    on_exit(fn -> Application.put_env(:foreman_server, :approvals, previous) end)
    %{previous: previous}
  end

  defp put(previous, key, value),
    do: Application.put_env(:foreman_server, :approvals, Keyword.put(previous, key, value))

  test "a misspelled on_timeout is an error, never the opposite policy", %{previous: previous} do
    put(previous, :on_timeout, :dney)
    assert_raise ArgumentError, ~r/on_timeout/, &Config.on_timeout/0
    put(previous, :on_timeout, "deny")
    assert_raise ArgumentError, ~r/on_timeout/, &Config.on_timeout/0
    put(previous, :on_timeout, :deny)
    assert Config.on_timeout() == :deny
  end

  test "pause_on_permission_denied must be a boolean", %{previous: previous} do
    put(previous, :pause_on_permission_denied, "false")

    assert_raise ArgumentError,
                 ~r/pause_on_permission_denied/,
                 &Config.pause_on_permission_denied?/0

    put(previous, :pause_on_permission_denied, false)
    refute Config.pause_on_permission_denied?()
  end
end
