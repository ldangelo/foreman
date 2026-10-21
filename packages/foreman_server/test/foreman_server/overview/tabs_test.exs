defmodule ForemanServer.Overview.TabsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.Overview.Tabs
  alias ForemanServer.TestSupport.ProjectionStoreReset

  defmodule CrashingLibrary do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :library
    def rows(_project_id), do: raise("provider exploded")
  end

  defmodule WorkingScheduled do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :scheduled
    def rows(project_id), do: [%{"project_id" => project_id, "name" => "nightly"}]
  end

  setup do
    ProjectionStoreReset.reset!()
    previous = Application.get_env(:foreman_server, :overview)

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous,
        do: Application.put_env(:foreman_server, :overview, previous),
        else: Application.delete_env(:foreman_server, :overview)
    end)

    Application.delete_env(:foreman_server, :overview)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "r1", task_id: "t1", project_id: "p"}},
        %{event_type: "PrReady", payload: %{run_id: "r1", pr_url: "https://g/p/1", pr_number: 1}},
        %{event_type: "RunStarted", payload: %{run_id: "r2", task_id: "t2", project_id: "p"}},
        %{event_type: "RunStarted", payload: %{run_id: "r3", task_id: "t3", project_id: "other"}},
        %{event_type: "PrReady", payload: %{run_id: "r3", pr_url: "https://g/p/3"}}
      ])

    :ok
  end

  test "pull_requests lists exactly this project's runs with a PR" do
    assert %{available: true, rows: [row]} = Tabs.build("p").pull_requests

    assert %{
             "run_id" => "r1",
             "thread_id" => "run:r1",
             "pr_url" => "https://g/p/1",
             "pr_number" => 1,
             "pr_state" => "open",
             "merge_gate" => "pending"
           } = row
  end

  test "library and scheduled are unavailable until a provider is registered" do
    tabs = Tabs.build("p")
    assert tabs.library == %{available: false, rows: []}
    assert tabs.scheduled == %{available: false, rows: []}

    Application.put_env(:foreman_server, :overview, tab_providers: [WorkingScheduled])
    assert %{available: true, rows: [%{"name" => "nightly"}]} = Tabs.build("p").scheduled
    assert Tabs.build("p").library == %{available: false, rows: []}
  end

  test "a crashing provider is isolated: its tab is unavailable, pull_requests still renders" do
    Application.put_env(:foreman_server, :overview, tab_providers: [CrashingLibrary])

    log = capture_log(fn -> send(self(), {:tabs, Tabs.build("p")}) end)
    assert_received {:tabs, tabs}

    assert log =~ "provider exploded"
    assert %{available: false, rows: [], error: "provider_failed"} = tabs.library
    assert %{available: true, rows: [_]} = tabs.pull_requests
  end

  test "the overview DTO carries the tabs" do
    {:ok, overview} = Overview.build("p")
    dto = Overview.to_dto(overview)

    assert dto["tabs"]["library"] == %{"available" => false, "rows" => []}
    assert %{"available" => true, "rows" => [_]} = dto["tabs"]["pull_requests"]
  end
end
