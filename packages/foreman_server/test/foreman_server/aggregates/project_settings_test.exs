defmodule ForemanServer.Aggregates.ProjectSettingsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project
  alias ForemanServer.Aggregates.Project.Settings

  defp registered do
    {:ok, spec} =
      Project.handle_command(Project.initial_state(), %{
        type: "project.register",
        payload: %{project_id: "p1", path: "/tmp/p1"}
      })

    Project.apply_event(Project.initial_state(), spec)
  end

  defp update(state, payload) do
    Project.handle_command(state, %{
      type: "project.update",
      payload: Map.put(payload, :project_id, "p1")
    })
  end

  describe "instructions" do
    test "exactly 16000 characters pass, 16001 fail with the measured length" do
      state = registered()
      assert {:ok, _} = update(state, %{instructions: String.duplicate("a", 16_000)})

      assert {:error, {:instructions_too_long, 16_001, 16_000}} =
               update(state, %{instructions: String.duplicate("a", 16_001)})
    end

    test "length counts characters, not bytes" do
      emoji = String.duplicate("😀", 16_000)
      assert byte_size(emoji) > 16_000
      assert {:ok, _} = update(registered(), %{instructions: emoji})
    end

    test "a non-string fails with a tuple distinct from too-long" do
      assert {:error, {:instructions_not_a_string, :integer}} =
               update(registered(), %{instructions: 123})
    end

    test "invalid UTF-8 is rejected with its own tuple" do
      assert {:error, {:instructions_invalid_encoding}} =
               update(registered(), %{instructions: <<0xFF, 0xFE>>})
    end

    test "CRLF is normalised to LF and surrounding whitespace is trimmed" do
      assert {:ok, %{payload: payload}} =
               update(registered(), %{instructions: "  a\r\nb  \n"})

      assert payload.instructions == "a\nb"
    end

    test "whitespace-only instructions mean clear" do
      assert {:ok, %{payload: payload}} = update(registered(), %{instructions: "  \n "})
      refute Map.has_key?(payload, :instructions)
      assert payload.cleared_settings == ["instructions"]
    end
  end

  describe "goal" do
    test "over 2000 characters is rejected with a goal tuple" do
      assert {:error, {:goal_too_long, 2001, 2000}} =
               update(registered(), %{goal: String.duplicate("g", 2001)})
    end
  end

  describe "other settings" do
    test "limits and model/effort validate with distinct tuples" do
      state = registered()

      assert {:error, {:max_concurrent_runs_invalid, 0, 1..1000}} =
               update(state, %{max_concurrent_runs: 0})

      assert {:error, {:max_concurrent_runs_invalid, "3", _}} =
               update(state, %{max_concurrent_runs: "3"})

      assert {:error, {:daily_thread_cap_invalid, 10_001, 1..10_000}} =
               update(state, %{daily_thread_cap: 10_001})

      assert {:error, {:thread_effort_invalid, "turbo", _}} =
               update(state, %{thread_effort: "turbo"})

      assert {:error, {:coordinator_effort_invalid, "x", _}} =
               update(state, %{coordinator_effort: "x"})

      assert {:error, {:thread_model_invalid, 5}} = update(state, %{thread_model: 5})

      assert {:error, {:coordinator_model_invalid, "a b"}} =
               update(state, %{coordinator_model: "a b"})
    end
  end

  describe "notification_preference" do
    test "accepts the three preferences, normalising case and whitespace" do
      for pref <- ~w(every_turn blocked_only off) do
        assert {:ok, %{notification_preference: ^pref}} =
                 Settings.normalize(%{notification_preference: " " <> String.upcase(pref) <> " "})
      end
    end

    test "rejects anything else with a distinct tuple listing the allowed values" do
      assert {:error, {:notification_preference_invalid, "always", allowed}} =
               update(registered(), %{notification_preference: "always"})

      assert allowed == ~w(every_turn blocked_only off)

      assert {:error, {:notification_preference_invalid, true, _}} =
               update(registered(), %{notification_preference: true})
    end

    test "nil and blank clear the setting" do
      assert {:ok, %{notification_preference: nil}} =
               Settings.normalize(%{notification_preference: nil})

      assert {:ok, %{notification_preference: nil}} =
               Settings.normalize(%{"notification_preference" => "  "})
    end
  end

  describe "config whitelist" do
    test "an unknown config key is rejected" do
      assert {:error, {:unknown_setting, "foo"}} = update(registered(), %{config: %{foo: 1}})
      assert {:error, {:unknown_setting, "bar"}} = update(registered(), %{config: %{"bar" => 1}})
    end

    test "legacy keys still pass untouched" do
      assert {:ok, %{payload: payload}} =
               update(registered(), %{
                 name: "x",
                 config: %{"database_path" => "/tmp/x.db", env: %{"A" => "b"}}
               })

      assert payload.config == %{"database_path" => "/tmp/x.db", env: %{"A" => "b"}}
    end

    test "a setting smuggled through raw config is validated like a top-level one" do
      assert {:error, {:instructions_too_long, 16_001, 16_000}} =
               update(registered(), %{config: %{instructions: String.duplicate("a", 16_001)}})

      assert {:error, {:instructions_too_long, 16_001, 16_000}} =
               update(registered(), %{config: %{"instructions" => String.duplicate("a", 16_001)}})
    end

    test "string and atom keys normalise identically" do
      {:ok, a} = update(registered(), %{goal: "ship", max_concurrent_runs: 2})
      {:ok, b} = update(registered(), %{"goal" => "ship", "max_concurrent_runs" => 2})
      assert a.payload == b.payload
    end

    test "unknown cleared setting names are rejected" do
      assert {:error, {:unknown_setting, "name"}} =
               update(registered(), %{cleared_settings: ["name"]})
    end

    test "setting and clearing the same key in one update is rejected" do
      assert {:error, {:setting_set_and_cleared, :goal}} =
               update(registered(), %{goal: "x", cleared_settings: ["goal"]})
    end

    test "register accepts and folds settings too" do
      {:ok, spec} =
        Project.handle_command(Project.initial_state(), %{
          type: "project.register",
          payload: %{project_id: "p2", path: "/tmp/p2", config: %{goal: "hi"}}
        })

      state = Project.apply_event(Project.initial_state(), spec)
      assert state.config.goal == "hi"
    end
  end

  describe "required_checks" do
    defp checks(raw), do: Settings.normalize(%{required_checks: raw})

    test "a valid list is sorted, de-duplicated and string keyed, with a false allow_skipped dropped" do
      assert {:ok, %{required_checks: normalized}} =
               checks([
                 %{name: " test ", kind: "check_run", allow_skipped: false},
                 %{
                   "name" => "build",
                   "kind" => "check_run",
                   "workflow" => "ci",
                   "allow_skipped" => true
                 },
                 %{
                   "name" => "build",
                   "kind" => "check_run",
                   "workflow" => "ci",
                   "allow_skipped" => true
                 },
                 %{"name" => "ci/status", "kind" => "status_context"},
                 %{"name" => "build", "kind" => "check_run"}
               ])

      assert normalized == [
               %{"name" => "build", "kind" => "check_run"},
               %{
                 "name" => "build",
                 "kind" => "check_run",
                 "workflow" => "ci",
                 "allow_skipped" => true
               },
               %{"name" => "ci/status", "kind" => "status_context"},
               %{"name" => "test", "kind" => "check_run"}
             ]

      refute Enum.any?(
               normalized,
               &(Map.has_key?(&1, "allow_skipped") and &1["allow_skipped"] == false)
             )
    end

    test "nil clears the setting and an empty list stays gate on with no checks" do
      assert {:ok, %{required_checks: nil}} = checks(nil)
      assert {:ok, %{required_checks: []}} = checks([])
      assert {:ok, %{required_checks: []}} = Settings.normalize(%{"required_checks" => []})
      refute checks([]) == checks(nil)
    end

    test "each failure has its own typed error and nothing is stored" do
      ok = %{"name" => "build", "kind" => "check_run"}

      assert {:error, {:required_checks_invalid, "build"}} = checks("build")
      assert {:error, {:required_checks_invalid, "build"}} = checks(["build"])
      assert {:error, {:required_checks_invalid, %{}}} = checks(%{})

      assert {:error, {:required_checks_too_many, 21, 20}} =
               checks(for(i <- 1..21, do: %{ok | "name" => "c#{i}"}))

      assert {:ok, _} = checks(for(i <- 1..20, do: %{ok | "name" => "c#{i}"}))

      assert {:error, {:required_checks_kind_invalid, "deploy"}} =
               checks([%{ok | "kind" => "deploy"}])

      assert {:error, {:required_checks_kind_invalid, nil}} = checks([%{"name" => "build"}])

      assert {:error, {:required_checks_unknown_key, "color"}} =
               checks([Map.put(ok, "color", "red")])

      for bad <- [nil, "", "  ", "a\nb", String.duplicate("a", 201), 7] do
        assert {:error, {:required_checks_name_invalid, ^bad}} = checks([%{ok | "name" => bad}])
      end

      assert {:ok, _} = checks([%{ok | "name" => String.duplicate("a", 200)}])

      for bad <- ["", "a\tb", String.duplicate("w", 201), 3] do
        assert {:error, {:required_checks_workflow_invalid, ^bad}} =
                 checks([Map.put(ok, "workflow", bad)])
      end

      assert {:error, {:required_checks_allow_skipped_invalid, "yes"}} =
               checks([Map.put(ok, "allow_skipped", "yes")])
    end

    test "workflow and allow_skipped are refused on a status_context, even false" do
      ctx = %{"name" => "ci/status", "kind" => "status_context"}

      assert {:error, {:required_checks_workflow_invalid, "ci"}} =
               checks([Map.put(ctx, "workflow", "ci")])

      assert {:error, {:required_checks_allow_skipped_invalid, true}} =
               checks([Map.put(ctx, "allow_skipped", true)])

      assert {:error, {:required_checks_allow_skipped_invalid, false}} =
               checks([Map.put(ctx, "allow_skipped", false)])
    end

    test "one name, kind and workflow with two allow_skipped values conflicts" do
      assert {:error, {:required_checks_conflicting_entry, "build", "check_run", nil}} =
               checks([
                 %{"name" => "build", "kind" => "check_run", "allow_skipped" => true},
                 %{"name" => "build", "kind" => "check_run"}
               ])

      assert {:ok, %{required_checks: [_, _]}} =
               checks([
                 %{"name" => "build", "kind" => "check_run", "allow_skipped" => true},
                 %{"name" => "build", "kind" => "check_run", "workflow" => "ci"}
               ])
    end

    test "an update stores the list, [] included, and a clear removes it" do
      state = registered()
      assert {:ok, %{payload: payload} = spec} = update(state, %{required_checks: []})
      assert payload.required_checks == []
      state = Project.apply_event(state, spec)
      assert state.config.required_checks == []

      assert {:ok, %{payload: cleared} = spec} =
               update(state, %{cleared_settings: ["required_checks"]})

      assert cleared.cleared_settings == ["required_checks"]
      refute Map.has_key?(Project.apply_event(state, spec).config, :required_checks)

      assert {:error, {:required_checks_kind_invalid, "x"}} =
               update(state, %{required_checks: [%{"name" => "a", "kind" => "x"}]})
    end
  end

  describe "changed_keys/1" do
    test "reports top-level sets, nested config sets, nil clears and cleared_settings" do
      assert Settings.changed_keys(%{
               project_id: "p1",
               required_checks: [],
               goal: nil,
               config: %{"pr_auto_fix" => %{"kinds" => []}, "name" => "x"},
               cleared_settings: ["instructions", :thread_model, "bogus"]
             }) == %{
               required_checks: :set,
               goal: :clear,
               pr_auto_fix: :set,
               instructions: :clear,
               thread_model: :clear
             }
    end

    test "string keys count and a nested required_checks is found in config" do
      assert Settings.changed_keys(%{"config" => %{"required_checks" => []}}) == %{
               required_checks: :set
             }

      assert Settings.changed_keys(%{"cleared_settings" => ["required_checks"]}) == %{
               required_checks: :clear
             }

      assert Settings.changed_keys(%{config: %{required_checks: nil}}) == %{
               required_checks: :clear
             }

      assert Settings.changed_keys(%{project_id: "p1"}) == %{}
    end

    test "a key both set and cleared reports :set" do
      assert Settings.changed_keys(%{required_checks: [], cleared_settings: ["required_checks"]}) ==
               %{required_checks: :set}
    end
  end

  describe "fold" do
    test "settings land in state.config and clearing removes them (string-key replay safe)" do
      state = registered()
      {:ok, spec} = update(state, %{goal: "ship it", instructions: "be kind"})
      state = Project.apply_event(state, spec)
      assert state.config.goal == "ship it"

      # event as read back from JSON: string keys
      json_event = %{
        "event_type" => "ProjectUpdated",
        "payload" => spec.payload |> Jason.encode!() |> Jason.decode!()
      }

      replayed = Project.apply_event(registered(), json_event)
      assert replayed.config == state.config

      {:ok, spec} = update(state, %{cleared_settings: ["instructions"]})
      state = Project.apply_event(state, spec)
      refute Map.has_key?(state.config, :instructions)
      assert state.config.goal == "ship it"
    end

    test "keys/0 is the single table the typed event mirrors" do
      fields = ForemanServer.Events.ProjectUpdated.__struct__() |> Map.keys()
      for key <- Settings.keys(), do: assert(key in fields)
    end
  end
end
