defmodule ForemanServer.Schedule.TickerEnvConfigTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @var "FOREMAN_SCHEDULE_TICKER_ENABLED"

  setup do
    original = System.get_env(@var)

    on_exit(fn ->
      if original, do: System.put_env(@var, original), else: System.delete_env(@var)
    end)

    :ok
  end

  # What a booting node would configure. `runtime.exs` leaves the test env alone, so it is
  # evaluated as `:prod`, reading the variable at call time.
  defp ticker_config(value) do
    if value, do: System.put_env(@var, value), else: System.delete_env(@var)

    @runtime
    |> Config.Reader.read!(env: :prod)
    |> get_in([:foreman_server, :schedule])
  end

  test "unset changes nothing: the config.exs default (ticker on) stands" do
    assert ticker_config(nil) == nil
  end

  test "exactly true and false are applied" do
    assert ticker_config("true") == [ticker_enabled: true]
    assert ticker_config("false") == [ticker_enabled: false]
  end

  test "anything else aborts boot instead of leaving the ticker running" do
    for value <- ["off", "0", "no", "False", "TRUE", " true", "true ", ""] do
      error = assert_raise RuntimeError, fn -> ticker_config(value) end

      assert error.message =~ @var
      assert error.message =~ inspect(value)
    end
  end
end
