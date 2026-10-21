defmodule ForemanServer.PrAutoFixSettingTest do
  @moduledoc """
  The `pr_auto_fix` project setting (E9-S4): opt-in, validated at the aggregate
  boundary (one typed error per mistake), stored string-keyed so the live value
  equals the one replayed from the JSON event log, readable through
  `ProjectSettings`, the `ProjectSettingsDTO` wire shape and the auto-fix policy,
  and clearable.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Project.Settings
  alias ForemanServer.PrWatcher.AutoFix
  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectSettingsDTO}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  describe "validation (every typed error)" do
    defp normalize(value), do: Settings.normalize(%{pr_auto_fix: value})

    test "a valid setting normalises to a string-keyed map with defaults filled in" do
      assert {:ok, %{pr_auto_fix: normalized}} = normalize(%{kinds: [:comments, "ci"]})

      assert normalized == %{
               "kinds" => ["ci", "comments"],
               "max_attempts" => 2,
               "cooldown_seconds" => 0
             }

      assert {:ok, %{pr_auto_fix: full}} =
               normalize(%{
                 "kinds" => ["conflicts", "ci", "ci"],
                 "max_attempts" => 5,
                 "cooldown_seconds" => 86_400
               })

      assert full == %{
               "kinds" => ["ci", "conflicts"],
               "max_attempts" => 5,
               "cooldown_seconds" => 86_400
             }
    end

    test "atom and string keys normalise to the identical value" do
      assert normalize(%{kinds: ["ci"], max_attempts: 3, cooldown_seconds: 60}) ==
               normalize(%{"kinds" => ["ci"], "max_attempts" => 3, "cooldown_seconds" => 60})
    end

    test "nil, an empty map and an empty kinds list all mean off" do
      assert {:ok, %{pr_auto_fix: nil}} = normalize(nil)
      assert {:ok, %{pr_auto_fix: nil}} = normalize(%{})
      assert {:ok, %{pr_auto_fix: nil}} = normalize(%{kinds: [], max_attempts: 3})
    end

    test "an unknown kind names the offender, atom or string" do
      assert {:error, {:pr_auto_fix_unknown_kind, "deploy"}} =
               normalize(%{kinds: ["ci", "deploy"]})

      assert {:error, {:pr_auto_fix_unknown_kind, :merge}} = normalize(%{kinds: [:merge]})
    end

    test "a non-map setting and a non-list kinds are pr_auto_fix_invalid" do
      assert {:error, {:pr_auto_fix_invalid, "ci"}} = normalize("ci")
      assert {:error, {:pr_auto_fix_invalid, ["ci"]}} = normalize(["ci"])
      assert {:error, {:pr_auto_fix_invalid, "ci"}} = normalize(%{kinds: "ci"})
    end

    test "max_attempts is an integer in 1..5" do
      for bad <- [0, 6, -1, 2.0, "2"] do
        assert {:error, {:pr_auto_fix_max_attempts_invalid, ^bad, 1..5}} =
                 normalize(%{kinds: ["ci"], max_attempts: bad})
      end

      for good <- 1..5 do
        assert {:ok, %{pr_auto_fix: %{"max_attempts" => ^good}}} =
                 normalize(%{kinds: ["ci"], max_attempts: good})
      end
    end

    test "cooldown_seconds is an integer in 0..86400" do
      for bad <- [-1, 86_401, 1.5, "10"] do
        assert {:error, {:pr_auto_fix_cooldown_invalid, ^bad, 0..86_400}} =
                 normalize(%{kinds: ["ci"], cooldown_seconds: bad})
      end

      assert {:ok, %{pr_auto_fix: %{"cooldown_seconds" => 0}}} =
               normalize(%{kinds: ["ci"], cooldown_seconds: 0})
    end

    test "the kinds are checked before the bounds" do
      assert {:error, {:pr_auto_fix_unknown_kind, "x"}} =
               normalize(%{kinds: ["x"], max_attempts: 99})
    end
  end

  describe "through project.update" do
    setup do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)
      id = "prafix-#{System.unique_integer([:positive])}"
      {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}"})
      {:ok, id: id}
    end

    defp dispatch(id, type, payload) do
      CommandGateway.dispatch_operator(%{
        command_id: "#{type}-#{System.unique_integer([:positive])}",
        aggregate_id: "project:#{id}",
        type: type,
        payload: Map.put(payload, :project_id, id)
      })
    end

    defp replay(id) do
      {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 1_000)
      :ok = ProjectionStore.rebuild(events)
    end

    defp stored(id), do: ProjectionStore.project_settings(id).pr_auto_fix

    @on %{"kinds" => ["ci", "comments"], "max_attempts" => 3, "cooldown_seconds" => 120}

    test "off by default", %{id: id} do
      assert stored(id) == nil
      assert AutoFix.settings(id) == nil
    end

    test "the setting round-trips live, replayed, over the DTO and to the policy", %{id: id} do
      {:ok, _} =
        dispatch(id, "project.update", %{
          pr_auto_fix: %{kinds: [:comments, :ci], max_attempts: 3, cooldown_seconds: 120}
        })

      assert stored(id) == @on
      replay(id)
      assert stored(id) == @on

      assert {:ok, %{"settings" => %{"pr_auto_fix" => @on}}} = ProjectSettingsDTO.fetch(id)
      assert AutoFix.settings(id) == @on
    end

    test "a JSON-shaped (string-keyed) request stores the same value", %{id: id} do
      {:ok, _} =
        dispatch(id, "project.update", %{
          "pr_auto_fix" => %{
            "kinds" => ["comments", "ci"],
            "max_attempts" => 3,
            "cooldown_seconds" => 120
          }
        })

      assert stored(id) == @on
      replay(id)
      assert stored(id) == @on
    end

    test "an invalid setting is refused with its typed error and nothing changes", %{id: id} do
      {:ok, _} = dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["ci"]}})
      before = stored(id)
      assert %{"kinds" => ["ci"]} = before

      assert {:error, {:pr_auto_fix_unknown_kind, "merge"}} =
               dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["merge"]}})

      assert {:error, {:pr_auto_fix_max_attempts_invalid, 9, 1..5}} =
               dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["ci"], max_attempts: 9}})

      assert {:error, {:pr_auto_fix_cooldown_invalid, -5, 0..86_400}} =
               dispatch(id, "project.update", %{
                 pr_auto_fix: %{kinds: ["ci"], cooldown_seconds: -5}
               })

      assert {:error, {:pr_auto_fix_invalid, "ci"}} =
               dispatch(id, "project.update", %{pr_auto_fix: "ci"})

      assert stored(id) == before
      replay(id)
      assert stored(id) == before
    end

    test "other settings neither clobber nor are clobbered by it", %{id: id} do
      {:ok, _} = dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["conflicts"]}})
      {:ok, _} = dispatch(id, "project.update", %{daily_thread_cap: 7})

      assert %{"kinds" => ["conflicts"]} = stored(id)
      replay(id)
      assert %{"kinds" => ["conflicts"]} = stored(id)
      assert ProjectionStore.project_settings(id).daily_thread_cap == 7
    end

    test "cleared_settings turns it off, live and after replay", %{id: id} do
      {:ok, _} = dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["ci"]}})
      assert stored(id) != nil

      {:ok, _} = dispatch(id, "project.update", %{cleared_settings: ["pr_auto_fix"]})
      assert stored(id) == nil
      assert AutoFix.settings(id) == nil
      replay(id)
      assert stored(id) == nil
      assert {:ok, %{"settings" => %{"pr_auto_fix" => nil}}} = ProjectSettingsDTO.fetch(id)
    end

    test "an empty kinds list clears it too", %{id: id} do
      {:ok, _} = dispatch(id, "project.update", %{pr_auto_fix: %{kinds: ["ci"]}})
      {:ok, _} = dispatch(id, "project.update", %{pr_auto_fix: %{kinds: []}})

      assert stored(id) == nil
      replay(id)
      assert stored(id) == nil
    end
  end
end
