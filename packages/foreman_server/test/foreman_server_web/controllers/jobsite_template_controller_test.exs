defmodule ForemanServerWeb.JobsiteTemplateControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Aggregates.JobsiteAudit
  alias ForemanServer.EventStore
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.Spec
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "jobsite-template-controller-test-token"
  @project_id "template-project"

  # The response shape the Go CLI decodes. packages/foreman_cli/cmd/foreman/jobsite_test.go reads
  # the same file, so a change to either side's JSON fails a test on that side.
  @response_fixture Path.expand(
                      "../../../../foreman_cli/cmd/foreman/testdata/jobsite_template_response.json",
                      __DIR__
                    )

  setup do
    ProjectionStoreReset.reset!()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{project_id: @project_id, path: "/srv/repos/template-project"}
               }
             ])

    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_jobsites = Application.get_env(:foreman_server, :jobsites)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    # Remote start is OFF: authoring a script starts nothing, so it must not need the flag.
    Application.put_env(:foreman_server, :jobsites, [])

    on_exit(fn ->
      restore(:api_bearer_token, previous_token)
      restore(:jobsites, previous_jobsites)
      ProjectionStoreReset.reset!()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp authed do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp post_template(conn, body), do: post(conn, "/api/jobsites/template", Jason.encode!(body))

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        "project_id" => @project_id,
        "prompt" => "Loop until the failing test passes, then push it",
        "agent" => %{"provider" => "pi", "model" => "minimax"}
      },
      extra
    )
  end

  defp audit_count do
    case EventStore.read_stream_forward(JobsiteAudit.stream_id(), 0, 99_999_999) do
      {:ok, events} -> length(events)
      {:error, :stream_not_found} -> 0
    end
  end

  defp kind(value) when is_map(value), do: :object
  defp kind(value) when is_list(value), do: :array
  defp kind(value) when is_binary(value), do: :string
  defp kind(value) when is_number(value), do: :number
  defp kind(value) when is_boolean(value), do: :boolean

  describe "authentication fails closed" do
    test "no token configured => 401, never open" do
      Application.delete_env(:foreman_server, :api_bearer_token)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post_template(request())

      assert conn.status == 401
    end

    test "missing and wrong tokens => 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post_template(request())

      assert conn.status == 401

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer nope")
        |> put_req_header("content-type", "application/json")
        |> post_template(request())

      assert conn.status == 401
    end
  end

  describe "POST /api/jobsites/template" do
    test "answers with the files, the validated spec and what was read from the prompt" do
      conn = post_template(authed(), request())

      assert conn.status == 200

      assert %{
               "name" => "loop-until-the-failing",
               "spec" => spec,
               "features" => features,
               "notes" => [],
               "files" => [script, prompt]
             } = json_response(conn, 200)

      assert features == ["loop", "review-and-fix", "push-to-origin"]
      assert script["path"] == "loop-until-the-failing.exs"
      assert prompt["path"] == "prompts/loop-until-the-failing.md"
      assert script["content"] =~ "Foreman.Client.run(client, spec)"
      assert prompt["content"] == spec["prompt"]

      assert spec["max_iterations"] == 5
      assert spec["push"] == true
      assert spec["agent"]["provider"] == "pi"
      assert spec["project_id"] == @project_id

      # What came back is the spec the server's own validator accepts, and it can be POSTed as is.
      assert {:ok, _built} = Spec.from_json(spec)
    end

    test "the response has the shape the CLI's fixture pins" do
      fixture = @response_fixture |> File.read!() |> Jason.decode!()
      body = authed() |> post_template(request()) |> json_response(200)

      assert Enum.sort(Map.keys(body)) == Enum.sort(Map.keys(fixture))
      for {key, expected} <- fixture, do: assert(kind(body[key]) == kind(expected), key)

      assert [%{} = fixture_file | _] = fixture["files"]
      assert [%{} | _] = body["files"]

      for file <- body["files"] do
        assert Enum.sort(Map.keys(file)) == Enum.sort(Map.keys(fixture_file))
        assert Enum.all?(file, fn {_key, value} -> is_binary(value) end)
      end

      assert Enum.all?(body["features"] ++ body["notes"], &is_binary/1)
      assert Enum.sort(Map.keys(body["spec"])) -- Enum.sort(Map.keys(fixture["spec"])) == []
    end

    test "starts nothing, audits nothing, and does not need allow_remote_start" do
      jobsites_before = Jobsite.list()
      audit_before = audit_count()

      assert post_template(authed(), request()).status == 200
      assert post_template(authed(), request(%{"project_id" => "nobody"})).status == 404

      assert Jobsite.list() == jobsites_before
      assert audit_count() == audit_before
    end

    test "the validator's refusals keep the status mapping the rest of /api/jobsites uses" do
      cases = [
        {%{"project_id" => "nobody"}, 404, "spec_project_not_found"},
        {%{"sandbox" => "host"}, 403, "spec_sandbox_not_allowed"},
        {%{"agent" => %{"model" => "m"}}, 422, "spec_provider_invalid"},
        {%{"max_iterations" => 0}, 422, "spec_option_invalid"},
        {%{"hooks" => %{}}, 422, "template_option_unsupported"}
      ]

      for {extra, status, code} <- cases do
        conn = post_template(authed(), request(extra))
        assert conn.status == status, "#{inspect(extra)}: #{inspect(conn.resp_body)}"
        assert %{"error" => ^code, "message" => message} = json_response(conn, status)
        assert is_binary(message) and message != ""
      end

      assert %{"error" => "spec_prompt_missing"} =
               authed() |> post_template(Map.delete(request(), "prompt")) |> json_response(400)

      assert %{"error" => "spec_project_id_missing"} =
               authed()
               |> post_template(Map.delete(request(), "project_id"))
               |> json_response(400)
    end

    test "a body that is not a JSON object is refused, not generated for" do
      conn = post(authed(), "/api/jobsites/template", Jason.encode!([1, 2]))
      assert conn.status == 422
      assert %{"error" => "template_option_unsupported"} = json_response(conn, 422)
    end
  end
end
