defmodule ForemanServer.Observability.RedactorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Observability.Redactor

  test "keeps whitelisted diagnostic metadata and drops unknown fields" do
    assert Redactor.redact_metadata(%{
             run_id: "run-1",
             task_id: "task-1",
             workflow_name: "implement",
             unknown_payload: "drop me"
           }) == %{run_id: "run-1", task_id: "task-1", workflow_name: "implement"}
  end

  test "removes sensitive keys entirely" do
    result =
      Redactor.redact_metadata(%{
        run_id: "run-1",
        authorization: "Bearer token",
        prompt: "user prompt",
        database_url: "postgres://u:p@localhost/db"
      })

    assert result == %{run_id: "run-1"}
  end

  test "redacts sensitive keys nested inside a Logger :report term before inspection" do
    redacted =
      Redactor.redact_message(
        {:report, %{password: "hunter2", reason: :normal, nested: %{token: "abc123"}}}
      )

    refute redacted =~ "hunter2"
    refute redacted =~ "abc123"
    assert redacted =~ "[REDACTED]"
    assert redacted =~ "normal"
  end

  test "redacts sentinel secrets, auth headers, database urls, env values, and home paths" do
    text =
      "Authorization: Bearer secret-token DATABASE_URL=postgres://user:pass@db/app " <>
        "SECRET_KEY_BASE=sentinel /Users/alice/private/file"

    redacted = Redactor.redact_message(text)

    refute redacted =~ "secret-token"
    refute redacted =~ "user:pass"
    refute redacted =~ "sentinel"
    refute redacted =~ "/Users/alice"
    assert redacted =~ "[REDACTED]"
    assert redacted =~ "/[REDACTED_PATH]"
  end
end
