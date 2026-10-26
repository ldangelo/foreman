defmodule ForemanServer.Library.IngestLimitsTest do
  # foreman-8ervf: `upload_max_bytes`, the cap on the total size of ONE add, is read through
  # `Ingest.limits/1` like every other library limit, so the HTTP parser and the workspace's
  # socket uploads enforce the same number. It changes global config, hence not async.
  use ExUnit.Case, async: false

  alias ForemanServer.Library.Ingest
  alias ForemanServer.TestSupport.Eventually

  test "upload_max_bytes is 512 MiB when the config does not name it" do
    Eventually.put_env_for_test(:foreman_server, :library, max_files_per_add: 7)

    assert %{upload_max_bytes: 536_870_912, max_files_per_add: 7} = Ingest.limits()
  end

  test "upload_max_bytes follows the config" do
    Eventually.put_env_for_test(:foreman_server, :library, upload_max_bytes: 1_000_000)

    assert %{upload_max_bytes: 1_000_000} = Ingest.limits()
  end

  test "the shipped config names the same default" do
    assert Application.get_env(:foreman_server, :library)[:upload_max_bytes] == 512 * 1024 * 1024
  end

  test "an override passed to limits/1 wins over the config" do
    Eventually.put_env_for_test(:foreman_server, :library, upload_max_bytes: 1_000_000)

    assert %{upload_max_bytes: 5} = Ingest.limits(%{upload_max_bytes: 5})
  end
end
