defmodule ForemanServer.Coordinator.RedactTest do
  @moduledoc """
  Coordinator conversation text is redacted before it is persisted, with the project's ONE
  redaction list (`ProjectEnvironment.secrets/1`): every secret-store value whatever its name,
  plus the env values whose names look secret. A value stored as `DB_URL` looks like no secret by
  name, so name patterns alone let it into the transcript events.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Commands, Redact}

  alias ForemanServer.{
    CommandGateway,
    CommandRouter,
    EventStore,
    ProjectEnvironment,
    ProjectionStore,
    ProjectSecrets
  }

  # A gateway that only reports what it was handed (to the test process, which calls it).
  defmodule RecordingGateway do
    @moduledoc false
    def dispatch_system(command) do
      send(self(), {:dispatched, command})
      {:ok, nil}
    end
  end

  @db_url "postgres://svc:hunter2pw@db.internal:5432/app"
  @api_token "tok-secret-12345"

  setup %{tmp_dir: dir} do
    store = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(dir, "secrets"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, store) end)

    project_id = "co-redact-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{
          project_id: project_id,
          path: dir,
          config: %{env: %{"API_TOKEN" => @api_token}}
        }
      })

    assert {:ok, %{name: "DB_URL"}} = ProjectSecrets.set(project_id, "DB_URL", @db_url, "test")

    {:ok, project_id: project_id}
  end

  defp stream_text(project_id) do
    {:ok, events} = EventStore.read_stream_forward("coordinator:#{project_id}", 0, 100)
    inspect(events)
  end

  defp texts(project_id) do
    {:ok, %{messages: messages}} = ProjectionStore.coordinator_conversation(project_id)
    Enum.map(messages, & &1.text)
  end

  test "text/3 redacts a stored value whatever its name, and an env value whose name looks secret",
       %{project_id: p} do
    redacted = Redact.text(p, "db #{@db_url} and key #{@api_token} but not the word DB_URL")

    refute redacted =~ @db_url
    refute redacted =~ @api_token
    assert redacted == "db [REDACTED] and key [REDACTED] but not the word DB_URL"
  end

  # Redaction replaces a value verbatim wherever it occurs, so a stored value of "1" or "ok"
  # would rewrite those characters across every message. Short values whose names look like no
  # secret are left out of the list; a secret-named value is listed at any length.
  test "a short stored value corrupts nothing; a long one and a secret-named short one are redacted",
       %{project_id: p} do
    assert {:ok, _} = ProjectSecrets.set(p, "RETRY_COUNT", "1", "test")
    assert {:ok, _} = ProjectSecrets.set(p, "FLAG_WORD", "ok", "test")
    assert {:ok, _} = ProjectSecrets.set(p, "LONG_ONE", "exactly8", "test")
    assert {:ok, _} = ProjectSecrets.set(p, "SHORT_TOKEN", "ab", "test")

    text = "retry 1 time, status ok, id 1001; pw exactly8 and tok ab end"

    assert Redact.text(p, text) ==
             "retry 1 time, status ok, id 1001; pw [REDACTED] and tok [REDACTED] end"
  end

  test "an operator message never reaches the event log with a stored value in it",
       %{project_id: p} do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "op-redact-#{p}",
               aggregate_id: "coordinator:#{p}",
               type: "coordinator.message",
               payload: %{
                 project_id: p,
                 message_id: "m1",
                 text: "the database is #{@db_url}, remember it",
                 source: "cli"
               }
             })

    assert ["the database is [REDACTED], remember it"] = texts(p)
    refute stream_text(p) =~ @db_url
  end

  test "a coordinator-authored message never reaches the event log with a stored value in it",
       %{project_id: p} do
    assert {:ok, _} =
             Commands.append(CommandGateway, p, "reply-1", %{
               role: "coordinator",
               kind: "reply",
               text: "I connected to #{@db_url} and it works"
             })

    assert ["I connected to [REDACTED] and it works"] = texts(p)
    refute stream_text(p) =~ @db_url
  end

  defp conversation(p), do: elem(ProjectionStore.coordinator_state(p), 1)

  # A project whose stored environment `ProjectEnvironment.secrets/1` refuses (a reserved name).
  defp refused_project! do
    id = "co-redact-refused-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: id,
            path: "/tmp/#{id}",
            config: %{env: %{"FOREMAN_RUN_ID" => "sneaky-value-9"}}
          }
        }
      ])

    assert_raise ArgumentError, fn -> ProjectEnvironment.secrets(id) end
    id
  end

  describe "text/3 and data/3 without :secrets resolve the list themselves" do
    test "no project (nil or empty id) is the patterns alone, never a crash" do
      assert Redact.text(nil, "tok password=hunter2 end") == "tok password=[REDACTED] end"
      assert Redact.text("", "tok password=hunter2 end") == "tok password=[REDACTED] end"

      assert Redact.data(nil, %{"a" => ["password=hunter2", 3]}) ==
               %{"a" => ["password=[REDACTED]", 3]}

      assert Redact.data("", "tok password=hunter2 end") == "tok password=[REDACTED] end"
    end

    # The coordinator conversation is never persisted under a partial list: this is the stricter
    # contract the persist paths that must not raise opt out of with `secrets/1`.
    test "a project whose environment is refused raises, as ProjectEnvironment.secrets/1 does" do
      id = refused_project!()

      assert_raise ArgumentError, ~r/environment is invalid/, fn -> Redact.text(id, "x") end

      assert_raise ArgumentError, ~r/environment is invalid/, fn ->
        Redact.data(id, %{"a" => "x"})
      end

      capture_log(fn -> assert Redact.secrets(id) == [] end)
    end
  end

  describe "secrets/1, redactor/1 and data/3: the list is resolved once and never raises" do
    test "no project, an empty id and an unknown project have no list: the patterns still apply" do
      assert Redact.secrets(nil) == []
      assert Redact.secrets("") == []
      assert Redact.secrets("no-such-project-#{System.unique_integer([:positive])}") == []

      assert Redact.redactor(nil).("tok password=hunter2 end") == "tok password=[REDACTED] end"
    end

    test "the list is the project's: a stored value whatever its name, an env value that looks secret",
         %{project_id: p} do
      assert Enum.sort(Redact.secrets(p)) == Enum.sort([@db_url, @api_token])
    end

    test "an environment the resolver refuses degrades to the patterns, logged without a name or a value" do
      id = refused_project!()

      log = capture_log(fn -> assert Redact.secrets(id) == [] end)

      assert log =~ id
      assert log =~ "reserved_project_env_keys"
      refute log =~ "FOREMAN_RUN_ID"
      refute log =~ "sneaky-value-9"

      assert Redact.redactor(id).("tok password=hunter2 end") == "tok password=[REDACTED] end"
    end

    test "an unreadable secret store costs the store's values only, logged without a value",
         %{project_id: p, tmp_dir: dir} do
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "x")
      store = Application.get_env(:foreman_server, :secret_store)

      Application.put_env(
        :foreman_server,
        :secret_store,
        Keyword.put(store, :dir, Path.join(blocker, "sub"))
      )

      log = capture_log(fn -> assert Redact.secrets(p) == [@api_token] end)

      assert log =~ "secret store unavailable"
      assert log =~ p
      refute log =~ @db_url
      refute log =~ @api_token
    end

    test "the list is read once: a redactor does not see a secret stored after it was made",
         %{project_id: p} do
      redact = Redact.redactor(p)
      assert {:ok, _} = ProjectSecrets.set(p, "LATE_ONE", "stored-after-the-redactor", "test")

      assert redact.("a #{@db_url} b stored-after-the-redactor c") ==
               "a [REDACTED] b stored-after-the-redactor c"
    end

    test "data/3 redacts every string inside maps and lists and keeps everything else",
         %{project_id: p} do
      at = ~U[2026-01-01 00:00:00Z]

      data = %{
        "url" => "go #{@db_url}",
        "nested" => %{"list" => ["x", "tok #{@api_token}", 3, nil, true, [@db_url]]},
        "at" => at,
        plain: "kept"
      }

      assert Redact.data(p, data, secrets: Redact.secrets(p)) == %{
               "url" => "go [REDACTED]",
               "nested" => %{"list" => ["x", "tok [REDACTED]", 3, nil, true, ["[REDACTED]"]]},
               "at" => at,
               plain: "kept"
             }
    end
  end

  describe "a coordinator turn's failure message" do
    setup %{project_id: p} do
      assert {:ok, _} = Commands.turn_start(CommandGateway, p, "t1", 1, ["m1"])
      :ok
    end

    test "never reaches the event log or the status with a stored value in it, whatever its name",
         %{project_id: p} do
      assert {:ok, _} =
               Commands.turn_fail(
                 CommandGateway,
                 p,
                 "t1",
                 1,
                 :agent_failed,
                 "provider said: cannot reach #{@db_url} (#{@api_token})",
                 3
               )

      refute stream_text(p) =~ @db_url
      refute stream_text(p) =~ @api_token

      assert {:ok,
              %{last_error: %{message: "provider said: cannot reach [REDACTED] ([REDACTED])"}}} =
               ProjectionStore.coordinator_status(p)
    end

    test "is redacted BEFORE it is cut: a value straddling the cut leaves no half behind",
         %{project_id: p} do
      message = String.duplicate("x", 490) <> @db_url <> " tail"

      assert {:ok, _} = Commands.turn_fail(CommandGateway, p, "t1", 1, :agent_failed, message, 3)

      assert {:ok, %{last_error: %{message: recorded}}} = ProjectionStore.coordinator_status(p)
      # redacted first (10 characters stand for the 45), then cut to 500: no half of it remains
      assert recorded == String.duplicate("x", 490) <> "[REDACTED]"
      refute stream_text(p) =~ "postgres://svc"
    end

    test "of a project whose environment is refused is recorded with the patterns alone, never raising" do
      id = refused_project!()

      capture_log(fn ->
        assert {:ok, nil} =
                 Commands.turn_fail(
                   RecordingGateway,
                   id,
                   "t1",
                   1,
                   :agent_failed,
                   "oops password=hunter2",
                   3
                 )
      end)

      assert_received {:dispatched, %{payload: %{message: "oops password=[REDACTED]"}}}
    end
  end

  describe "a coordinator action record" do
    setup %{project_id: p} do
      assert {:ok, _} = Commands.turn_start(CommandGateway, p, "t1", 1, ["m1"])
      :ok
    end

    test "never reaches the event log or the read model with a stored value in its params, reason or result",
         %{project_id: p} do
      attrs = %{
        action_id: "a1",
        kind: "remember",
        status: "executed",
        params: %{
          "name" => "db",
          "content" => "connect to #{@db_url}",
          "tags" => ["x", "tok #{@api_token}"]
        },
        reason: "refused: #{@api_token}",
        result_ref: %{"threads" => [%{"title" => "fix #{@db_url}"}]}
      }

      assert {:ok, _} = Commands.record_action(CommandGateway, p, "t1", attrs)

      refute stream_text(p) =~ @db_url
      refute stream_text(p) =~ @api_token

      assert [recorded] = Map.values(conversation(p).actions)

      assert recorded.params == %{
               "name" => "db",
               "content" => "connect to [REDACTED]",
               "tags" => ["x", "tok [REDACTED]"]
             }

      assert recorded.reason == "refused: [REDACTED]"
      assert recorded.result_ref == %{"threads" => [%{"title" => "fix [REDACTED]"}]}
    end

    test "does not rewrite a stored value shorter than the floor", %{project_id: p} do
      seven = String.duplicate("a", ProjectEnvironment.min_stored_secret_chars() - 1)
      assert {:ok, _} = ProjectSecrets.set(p, "SEVEN_CHR", seven, "test")
      assert {:ok, _} = ProjectSecrets.set(p, "RETRY_COUNT", "1", "test")

      attrs = %{
        action_id: "a2",
        kind: "answer",
        status: "executed",
        params: %{"text" => "retry 1 time, #{seven} stays, #{@db_url} goes"},
        reason: nil,
        result_ref: nil
      }

      assert {:ok, _} = Commands.record_action(CommandGateway, p, "t1", attrs)

      assert %{params: %{"text" => recorded}} = conversation(p).actions["a2"]
      assert recorded == "retry 1 time, #{seven} stays, [REDACTED] goes"
    end

    test "of a project with no resolvable list is recorded with the patterns alone, never raising" do
      ghost = "co-redact-ghost-#{System.unique_integer([:positive])}"
      refused = refused_project!()

      for project <- [ghost, refused] do
        attrs = %{
          action_id: "a3",
          kind: "answer",
          status: "executed",
          params: %{"text" => "password=hunter2 and #{@db_url}"},
          reason: nil,
          result_ref: nil
        }

        capture_log(fn ->
          assert {:ok, nil} = Commands.record_action(RecordingGateway, project, "t9", attrs)
        end)

        # no list for this project: its own values are not known, the patterns still apply
        assert_received {:dispatched,
                         %{payload: %{params: %{"text" => "password=[REDACTED] and " <> kept}}}}

        assert kept == @db_url
      end
    end
  end
end
