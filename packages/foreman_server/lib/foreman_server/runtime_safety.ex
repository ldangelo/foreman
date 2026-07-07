defmodule ForemanServer.RuntimeSafety do
  @moduledoc "Fail-fast guards that keep test runtime from touching user data."

  @user_http_port 4766

  @spec validate!() :: :ok
  def validate! do
    validate_postgres_config!()

    if ForemanServer.RuntimeInfo.mix_env() == "test" do
      validate_test_port!()
      validate_test_storage!()
    end

    :ok
  end

  defp validate_postgres_config! do
    if ForemanServer.RuntimeInfo.event_store_adapter() == :postgres and
         not ForemanServer.RuntimeInfo.database_url?() do
      raise ArgumentError,
            "refusing to start Foreman with postgres event store but no DATABASE_URL; " <>
              "set DATABASE_URL or use FOREMAN_SERVER_EVENT_STORE_ADAPTER=term intentionally"
    end
  end

  defp validate_test_port! do
    if ForemanServer.RuntimeInfo.http_enabled?() and
         ForemanServer.RuntimeInfo.http_port() == @user_http_port and
         System.get_env("FOREMAN_ALLOW_TEST_PORT_COLLISION") != "1" do
      raise ArgumentError,
            "refusing to start Foreman with MIX_ENV=test on user HTTP port #{@user_http_port}; " <>
              "use test port #{ForemanServer.RuntimeInfo.default_http_port()} or set FOREMAN_ALLOW_TEST_PORT_COLLISION=1"
    end
  end

  defp validate_test_storage! do
    if System.get_env("FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE") == "1" do
      :ok
    else
      [
        {"event log", ForemanServer.RuntimeInfo.event_log_path()},
        {"project store", ForemanServer.RuntimeInfo.project_store_path(required?: true)},
        {"FOREMAN_SERVER_EVENT_LOG", System.get_env("FOREMAN_SERVER_EVENT_LOG")},
        {"FOREMAN_SERVER_PROJECT_STORE", System.get_env("FOREMAN_SERVER_PROJECT_STORE")}
      ]
      |> Enum.each(fn {label, path} ->
        if unsafe_test_path?(path) do
          raise ArgumentError,
                "refusing to start Foreman with MIX_ENV=test using non-temp #{label} path #{Path.expand(path)}; " <>
                  "use #{Path.expand("../../../tmp/test", __DIR__)} or an OS temp path, or set FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE=1"
        end
      end)
    end
  end

  defp unsafe_test_path?(nil), do: false

  defp unsafe_test_path?(path) do
    expanded = Path.expand(path)

    not path_within?(expanded, System.tmp_dir!()) and
      not path_within?(expanded, Path.expand("../../../tmp/test", __DIR__))
  end

  defp path_within?(path, root) do
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end
end
