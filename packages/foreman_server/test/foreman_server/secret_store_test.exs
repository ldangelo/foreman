defmodule ForemanServer.SecretStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.SecretStore
  alias ForemanServer.SecretStore.Error

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:foreman_server, :secret_store)
    dir = Path.join(tmp_dir, "secrets")
    Application.put_env(:foreman_server, :secret_store, Keyword.put(previous, :dir, dir))
    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, previous) end)
    %{dir: dir}
  end

  test "put/get/names/delete round trip; put overwrites", %{dir: dir} do
    assert {:ok, :stored} = SecretStore.put("p1", "API_TOKEN", "v1")
    assert {:ok, :stored} = SecretStore.put("p1", "DB_PASSWORD", "pw")
    assert {:ok, :stored} = SecretStore.put("p1", "API_TOKEN", "v2")
    assert {:ok, "v2"} = SecretStore.get("p1", "API_TOKEN")
    assert {:ok, ["API_TOKEN", "DB_PASSWORD"]} = SecretStore.names("p1")
    assert {:ok, %{"API_TOKEN" => "v2", "DB_PASSWORD" => "pw"}} = SecretStore.pairs("p1")
    assert {:ok, :deleted} = SecretStore.delete("p1", "API_TOKEN")
    assert {:error, %Error{code: :secret_not_found}} = SecretStore.get("p1", "API_TOKEN")
    assert {:error, %Error{code: :secret_not_found}} = SecretStore.delete("p1", "API_TOKEN")
    assert {:ok, ["DB_PASSWORD"]} = SecretStore.names("p1")
    # No temp file survives an atomic write.
    assert dir |> File.ls!() |> Enum.all?(&String.ends_with?(&1, ".json"))
  end

  test "an unknown project has no secrets" do
    assert {:ok, []} = SecretStore.names("nobody")
    assert {:ok, %{}} = SecretStore.pairs("nobody")
  end

  test "secrets are scoped per project" do
    {:ok, :stored} = SecretStore.put("a", "API_TOKEN", "A")
    {:ok, :stored} = SecretStore.put("b", "API_TOKEN", "B")
    assert {:ok, "A"} = SecretStore.get("a", "API_TOKEN")
    assert {:ok, "B"} = SecretStore.get("b", "API_TOKEN")
  end

  test "the directory is 0700 and the file 0600", %{dir: dir} do
    {:ok, :stored} = SecretStore.put("p1", "API_TOKEN", "v1")
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    [file] = File.ls!(dir)
    assert Bitwise.band(File.stat!(Path.join(dir, file)).mode, 0o777) == 0o600
  end

  test "a hostile project id cannot escape the store directory", %{dir: dir, tmp_dir: tmp_dir} do
    {:ok, :stored} = SecretStore.put("../../escape", "API_TOKEN", "v")
    assert File.ls!(tmp_dir) == ["secrets"]
    assert length(File.ls!(dir)) == 1
  end

  test "names and values are validated" do
    for bad <- ["lower", "1ABC", "FOREMAN_X", "", "A B", String.duplicate("A", 65)] do
      assert {:error, %Error{code: :invalid_secret_name}} = SecretStore.put("p", bad, "v")
    end

    assert {:error, %Error{code: :invalid_secret_value}} = SecretStore.put("p", "OK", "")

    assert {:error, %Error{code: :invalid_secret_value}} =
             SecretStore.put("p", "OK", <<"a", 0, "b">>)

    assert {:error, %Error{code: :invalid_secret_value}} =
             SecretStore.put("p", "OK", String.duplicate("x", 16 * 1024 + 1))

    assert {:ok, :stored} = SecretStore.put("p", "OK", String.duplicate("x", 16 * 1024))
    assert {:error, %Error{code: :invalid_project_id}} = SecretStore.put("", "OK", "v")
  end

  test "a corrupt secret file is :store_malformed, an unwritable dir :store_unavailable", %{
    dir: dir,
    tmp_dir: tmp_dir
  } do
    {:ok, :stored} = SecretStore.put("p1", "API_TOKEN", "v")
    [file] = File.ls!(dir)
    File.write!(Path.join(dir, file), "not json")
    assert {:error, %Error{code: :store_malformed}} = SecretStore.get("p1", "API_TOKEN")

    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "x")
    previous = Application.get_env(:foreman_server, :secret_store)
    Application.put_env(:foreman_server, :secret_store, Keyword.put(previous, :dir, blocker))
    assert {:error, %Error{code: :store_unavailable}} = SecretStore.put("p1", "API_TOKEN", "v")
  end

  test "errors never carry the secret value" do
    {:error, error} = SecretStore.put("p", "lower", "super-secret-value")
    refute inspect(error) =~ "super-secret-value"
  end
end
