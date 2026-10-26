defmodule ForemanServerWeb.ThreadRereviewControllerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Analyzer
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Subject
  alias ForemanServer.Review.Verdict
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.TestSupport.UniqueIds

  @endpoint ForemanServerWeb.Endpoint
  @token "thread-rereview-controller-test-token"

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    original_review = Application.get_env(:foreman_server, :review, [])
    original_stub = Application.get_env(:foreman_server, :review_stub_verdict)

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original_review,
        capture: true,
        archive_root: Path.join(tmp, "archive"),
        evaluator: ForemanServer.Review.Evaluator.Stub
      )
    )

    Application.delete_env(:foreman_server, :review_stub_verdict)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      Application.put_env(:foreman_server, :review, original_review)

      if original_stub,
        do: Application.put_env(:foreman_server, :review_stub_verdict, original_stub),
        else: Application.delete_env(:foreman_server, :review_stub_verdict)

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    {:ok, repo: Path.join(tmp, "repo")}
  end

  defp post_rereview(id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> post("/api/threads/#{id}/rereview", %{})
  end

  defp start_analyzer! do
    start_supervised!({Task.Supervisor, name: ForemanServer.Review.TaskSupervisor})
    start_supervised!(Analyzer)
  end

  defp start_run!(run_id) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p"}}
      ])
  end

  defp record_review!(run_id, verdict, extra \\ %{}) do
    payload =
      Map.merge(
        %{
          subject_kind: "run",
          subject_id: run_id,
          project_id: "p",
          verdict: verdict,
          summary: "s",
          gap_bead_ids: [],
          at: "2026-01-01T00:00:00Z"
        },
        extra
      )

    :ok = ProjectionStore.apply_events([%{event_type: "ReviewRecorded", payload: payload}])
  end

  defp await(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        await(fun, tries - 1)

      other ->
        other
    end
  end

  test "unknown thread is 404" do
    assert %{"error" => "thread_not_found", "thread_id" => "run:nope"} =
             json_response(post_rereview("run:nope"), 404)
  end

  test "a run with no recorded review is 409 not_reviewed" do
    start_analyzer!()
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)

    assert %{"error" => "not_reviewed", "thread_id" => thread_id} =
             json_response(post_rereview("run:" <> run_id), 409)

    assert thread_id == "run:" <> run_id
  end

  test "a real verdict is 409 not_rerunnable naming the verdict" do
    start_analyzer!()
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)
    record_review!(run_id, "met")

    assert %{"error" => "not_rerunnable", "verdict" => "met"} =
             json_response(post_rereview("run:" <> run_id), 409)
  end

  test "with analysis switched off it is 503 analysis_disabled" do
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)
    record_review!(run_id, "undetermined")

    assert %{"error" => "analysis_disabled"} = json_response(post_rereview("run:" <> run_id), 503)
  end

  test "an undetermined review whose archive is missing is 422 archive_unusable", %{repo: repo} do
    start_analyzer!()
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)
    record_review!(run_id, "undetermined", %{archive_path: Archive.dir(:run, run_id, repo)})

    assert %{"error" => "archive_unusable", "code" => code, "detail" => detail} =
             json_response(post_rereview("run:" <> run_id), 422)

    assert is_binary(code) and is_binary(detail)
  end

  test "an undetermined review is 202 and a met verdict supersedes it", %{repo: repo} do
    start_analyzer!()
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)

    subject = %Subject{
      kind: :run,
      subject_id: run_id,
      project_id: "p",
      repo_path: repo,
      archive_dir: Archive.dir(:run, run_id, repo),
      status: "completed"
    }

    :ok =
      Archive.init(subject.archive_dir, %{
        "kind" => "run",
        "subject_id" => run_id,
        "project_id" => "p",
        "repo_path" => repo,
        "bead_id" => nil,
        "status" => "completed",
        "request" => %{"source" => "run"}
      })

    Application.put_env(
      :foreman_server,
      :review_stub_verdict,
      {:error, Error.new(:evaluator_failed, "reviewer run ended failed: 429")}
    )

    assert :ok = Analyzer.analyze(subject)
    assert await(fn -> undetermined(run_id) end)

    Application.put_env(
      :foreman_server,
      :review_stub_verdict,
      %Verdict{
        verdict: :met,
        summary: "Now it is met.",
        scores: %{correctness: 5, tests: 5, documentation: 5, robustness: 5}
      }
    )

    assert %{"thread_id" => thread_id, "requested" => "rereview"} =
             json_response(post_rereview("run:" <> run_id), 202)

    assert thread_id == "run:" <> run_id

    assert await(fn ->
             case ProjectionStore.review("run", run_id) do
               %{verdict: "met"} = review -> review
               _other -> nil
             end
           end)
  end

  defp undetermined(run_id) do
    case ProjectionStore.review("run", run_id) do
      %{verdict: "undetermined"} = review -> review
      _other -> nil
    end
  end
end
