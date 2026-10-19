defmodule ForemanServerWeb.Plugs.BearerAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]

  alias ForemanServerWeb.Plugs.BearerAuth

  @endpoint ForemanServerWeb.Endpoint
  @token "bearer-auth-test-token"
  @no_token_detail "no API token is configured on the server " <>
                     "(set FOREMAN_API_TOKEN, or allow_insecure_local for local development)"

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_api = Application.get_env(:foreman_server, :api)

    on_exit(fn ->
      restore(:api_bearer_token, previous_token)
      restore(:api, previous_api)
    end)

    Application.delete_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api, allow_insecure_local: false)
    :ok
  end

  describe "token configured" do
    setup do
      Application.put_env(:foreman_server, :api_bearer_token, @token)
      :ok
    end

    test "correct Authorization header passes" do
      conn =
        Plug.Test.conn(:get, "/api/x")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> run()

      refute conn.halted
      assert conn.status == nil
    end

    test "correct ?token= passes" do
      conn = Plug.Test.conn(:get, "/api/x?token=#{@token}") |> run()

      refute conn.halted
      assert conn.status == nil
    end

    test "wrong token is rejected with the plain unauthorized body" do
      conn =
        Plug.Test.conn(:get, "/api/x")
        |> put_req_header("authorization", "Bearer nope")
        |> run()

      assert_unauthorized(conn, %{"error" => "unauthorized"})
    end

    test "missing token is rejected with the plain unauthorized body" do
      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{"error" => "unauthorized"})
    end

    test "opt-in does not weaken a configured token" do
      Application.put_env(:foreman_server, :api, allow_insecure_local: true)

      conn =
        Plug.Test.conn(:get, "/api/x")
        |> put_req_header("authorization", "Bearer nope")
        |> run()

      assert_unauthorized(conn, %{"error" => "unauthorized"})
      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{"error" => "unauthorized"})
    end
  end

  describe "token not configured" do
    test "opt-in false is rejected with the no-token detail" do
      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{
        "error" => "unauthorized",
        "detail" => @no_token_detail
      })
    end

    test "empty-string token counts as not configured" do
      Application.put_env(:foreman_server, :api_bearer_token, "")

      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{
        "error" => "unauthorized",
        "detail" => @no_token_detail
      })
    end

    test "missing :api config is closed" do
      Application.delete_env(:foreman_server, :api)

      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{
        "error" => "unauthorized",
        "detail" => @no_token_detail
      })
    end

    test "missing allow_insecure_local key is closed" do
      Application.put_env(:foreman_server, :api, [])

      assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{
        "error" => "unauthorized",
        "detail" => @no_token_detail
      })
    end

    test "non-boolean opt-in values are closed" do
      for value <- ["true", nil, 1, :true_ish] do
        Application.put_env(:foreman_server, :api, allow_insecure_local: value)

        assert_unauthorized(run(Plug.Test.conn(:get, "/api/x")), %{
          "error" => "unauthorized",
          "detail" => @no_token_detail
        })
      end
    end

    test "opt-in true passes" do
      Application.put_env(:foreman_server, :api, allow_insecure_local: true)

      conn = run(Plug.Test.conn(:get, "/api/x"))

      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "real router" do
    test "GET /api/projects is 401 without a token unless opted in" do
      conn = get(build_conn(), "/api/projects")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["detail"] == @no_token_detail

      Application.put_env(:foreman_server, :api, allow_insecure_local: true)
      conn = get(build_conn(), "/api/projects")
      refute conn.status == 401
    end
  end

  defp run(conn), do: conn |> fetch_query_params() |> BearerAuth.call(BearerAuth.init([]))

  defp assert_unauthorized(conn, expected_body) do
    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    assert Jason.decode!(conn.resp_body) == expected_body
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)
end
