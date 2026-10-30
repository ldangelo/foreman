defmodule ForemanServer.PrFixNoteRedactionTest do
  @moduledoc """
  The operator's note on a PR fix (`run.pr.fix_ci | address_comments | resolve_conflicts`) is
  free text that may paste a secret. The aggregate is pure and cannot read the secret store,
  so `CommandGateway` redacts the note by the project's secret VALUES before the command
  reaches it: the persisted `PrFixRequested` never carries a stored secret, whatever the
  secret's name (the operator question surface does the same).
  """
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.MCP.Tools
  alias ForemanServer.TestSupport.{PrWatchSupport, SecretStoreDir}

  @secret "postgres://svc:hunter2pw@db.internal:5432/app"
  @kinds [
    {"run.pr.fix_ci", "ci"},
    {"run.pr.address_comments", "comments"},
    {"run.pr.resolve_conflicts", "conflicts"}
  ]

  # A watched, open PR on a run whose project stores `DB_URL` (a name that looks like no secret).
  defp watched_run!(tmp_dir) do
    SecretStoreDir.use_tmp_dir!(tmp_dir)

    %{run_id: run_id, project_id: project_id, pr_url: pr_url} =
      PrWatchSupport.start_run!(complete: true)

    SecretStoreDir.put!(project_id, "DB_URL", @secret)

    PrWatchSupport.dispatch!(%{
      type: "run.pr.checks",
      command_id: "checks:#{run_id}",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        pr_url: pr_url,
        head_sha: "sha-1",
        digest: "d1",
        checks_state: "failing",
        pr_status: "open",
        observation_seq: 1
      }
    })

    %{run_id: run_id, pr_url: pr_url}
  end

  defp fix_requested(run_id) do
    run_id
    |> PrWatchSupport.run_events()
    |> Enum.filter(&(&1.event_type == "PrFixRequested"))
  end

  defp stored(event), do: inspect(event.data, limit: :infinity, printable_limit: :infinity)

  describe "the operator command path" do
    @describetag :tmp_dir

    for {type, kind} <- @kinds do
      test "#{type} stores the note with the project's secret values redacted", %{tmp_dir: tmp} do
        %{run_id: run_id, pr_url: pr_url} = watched_run!(tmp)

        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   type: unquote(type),
                   command_id: "fix:#{run_id}",
                   aggregate_id: "run:#{run_id}",
                   payload: %{
                     run_id: run_id,
                     pr_url: pr_url,
                     note: "retry with #{@secret} as the database"
                   }
                 })

        assert [event] = fix_requested(run_id)
        assert event.data.kind == unquote(kind)
        refute stored(event) =~ @secret
        refute stored(event) =~ "hunter2pw"
        assert event.data.note == "retry with [REDACTED] as the database"
      end
    end

    test "a note-less command stores no note", %{tmp_dir: tmp} do
      %{run_id: run_id, pr_url: pr_url} = watched_run!(tmp)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 type: "run.pr.fix_ci",
                 command_id: "fix:#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 payload: %{run_id: run_id, pr_url: pr_url}
               })

      assert [event] = fix_requested(run_id)
      assert event.data.note == nil
    end

    # The real operator path is string-keyed JSON (`POST /api/commands`, the CLI's `--note`):
    # the gateway atomises the payload keys before the redaction clause runs. Pin THAT path.
    test "a string-keyed payload (the HTTP/CLI shape) is redacted too", %{tmp_dir: tmp} do
      %{run_id: run_id, pr_url: pr_url} = watched_run!(tmp)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 type: "run.pr.fix_ci",
                 command_id: "fix:#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 payload: %{
                   "run_id" => run_id,
                   "pr_url" => pr_url,
                   "note" => "retry with #{@secret} as the database"
                 }
               })

      assert [event] = fix_requested(run_id)
      refute stored(event) =~ "hunter2pw"
      assert event.data.note == "retry with [REDACTED] as the database"
    end

    test "a note on an unknown run is refused, not stored unredacted" do
      assert {:error, {:not_found, :run, "run-no-such-run"}} =
               CommandGateway.dispatch_operator(%{
                 type: "run.pr.fix_ci",
                 command_id: "fix:run-no-such-run",
                 aggregate_id: "run:run-no-such-run",
                 payload: %{
                   run_id: "run-no-such-run",
                   pr_url: "https://github.com/acme/repo/pull/1",
                   note: "x"
                 }
               })
    end
  end

  describe "the MCP foreman_pr_fix tool" do
    @describetag :tmp_dir

    setup do
      previous = Application.get_env(:foreman_server, :mcp, [])

      Application.put_env(
        :foreman_server,
        :mcp,
        Keyword.put(previous, :allow_workflow_writes, true)
      )

      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous) end)
    end

    test "stores the note with the project's secret values redacted", %{tmp_dir: tmp} do
      %{run_id: run_id, pr_url: pr_url} = watched_run!(tmp)

      assert {:ok, %{command: "run.pr.fix_ci"}} =
               Tools.call_tool("foreman_pr_fix", %{
                 run_id: run_id,
                 kind: "ci",
                 pr_url: pr_url,
                 note: "use #{@secret}"
               })

      assert [event] = fix_requested(run_id)
      refute stored(event) =~ "hunter2pw"
      assert event.data.note == "use [REDACTED]"
    end
  end
end
