defmodule ForemanServer.Overview.TabsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.Overview.Tabs
  alias ForemanServer.TestSupport.{ProjectionStoreReset, Tmp}

  defmodule CrashingExtra do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :extra
    def rows(_project_id), do: raise("provider exploded")
  end

  defmodule ShadowingLibrary do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :library
    def rows(_project_id), do: []
  end

  defmodule ShadowingScheduled do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :scheduled
    def rows(_project_id), do: []
  end

  defmodule RaisingTab do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: raise("tab exploded")
    def rows(_project_id), do: []
  end

  defmodule WorkingExtra do
    @behaviour ForemanServer.Overview.TabProvider
    def tab, do: :extra
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

  test "scheduled lists the project's schedules from the schedule read model" do
    assert Tabs.build("p").scheduled == %{available: true, rows: []}

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ScheduleCreated",
          payload: %{
            schedule_id: "s1",
            project_id: "p",
            name: "nightly triage",
            spec: %{"every" => "1h", "timezone" => "UTC", "anchor" => "2026-01-01T00:00:00Z"},
            prompt: "triage",
            workflow: "implement",
            created_at: "2026-01-01T00:00:00Z"
          }
        },
        %{
          event_type: "ScheduleCreated",
          payload: %{
            schedule_id: "s2",
            project_id: "other",
            name: "elsewhere",
            spec: %{"every" => "1h", "timezone" => "UTC", "anchor" => "2026-01-01T00:00:00Z"},
            prompt: "triage",
            workflow: "implement",
            created_at: "2026-01-01T00:00:00Z"
          }
        }
      ])

    assert %{available: true, rows: [row]} = Tabs.build("p").scheduled
    assert %{"schedule_id" => "s1", "name" => "nightly triage", "status" => "active"} = row
    assert is_binary(row["next_fire_at"])
    assert %{available: true, rows: [%{"schedule_id" => "s2"}]} = Tabs.build("other").scheduled
  end

  test "a custom provider can add a tab beyond the built-in three" do
    assert Map.keys(Tabs.build("p")) |> Enum.sort() == [:library, :pull_requests, :scheduled]

    Application.put_env(:foreman_server, :overview, tab_providers: [WorkingExtra])
    assert %{available: true, rows: [%{"name" => "nightly"}]} = Tabs.build("p").extra
  end

  # Found by the live acceptance run: a project with library files showed
  # "Not available yet." because no provider for the tab was ever registered.
  test "library lists the project's library entries" do
    root =
      Path.join(System.tmp_dir!(), "overview-library-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    # The Library publishes its entries read-only, which `File.rm_rf/1` cannot delete (it swallows
    # the `:eacces` and returns an error nobody looked at), so every suite run left this tree behind.
    on_exit(fn -> :ok = Tmp.remove_tree(root) end)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "lib-p", path: root}}
      ])

    source = Path.join(root, "facts.txt")
    File.write!(source, "the number is 7319")

    assert {:ok, _result} =
             ForemanServer.Library.add(
               "lib-p",
               {:files, [%{relative_path: "facts.txt", source_path: source}]},
               %{name: "facts"},
               %{kind: :system}
             )

    assert %{available: true, rows: [%{"name" => "facts", "kind" => "file", "file_count" => 1}]} =
             Tabs.build("lib-p").library

    assert %{available: true, rows: []} = Tabs.build("p").library
  end

  test "a crashing provider is isolated: its tab is unavailable, pull_requests still renders" do
    Application.put_env(:foreman_server, :overview, tab_providers: [CrashingExtra])

    log = capture_log(fn -> send(self(), {:tabs, Tabs.build("p")}) end)
    assert_received {:tabs, tabs}

    assert log =~ "provider exploded"
    assert %{available: false, rows: [], error: "provider_failed"} = tabs.extra
    assert %{available: true, rows: [_]} = tabs.pull_requests
  end

  test "two providers naming one tab is a configuration error, not a silent override" do
    Application.put_env(:foreman_server, :overview, tab_providers: [WorkingExtra, CrashingExtra])

    assert_raise ArgumentError, ~r/:extra.*WorkingExtra.*CrashingExtra/s, fn ->
      Tabs.build("p")
    end
  end

  test "a configured provider cannot shadow a built-in tab" do
    Application.put_env(:foreman_server, :overview, tab_providers: [ShadowingLibrary])

    assert_raise ArgumentError, ~r/:library.*Tabs\.Library.*ShadowingLibrary/s, fn ->
      Tabs.build("p")
    end

    Application.put_env(:foreman_server, :overview, tab_providers: [ShadowingScheduled])

    assert_raise ArgumentError, ~r/:scheduled.*Tabs\.Scheduled.*ShadowingScheduled/s, fn ->
      Tabs.build("p")
    end
  end

  test "a provider whose tab/0 raises is isolated: the other tabs still build" do
    Application.put_env(:foreman_server, :overview, tab_providers: [RaisingTab, WorkingExtra])

    log = capture_log(fn -> send(self(), {:tabs, Tabs.build("p")}) end)
    assert_received {:tabs, tabs}

    assert log =~ "tab/0 failed: tab exploded"
    assert %{available: true, rows: [%{"name" => "nightly"}]} = tabs.extra
    assert %{available: true, rows: [_]} = tabs.pull_requests
  end

  test "the overview DTO carries the tabs" do
    {:ok, overview} = Overview.build("p")
    dto = Overview.to_dto(overview)

    assert dto["tabs"]["library"] == %{"available" => true, "rows" => []}
    assert %{"available" => true, "rows" => [_]} = dto["tabs"]["pull_requests"]
  end
end
