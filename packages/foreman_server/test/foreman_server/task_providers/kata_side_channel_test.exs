defmodule ForemanServer.TaskProviders.KataSideChannelTest do
  @moduledoc """
  TRD-KATA-T041-TEST: REQ-017 (the adapter is silent about sensitive content in every outward
  channel) and REQ-015 (sensitive field classification), proved with sentinel values.

  Sentinel assignees, task bodies, a Kata field the Foreman issue has no place for, comments and
  stderr text go through every adapter callback, on its success path and on its error paths,
  against `KataRunnerMock` and against the real `SystemKataRunner` (a fake `kata` on `PATH`). A
  sentinel never reaches

    * the application log (AC-017-1),
    * standard output or standard error (AC-017-2),
    * the metadata or measurements of a telemetry event (AC-017-3), whose metadata keys also stay
      inside the allowlist the telemetry taxonomy declares for that event,
    * a `ProviderError`: its context holds exactly the seven allowlisted keys, for every error
      code the adapter can produce (AC-017-4, AC-015-1), or
    * an exception message, because an exception ends up in the crash log;

  while the domain record handed to the caller still carries the sensitive values (AC-017-5). A
  Kata field outside the Foreman issue contract is sensitive by default (AC-015-2) and is run
  through the same paths. The last describe is static: no Kata module can log, print or emit
  telemetry beyond what the taxonomy allows.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Mox

  alias ForemanServer.TaskProvider.{Comment, Issue}
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProvider.Telemetry
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ConcurrencyLimiter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemKataRunner

  @providers_root Path.expand("../../../lib/foreman_server/task_providers", __DIR__)
  @kata_sources [
    Path.join(@providers_root, "kata_adapter.ex"),
    Path.join(@providers_root, "kata_adapter/build_provider_error.ex"),
    Path.join(@providers_root, "kata_runner.ex"),
    Path.join(@providers_root, "system_kata_runner.ex")
  ]

  @cwd "/projects/kata-side-channel"
  @config %{cwd: @cwd}
  @spawned_event [:foreman_server, :task_provider, :kata, :subprocess, :spawned]

  # Sensitive: the assignee (Kata `owner`), the body (Kata `body`) and a Kata field the Foreman
  # issue has no place for. The rest is task content and diagnostics that must stay quiet too.
  @assignee "SENTINEL-ASSIGNEE-4f1c9a"
  @other_owner "SENTINEL-OTHER-OWNER-77de02"
  @body "SENTINEL-BODY-b83e51"
  @unmapped "SENTINEL-UNMAPPED-6a90d3"
  @comment "SENTINEL-COMMENT-19ab7e"
  @stderr_text "SENTINEL-STDERR-c51f08"
  @sentinels [@assignee, @other_owner, @body, @unmapped, @comment, @stderr_text]

  # AC-017-4: the closed key set of every `ProviderError.context` this provider returns.
  @allowlisted_keys [
    :command,
    :exit_code,
    :id,
    :missing_fields,
    :redacted_fields,
    :sanitized?,
    :stderr_byte_count
  ]

  @mock_scenarios ~w(
    list_ready get claim complete fail reopen annotate create
    list_ready_schema_error get_schema_error claim_without_owner parse_error
    fail_owned_by_other fail_unowned fail_unassign_race complete_without_evidence runner_failure
  )a

  @raising_scenarios ~w(
    fail_without_run_id annotate_with_a_map_body reopen_with_a_list_comment get_with_a_tuple_ref
    complete_with_a_list_commit_sha complete_with_wrong_evidence malformed_argv_to_the_runner
  )a

  @real_scenarios ~w(
    real_list_ready real_claim_refused real_exit_1_with_output real_unparseable real_fail
    real_runner_error
  )a

  # Every `ProviderError` code the adapter, its factory and the runner can produce.
  @error_codes ~w(
    VALIDATION_FAILED INVALID_TASK_ID INVALID_TRANSITION_COMMENT INVALID_PRIORITY
    DEPENDENCY_CYCLE INVALID_TITLE INVALID_ISSUE_TYPE CLAIMED_BY_OTHER ISSUE_NOT_FOUND
    BR_TIMEOUT_SUBPROCESS BR_TIMEOUT_QUEUE BR_ERROR_ENVELOPE BR_PARSE_ERROR
    BR_CONTRACT_MISMATCH SCHEMA_VALIDATION_FAILED WORKSPACE_NOT_FOUND
  )

  # `IO` functions that print; `IO.iodata_to_binary/1` and friends are not an outward channel.
  @io_output [:puts, :write, :inspect, :warn, :binwrite]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "kata_side_channel_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(temp_dir, "workspace")
    artifact = Path.join(temp_dir, "phase-1.md")
    File.mkdir_p!(workspace)
    File.write!(artifact, "# phase report\n")

    {:ok, _} = Application.ensure_all_started(:telemetry)

    original_path = System.get_env("PATH") || ""
    previous_runner = Application.fetch_env!(:foreman_server, :kata_runner)
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      Application.put_env(:foreman_server, :kata_runner, previous_runner)
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, workspace: workspace, artifact: artifact}
  end

  ## AC-017-1, AC-017-2, AC-017-3, AC-017-5 through KataRunnerMock

  describe "AC-017-1, AC-017-2, AC-017-3, AC-017-5: sentinels through the adapter" do
    for name <- @mock_scenarios do
      test "#{name} is silent in the log, on stdout and stderr and in telemetry", ctx do
        run_scenario(unquote(name), ctx)
      end
    end
  end

  describe "AC-017-1: an exception raised for a bad argument never carries a sentinel" do
    for name <- @raising_scenarios do
      test "#{name}", ctx do
        run_scenario(unquote(name), ctx)
      end
    end
  end

  describe "AC-017-1, AC-017-2, AC-017-3, AC-017-5: sentinels through the real SystemKataRunner" do
    for name <- @real_scenarios do
      test "#{name} (stderr is discarded, only its size survives)", ctx do
        run_scenario(unquote(name), ctx)
      end
    end
  end

  ## AC-017-4, AC-015-1: the closed context

  describe "AC-017-4, AC-015-1: the context of every error code the adapter can produce" do
    test "the trigger table covers every code the adapter, its factory and the runner name" do
      assert scanned_error_codes() -- @error_codes == [],
             "an error code has no trigger in this test: #{inspect(scanned_error_codes() -- @error_codes)}"

      assert @error_codes -- scanned_error_codes() == [],
             "the table names a code the Kata modules no longer produce"
    end

    for code <- @error_codes do
      test "#{code}: exactly the seven allowlisted keys, sanitized, redacted, no sentinel", ctx do
        %{call: call, opts: opts, after: cleanup} = error_trigger(unquote(code), ctx)
        captured = capture_side_channels(call)
        cleanup.()

        error = assert_error(captured.result, unquote(code), opts)
        assert_silent(captured, unquote(code))

        # `missing_fields` names absent fields only on schema-validation errors.
        if unquote(code) == "SCHEMA_VALIDATION_FAILED" do
          assert error.context.missing_fields != []
        else
          assert error.context.missing_fields == []
        end
      end
    end

    test "redacted_fields is the same literal for every code, and sanitized? is always true" do
      for code <- @error_codes do
        error =
          code
          |> ProviderErrorInput.from_local("message", nil, false)
          |> BuildProviderError.build_provider_error(nil, 0)

        assert error.context.redacted_fields == ["assignee", "description"], code
        assert error.context.sanitized? == true, code
      end
    end
  end

  ## AC-015-2: sensitive by default

  describe "AC-015-2: a Kata field the Foreman issue has no place for is sensitive by default" do
    test "it reaches the caller only under metadata, and no other channel" do
      issue = sensitive_issue(%{"future_secret" => @unmapped})

      stub_kata(%{
        "ready" => ok(%{"kata_api_version" => 1, "issues" => [issue]}),
        "show" => ok(show_payload(issue))
      })

      captured =
        capture_side_channels(fn ->
          {KataAdapter.list_ready(@config, []), KataAdapter.get("zq27", @config)}
        end)

      assert {:returned, {{:ok, [%Issue{} = listed]}, {:ok, %Issue{} = shown}}} = captured.result

      for %Issue{} = record <- [listed, shown] do
        assert record.metadata["future_secret"] == @unmapped

        # Nothing but `metadata`, `assignee` and `description` holds a sentinel.
        elsewhere = record |> Map.from_struct() |> Map.drop([:metadata, :assignee, :description])
        refute inspect(elsewhere) =~ @unmapped
        refute inspect(elsewhere) =~ @assignee
        refute inspect(elsewhere) =~ @body
      end

      assert_silent(captured, "unmapped field")
    end
  end

  ## Static: no Kata module can speak

  describe "static: no Kata module logs, prints, inspects or emits outside the taxonomy (REQ-017)" do
    test "the Kata modules contain no outward channel" do
      offenders =
        for file <- @kata_sources, site <- outward_channels(File.read!(file)) do
          {Path.relative_to(file, @providers_root), site.line, site.what}
        end

      assert offenders == [],
             "a Kata module can leak through an outward channel:\n" <>
               Enum.map_join(offenders, "\n", fn {file, line, what} ->
                 "  - #{file}:#{line} (#{what})"
               end)
    end

    test "the scanner flags every way a Kata module could speak, and nothing quiet" do
      speaking = [
        ~S|Logger.debug("x")|,
        ~S|require Logger|,
        ~S|IO.puts("x")|,
        ~S|IO.inspect(x)|,
        ~S|IO.warn("x")|,
        ~S|:logger.info("x")|,
        ~S|:io.format("x")|,
        ~S|:telemetry.execute([:a], %{}, %{})|,
        ~S|inspect(x)|,
        ~S|Kernel.inspect(x)|,
        ~S|dbg(x)|,
        ~S|raise ArgumentError, "got #{x}"|
      ]

      for expression <- speaking do
        source = "defmodule Fixture do\n  def run(x) do\n    #{expression}\n  end\nend\n"

        assert [%{line: 3}] = outward_channels(source), "scanner missed: #{expression}"
      end

      quiet = """
      defmodule Fixture do
        def run(chunks) do
          if chunks == [], do: raise(ArgumentError, "expected chunks")
          IO.iodata_to_binary(chunks)
        end
      end
      """

      assert outward_channels(quiet) == []
    end

    test "every telemetry call in the Kata modules carries only keys the taxonomy allows" do
      emits = for file <- @kata_sources, emit <- telemetry_emits(File.read!(file)), do: emit

      # The runner announces the OS pid of the child it spawned, and nothing else.
      assert [%{event: @spawned_event, keys: [:os_pid]}] = emits

      for %{event: event, keys: keys} <- emits do
        allowed = Map.fetch!(Telemetry.taxonomy(), event).metadata_keys

        assert is_list(keys) and keys -- allowed == [],
               "#{inspect(event)} emits keys outside its allowlist: #{inspect(keys)}"
      end
    end

    test "the telemetry scan reads the event and keys, and flags a dynamic metadata map" do
      source = """
      defmodule Fixture do
        alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
        @event [:foreman_server, :task_provider, :kata, :subprocess, :spawned]

        def literal(pid), do: TaskProviderTelemetry.emit(@event, %{}, %{os_pid: pid, argv: []})
        def dynamic(metadata), do: TaskProviderTelemetry.emit(@event, %{}, metadata)
      end
      """

      assert [
               %{event: @spawned_event, keys: [:os_pid, :argv]},
               %{event: @spawned_event, keys: :dynamic}
             ] = telemetry_emits(source)
    end
  end

  ## Scenarios

  # Every scenario sets up its runner, and returns the call to capture and the check to apply to
  # its outcome. `emits:` lists telemetry events the call must have produced, so the telemetry
  # assertions are never vacuous.
  defp run_scenario(name, ctx) do
    scenario = scenario(name, ctx)
    captured = capture_side_channels(scenario.call)
    commands = commands_run()

    scenario.check.(captured.result, commands)
    assert_silent(captured, name)

    for event <- Map.get(scenario, :emits, []) do
      assert Enum.any?(captured.telemetry, &(&1.event == event)),
             "#{name} never emitted #{inspect(event)}"
    end

    captured
  end

  # --- success paths: the sentinels are in the payload and the argv, and in the returned record

  defp scenario(:list_ready, _ctx) do
    stub_kata(%{"ready" => ok(%{"kata_api_version" => 1, "issues" => [sensitive_issue()]})})

    %{
      call: fn -> KataAdapter.list_ready(@config, []) end,
      check: fn result, _commands ->
        assert {:returned, {:ok, [%Issue{} = issue]}} = result
        assert_sensitive_record(issue)
      end
    }
  end

  defp scenario(:get, _ctx) do
    stub_kata(%{"show" => ok(show_payload(sensitive_issue()))})

    %{
      call: fn -> KataAdapter.get("zq27", @config) end,
      check: fn result, _commands ->
        assert {:returned, {:ok, %Issue{} = issue}} = result
        assert_sensitive_record(issue)
      end
    }
  end

  # The claim token is a sentinel too: it is ignored, and must not be echoed.
  defp scenario(:claim, _ctx) do
    stub_kata(%{"claim" => ok(mutation(sensitive_issue(), "issue.assigned"))})

    %{
      call: fn -> KataAdapter.claim("zq27", @assignee, @config) end,
      check: fn result, _commands ->
        assert {:returned, {:ok, %Issue{} = issue}} = result
        assert_sensitive_record(issue)
      end
    }
  end

  defp scenario(:complete, %{artifact: artifact}) do
    stub_kata(%{
      "close" => ok(mutation(sensitive_issue(%{"status" => "closed"}), "issue.closed"))
    })

    token = %{
      run_id: "run-1",
      artifact_path: artifact,
      transition_comment: "Completed the task; verification notes: " <> @comment,
      evidence: ["pr:https://example.test/" <> @comment]
    }

    %{
      call: fn -> KataAdapter.complete("zq27", token, @config) end,
      check: fn result, commands ->
        assert {:returned, {:ok, :terminal}} = result
        assert_runner_received(commands, @comment)
      end
    }
  end

  defp scenario(:fail, _ctx) do
    stub_kata(%{
      "status" => ok(status(@assignee)),
      "reopen" => ok(%{"kata_api_version" => 1, "changed" => true}),
      "comment" => ok(%{"kata_api_version" => 1, "changed" => true}),
      "unassign" => ok(unassigned())
    })

    token = %{
      run_id: "run-1",
      artifact_path: nil,
      reason: "Phase develop failed: " <> @comment,
      transition_comment: "foreman-run:run-1:"
    }

    %{
      call: fn -> KataAdapter.fail("zq27", token, @config) end,
      check: fn result, commands ->
        assert {:returned, {:ok, :reopened}} = result
        # The failure comment and `--expect-owner <actor>` carry sentinels to the runner.
        assert_runner_received(commands, @comment)
        assert_runner_received(commands, @assignee)
      end
    }
  end

  # An unowned issue still gets the reopen and the comment, but no unassign.
  defp scenario(:fail_unowned, _ctx) do
    stub_kata(%{
      "status" => ok(status(nil)),
      "reopen" => ok(%{"kata_api_version" => 1, "changed" => true}),
      "comment" => ok(%{"kata_api_version" => 1, "changed" => true})
    })

    %{
      call: fn -> KataAdapter.fail("zq27", failure_token(), @config) end,
      check: fn result, commands ->
        assert {:returned, {:ok, :reopened}} = result
        assert_runner_received(commands, @comment)
        refute Enum.any?(commands, &match?(["unassign" | _], &1))
      end
    }
  end

  defp scenario(:reopen, _ctx) do
    stub_kata(%{"reopen" => ok(%{"kata_api_version" => 1, "changed" => true})})

    %{
      call: fn -> KataAdapter.reopen("zq27", "Reopened: " <> @comment, @config) end,
      check: fn result, commands ->
        assert {:returned, :ok} = result
        assert_runner_received(commands, @comment)
      end
    }
  end

  defp scenario(:annotate, _ctx) do
    stub_kata(%{"comment" => ok(%{"kata_api_version" => 1, "changed" => true})})

    %{
      call: fn -> KataAdapter.annotate("zq27", @comment <> " " <> @body, @config) end,
      check: fn result, commands ->
        assert {:returned, {:ok, %Comment{provider_issue_id: "zq27"}}} = result
        assert_runner_received(commands, @comment)
        assert_runner_received(commands, @body)
      end
    }
  end

  defp scenario(:create, ctx) do
    project_id = register_kata_project!(ctx)
    stub_kata(%{"create" => ok(mutation(sensitive_issue(), "issue.created"))})

    attrs = %{
      task_id: "tsk-1",
      command_id: "cmd-1",
      title: "A task whose owner and body are sentinels",
      description: @body,
      labels: ["triage"]
    }

    %{
      call: fn -> KataAdapter.create(project_id, attrs) end,
      check: fn result, commands ->
        assert {:returned, {:ok, %Issue{} = issue}} = result
        assert_sensitive_record(issue)
        assert_runner_received(commands, @body)
      end
    }
  end

  # --- error paths: the sentinels are in the payload, and the error carries none of them

  defp scenario(:list_ready_schema_error, _ctx) do
    invalid =
      sensitive_issue(%{
        "short_id" => "",
        "status" => 5,
        "owner" => %{"name" => @assignee},
        "body" => [@body]
      })

    stub_kata(%{"ready" => ok(%{"kata_api_version" => 1, "issues" => [invalid]})})

    %{
      call: fn -> KataAdapter.list_ready(@config, []) end,
      check: fn result, _commands ->
        # Names of the fields, never their values.
        assert_error(result, "SCHEMA_VALIDATION_FAILED",
          missing_fields: ["short_id", "status", "owner", "body"]
        )
      end
    }
  end

  defp scenario(:get_schema_error, _ctx) do
    stub_kata(%{"show" => ok(show_payload(Map.delete(sensitive_issue(), "title")))})

    %{
      call: fn -> KataAdapter.get("zq27", @config) end,
      check: fn result, _commands ->
        assert_error(result, "SCHEMA_VALIDATION_FAILED", missing_fields: ["title"])
      end
    }
  end

  defp scenario(:claim_without_owner, _ctx) do
    stub_kata(%{
      "claim" => ok(mutation(Map.delete(sensitive_issue(), "owner"), "issue.assigned"))
    })

    %{
      call: fn -> KataAdapter.claim("zq27", nil, @config) end,
      check: fn result, _commands ->
        assert_error(result, "SCHEMA_VALIDATION_FAILED", missing_fields: ["owner"])
      end
    }
  end

  defp scenario(:parse_error, _ctx) do
    stub_kata(%{"ready" => {:ok, "this is not json: " <> @body <> " " <> @assignee}})

    %{
      call: fn -> KataAdapter.list_ready(@config, []) end,
      check: fn result, _commands -> assert_error(result, "BR_PARSE_ERROR") end
    }
  end

  # The owner is a sentinel: nothing is written, and the owner is never named.
  defp scenario(:fail_owned_by_other, _ctx) do
    stub_kata(%{"status" => ok(status(@other_owner))})

    %{
      call: fn -> KataAdapter.fail("zq27", failure_token(), @config) end,
      check: fn result, commands ->
        assert_error(result, "CLAIMED_BY_OTHER")
        assert commands == [["status", "zq27", "--json"]]
      end
    }
  end

  defp scenario(:fail_unassign_race, _ctx) do
    stub_kata(%{
      "status" => ok(status(@assignee)),
      "reopen" => ok(%{"kata_api_version" => 1, "changed" => false}),
      "comment" => ok(%{"kata_api_version" => 1, "changed" => true}),
      "unassign" => runner_exit(5, 154)
    })

    %{
      call: fn -> KataAdapter.fail("zq27", failure_token(), @config) end,
      check: fn result, _commands ->
        assert_error(result, "CLAIMED_BY_OTHER", exit_code: 5, stderr_byte_count: 154)
      end
    }
  end

  # No sha, no evidence and an artifact that was never written: the message is a sentinel and
  # nothing runs.
  defp scenario(:complete_without_evidence, %{temp_dir: temp_dir}) do
    stub_kata(%{})

    token = %{
      run_id: "run-1",
      artifact_path: Path.join(temp_dir, "never-written.md"),
      transition_comment: "Completed the task; verification notes: " <> @comment
    }

    %{
      call: fn -> KataAdapter.complete("zq27", token, @config) end,
      check: fn result, commands ->
        assert_error(result, "VALIDATION_FAILED")
        assert commands == []
      end
    }
  end

  defp scenario(:runner_failure, _ctx) do
    stub_kata(%{"claim" => runner_exit(1, 321)})

    %{
      call: fn -> KataAdapter.claim("zq27", @assignee, @config) end,
      check: fn result, _commands ->
        assert_error(result, "BR_ERROR_ENVELOPE", exit_code: 1, stderr_byte_count: 321)
      end
    }
  end

  # --- raises: a wrongly typed argument raises, and its message carries none of the argument

  defp scenario(:fail_without_run_id, _ctx) do
    stub_kata(%{})

    raising(fn ->
      KataAdapter.fail("zq27", %{reason: @comment, transition_comment: @comment}, @config)
    end)
  end

  defp scenario(:annotate_with_a_map_body, _ctx) do
    stub_kata(%{})
    raising(fn -> KataAdapter.annotate("zq27", %{body: @body, owner: @assignee}, @config) end)
  end

  defp scenario(:reopen_with_a_list_comment, _ctx) do
    stub_kata(%{})
    raising(fn -> KataAdapter.reopen("zq27", [@comment, @body], @config) end)
  end

  defp scenario(:get_with_a_tuple_ref, _ctx) do
    stub_kata(%{})
    raising(fn -> KataAdapter.get({@assignee, @body}, @config) end)
  end

  defp scenario(:complete_with_a_list_commit_sha, _ctx) do
    stub_kata(%{})

    raising(fn ->
      KataAdapter.complete("zq27", %{run_id: "run-1", commit_sha: [@comment]}, @config)
    end)
  end

  defp scenario(:complete_with_wrong_evidence, _ctx) do
    stub_kata(%{})

    raising(fn ->
      token = %{run_id: "run-1", commit_sha: "abc123", evidence: [%{note: @comment}]}
      KataAdapter.complete("zq27", token, @config)
    end)
  end

  # The runner is a public module too: its argv holds comments and bodies.
  defp scenario(:malformed_argv_to_the_runner, %{workspace: workspace}) do
    raising(fn ->
      SystemKataRunner.cmd(["comment", "zq27", "--body", @body, :not_a_binary], workspace)
    end)
  end

  # --- the real runner: a fake kata prints sentinels on stdout and stderr

  defp scenario(:real_list_ready, ctx) do
    use_real_runner!(ctx, %{
      "ready" => [
        stdout: Jason.encode!(%{"kata_api_version" => 1, "issues" => [sensitive_issue()]}),
        stderr: @stderr_text <> " " <> @other_owner
      ]
    })

    %{
      call: fn -> KataAdapter.list_ready(%{cwd: ctx.workspace}, []) end,
      check: fn result, _commands ->
        assert {:returned, {:ok, [%Issue{} = issue]}} = result
        assert_sensitive_record(issue)
      end,
      emits: [@spawned_event]
    }
  end

  defp scenario(:real_claim_refused, ctx) do
    stderr =
      Jason.encode!(%{
        "error" => %{
          "kind" => "conflict",
          "code" => "already_claimed",
          "message" => "issue is already assigned to " <> @other_owner,
          "exit_code" => 5,
          "data" => %{"current_owner" => @other_owner, "note" => @stderr_text}
        }
      })

    use_real_runner!(ctx, %{"claim" => [stderr: stderr, exit: 5]})

    %{
      call: fn -> KataAdapter.claim("zq27", nil, %{cwd: ctx.workspace}) end,
      check: fn result, _commands ->
        assert_error(result, "CLAIMED_BY_OTHER",
          exit_code: 5,
          stderr_byte_count: byte_size(stderr)
        )
      end,
      emits: [@spawned_event]
    }
  end

  # Kata prints a full payload on stdout and fails: the stdout of a failed command is dropped.
  defp scenario(:real_exit_1_with_output, ctx) do
    use_real_runner!(ctx, %{
      "show" => [
        stdout: Jason.encode!(show_payload(sensitive_issue())),
        stderr: @stderr_text,
        exit: 1
      ]
    })

    %{
      call: fn -> KataAdapter.get("zq27", %{cwd: ctx.workspace}) end,
      check: fn result, _commands ->
        assert_error(result, "BR_ERROR_ENVELOPE",
          exit_code: 1,
          stderr_byte_count: byte_size(@stderr_text)
        )
      end,
      emits: [@spawned_event]
    }
  end

  defp scenario(:real_unparseable, ctx) do
    use_real_runner!(ctx, %{"show" => [stdout: "not json " <> @body <> " " <> @assignee]})

    %{
      call: fn -> KataAdapter.get("zq27", %{cwd: ctx.workspace}) end,
      check: fn result, _commands -> assert_error(result, "BR_PARSE_ERROR") end,
      emits: [@spawned_event]
    }
  end

  defp scenario(:real_fail, ctx) do
    noise = [stderr: @stderr_text <> " " <> @other_owner]

    use_real_runner!(ctx, %{
      "status" => [stdout: Jason.encode!(status(@assignee))] ++ noise,
      "reopen" => [stdout: Jason.encode!(%{"kata_api_version" => 1, "changed" => true})] ++ noise,
      "comment" =>
        [stdout: Jason.encode!(%{"kata_api_version" => 1, "changed" => true})] ++ noise,
      "unassign" => [stdout: Jason.encode!(unassigned())] ++ noise
    })

    token = %{
      run_id: "run-1",
      artifact_path: nil,
      reason: "Phase develop failed: " <> @comment,
      transition_comment: "foreman-run:run-1:"
    }

    %{
      call: fn -> KataAdapter.fail("zq27", token, %{cwd: ctx.workspace}) end,
      check: fn result, _commands -> assert {:returned, {:ok, :reopened}} = result end,
      emits: [@spawned_event]
    }
  end

  # The runner's own error, as its direct callers (the doctor among them) receive it, before the
  # adapter rewrites it: the stdout of the failed command and the text of its stderr are gone,
  # and only the exit status and the stderr byte count are left.
  defp scenario(:real_runner_error, ctx) do
    stderr = @stderr_text <> " " <> @other_owner

    use_real_runner!(ctx, %{
      "claim" => [stdout: Jason.encode!(show_payload(sensitive_issue())), stderr: stderr, exit: 5]
    })

    %{
      call: fn -> SystemKataRunner.cmd(["claim", "zq27", "--json"], ctx.workspace) end,
      check: fn result, _commands ->
        assert_error(result, "BR_ERROR_ENVELOPE",
          exit_code: 5,
          stderr_byte_count: byte_size(stderr)
        )
      end,
      emits: [@spawned_event]
    }
  end

  defp raising(call) do
    %{
      call: call,
      check: fn result, commands ->
        assert {:raised, %ArgumentError{}} = result
        assert commands == []
      end
    }
  end

  # --- one trigger per error code, each through the adapter's real path

  defp error_trigger("VALIDATION_FAILED", _ctx),
    do: trigger(fn -> KataAdapter.list_ready(%{}, []) end)

  defp error_trigger("INVALID_TASK_ID", _ctx),
    do: trigger(fn -> KataAdapter.get("NOT-A-REF", @config) end)

  defp error_trigger("INVALID_TRANSITION_COMMENT", _ctx),
    do: trigger(fn -> KataAdapter.annotate("zq27", "  ", @config) end)

  defp error_trigger("INVALID_PRIORITY", _ctx),
    do: trigger(fn -> KataAdapter.set_priority("zq27", 9, @config) end)

  defp error_trigger("DEPENDENCY_CYCLE", _ctx),
    do: trigger(fn -> KataAdapter.add_dependency("zq27", "zq27", @config) end)

  defp error_trigger("INVALID_TITLE", _ctx),
    do:
      trigger(fn ->
        KataAdapter.create("project", %{task_id: "t", command_id: "c", title: ""})
      end)

  defp error_trigger("INVALID_ISSUE_TYPE", _ctx) do
    attrs = %{task_id: "t", command_id: "c", title: "x", task_type: 3}
    trigger(fn -> KataAdapter.create("project", attrs) end)
  end

  defp error_trigger("CLAIMED_BY_OTHER", _ctx) do
    stub_kata(%{"claim" => runner_exit(5, 143)})

    trigger(fn -> KataAdapter.claim("zq27", nil, @config) end,
      exit_code: 5,
      stderr_byte_count: 143
    )
  end

  defp error_trigger("ISSUE_NOT_FOUND", _ctx) do
    stub_kata(%{"show" => runner_exit(4, 52)})
    trigger(fn -> KataAdapter.get("zq27", @config) end, exit_code: 4, stderr_byte_count: 52)
  end

  defp error_trigger("BR_TIMEOUT_SUBPROCESS", _ctx) do
    stub_kata(%{"ready" => runner_exit(7, 31)})
    trigger(fn -> KataAdapter.list_ready(@config, []) end, exit_code: 7, stderr_byte_count: 31)
  end

  defp error_trigger("BR_ERROR_ENVELOPE", _ctx) do
    stub_kata(%{"claim" => runner_exit(1, 9)})
    trigger(fn -> KataAdapter.claim("zq27", nil, @config) end, exit_code: 1, stderr_byte_count: 9)
  end

  defp error_trigger("BR_PARSE_ERROR", _ctx) do
    stub_kata(%{"ready" => {:ok, "not json"}})
    trigger(fn -> KataAdapter.list_ready(@config, []) end)
  end

  defp error_trigger("BR_CONTRACT_MISMATCH", _ctx) do
    stub_kata(%{"comment" => ok(%{"kata_api_version" => 1, "changed" => false})})
    trigger(fn -> KataAdapter.annotate("zq27", "a note", @config) end)
  end

  defp error_trigger("SCHEMA_VALIDATION_FAILED", _ctx) do
    stub_kata(%{"ready" => ok(%{"issues" => [%{"uid" => "01M7SJBGQSWGVAJKVM2F82ZQ27"}]})})

    trigger(fn -> KataAdapter.list_ready(@config, []) end,
      missing_fields: ["short_id", "title", "status"]
    )
  end

  defp error_trigger("WORKSPACE_NOT_FOUND", %{temp_dir: temp_dir} = ctx) do
    use_real_runner!(ctx, %{})
    missing = %{cwd: Path.join(temp_dir, "missing")}
    trigger(fn -> KataAdapter.list_ready(missing, []) end)
  end

  # Four callers hold every slot of the project's directory; the fifth waits out a 50 ms queue
  # timeout and never starts a process.
  defp error_trigger("BR_TIMEOUT_QUEUE", _ctx) do
    task_provider = Application.fetch_env!(:foreman_server, :task_provider)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, task_provider)
      restart_limiter!()
    end)

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.put(task_provider, :timeout_ms, 50)
    )

    restart_limiter!()
    test_pid = self()

    stub(KataRunnerMock, :cmd, fn _argv, _cwd, [] ->
      send(test_pid, {:holding_a_slot, self()})

      receive do
        :release -> {:ok, ~s({"kata_api_version": 1, "changed": true})}
      end
    end)

    holders =
      for index <- 1..4 do
        Task.async(fn -> KataAdapter.add_dependency("a#{index}", "b#{index}", @config) end)
      end

    runners =
      for _holder <- holders do
        assert_receive {:holding_a_slot, runner}, 5_000
        runner
      end

    %{
      call: fn -> KataAdapter.add_dependency("e1", "f1", @config) end,
      opts: [],
      after: fn ->
        Enum.each(runners, &send(&1, :release))
        Enum.each(holders, &Task.await(&1, 5_000))
      end
    }
  end

  defp trigger(call, opts \\ []), do: %{call: call, opts: opts, after: fn -> :ok end}

  ## Fixtures

  defp sensitive_issue(overrides \\ %{}) do
    Map.merge(
      %{
        "uid" => "01M7SJBGQSWGVAJKVM2F82ZQ27",
        "short_id" => "zq27",
        "title" => "A task whose owner and body are sentinels",
        "status" => "open",
        "owner" => @assignee,
        "body" => @body,
        "author" => @unmapped,
        "zz_future_field" => @unmapped,
        "revision" => 1
      },
      overrides
    )
  end

  defp show_payload(issue) do
    %{
      "kata_api_version" => 1,
      "issue" => issue,
      "comments" => [%{"body" => @comment, "author" => @assignee}],
      "links" => [],
      "labels" => [%{"label" => "triage", "author" => @assignee}]
    }
  end

  defp mutation(issue, event_type) do
    %{
      "kata_api_version" => 1,
      "changed" => true,
      "issue" => issue,
      "event" => %{"type" => event_type, "actor" => @assignee}
    }
  end

  defp unassigned do
    %{
      "kata_api_version" => 1,
      "changed" => true,
      "event" => %{"type" => "issue.unassigned", "actor" => @assignee}
    }
  end

  defp status(nil) do
    %{"kata_api_version" => 1, "issue" => "zq27", "actor" => @assignee, "hold" => "unassigned"}
  end

  defp status(owner) do
    %{
      "kata_api_version" => 1,
      "issue" => "zq27",
      "actor" => @assignee,
      "owner" => owner,
      "hold" => "assigned"
    }
  end

  defp failure_token do
    %{
      run_id: "run-1",
      artifact_path: nil,
      reason: "Phase develop failed: " <> @comment,
      transition_comment: "foreman-run:run-1:"
    }
  end

  defp ok(payload), do: {:ok, Jason.encode!(payload)}

  # The error the runner returns for a command that exited non-zero (stderr is never read).
  defp runner_exit(exit_code, stderr_byte_count) do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_ERROR_ENVELOPE",
         "Kata CLI exited with a non-zero status.",
         nil,
         false
       ),
       exit_code,
       stderr_byte_count
     )}
  end

  ## Runners

  # Answers each verb with its canned reply, and reports every command to the test process. A verb
  # without a reply raises, so a command that must not run fails the test.
  defp stub_kata(replies) do
    test_pid = self()

    stub(KataRunnerMock, :cmd, fn [verb | _rest] = argv, cwd, [] ->
      send(test_pid, {:kata_command, argv, cwd})
      Map.fetch!(replies, verb)
    end)
  end

  defp commands_run(commands \\ []) do
    receive do
      {:kata_command, argv, _cwd} -> commands_run([argv | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  # Puts a fake `kata` on PATH and binds the real runner, so the shell, the port, the stderr file
  # and the telemetry are the production ones. `replies` maps a verb to the stdout, stderr and
  # exit status it produces.
  defp use_real_runner!(%{temp_dir: temp_dir}, replies) do
    fake_dir = Path.join(temp_dir, "fake")
    bin_dir = Path.join(temp_dir, "bin")
    File.mkdir_p!(fake_dir)
    File.mkdir_p!(bin_dir)

    for {verb, reply} <- replies do
      File.write!(Path.join(fake_dir, verb <> ".out"), Keyword.get(reply, :stdout, ""))
      File.write!(Path.join(fake_dir, verb <> ".err"), Keyword.get(reply, :stderr, ""))

      File.write!(
        Path.join(fake_dir, verb <> ".code"),
        Integer.to_string(Keyword.get(reply, :exit, 0))
      )
    end

    script = Path.join(bin_dir, "kata")

    File.write!(script, """
    #!/bin/sh
    cat "#{fake_dir}/$1.out"
    cat "#{fake_dir}/$1.err" >&2
    exit "$(cat "#{fake_dir}/$1.code")"
    """)

    File.chmod!(script, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))
    Application.put_env(:foreman_server, :kata_runner, SystemKataRunner)
  end

  # `create/2` resolves the project's directory from the registry.
  defp register_kata_project!(%{temp_dir: temp_dir, workspace: workspace}) do
    bin_dir = Path.join(temp_dir, "registry_bin")
    File.mkdir_p!(bin_dir)
    script = Path.join(bin_dir, "kata")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    task_provider = Application.fetch_env!(:foreman_server, :task_provider)
    on_exit(fn -> Application.put_env(:foreman_server, :task_provider, task_provider) end)

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.put(task_provider, :providers, [])
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)

    project_id = "kata-side-channel-#{System.unique_integer([:positive])}"
    expect(KataRunnerMock, :cmd, fn ["--version"], _cwd, [] -> {:ok, "kata v0.23.0\n"} end)

    assert :ok =
             TaskProviderRegistry.register_for_project(project_id, KataAdapter, %{
               cwd: workspace
             })

    project_id
  end

  defp restart_limiter! do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ConcurrencyLimiter)
    {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, ConcurrencyLimiter)
    :ok
  end

  ## Capturing every outward channel

  # Runs `fun` with the log, stdout, stderr and every telemetry event of the task-provider
  # taxonomy captured. A raise is captured too, as `{:raised, exception}`.
  defp capture_side_channels(fun) do
    parent = self()
    ref = :telemetry_test.attach_event_handlers(parent, Map.keys(Telemetry.taxonomy()))

    try do
      log =
        capture_log(fn ->
          stdout =
            capture_io(fn ->
              stderr =
                capture_io(:stderr, fn ->
                  send(parent, {:captured, :result, run_catching(fun)})
                end)

              send(parent, {:captured, :stderr, stderr})
            end)

          send(parent, {:captured, :stdout, stdout})
        end)

      %{
        result: receive_captured!(:result),
        stdout: receive_captured!(:stdout),
        stderr: receive_captured!(:stderr),
        log: log,
        telemetry: drain_telemetry(ref, [])
      }
    after
      :telemetry.detach(ref)
    end
  end

  defp run_catching(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, exception}
  end

  defp receive_captured!(tag) do
    receive do
      {:captured, ^tag, value} -> value
    after
      1_000 -> flunk("did not capture #{inspect(tag)}")
    end
  end

  defp drain_telemetry(ref, events) do
    receive do
      {event, ^ref, measurements, metadata} ->
        drain_telemetry(ref, [
          %{event: event, measurements: measurements, metadata: metadata} | events
        ])
    after
      0 -> Enum.reverse(events)
    end
  end

  ## Assertions

  # AC-017-1, AC-017-2, AC-017-3: no sentinel in the log, on stdout or stderr or in telemetry, and
  # no telemetry key outside the taxonomy's allowlist; and the outcome itself (an error or an
  # exception) names no sentinel.
  defp assert_silent(captured, label) do
    refute_sentinels(captured.log, "#{label}: the log")
    refute_sentinels(captured.stdout, "#{label}: standard output")
    refute_sentinels(captured.stderr, "#{label}: standard error")

    for %{event: event, measurements: measurements, metadata: metadata} <- captured.telemetry do
      refute_sentinels(
        inspect({measurements, metadata}, limit: :infinity, printable_limit: :infinity),
        "#{label}: telemetry #{inspect(event)}"
      )

      allowed = Map.fetch!(Telemetry.taxonomy(), event).metadata_keys
      outside = Map.keys(metadata) -- allowed

      assert outside == [],
             "#{label}: #{inspect(event)} emitted metadata keys outside its allowlist: " <>
               inspect(outside)
    end

    assert_quiet_outcome(captured.result, label)
  end

  defp assert_quiet_outcome({:returned, {:error, %ProviderError{} = error}}, label) do
    refute_sentinels(
      inspect(error, limit: :infinity, printable_limit: :infinity) <> Jason.encode!(error),
      "#{label}: the error"
    )
  end

  defp assert_quiet_outcome({:raised, exception}, label) do
    refute_sentinels(
      Exception.message(exception) <>
        inspect(exception, limit: :infinity, printable_limit: :infinity),
      "#{label}: the exception"
    )
  end

  # A domain result legitimately carries the sensitive values (AC-017-5).
  defp assert_quiet_outcome({:returned, _domain_result}, _label), do: :ok

  defp refute_sentinels(text, what) do
    for sentinel <- @sentinels do
      refute String.contains?(text, sentinel), "#{what} carries #{sentinel}"
    end

    :ok
  end

  # AC-017-5: redaction never touches the record the caller receives.
  defp assert_sensitive_record(%Issue{} = issue) do
    assert issue.assignee == @assignee
    assert issue.description == @body
    assert issue.metadata["author"] == @unmapped
    assert issue.metadata["zz_future_field"] == @unmapped
  end

  # The sentinel really reached the runner (so the silence above is not vacuous).
  defp assert_runner_received(commands, sentinel) do
    assert Enum.any?(commands, fn argv -> Enum.any?(argv, &String.contains?(&1, sentinel)) end),
           "the runner never received #{sentinel}: #{inspect(commands)}"
  end

  # AC-017-4: exactly the seven allowlisted keys, and what they say.
  defp assert_error(result, code, opts \\ []) do
    assert {:returned, {:error, %ProviderError{} = error}} = result,
           "expected the #{code} error, got: #{inspect(result)}"

    assert error.code == code
    assert Enum.sort(Map.keys(error.context)) == @allowlisted_keys
    assert Enum.sort(BuildProviderError.context_keys()) == @allowlisted_keys

    assert error.context.id == code
    assert error.context.command == %{binary: "kata"}
    assert error.context.sanitized? == true
    assert error.context.redacted_fields == ["assignee", "description"]
    assert error.context.exit_code == Keyword.get(opts, :exit_code)
    assert error.context.stderr_byte_count == Keyword.get(opts, :stderr_byte_count, 0)
    assert error.context.missing_fields == Keyword.get(opts, :missing_fields, [])

    error
  end

  ## Static scans

  # The error codes the Kata modules name: every string literal shaped like a code that
  # `BeadsAdapter.CodeMap` knows.
  defp scanned_error_codes do
    for file <- @kata_sources,
        code <- string_literals(File.read!(file)),
        Regex.match?(~r/\A[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\z/, code),
        known_code?(code),
        uniq: true,
        do: code
  end

  defp known_code?(code) do
    error =
      code
      |> ProviderErrorInput.from_local("message", nil, false)
      |> CodeMap.build_provider_error(nil, 0)

    error.code == code
  end

  defp string_literals(source) do
    {_ast, literals} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        literal, acc when is_binary(literal) -> {literal, [literal | acc]}
        node, acc -> {node, acc}
      end)

    literals
  end

  # `%{line:, what:}` for every way the source could log, print, inspect, emit telemetry directly
  # or put a value into an exception message.
  defp outward_channels(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn node, acc ->
        case outward_channel(node) do
          nil -> {node, acc}
          what -> {node, [%{line: node_line(node), what: what} | acc]}
        end
      end)

    Enum.reverse(found)
  end

  defp outward_channel({:__aliases__, _, [:Logger]}), do: "Logger"

  defp outward_channel({{:., _, [{:__aliases__, _, [:IO]}, function]}, _, _})
       when function in @io_output,
       do: "IO.#{function}"

  defp outward_channel({{:., _, [module, function]}, _, _})
       when module in [:logger, :io, :telemetry],
       do: ":#{module}.#{function}"

  defp outward_channel({{:., _, [{:__aliases__, _, [:Kernel]}, :inspect]}, _, _}),
    do: "Kernel.inspect"

  defp outward_channel({name, _, args}) when name in [:inspect, :dbg] and is_list(args),
    do: Atom.to_string(name)

  defp outward_channel({:raise, _, [_exception, {:<<>>, _, _interpolated}]}),
    do: "a raise message that interpolates a value"

  defp outward_channel(_node), do: nil

  defp node_line({_form, meta, _args}) when is_list(meta), do: meta[:line] || 0
  defp node_line(_literal), do: 0

  # `%{line:, event:, keys:}` for every `TaskProviderTelemetry.emit/3` call: the event path (an
  # attribute is followed) and the keys of the metadata map, or `:dynamic` when it is not a
  # literal map.
  defp telemetry_emits(source) do
    ast = Code.string_to_quoted!(source, columns: true)
    attributes = attribute_values(ast)

    {_ast, emits} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:TaskProviderTelemetry]}, :emit]}, meta,
         [event, _measurements, metadata]} = node,
        acc ->
          emit = %{
            line: meta[:line],
            event: event_path(event, attributes),
            keys: metadata_keys(metadata)
          }

          {node, [emit | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(emits)
  end

  defp attribute_values(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp event_path({:@, _, [{name, _, _}]}, attributes), do: Map.get(attributes, name)
  defp event_path(path, _attributes) when is_list(path), do: path

  defp metadata_keys({:%{}, _, pairs}) do
    if Enum.all?(pairs, &match?({key, _value} when is_atom(key), &1)),
      do: Keyword.keys(pairs),
      else: :dynamic
  end

  defp metadata_keys(_not_a_literal_map), do: :dynamic
end
