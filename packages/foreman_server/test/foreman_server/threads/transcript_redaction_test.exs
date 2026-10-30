defmodule ForemanServer.Threads.TranscriptRedactionTest do
  @moduledoc """
  `Threads.Transcript` redacts with the thread's project's secret VALUES (every stored value
  whatever its name, `ProjectEnvironment.secrets/1`) as well as the name patterns, at read
  time, so an old event and an agent's echo are covered. The list is read once per page.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.SecretStore
  alias ForemanServer.TestSupport.{MeckScope, SecretStoreDir}
  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Transcript.Page

  @moduletag :tmp_dir

  # `DB_URL` looks like no secret by name; the store holds it all the same.
  @db_url "postgres://svc:hunter2pw@db.internal:5432/app"
  @seven "abcdefg"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:meck)
    MeckScope.new_once!([SecretStore])
  end

  setup %{tmp_dir: tmp} do
    MeckScope.restore_on_exit!([SecretStore])
    SecretStoreDir.use_tmp_dir!(tmp)
    project_id = uid("tr-secret-project")
    SecretStoreDir.put!(project_id, "DB_URL", @db_url)
    SecretStoreDir.put!(project_id, "SEVEN_CHR", @seven)
    {:ok, project_id: project_id}
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp iso(offset_ms),
    do:
      DateTime.utc_now()
      |> DateTime.add(offset_ms, :millisecond)
      |> DateTime.to_iso8601()

  defp log_line(type, run_id, seq, line, at),
    do: %{
      event_type: type,
      payload: %{run_id: run_id, worker_id: "w1", sequence: seq, line: line, timestamp: at}
    }

  defp append_run_events(run_id, events) do
    stream = "run:#{run_id}"

    :ok =
      Store.append_to_stream(
        stream,
        0,
        Enum.map(events, fn {type, data} ->
          %EventData{event_type: type, data: Map.put(data, :run_id, run_id), metadata: %{}}
        end)
      )

    on_exit(fn -> Store.delete_stream(stream, :any_version, :hard) end)
  end

  defp seed_run(project_id, lines \\ 1) do
    run_id = uid("tr-secret-run")

    append_run_events(run_id, [
      {"RunSteerQueued", %{message_id: uid("m"), text: "use #{@db_url} (#{@seven})"}},
      {"RunPaused", %{reason: "waiting for #{@db_url}"}}
    ])

    :ok =
      ProjectionStore.apply_events(
        [
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: project_id}},
          log_line("WorkerStdout", run_id, 1, "connecting to #{@db_url}", iso(-20_000)),
          log_line("WorkerStderr", run_id, 2, "failed: #{@db_url} #{@seven}", iso(-19_900))
        ] ++
          for(
            n <- 3..(lines + 2)//1,
            do: log_line("WorkerStdout", run_id, n, "line #{n} #{@db_url}", iso(-19_000 + n))
          ) ++
          [
            %{
              event_type: "ReviewRecorded",
              payload: %{
                subject_kind: "run",
                subject_id: run_id,
                verdict: "partial",
                summary: "see #{@db_url}",
                at: "2026-01-01T00:00:00Z"
              }
            },
            %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: project_id}}
          ]
      )

    run_id
  end

  defp texts(thread_id) do
    {:ok, %Page{turns: turns}} = Transcript.page(thread_id, limit: 1000)
    Enum.map(turns, & &1.text)
  end

  test "no turn of a workflow thread carries a stored project value; a value under the floor is not rewritten",
       %{project_id: project_id} do
    run_id = seed_run(project_id)

    texts = texts("run:" <> run_id)

    assert length(texts) >= 5
    for text <- texts, do: refute(text =~ @db_url, "a turn carries the stored value: #{text}")

    assert "connecting to [REDACTED]" in texts
    assert "failed: [REDACTED] #{@seven}" in texts
    assert "use [REDACTED] (#{@seven})" in texts
    assert "Run paused: waiting for [REDACTED]" in texts
    assert "partial: see [REDACTED]" in texts
  end

  test "no turn of a jobsite thread carries a stored project value", %{project_id: project_id} do
    jobsite_id = uid("tr-secret-job")

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{
            jobsite_id: jobsite_id,
            project_id: project_id,
            repo_path: "/r",
            strategy: "worktree"
          }
        },
        %{
          event_type: "JobsiteIterationCompleted",
          payload: %{
            jobsite_id: jobsite_id,
            index: 1,
            status: "completed",
            text: "wrote the config for #{@db_url}"
          }
        },
        %{
          event_type: "JobsiteIterationFailed",
          payload: %{
            jobsite_id: jobsite_id,
            index: 2,
            code: "boom",
            message: "could not reach #{@db_url}"
          }
        },
        %{
          event_type: "JobsiteOutputCaptured",
          payload: %{jobsite_id: jobsite_id, tag: "out", value: %{"url" => @db_url}}
        },
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "jobsite",
            subject_id: jobsite_id,
            verdict: "partial",
            summary: "see #{@db_url}",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])

    texts = texts("jobsite:" <> jobsite_id)

    assert length(texts) == 4
    for text <- texts, do: refute(text =~ @db_url, "a turn carries the stored value: #{text}")
    assert "wrote the config for [REDACTED]" in texts
    assert "Iteration 2 failed: could not reach [REDACTED]" in texts
    assert "partial: see [REDACTED]" in texts
    assert Enum.any?(texts, &(&1 =~ "[REDACTED]" and &1 =~ "url"))
  end

  test "the project's list is read once per page, not once per entry", %{project_id: project_id} do
    run_id = seed_run(project_id, 30)

    assert {:ok, %Page{turns: [_ | _]}} = Transcript.page("run:" <> run_id, limit: 1000)

    assert :meck.num_calls(SecretStore, :pairs, [project_id]) == 1
  end

  test "a run with no project, and one whose environment is refused, are redacted by the patterns alone" do
    run_id = uid("tr-no-project")

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: nil}},
        log_line("WorkerStdout", run_id, 1, "password=hunter2 and #{@db_url}", iso(-5_000)),
        %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: nil}}
      ])

    assert ["password=[REDACTED] and " <> kept] = texts("run:" <> run_id)
    assert kept == @db_url

    refused = uid("tr-refused-project")

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: refused,
            path: "/tmp/#{refused}",
            config: %{env: %{"FOREMAN_RUN_ID" => "sneaky"}}
          }
        }
      ])

    refused_run = uid("tr-refused-run")

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: refused_run, project_id: refused}},
        log_line("WorkerStdout", refused_run, 1, "password=hunter2", iso(-5_000)),
        %{event_type: "RunCompleted", payload: %{run_id: refused_run, project_id: refused}}
      ])

    log = capture_log(fn -> assert ["password=[REDACTED]"] = texts("run:" <> refused_run) end)
    assert log =~ "reserved_project_env_keys"
  end
end
