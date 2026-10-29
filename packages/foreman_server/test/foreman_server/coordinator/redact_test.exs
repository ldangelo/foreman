defmodule ForemanServer.Coordinator.RedactTest do
  @moduledoc """
  Coordinator conversation text is redacted before it is persisted, with the project's ONE
  redaction list (`ProjectEnvironment.secrets/1`): every secret-store value whatever its name,
  plus the env values whose names look secret. A value stored as `DB_URL` looks like no secret by
  name, so name patterns alone let it into the transcript events.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Commands, Redact}
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, ProjectionStore, ProjectSecrets}

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
end
