defmodule Foreman.ClientTest do
  use ExUnit.Case, async: false

  alias Foreman.Client

  setup do
    for var <- ["FOREMAN_API_URL", "FOREMAN_API_TOKEN"] do
      previous = System.get_env(var)
      System.delete_env(var)
      on_exit(fn -> if previous, do: System.put_env(var, previous), else: System.delete_env(var) end)
    end

    :ok
  end

  test "a missing token is an error, never an unauthenticated client" do
    assert_raise ArgumentError, ~r/FOREMAN_API_TOKEN/, fn -> Client.new() end
  end

  test "options win over the environment and a trailing slash is dropped" do
    System.put_env("FOREMAN_API_URL", "http://env:1")
    System.put_env("FOREMAN_API_TOKEN", "env-token")

    assert %Client{base_url: "http://opt:2", token: "opt-token"} =
             Client.new(url: "http://opt:2/", token: "opt-token")

    assert %Client{base_url: "http://env:1", token: "env-token"} = Client.new()
  end

  test "a refused connection is a transport error, not a crash" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    client = Client.new(url: "http://127.0.0.1:#{port}", token: "t")
    assert {:error, {:transport, _}} = Client.get(client, "js-1")
  end
end
