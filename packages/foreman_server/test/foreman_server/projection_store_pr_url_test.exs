defmodule ForemanServer.ProjectionStorePrUrlTest do
  @moduledoc """
  Run-776527010ea5d3568b742adbd25ab872 opened
  https://github.com/ldangelo/foreman/pull/420 — the server log shows
  `gh pr create` succeeding and `finalize_run` echoing the URL — yet
  `GET /api/runs/run-776527010ea5d3568b742adbd25ab872` reported no PR.

  Two independent defects, both fixed:

    1. `RunExecutor.finalize_run/1` only logged AutoPR's `{:ok, pr_url}`, so no
       `PrAssociated` event was ever appended. That run's stream held exactly
       `RunStarted` then `RunCompleted`, and the whole dev event store held
       zero `PrAssociated` events and zero `pr_association:*` streams.
    2. `ProjectionStore`'s `PrAssociated` handler wrote only to the
       `pr_associations` side map, which no run read path consults — so even a
       correctly appended event would not have reached `run/1`, `list_runs/1`,
       `GET /api/runs`, `GET /api/runs/:id`, or `foreman_run_get`.

  These tests pin the read model and the producer chain
  `PrAssociate.store/2` -> command -> event -> run projection -> HTTP.
  """

  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServer.PrAssociate
  alias ForemanServer.ProjectionStore

  @pr_url "https://github.com/ldangelo/foreman/pull/420"

  setup do
    reset_projections()
    on_exit(&reset_projections/0)
    :ok
  end

  test "PrAssociated puts pr_url on the run read model, not only the association map" do
    run_id = unique_run_id()
    start_and_complete_run(run_id)
    apply_pr_associated(run_id, @pr_url, 420)

    assert %{pr_url: @pr_url, status: "completed"} = ProjectionStore.run(run_id)
    assert {:ok, %{pr_url: @pr_url, pr_number: 420}} = ProjectionStore.pr_association(run_id)

    assert [%{pr_url: @pr_url}] =
             ProjectionStore.list_runs() |> Enum.filter(&(&1.run_id == run_id))
  end

  test "a run with no PrAssociated carries pr_url: nil — explicitly absent, not a missing field" do
    run_id = unique_run_id()
    start_and_complete_run(run_id)

    run = ProjectionStore.run(run_id)

    assert Map.has_key?(run, :pr_url),
           "every projected run must carry pr_url so 'no PR' is an explicit nil " <>
             "rather than a field the read model forgot"

    assert run.pr_url == nil
    assert {:error, :not_found} = ProjectionStore.pr_association(run_id)
  end

  test "GET /api/runs/:id distinguishes a run that opened a PR from one that did not" do
    with_pr = unique_run_id()
    without_pr = unique_run_id()

    start_and_complete_run(with_pr)
    start_and_complete_run(without_pr)
    apply_pr_associated(with_pr, @pr_url, 420)

    assert %{"pr_url" => @pr_url, "status" => "completed"} = get_run!(with_pr)
    assert Map.fetch!(get_run!(without_pr), "pr_url") == nil
  end

  test "GET /api/runs carries pr_url for every projected run" do
    with_pr = unique_run_id()
    without_pr = unique_run_id()

    start_and_complete_run(with_pr)
    start_and_complete_run(without_pr)
    apply_pr_associated(with_pr, @pr_url, 420)

    by_run_id =
      build_conn()
      |> get("/api/runs")
      |> json_response(200)
      |> Map.fetch!("runs")
      |> Map.new(&{&1["run_id"], &1})

    assert by_run_id[with_pr]["pr_url"] == @pr_url
    assert Map.fetch!(by_run_id[without_pr], "pr_url") == nil
  end

  test "PrAssociate.store/2 makes the PR URL retrievable through the API" do
    run_id = unique_run_id()
    start_and_complete_run(run_id)

    assert {:ok, ^run_id} = PrAssociate.store(run_id, @pr_url)

    assert %{pr_url: @pr_url} = ProjectionStore.run(run_id)
    assert {:ok, %{pr_url: @pr_url, pr_number: 420}} = PrAssociate.lookup(run_id)
    assert %{"pr_url" => @pr_url} = get_run!(run_id)
  end

  defp reset_projections do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  defp unique_run_id, do: "run-pr-url-#{System.unique_integer([:positive])}"

  defp start_and_complete_run(run_id) do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: "task-#{run_id}",
                   project_id: "project-pr-url",
                   workflow_snapshot: %{}
                 }
               },
               %{event_type: "RunCompleted", payload: %{run_id: run_id}}
             ])
  end

  defp apply_pr_associated(run_id, pr_url, pr_number) do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "PrAssociated",
                 payload: %{
                   run_id: run_id,
                   pr_url: pr_url,
                   pr_number: pr_number,
                   associated_at: 1_700_000_000_000
                 }
               }
             ])
  end

  defp get_run!(run_id) do
    build_conn()
    |> get("/api/runs/#{run_id}")
    |> json_response(200)
    |> Map.fetch!("run")
  end
end
