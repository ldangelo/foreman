defmodule ForemanServer.ProjectSettingsReadModelTest do
  # AGENTS 5.4 for the settings read model (CodeRabbit PR #591 [2], bead foreman-27ayh).
  #
  # The projection fold (`ProjectionStore`'s ProjectRegistered/ProjectUpdated handlers) is the
  # ONE place settings are normalised: they reach `project.config` under atom keys and nowhere
  # else, whatever spelling the command carried. So `ProjectSettings.from_config/1` reads that
  # one convention. These tests pin both halves: the invariant that makes a single spelling
  # safe, and the reader that does not guess a second one.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectSettings}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    {:ok, id: "settings-keys-#{System.unique_integer([:positive])}"}
  end

  defp dispatch(id, type, payload) do
    CommandGateway.dispatch_operator(%{
      command_id: "#{type}-#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{id}",
      type: type,
      payload: Map.put(payload, :project_id, id)
    })
  end

  defp config(id), do: ProjectionStore.project_projection(id).config

  defp setting_keys_in(config) do
    names = Enum.map(ProjectSettings.keys(), &Atom.to_string/1)
    for key <- Map.keys(config), key in ProjectSettings.keys() or key in names, do: key
  end

  describe "the projected config" do
    test "holds every setting under its atom key only: live, from string-keyed input, replayed",
         %{
           id: id
         } do
      # what an HTTP/JSON client sends: string keys at the top level and inside the open
      # `config` (the aggregate accepts settings in either place)
      assert {:ok, _} =
               dispatch(id, "project.register", %{
                 "path" => "/tmp/#{id}",
                 "goal" => "top level",
                 "config" => %{"thread_model" => "opus", "name" => "Demo"}
               })

      assert {:ok, _} =
               dispatch(id, "project.update", %{
                 "daily_thread_cap" => 5,
                 "config" => %{"max_concurrent_runs" => 2}
               })

      live = config(id)

      assert setting_keys_in(live) |> Enum.sort() ==
               Enum.sort([:goal, :thread_model, :daily_thread_cap, :max_concurrent_runs])

      assert %ProjectSettings{
               goal: "top level",
               thread_model: "opus",
               daily_thread_cap: 5,
               max_concurrent_runs: 2
             } = ProjectionStore.project_settings(id)

      {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 1_000)
      :ok = ProjectionStore.rebuild(events)

      assert config(id) == live
    end

    test "a setting cleared or replaced leaves no stale spelling behind", %{id: id} do
      assert {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}", goal: "old"})
      assert {:ok, _} = dispatch(id, "project.update", %{"goal" => "new"})
      assert {:ok, _} = dispatch(id, "project.update", %{cleared_settings: ["goal"]})

      assert setting_keys_in(config(id)) == []
      assert %ProjectSettings{goal: nil} = ProjectionStore.project_settings(id)
    end
  end

  describe "ProjectSettings.from_config/1" do
    test "reads the atom keys the projection writes" do
      assert %ProjectSettings{goal: "ship", daily_thread_cap: 3} =
               ProjectSettings.from_config(%{goal: "ship", daily_thread_cap: 3})
    end

    test "a string key is not a second spelling of a setting" do
      assert %ProjectSettings{goal: nil, daily_thread_cap: nil} =
               ProjectSettings.from_config(%{"goal" => "ship", "daily_thread_cap" => 3})
    end

    test "false is a value: it never falls through to another spelling" do
      config = %{
        :coordinator_propose_before_start => false,
        "coordinator_propose_before_start" => true
      }

      assert %ProjectSettings{coordinator_propose_before_start: false} =
               ProjectSettings.from_config(config)
    end

    test "a missing or non-map config has no settings" do
      assert ProjectSettings.from_config(nil) == %ProjectSettings{}
      assert ProjectSettings.from_config(%{}) == %ProjectSettings{}
    end
  end
end
