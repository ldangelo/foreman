defmodule ForemanServer.ProjectSecretsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, ProjectSecrets}
  alias ForemanServer.ProjectEnvironment
  alias ForemanServer.SecretStore.Error

  @moduletag :tmp_dir
  @value "zq-very-secret-value-4711"

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:foreman_server, :secret_store)
    Application.put_env(:foreman_server, :secret_store, Keyword.put(previous, :dir, tmp_dir))
    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, previous) end)

    project_id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}", config: %{}},
        aggregate_id: "project:#{project_id}"
      })

    %{project_id: project_id}
  end

  test "set records name+version only; versions increase; unset removes the name", %{
    project_id: id
  } do
    assert {:ok, %{name: "API_TOKEN", version: 1}} =
             ProjectSecrets.set(id, "API_TOKEN", @value, "t")

    assert {:ok, %{version: 2}} = ProjectSecrets.set(id, "API_TOKEN", @value <> "2", "t")

    assert [%{name: "API_TOKEN", version: 2, updated_at: at}] =
             ProjectionStore.project_secret_names(id)

    assert is_binary(at)

    assert {:ok, %{name: "API_TOKEN"}} = ProjectSecrets.unset(id, "API_TOKEN", "t")
    assert [] = ProjectionStore.project_secret_names(id)
    assert {:error, %Error{code: :secret_not_found}} = ProjectSecrets.unset(id, "API_TOKEN")

    # A re-set after unset continues the version sequence.
    assert {:ok, %{version: 4}} = ProjectSecrets.set(id, "API_TOKEN", @value, "t")
  end

  test "an unknown project cannot receive a secret and nothing is written" do
    assert {:error, {:not_found, :project, "ghost"}} =
             ProjectSecrets.set("ghost", "API_TOKEN", @value)

    assert {:ok, []} = ForemanServer.SecretStore.names("ghost")
  end

  test "leakage audit: the value appears in no event, projection, log or return value", %{
    project_id: id
  } do
    log =
      capture_log(fn ->
        assert {:ok, result} = ProjectSecrets.set(id, "API_TOKEN", @value, "t")
        refute inspect(result) =~ @value

        assert {:ok, %{env: %{"API_TOKEN" => @value}, secrets: secrets}} =
                 ProjectEnvironment.resolve(id)

        assert @value in secrets
      end)

    refute log =~ @value

    {:ok, events} = EventStore.read_stream_forward("project_secret:#{id}", 0, 100)
    assert [%{event_type: "ProjectSecretSet"}] = events
    refute inspect(events) =~ @value

    state = :sys.get_state(ProjectionStore)
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @value
  end

  test "resolve merges secrets over vars and feeds the redaction list; secret wins on name clash",
       %{
         project_id: id
       } do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: %{project_id: id, vars: %{"REGION" => "us", "DEPLOY_KEY_NAME" => "from-vars"}},
        aggregate_id: "project:#{id}"
      })

    {:ok, _} = ProjectSecrets.set(id, "DEPLOY_KEY_NAME", @value, "t")

    assert {:ok, %{env: env, secrets: secrets}} = ProjectEnvironment.resolve(id)
    assert env == %{"REGION" => "us", "DEPLOY_KEY_NAME" => @value}
    assert secrets == [@value]
  end

  test "an unavailable secret store degrades to vars-only with a warning that has no value", %{
    project_id: id,
    tmp_dir: tmp_dir
  } do
    {:ok, _} = ProjectSecrets.set(id, "API_TOKEN", @value, "t")
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "x")
    previous = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(previous, :dir, Path.join(blocker, "sub"))
    )

    log =
      capture_log(fn ->
        assert {:ok, %{env: %{}, secrets: []}} = ProjectEnvironment.resolve(id)
      end)

    assert log =~ "secret store unavailable"
    refute log =~ @value
  end

  test "secrets/1 is the redaction list: every stored value whatever its name, plus the values of secret-looking env vars, never a name" do
    id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{
          project_id: id,
          path: "/tmp/#{id}",
          config: %{env: %{"LEGACY_API_KEY" => "legacy-key-value", "REGION" => "us"}}
        },
        aggregate_id: "project:#{id}"
      })

    # `DB_URL` looks like no secret by name; the store holds it all the same
    {:ok, _} = ProjectSecrets.set(id, "DB_URL", @value, "t")

    assert Enum.sort(ProjectEnvironment.secrets(id)) == Enum.sort([@value, "legacy-key-value"])
    assert ProjectEnvironment.secrets("unknown-project-id-zzz") == []
  end

  test "secrets/1 leaves out short stored values whose names look like no secret; resolve/2 (log redaction) keeps them" do
    id = "project-#{Elixir.EventStore.UUID.uuid4()}"
    min = ProjectEnvironment.min_stored_secret_chars()

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{
          project_id: id,
          path: "/tmp/#{id}",
          config: %{env: %{"LEGACY_API_KEY" => "k"}}
        },
        aggregate_id: "project:#{id}"
      })

    short = String.duplicate("s", min - 1)
    exact = String.duplicate("e", min)
    {:ok, _} = ProjectSecrets.set(id, "RETRY_COUNT", "1", "t")
    {:ok, _} = ProjectSecrets.set(id, "SHORT_NAME", short, "t")
    {:ok, _} = ProjectSecrets.set(id, "EXACT_NAME", exact, "t")
    {:ok, _} = ProjectSecrets.set(id, "SHORT_TOKEN", "ab", "t")

    assert Enum.sort(ProjectEnvironment.secrets(id)) == Enum.sort([exact, "ab", "k"])

    assert {:ok, %{secrets: all}} = ProjectEnvironment.resolve(id)
    assert Enum.sort(all) == Enum.sort(["1", short, exact, "ab", "k"])
  end

  for {label, short_name, long_name} <- [
        {"shorter secret listed first", "A_SHORT_VALUE", "B_LONG_VALUE"},
        {"longer secret listed first", "B_SHORT_VALUE", "A_LONG_VALUE"}
      ] do
    test "a secret that is a substring of another never leaves a remainder of the longer one (#{label})" do
      id = "project-#{Elixir.EventStore.UUID.uuid4()}"
      short = "abcdefgh"
      long = "abcdefghIJKLMNOP"

      # a short named value (no length floor) inside a stored one, and a stored value under the floor
      named_short = "ab"
      named_long = "abXYZ-named-secret"

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{
            project_id: id,
            path: "/tmp/#{id}",
            config: %{env: %{"LEGACY_API_KEY" => named_short, "LEGACY_TOKEN" => named_long}}
          },
          aggregate_id: "project:#{id}"
        })

      {:ok, _} = ProjectSecrets.set(id, unquote(short_name), short, "t")
      {:ok, _} = ProjectSecrets.set(id, unquote(long_name), long, "t")

      text = "short=#{short} long=#{long} named=#{named_long} short-named=#{named_short}"
      expected = "short=[REDACTED] long=[REDACTED] named=[REDACTED] short-named=[REDACTED]"

      assert {:ok, list} = ProjectEnvironment.fetch_secrets(id)
      assert Enum.sort(list) == Enum.sort([short, long, named_short, named_long])
      assert ProjectEnvironment.secrets(id) == list

      assert {:ok, %{secrets: all}} = ProjectEnvironment.resolve(id)

      # Order-independent: the redactor orders the list itself, so any caller's list works.
      for secrets <- [list, Enum.reverse(list), Enum.sort(list), all, Enum.reverse(all)] do
        assert ForemanServer.Overwatch.WorkerLogPolicy.redact(text, secrets) == expected
      end

      assert ForemanServer.Coordinator.Redact.text(id, text) == expected
    end
  end

  test "secrets/1 raises for an environment resolve/2 refuses: a partial list is never returned" do
    id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: id,
            path: "/tmp/#{id}",
            config: %{env: %{"FOREMAN_RUN_ID" => "evil"}}
          }
        }
      ])

    assert_raise ArgumentError, ~r/environment is invalid.*FOREMAN_RUN_ID/, fn ->
      ProjectEnvironment.secrets(id)
    end
  end

  test "fetch_secrets/1 is secrets/1 as a typed result: the same list, or the refusal instead of a raise" do
    id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{
          project_id: id,
          path: "/tmp/#{id}",
          config: %{env: %{"LEGACY_API_KEY" => "legacy-key-value"}}
        },
        aggregate_id: "project:#{id}"
      })

    {:ok, _} = ProjectSecrets.set(id, "DB_URL", @value, "t")

    assert {:ok, list} = ProjectEnvironment.fetch_secrets(id)
    assert list == ProjectEnvironment.secrets(id)
    assert Enum.sort(list) == Enum.sort([@value, "legacy-key-value"])
    assert {:ok, []} = ProjectEnvironment.fetch_secrets("unknown-project-id-zzz")

    refused = "project-#{Elixir.EventStore.UUID.uuid4()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: refused,
            path: "/tmp/#{refused}",
            config: %{env: %{"FOREMAN_RUN_ID" => "evil"}}
          }
        }
      ])

    assert {:error, {:reserved_project_env_keys, ["FOREMAN_RUN_ID"]}} =
             ProjectEnvironment.fetch_secrets(refused)
  end
end
