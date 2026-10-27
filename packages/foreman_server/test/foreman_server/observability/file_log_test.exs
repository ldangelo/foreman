defmodule ForemanServer.Observability.FileLogTest do
  # Installs a global :logger handler, so it must not run concurrently.
  use ExUnit.Case, async: false

  require Logger

  alias ForemanServer.Observability.FileLog

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> FileLog.uninstall() end)
  end

  test "install writes log lines to the configured file, creating its directory", %{
    tmp_dir: dir
  } do
    path = Path.join([dir, "nested", "foreman-server.log"])

    assert :ok = FileLog.install(%{path: path, max_bytes: 1_000_000, max_files: 2})
    Logger.error("file-log-marker-#{System.unique_integer([:positive])}")
    marker = "file-log-marker-"
    Logger.flush()
    :ok = :logger_std_h.filesync(:foreman_server_log_file)

    contents = File.read!(path)
    assert contents =~ marker
    assert contents =~ "[error]"
  end

  test "install returns an error (no raise) when the directory cannot be created", %{
    tmp_dir: dir
  } do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "x")

    assert {:error, _} =
             FileLog.install(%{
               path: Path.join(blocker, "foreman-server.log"),
               max_bytes: 1_000,
               max_files: 1
             })
  end

  test "install_from_config is :disabled under the test config" do
    assert :disabled = FileLog.install_from_config()
  end

  test "install_from_config installs when enabled", %{tmp_dir: dir} do
    path = Path.join(dir, "cfg.log")
    previous = Application.get_env(:foreman_server, :server_log)

    Application.put_env(:foreman_server, :server_log,
      enabled: true,
      path: path,
      max_bytes: 1_000_000,
      max_files: 2
    )

    on_exit(fn -> Application.put_env(:foreman_server, :server_log, previous) end)

    assert :ok = FileLog.install_from_config()
    assert File.exists?(path)
  end
end
