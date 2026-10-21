defmodule ForemanServerWeb.ProjectLibraryControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.CommandRouter

  @moduletag :tmp_dir
  @endpoint ForemanServerWeb.Endpoint
  @token "project-library-controller-test-token"
  @boundary "foremanLibraryBoundary"

  setup %{tmp_dir: dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)

    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    library = Application.get_env(:foreman_server, :library, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :library, library)

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    project_id = "http-lib-#{System.unique_integer([:positive])}"
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: repo}
      })

    {:ok, project_id: project_id, dir: dir}
  end

  defp authed, do: build_conn() |> put_req_header("authorization", "Bearer #{@token}")
  defp base(p), do: "/api/projects/#{p}/library"

  # A real multipart body, so the endpoint's parsers (and the library upload
  # parser) run, not just the controller.
  defp multipart(files, fields) do
    field_parts =
      for {name, value} <- fields do
        "--#{@boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      end

    file_parts =
      for {filename, content} <- files do
        "--#{@boundary}\r\ncontent-disposition: form-data; name=\"files[]\"; " <>
          "filename=\"#{filename}\"\r\ncontent-type: application/octet-stream\r\n\r\n" <>
          content <> "\r\n"
      end

    IO.iodata_to_binary(field_parts ++ file_parts ++ ["--#{@boundary}--\r\n"])
  end

  defp upload(conn, method, path, files, fields \\ %{}) do
    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> dispatch(@endpoint, method, path, multipart(files, fields))
  end

  test "requires the bearer token", %{project_id: p} do
    assert build_conn() |> get(base(p)) |> json_response(401)
  end

  test "upload, list, read, replace, remove round trip", %{project_id: p} do
    conn =
      upload(authed(), :post, base(p), [{"docs/guide.md", "# Guide"}, {"data.csv", "a,b"}], %{
        "name" => "kit"
      })

    assert %{
             "entry" => %{"entry_id" => id, "name" => "kit", "kind" => "file", "file_count" => 2},
             "skipped" => []
           } =
             json_response(conn, 201)

    assert %{
             "entries" => [%{"entry_id" => ^id, "files" => files}],
             "index" => index,
             "limits" => %{
               "max_files_per_add" => 100,
               "folder_max_files" => 100,
               "max_folders" => 10
             }
           } = authed() |> get(base(p)) |> json_response(200)

    assert Enum.map(files, & &1["path"]) == ["data.csv", "docs/guide.md"]
    assert index =~ "$FOREMAN_LIBRARY_PATH/#{id}/files/"

    read = authed() |> get(base(p) <> "/#{id}/files/docs/guide.md")
    assert response(read, 200) == "# Guide"
    assert get_resp_header(read, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(read, "content-disposition") == ["attachment"]

    replaced = upload(authed(), :put, base(p) <> "/#{id}", [{"docs/guide.md", "# Guide v2"}])

    assert %{"entry" => %{"entry_id" => ^id, "name" => "kit", "file_count" => 1}} =
             json_response(replaced, 200)

    assert authed() |> get(base(p) <> "/#{id}/files/docs/guide.md") |> response(200) ==
             "# Guide v2"

    assert %{"status" => "removed"} =
             authed() |> delete(base(p) <> "/#{id}") |> json_response(200)

    assert %{"entries" => []} = authed() |> get(base(p)) |> json_response(200)
    assert authed() |> delete(base(p) <> "/#{id}") |> json_response(404)
  end

  test "a folder upload applies the folder rules and reports every skipped file", %{project_id: p} do
    files = [
      {"proj/a.txt", "a"},
      {"proj/.env", "SECRET=1"},
      {"proj/node_modules/dep/index.js", "x"},
      {"proj/src/b.txt", "b"}
    ]

    conn = upload(authed(), :post, base(p), files, %{"name" => "proj", "kind" => "folder"})

    assert %{"entry" => %{"kind" => "folder", "file_count" => 2}, "skipped" => skipped} =
             json_response(conn, 201)

    assert Enum.sort_by(skipped, & &1["path"]) == [
             %{"path" => "proj/.env", "reason" => "hidden"},
             %{"path" => "proj/node_modules/dep/index.js", "reason" => "node_modules"}
           ]
  end

  test "typed errors: duplicate name, too many files, bad paths, unknown entry", %{project_id: p} do
    upload(authed(), :post, base(p), [{"a.txt", "a"}], %{"name" => "same"}) |> json_response(201)

    assert %{"error" => "duplicate_name"} =
             upload(authed(), :post, base(p), [{"b.txt", "b"}], %{"name" => "same"})
             |> json_response(422)

    many = for n <- 1..101, do: {"f#{n}.txt", "x"}

    assert %{"error" => "too_many_files", "details" => %{"max" => 100}} =
             upload(authed(), :post, base(p), many) |> json_response(422)

    assert %{"error" => "path_invalid"} =
             upload(authed(), :post, base(p), [{"../escape.txt", "x"}]) |> json_response(422)

    assert %{"error" => "not_found"} =
             authed() |> get(base(p) <> "/nope-1/files/a.txt") |> json_response(404)

    assert %{"error" => "invalid_body"} =
             authed()
             |> put_req_header("content-type", "application/json")
             |> post(base(p), %{})
             |> json_response(422)

    assert %{"error" => "project_not_found"} =
             upload(authed(), :post, base("missing-#{p}"), [{"a.txt", "a"}]) |> json_response(404)
  end

  test "server_path adds are forbidden unless enabled", %{project_id: p, dir: dir} do
    src = Path.join(dir, "srcdir")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "x.md"), "x")
    body = %{"server_path" => src, "name" => "srv"}

    json = fn ->
      authed() |> put_req_header("content-type", "application/json") |> post(base(p), body)
    end

    assert %{"error" => "server_path_disabled"} = json_response(json.(), 403)

    library = Application.get_env(:foreman_server, :library, [])

    Application.put_env(
      :foreman_server,
      :library,
      Keyword.put(library, :allow_server_paths, true)
    )

    assert %{
             "entry" => %{
               "name" => "srv",
               "source" => %{"kind" => "server_path", "path_label" => "srcdir"}
             }
           } =
             json_response(json.(), 201)
  end

  describe "upload size limit" do
    @nine_mb String.duplicate("a", 9 * 1024 * 1024)

    test "library routes accept a multipart body above the endpoint default (8 MB)", %{
      project_id: p
    } do
      conn = upload(authed(), :post, base(p), [{"big.bin", @nine_mb}], %{"name" => "big"})
      assert %{"entry" => %{"file_count" => 1, "bytes" => bytes}} = json_response(conn, 201)
      assert bytes == byte_size(@nine_mb)
    end

    test "an unauthenticated big upload is refused with 401 before its body is parsed", %{
      project_id: p
    } do
      conn = upload(build_conn(), :post, base(p), [{"big.bin", @nine_mb}], %{"name" => "big"})
      assert json_response(conn, 401)
      assert %Plug.Conn.Unfetched{} = conn.body_params
    end

    test "an overrun of upload_max_bytes is a JSON 413", %{project_id: p} do
      library = Application.get_env(:foreman_server, :library, [])

      Application.put_env(
        :foreman_server,
        :library,
        Keyword.put(library, :upload_max_bytes, 1_000_000)
      )

      conn = upload(authed(), :post, base(p), [{"big.bin", @nine_mb}], %{"name" => "big"})
      assert %{"error" => "upload_too_large"} = json_response(conn, 413)
    end

    test "other routes keep the default limit", %{project_id: p} do
      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        upload(authed(), :post, "/api/projects/#{p}/memory/sync", [{"big.bin", @nine_mb}])
      end
    end
  end
end
