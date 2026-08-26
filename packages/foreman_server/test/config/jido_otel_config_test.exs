defmodule ForemanServer.Config.JidoOtelConfigTest do
  use ExUnit.Case, async: true

  test "jido_otel has service_name and otlp_endpoint" do
    assert Application.get_env(:jido_otel, :service_name) == "foreman_server"
    assert Application.get_env(:jido_otel, :otlp_endpoint) != nil
  end
end
