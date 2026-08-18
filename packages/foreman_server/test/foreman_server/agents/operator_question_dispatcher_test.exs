defmodule ForemanServer.Agents.OperatorQuestionDispatcherTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.OperatorQuestionDispatcher` — the
  JSI-T007 dispatcher stub that the JSI-T006 subscriber delegates to.

  JSI-T007's full inbox-API conversion is the next session's work.
  For now the dispatcher is a no-op that returns `:ok` for any
  Jido.Signal and logs unknown payloads. These tests pin that
  contract so the next session's refactor can verify behavior
  preservation.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionDispatcher

  # Jido.Signal.new/3 reads the signal extension registry, which lives
  # in the :jido_signal application. Without it, inflate_extensions
  # exits with `no process`.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "dispatch/1 with a Jido.Signal" do
    test "returns :ok and logs the signal type" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-1",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{question: "what should I do?"}
        })

      assert :ok = OperatorQuestionDispatcher.dispatch(signal)
    end
  end

  describe "dispatch/1 with an unknown payload" do
    test "returns :ok and logs a warning" do
      assert :ok = OperatorQuestionDispatcher.dispatch(%{not: "a signal"})
    end
  end
end
