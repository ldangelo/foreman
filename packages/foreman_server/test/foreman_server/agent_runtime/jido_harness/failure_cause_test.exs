defmodule ForemanServer.AgentRuntime.JidoHarness.FailureCauseTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.{FailureCause, RunResult}
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias Jido.Harness.{Error, Event}

  defp failed(attrs),
    do: struct!(%Jido.Harness.RunResult{run_id: "r", provider: :pi, status: :failed}, attrs)

  defp cause(result, secrets \\ []) do
    {:error, code} = RunResult.normalize(result)
    FailureCause.from_run_result(result, code, secrets)
  end

  test "a killed agent keeps its normalized code AND says what happened" do
    error =
      Error.execution("provider run failed",
        provider: :pi,
        cause: {:exit_status, 137},
        details: %{exit_status: 137}
      )

    assert %FailureCause{code: {:other, :execution}, detail: detail} = cause(failed(error: error))
    assert detail =~ "provider run failed"
    assert detail =~ "137"

    rendered = FailureCause.render(cause(failed(error: error)))
    assert rendered =~ "{:other, :execution}"
    assert rendered =~ "137"
    refute rendered == "{:other, :execution}"
  end

  test "a timeout is reported as a timeout with its kind" do
    error = Error.new(:timeout, "idle timeout exceeded", provider: :pi)
    assert FailureCause.render(cause(failed(error: error))) =~ "idle timeout exceeded"
  end

  test "a failure with no error uses the provider's run_failed text" do
    event =
      Event.new!(
        provider: :pi,
        type: :run_failed,
        payload: %{"error" => "coderabbit: review exited 2"}
      )

    assert FailureCause.render(cause(failed(error: nil, events: [event]))) =~ "review exited 2"
  end

  test "a failure with nothing to say says so instead of an opaque tuple" do
    assert FailureCause.render(cause(failed(error: nil))) =~ "without detail"
  end

  test "secrets are redacted, text is single-line and bounded" do
    error =
      Error.execution(
        "auth failed token=abc123 with key s3cr3t-value\nsecond line " <>
          String.duplicate("x", 2_000)
      )

    detail = cause(failed(error: error), ["s3cr3t-value"]).detail
    refute detail =~ "abc123"
    refute detail =~ "s3cr3t-value"
    refute detail =~ "\n"
    assert byte_size(detail) <= 504
  end

  test "the workflow worker returns the cause, redacted with the run's secrets" do
    error = Error.execution("pi exited with status 137 key=hunter2", provider: :pi)

    assert {:error, %FailureCause{code: {:other, :execution}, detail: detail}} =
             JidoHarnessWorker.normalize_result(failed(error: error), ["hunter2"])

    assert detail =~ "status 137"
    refute detail =~ "hunter2"

    ok = %Jido.Harness.RunResult{run_id: "r", provider: :pi, status: :completed, text: "done"}
    assert {:ok, "done"} = JidoHarnessWorker.normalize_result(ok, [])
  end

  test "any other reason renders exactly as before" do
    assert FailureCause.render({:other, :execution}) == "{:other, :execution}"
    assert FailureCause.render(:worker_timeout) == ":worker_timeout"
  end
end
