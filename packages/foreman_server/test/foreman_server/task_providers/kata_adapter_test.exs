defmodule ForemanServer.TaskProviders.KataAdapterTest do
  @moduledoc """
  TRD-KATA-T017-TEST and T029-TEST: the 13 `TaskProvider` callbacks of `KataAdapter` against
  `KataRunnerMock`, every happy path and error path, and every error-envelope path keyed on the
  failing verb and exit code. The payloads mirror what `kata` v0.23.0 printed in a scratch
  workspace.
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProvider.{Comment, Issue}
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemKataRunner

  @lib_root Path.expand("../../../lib/foreman_server/task_providers", __DIR__)
  @cwd "/projects/kata-demo"
  @config %{cwd: @cwd}

  # The closed `ProviderError.context` key set of every Kata error (AC-017-4, plus the
  # `missing_fields` key `ProviderError.new/3` seeds).
  @closed_context_keys [
    :command,
    :exit_code,
    :id,
    :missing_fields,
    :redacted_fields,
    :sanitized?,
    :stderr_byte_count
  ]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "kata_adapter_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  ## name/0, capabilities/0, registry

  describe "name/0 and capabilities/0 (AC-001-2, AC-002-1)" do
    test "name/0 is a human-readable provider name" do
      assert KataAdapter.name() == "kata"
    end

    test "capabilities/0 declares the kata provider, its contract and its storage scheme" do
      assert %{
               provider_id: :kata,
               contract_version: "kata.capabilities.v1",
               storage_scheme: :cli_process,
               id_format: "^[a-z0-9]+$",
               supports: supports
             } = KataAdapter.capabilities()

      assert supports == [
               :create,
               :claim,
               :close,
               :reopen,
               :annotate,
               :set_priority,
               :set_assignee,
               :list_dependencies,
               :add_dependency,
               :remove_dependency
             ]
    end

    test "the declared id_format accepts and rejects the same references the adapter does" do
      %{id_format: id_format} = KataAdapter.capabilities()
      regex = Regex.compile!(id_format)

      for ref <- ["abc4", "4abc", "a1b2", String.duplicate("a1", 13)] do
        assert Regex.match?(regex, ref)

        # Accepted: the adapter lets the reference through to kata.
        expect_kata(["show", ref, "--json"], runner_exit(4, 1))

        assert_kata_error(KataAdapter.get(ref, @config), "ISSUE_NOT_FOUND", false,
          exit_code: 4,
          stderr_byte_count: 1
        )
      end

      for ref <- ["", "ABC4", "ab-c", "a b", "--force", "kata#abc4", "12.3"] do
        refute Regex.match?(regex, ref)

        # Rejected: the adapter refuses it itself; no kata call is expected, so one would raise.
        assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} = KataAdapter.get(ref, @config)
      end
    end
  end

  describe "registry acceptance (AC-001-1, AC-001-2)" do
    test "all 13 TaskProvider callbacks are exported" do
      for {name, arity} <- ForemanServer.TaskProvider.behaviour_info(:callbacks) do
        assert function_exported?(KataAdapter, name, arity),
               "KataAdapter does not export #{name}/#{arity}"
      end

      assert length(ForemanServer.TaskProvider.behaviour_info(:callbacks)) == 13
    end

    test "the configured registry routes :kata to KataAdapter next to :beads, with no exemption" do
      name = :kata_adapter_registry_acceptance
      start_supervised!({TaskProviderRegistry, [name: name]}, id: name)

      assert %{kata: KataAdapter, beads: BeadsAdapter} =
               GenServer.call(name, :routing_snapshot)

      assert {:ok, KataAdapter} = GenServer.call(name, {:register, KataAdapter})

      assert "kata.capabilities.v1" in Application.fetch_env!(:foreman_server, :task_provider)[
               :accepted_contract_versions
             ]
    end

    test "the registry rejects the adapter when its contract version is not accepted" do
      task_provider = Application.fetch_env!(:foreman_server, :task_provider)

      on_exit(fn -> Application.put_env(:foreman_server, :task_provider, task_provider) end)

      Application.put_env(
        :foreman_server,
        :task_provider,
        Keyword.put(task_provider, :accepted_contract_versions, ["br.capabilities.v1"])
      )

      name = :kata_adapter_registry_rejection

      # The registry logs a warning for every configured provider it skips.
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({TaskProviderRegistry, [name: name]}, id: name)
      end)

      assert GenServer.call(name, {:register, KataAdapter}) ==
               {:error, :contract_version_mismatch}

      refute Map.has_key?(GenServer.call(name, :routing_snapshot), :kata)
    end
  end

  ## available?/0

  describe "available?/0 (AC-002-3)" do
    test "is false, without raising or running kata, when kata is not on PATH", %{
      temp_dir: temp_dir
    } do
      empty_bin = Path.join(temp_dir, "empty_bin")
      File.mkdir_p!(empty_bin)
      System.put_env("PATH", empty_bin)

      assert KataAdapter.available?() == false
    end

    test "is false when kata --version exits non-zero", %{temp_dir: temp_dir} do
      put_fake_kata_on_path(temp_dir)

      expect(KataRunnerMock, :cmd, fn ["--version"], cwd, [] ->
        assert File.dir?(cwd)
        runner_exit(1)
      end)

      assert KataAdapter.available?() == false
    end

    test "is false when kata --version times out", %{temp_dir: temp_dir} do
      put_fake_kata_on_path(temp_dir)
      expect(KataRunnerMock, :cmd, fn ["--version"], _cwd, [] -> runner_timeout() end)

      assert KataAdapter.available?() == false
    end

    test "is true when kata is found and the version probe succeeds", %{temp_dir: temp_dir} do
      put_fake_kata_on_path(temp_dir)

      expect(KataRunnerMock, :cmd, fn ["--version"], _cwd, [] ->
        {:ok, "kata v0.23.0\n  commit:  unknown\n  built:   2026-11-09T11:49:11Z\n"}
      end)

      assert KataAdapter.available?() == true
    end

    test "a version outside accepted_kata_versions is not a reason to be unavailable", %{
      temp_dir: temp_dir
    } do
      put_fake_kata_on_path(temp_dir)

      expect(KataRunnerMock, :cmd, fn ["--version"], _cwd, [] ->
        {:ok, "kata v0.1.0\n"}
      end)

      assert KataAdapter.available?() == true
    end
  end

  ## list_ready/2

  describe "list_ready/2 (AC-005-1, AC-006-1, AC-006-2, AC-006-3)" do
    test "runs kata ready --unowned --json in the project cwd and maps the records" do
      expect_kata(
        ["ready", "--unowned", "--json"],
        ok(%{
          "kata_api_version" => 1,
          "issues" => [
            ready_record(%{
              "short_id" => "mwfm",
              "title" => "Second task",
              "priority" => 2,
              "labels" => ["foo"]
            }),
            ready_record(%{"short_id" => "j04d", "title" => "First task", "body" => "Body"})
          ]
        })
      )

      assert {:ok, [%Issue{} = second, %Issue{} = first]} = KataAdapter.list_ready(@config, [])

      assert second.id == "mwfm"
      assert second.title == "Second task"
      assert second.status == "open"
      assert second.priority == 2
      assert second.labels == ["foo"]
      assert second.assignee == nil
      assert second.dependencies == []
      assert second.notes == nil
      assert second.design == nil

      assert first.id == "j04d"
      assert first.description == "Body"
      assert first.priority == nil
      assert first.labels == []
    end

    test "fills the Foreman fields from Kata's keys and keeps the rest under metadata" do
      expect_kata(
        ["ready", "--unowned", "--json"],
        ok(%{
          "issues" => [
            ready_record(%{"owner" => "alice", "body" => "the body", "priority" => 0})
          ]
        })
      )

      assert {:ok, [issue]} = KataAdapter.list_ready(@config, [])

      assert issue.id == "zq27"
      assert issue.description == "the body"
      assert issue.assignee == "alice"
      assert issue.priority == 0

      for key <- ~w(uid author revision qualified_id web_url created_at updated_at) do
        assert Map.has_key?(issue.metadata, key), "metadata lost #{key}"
      end

      assert issue.metadata["qualified_id"] == "ws#zq27"
      assert Enum.all?(Map.keys(issue.metadata), &is_binary/1)

      for key <- ~w(short_id title status priority owner body labels) do
        refute Map.has_key?(issue.metadata, key), "metadata duplicates #{key}"
      end
    end

    test "an empty ready list is an empty result" do
      expect_kata(["ready", "--unowned", "--json"], ok(%{"issues" => []}))

      assert KataAdapter.list_ready(@config, []) == {:ok, []}
    end

    test "a record missing short_id, title or status is a typed schema error naming them" do
      expect_kata(
        ["ready", "--unowned", "--json"],
        ok(%{
          "issues" => [
            ready_record(%{"short_id" => "good1"}),
            %{"uid" => "01M7SJBGQSWGVAJKVM2F82ZQ27", "body" => "no id, title or status"}
          ]
        })
      )

      error =
        assert_kata_error(
          KataAdapter.list_ready(@config, []),
          "SCHEMA_VALIDATION_FAILED",
          false,
          missing_fields: ["short_id", "title", "status"]
        )

      assert error.message =~ "Kata payload"
    end

    test "a partly malformed list yields a typed error, never a partial list" do
      expect_kata(
        ["ready", "--unowned", "--json"],
        ok(%{
          "issues" => [
            ready_record(%{"short_id" => "good1"}),
            ready_record(%{"short_id" => "good2"}),
            ready_record(%{"short_id" => "bad3", "title" => ""})
          ]
        })
      )

      assert_kata_error(
        KataAdapter.list_ready(@config, []),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["title"]
      )
    end

    test "a wrongly typed optional field is reported, not coerced" do
      expect_kata(
        ["ready", "--unowned", "--json"],
        ok(%{
          "issues" => [
            ready_record(%{"priority" => "high", "labels" => "foo", "owner" => 7})
          ]
        })
      )

      assert_kata_error(
        KataAdapter.list_ready(@config, []),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["priority", "owner", "labels"]
      )
    end

    test "an envelope without an issues list, or with a non-object record, is a schema error" do
      expect_kata(["ready", "--unowned", "--json"], ok(%{"kata_api_version" => 1}))

      assert_kata_error(
        KataAdapter.list_ready(@config, []),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["issues"]
      )

      expect_kata(["ready", "--unowned", "--json"], ok(%{"issues" => ["not-a-record"]}))

      assert_kata_error(
        KataAdapter.list_ready(@config, []),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["issues"]
      )
    end

    test "a runner failure is mapped by verb and exit code" do
      expect_kata(["ready", "--unowned", "--json"], runner_exit(7, 31))

      assert_kata_error(KataAdapter.list_ready(@config, []), "BR_TIMEOUT_SUBPROCESS", true,
        exit_code: 7,
        stderr_byte_count: 31
      )
    end

    test "a project config without a working directory raises instead of running kata" do
      assert_raise ArgumentError, ~r/:cwd/, fn -> KataAdapter.list_ready(%{}, []) end
    end
  end

  ## get/2

  describe "get/2 (AC-005-1, AC-006-1, AC-006-2, AC-006-3)" do
    test "runs kata show --json and maps issue, labels and blocking links" do
      issue =
        kata_issue(%{
          "short_id" => "zq27",
          "uid" => "uid-zq27",
          "owner" => "alice",
          "priority" => 1
        })

      links = [
        link("blocks", {"j04d", "uid-j04d"}, {"zq27", "uid-zq27"}),
        link("blocks", {"zq27", "uid-zq27"}, {"later", "uid-later"}),
        link("related", {"rel1", "uid-rel1"}, {"zq27", "uid-zq27"}),
        link("blocks", {"mwfm", "uid-mwfm"}, {"zq27", "uid-zq27"})
      ]

      expect_kata(
        ["show", "zq27", "--json"],
        ok(show_payload(issue, links: links, labels: ["foo", "bar"]))
      )

      assert {:ok, %Issue{} = fetched} = KataAdapter.get("zq27", @config)

      assert fetched.id == "zq27"
      assert fetched.title == "Third task"
      assert fetched.status == "open"
      assert fetched.priority == 1
      assert fetched.assignee == "alice"
      assert fetched.description == "third body"
      assert fetched.labels == ["foo", "bar"]
      assert fetched.dependencies == ["j04d", "mwfm"]
      assert fetched.dependents == []
      assert fetched.notes == nil
      assert fetched.design == nil
      assert fetched.metadata["uid"] == "uid-zq27"
      assert fetched.metadata["web_url"] == "http://127.0.0.1:65448/kata?issue=uid-zq27#direct=1"
      refute Map.has_key?(fetched.metadata, "labels")
    end

    test "an absent priority maps to no priority and absent labels and links stay empty" do
      payload = show_payload(kata_issue()) |> Map.drop(["labels", "links"])
      expect_kata(["show", "zq27", "--json"], ok(payload))

      assert {:ok, %Issue{priority: nil, labels: [], dependencies: []}} =
               KataAdapter.get("zq27", @config)
    end

    test "falls back to short ids when the link endpoints carry no uid" do
      issue = kata_issue(%{"short_id" => "zq27"}) |> Map.delete("uid")

      links = [
        %{"type" => "blocks", "from" => %{"short_id" => "j04d"}, "to" => %{"short_id" => "zq27"}}
      ]

      expect_kata(["show", "zq27", "--json"], ok(show_payload(issue, links: links)))

      assert {:ok, %Issue{dependencies: ["j04d"]}} = KataAdapter.get("zq27", @config)
    end

    test "rejects a payload missing short_id, title or status, naming each, with no placeholder" do
      issue = kata_issue() |> Map.drop(["short_id", "title", "status"])
      expect_kata(["show", "zq27", "--json"], ok(show_payload(issue)))

      assert_kata_error(
        KataAdapter.get("zq27", @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["short_id", "title", "status"]
      )
    end

    test "rejects a payload without an issue object" do
      expect_kata(["show", "zq27", "--json"], ok(%{"kata_api_version" => 1, "labels" => []}))

      assert_kata_error(
        KataAdapter.get("zq27", @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["issue"]
      )
    end

    test "rejects malformed labels and links" do
      expect_kata(["show", "zq27", "--json"], ok(show_payload(kata_issue(), labels: "foo")))

      assert_kata_error(KataAdapter.get("zq27", @config), "SCHEMA_VALIDATION_FAILED", false,
        missing_fields: ["labels"]
      )

      expect_kata(
        ["show", "zq27", "--json"],
        ok(show_payload(kata_issue(), links: [%{"type" => "blocks", "from" => "j04d"}]))
      )

      assert_kata_error(KataAdapter.get("zq27", @config), "SCHEMA_VALIDATION_FAILED", false,
        missing_fields: ["links"]
      )
    end

    test "an unknown issue is ISSUE_NOT_FOUND" do
      expect_kata(["show", "zzzz", "--json"], runner_exit(4, 52))

      assert_kata_error(KataAdapter.get("zzzz", @config), "ISSUE_NOT_FOUND", false,
        exit_code: 4,
        stderr_byte_count: 52
      )
    end

    test "refuses a reference that is not a Kata short id before running anything" do
      for ref <- ["", "ABC4", "ab-c", "--force", "a b", "abc\n", "kata#abc4"] do
        assert {:error, %ProviderError{code: "INVALID_TASK_ID", retryable?: false}} =
                 KataAdapter.get(ref, @config)
      end

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} = KataAdapter.get(nil, @config)
      assert_raise ArgumentError, fn -> KataAdapter.get(42, @config) end
    end
  end

  ## claim/3

  describe "claim/3 (AC-005-2)" do
    test "issues exactly one atomic kata claim --if-unowned and returns the claimed issue" do
      claimed =
        kata_issue(%{"short_id" => "j04d", "owner" => "ldangelo", "title" => "First task"})

      expect_kata(
        ["claim", "j04d", "--if-unowned", "--json"],
        ok(mutation(claimed, "issue.assigned"))
      )

      assert {:ok, %Issue{} = issue} = KataAdapter.claim("j04d", "ldangelo", @config)

      assert issue.id == "j04d"
      assert issue.title == "First task"
      assert issue.assignee == "ldangelo"
      assert issue.status == "open"
    end

    test "ignores the claim token: kata resolves the acting identity itself" do
      for token <- [nil, "alice", %{actor: "bob"}] do
        expect_kata(
          ["claim", "j04d", "--if-unowned", "--json"],
          ok(
            mutation(kata_issue(%{"short_id" => "j04d", "owner" => "ldangelo"}), "issue.assigned")
          )
        )

        assert {:ok, %Issue{assignee: "ldangelo"}} = KataAdapter.claim("j04d", token, @config)
      end
    end

    test "an envelope whose issue is not owned is not a claim" do
      expect_kata(
        ["claim", "j04d", "--if-unowned", "--json"],
        ok(mutation(kata_issue(%{"short_id" => "j04d"}), "issue.assigned"))
      )

      assert_kata_error(
        KataAdapter.claim("j04d", nil, @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["owner"]
      )
    end

    test "an envelope without an issue object is a schema error" do
      expect_kata(["claim", "j04d", "--if-unowned", "--json"], ok(%{"changed" => true}))

      assert_kata_error(
        KataAdapter.claim("j04d", nil, @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["issue"]
      )
    end

    test "an issue another actor owns is CLAIMED_BY_OTHER and never retried (AC-013-2)" do
      expect_kata(["claim", "j04d", "--if-unowned", "--json"], runner_exit(5, 143))

      error =
        assert_kata_error(
          KataAdapter.claim("j04d", nil, @config),
          "CLAIMED_BY_OTHER",
          false,
          exit_code: 5,
          stderr_byte_count: 143
        )

      refute Map.has_key?(error.context, :current_assignee_present?)
    end

    test "refuses an invalid reference before running anything" do
      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.claim("NOT-A-REF", nil, @config)
    end
  end

  ## complete/3

  describe "complete/3 (AC-005-3, AC-013-1)" do
    test "closes as done with the message, the commit sha and the evidence" do
      token = %{
        run_id: "run-1",
        artifact_path: "artifacts/out.md",
        transition_comment:
          "Implemented the retry path; mix test passes for the touched modules.",
        commit_sha: "abc1234def",
        evidence: ["pr:https://example.test/pull/1", "test:mix test"]
      }

      expect_kata(
        [
          "close",
          "j04d",
          "--done",
          "--message",
          "Implemented the retry path; mix test passes for the touched modules.",
          "--commit",
          "abc1234def",
          "--evidence",
          "pr:https://example.test/pull/1",
          "--evidence",
          "test:mix test",
          "--json"
        ],
        ok(mutation(kata_issue(%{"status" => "closed"}), "issue.closed", true))
      )

      assert KataAdapter.complete("j04d", token, @config) == {:ok, :terminal}
    end

    test "without a message the default names the run and artifact and meets Kata's minimum" do
      long_default = "foreman-run:run-1234567890:artifacts/phase-1/output.md"

      for {token, expected} <- [
            {%{run_id: "run-1234567890", artifact_path: "artifacts/phase-1/output.md"},
             long_default},
            {%{run_id: "r", artifact_path: nil},
             "foreman-run:r: - closed by the Foreman task runner"},
            {%{run_id: "run-1", artifact_path: "a.md"},
             "foreman-run:run-1:a.md - closed by the Foreman task runner"}
          ] do
        expect(KataRunnerMock, :cmd, fn argv, @cwd, [] ->
          assert ["close", "j04d", "--done", "--message", message, "--commit", "abc123", "--json"] =
                   argv

          assert message == expected
          assert String.length(message) >= 40
          ok(mutation(kata_issue(), "issue.closed", true))
        end)

        assert KataAdapter.complete("j04d", Map.put(token, :commit_sha, "abc123"), @config) ==
                 {:ok, :terminal}
      end
    end

    test "the default message is deterministic" do
      token = %{run_id: "run-1", artifact_path: "a.md", commit_sha: "abc123"}
      parent = self()

      expect(KataRunnerMock, :cmd, 2, fn argv, @cwd, [] ->
        send(parent, {:argv, argv})
        ok(mutation(kata_issue(), "issue.closed", true))
      end)

      KataAdapter.complete("j04d", token, @config)
      KataAdapter.complete("j04d", token, @config)

      assert_received {:argv, first}
      assert_received {:argv, second}
      assert first == second
    end

    test "a blank transition comment falls back to the default" do
      expect(KataRunnerMock, :cmd, fn argv, @cwd, [] ->
        assert ["close", "j04d", "--done", "--message", "foreman-run:run-1:" <> _ | _] = argv
        ok(mutation(kata_issue(), "issue.closed", true))
      end)

      assert {:ok, :terminal} =
               KataAdapter.complete(
                 "j04d",
                 %{
                   run_id: "run-1",
                   artifact_path: "a.md",
                   transition_comment: "",
                   commit_sha: "abc123"
                 },
                 @config
               )
    end

    test "a close envelope with changed: false is an explicit already-terminal success" do
      expect_kata(
        [
          "close",
          "j04d",
          "--done",
          "--message",
          close_message("a.md"),
          "--commit",
          "abc123",
          "--json"
        ],
        ok(%{
          "kata_api_version" => 1,
          "changed" => false,
          "event" => nil,
          "issue" => kata_issue(%{"status" => "closed"})
        })
      )

      assert KataAdapter.complete(
               "j04d",
               %{run_id: "run-1", artifact_path: "a.md", commit_sha: "abc123"},
               @config
             ) == {:ok, :already_terminal}
    end

    test "kata refusing the close is a typed error, not a success" do
      expect(KataRunnerMock, :cmd, fn ["close" | _], @cwd, [] -> runner_exit(3, 188) end)

      assert_kata_error(
        KataAdapter.complete("j04d", %{run_id: "run-1", artifact_path: "a.md"}, @config),
        "VALIDATION_FAILED",
        false,
        exit_code: 3,
        stderr_byte_count: 188
      )
    end

    test "an envelope without a boolean changed is a schema error" do
      expect(KataRunnerMock, :cmd, fn ["close" | _], @cwd, [] ->
        ok(%{"kata_api_version" => 1})
      end)

      assert_kata_error(
        KataAdapter.complete("j04d", %{run_id: "run-1", commit_sha: "abc123"}, @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["changed"]
      )
    end

    test "needs a message or a run id to derive one, and runs nothing without them" do
      assert {:error, %ProviderError{code: "INVALID_TRANSITION_COMMENT", retryable?: false}} =
               KataAdapter.complete("j04d", %{artifact_path: "a.md"}, @config)
    end

    test "refuses an invalid reference and raises on wrongly typed token entries" do
      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.complete("J04D", %{run_id: "run-1"}, @config)

      assert_raise ArgumentError, ~r/commit_sha/, fn ->
        KataAdapter.complete("j04d", %{run_id: "run-1", commit_sha: 42}, @config)
      end

      assert_raise ArgumentError, ~r/evidence/, fn ->
        KataAdapter.complete("j04d", %{run_id: "run-1", evidence: "pr:x"}, @config)
      end

      assert_raise ArgumentError, ~r/evidence/, fn ->
        KataAdapter.complete("j04d", %{run_id: "run-1", evidence: [""]}, @config)
      end
    end
  end

  ## fail/3

  describe "fail/3 (AC-005-4)" do
    test "reads status, reopens, comments under a keyed idempotency key, then releases the claim" do
      token = failure_token("run-77", "Phase develop failed: the tests are red.")

      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false, "event" => nil}))

      expect_kata(
        [
          "comment",
          "j04d",
          "--body",
          "Phase develop failed: the tests are red.",
          "--idempotency-key",
          failure_key("run-77", "Phase develop failed: the tests are red."),
          "--json"
        ],
        ok(%{"changed" => true})
      )

      expect_kata(
        ["unassign", "j04d", "--expect-owner", "ldangelo", "--json"],
        ok(%{"changed" => true, "event" => %{"type" => "issue.unassigned"}})
      )

      assert KataAdapter.fail("j04d", token, @config) == {:ok, :reopened}
    end

    test "the idempotency key is foreman-fail:<run_id>:<first 16 hex of sha256 of the body>" do
      body = "exact body"
      hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 16)

      assert failure_key("run-1", body) == "foreman-fail:run-1:" <> hash
      assert byte_size(hash) == 16

      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", nil)))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => true}))

      expect(KataRunnerMock, :cmd, fn [
                                        "comment",
                                        "j04d",
                                        "--body",
                                        ^body,
                                        "--idempotency-key",
                                        key,
                                        "--json"
                                      ],
                                      @cwd,
                                      [] ->
        assert key == "foreman-fail:run-1:" <> hash
        ok(%{"changed" => true})
      end)

      assert {:ok, :reopened} = KataAdapter.fail("j04d", failure_token("run-1", body), @config)
    end

    test "a differently worded comment under the same run gets a different key" do
      test_pid = self()

      key_sent_for = fn run_id, body ->
        expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", nil)))
        expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => true}))

        expect(KataRunnerMock, :cmd, fn [
                                          "comment",
                                          "j04d",
                                          "--body",
                                          ^body,
                                          "--idempotency-key",
                                          key,
                                          "--json"
                                        ],
                                        @cwd,
                                        [] ->
          send(test_pid, {:comment_key, key})
          ok(%{"changed" => true})
        end)

        assert {:ok, :reopened} = KataAdapter.fail("j04d", failure_token(run_id, body), @config)
        assert_receive {:comment_key, sent_key}
        sent_key
      end

      assert key_sent_for.("run-1", "first wording") != key_sent_for.("run-1", "second wording")
      assert key_sent_for.("run-1", "same") != key_sent_for.("run-2", "same")
      assert key_sent_for.("run-1", "same") == key_sent_for.("run-1", "same")
    end

    test "a task owned by a different actor is left untouched: only status is called" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "SECRET-owner-bob")))

      error =
        assert_kata_error(
          KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
          "CLAIMED_BY_OTHER",
          false
        )

      refute inspect(error) =~ "SECRET-owner-bob"
      refute Map.has_key?(error.context, :current_assignee_present?)
    end

    test "an unowned task still gets the reopen and the comment, but no unassign" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", nil)))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => true}))

      expect(KataRunnerMock, :cmd, fn ["comment", "j04d", "--body", "boom" | _], @cwd, [] ->
        ok(%{"changed" => true})
      end)

      assert KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config) == {:ok, :reopened}
    end

    test "ownership that changed after the status read surfaces as a non-retryable CLAIMED_BY_OTHER" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false}))

      expect(KataRunnerMock, :cmd, fn ["comment" | _], @cwd, [] -> ok(%{"changed" => true}) end)

      expect_kata(
        ["unassign", "j04d", "--expect-owner", "ldangelo", "--json"],
        runner_exit(5, 154)
      )

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "CLAIMED_BY_OTHER",
        false,
        exit_code: 5,
        stderr_byte_count: 154
      )
    end

    test "a retry after the comment succeeded replays the comment instead of repeating it" do
      # `fail_retry_loop` rebuilds an identical token for each attempt, so the retry starts at
      # status again and the comment goes out under the same key (and body).
      token = failure_token("run-9", "boom")

      comment = [
        "comment",
        "j04d",
        "--body",
        "boom",
        "--idempotency-key",
        failure_key("run-9", "boom"),
        "--json"
      ]

      # Attempt 1: the comment lands, the unassign hits a transient failure.
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => true}))
      expect_kata(comment, ok(%{"changed" => true}))

      expect_kata(
        ["unassign", "j04d", "--expect-owner", "ldangelo", "--json"],
        runner_exit(7, 0)
      )

      assert_kata_error(KataAdapter.fail("j04d", token, @config), "BR_TIMEOUT_SUBPROCESS", true,
        exit_code: 7
      )

      # Attempt 2: kata replays the identical comment as changed: false (no second comment).
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false}))
      expect_kata(comment, ok(%{"changed" => false, "event" => nil}))

      expect_kata(
        ["unassign", "j04d", "--expect-owner", "ldangelo", "--json"],
        ok(%{"changed" => true, "event" => %{"type" => "issue.unassigned"}})
      )

      assert KataAdapter.fail("j04d", token, @config) == {:ok, :reopened}
    end

    test "the comment body is the reason, else the transition comment" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", nil)))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => true}))

      expect(KataRunnerMock, :cmd, fn ["comment", "j04d", "--body", "foreman-run:run-1:a.md" | _],
                                      @cwd,
                                      [] ->
        ok(%{"changed" => true})
      end)

      assert {:ok, :reopened} =
               KataAdapter.fail(
                 "j04d",
                 %{
                   run_id: "run-1",
                   artifact_path: "a.md",
                   transition_comment: "foreman-run:run-1:a.md"
                 },
                 @config
               )
    end

    test "without a reason or a transition comment nothing is written" do
      assert {:error, %ProviderError{code: "INVALID_TRANSITION_COMMENT", retryable?: false}} =
               KataAdapter.fail("j04d", %{run_id: "run-1", reason: ""}, @config)
    end

    test "a status payload without an actor or with a malformed owner is a schema error" do
      expect_kata(
        ["status", "j04d", "--json"],
        ok(%{"owner" => "ldangelo", "hold" => "assigned"})
      )

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["actor"]
      )

      expect_kata(["status", "j04d", "--json"], ok(%{"actor" => "ldangelo", "owner" => 12}))

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["owner"]
      )
    end

    test "an unassign that does not report the claim as released is a contract mismatch" do
      for unassigned <- [
            %{"changed" => false, "event" => nil},
            %{"changed" => true, "event" => %{"type" => "issue.assigned"}},
            %{"changed" => true}
          ] do
        expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
        expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false}))
        expect(KataRunnerMock, :cmd, fn ["comment" | _], @cwd, [] -> ok(%{"changed" => true}) end)
        expect_kata(["unassign", "j04d", "--expect-owner", "ldangelo", "--json"], ok(unassigned))

        assert_kata_error(
          KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
          "BR_CONTRACT_MISMATCH",
          false
        )
      end
    end

    test "a failing step stops the sequence and is returned as a typed error" do
      expect_kata(["status", "j04d", "--json"], runner_exit(4, 40))

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "ISSUE_NOT_FOUND",
        false,
        exit_code: 4,
        stderr_byte_count: 40
      )

      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], runner_exit(1, 9))

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "BR_ERROR_ENVELOPE",
        false,
        exit_code: 1,
        stderr_byte_count: 9
      )
    end

    test "a comment kata refuses with a conflict is BR_ERROR_ENVELOPE, not claimed-by-other" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false}))
      expect(KataRunnerMock, :cmd, fn ["comment" | _], @cwd, [] -> runner_exit(5, 120) end)

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "BR_ERROR_ENVELOPE",
        false,
        exit_code: 5,
        stderr_byte_count: 120
      )
    end

    test "refuses an invalid reference and raises on a token without a run id" do
      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.fail("J04D", failure_token("run-1", "boom"), @config)

      assert_raise ArgumentError, ~r/run_id/, fn ->
        KataAdapter.fail("j04d", %{reason: "boom"}, @config)
      end
    end
  end

  ## reopen/3

  describe "reopen/3 (AC-005-5)" do
    test "reopens with the transition comment and returns :ok" do
      expect_kata(
        ["reopen", "j04d", "--comment", "orphaned run", "--json"],
        ok(mutation(kata_issue(), "issue.reopened"))
      )

      assert KataAdapter.reopen("j04d", "orphaned run", @config) == :ok
    end

    test "an issue that is already open is a no-op success" do
      expect_kata(
        ["reopen", "j04d", "--comment", "orphaned run", "--json"],
        ok(%{"changed" => false, "event" => nil, "issue" => kata_issue()})
      )

      assert KataAdapter.reopen("j04d", "orphaned run", @config) == :ok
    end

    test "returns success only when kata reports it: a refusal is a typed error" do
      expect_kata(["reopen", "j04d", "--comment", "why", "--json"], runner_exit(4, 52))

      assert_kata_error(KataAdapter.reopen("j04d", "why", @config), "ISSUE_NOT_FOUND", false,
        exit_code: 4,
        stderr_byte_count: 52
      )

      expect_kata(["reopen", "j04d", "--comment", "why", "--json"], {:ok, "not json"})

      assert_kata_error(KataAdapter.reopen("j04d", "why", @config), "BR_PARSE_ERROR", false)
    end

    test "refuses a blank comment and an invalid reference before running anything" do
      for comment <- ["", "   ", nil] do
        assert {:error, %ProviderError{code: "INVALID_TRANSITION_COMMENT"}} =
                 KataAdapter.reopen("j04d", comment, @config)
      end

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.reopen("J04D", "why", @config)

      assert_raise ArgumentError, fn -> KataAdapter.reopen("j04d", 7, @config) end
    end
  end

  ## set_priority/3

  describe "set_priority/3 (AC-005-5)" do
    test "edits the priority and returns :ok, including when it already had that value" do
      for changed? <- [true, false] do
        expect_kata(
          ["edit", "mwfm", "--priority", "1", "--json"],
          ok(%{"changed" => changed?, "issue" => kata_issue(%{"priority" => 1})})
        )

        assert KataAdapter.set_priority("mwfm", 1, @config) == :ok
      end
    end

    test "refuses a priority outside 0..4 before running anything" do
      for priority <- [-1, 5, "1", nil, 1.0] do
        assert {:error, %ProviderError{code: "INVALID_PRIORITY", retryable?: false}} =
                 KataAdapter.set_priority("mwfm", priority, @config)
      end
    end

    test "returns success only when kata reports it" do
      expect_kata(["edit", "mwfm", "--priority", "2", "--json"], runner_exit(3, 60))

      assert_kata_error(KataAdapter.set_priority("mwfm", 2, @config), "VALIDATION_FAILED", false,
        exit_code: 3,
        stderr_byte_count: 60
      )

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.set_priority("MWFM", 2, @config)
    end
  end

  ## add_dependency/3

  describe "add_dependency/3 (AC-005-5)" do
    test "makes the dependent blocked by the dependency and returns :ok, repeated edge included" do
      for changed? <- [true, false] do
        expect_kata(
          ["edit", "mwfm", "--blocked-by", "zq27", "--json"],
          ok(%{"changed" => changed?, "issue" => kata_issue()})
        )

        assert KataAdapter.add_dependency("mwfm", "zq27", @config) == :ok
      end
    end

    test "refuses a self-dependency and invalid references before running anything" do
      assert {:error, %ProviderError{code: "DEPENDENCY_CYCLE", retryable?: false}} =
               KataAdapter.add_dependency("mwfm", "mwfm", @config)

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.add_dependency("MWFM", "zq27", @config)

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.add_dependency("mwfm", "--blocks", @config)
    end

    test "returns success only when kata reports it" do
      expect_kata(["edit", "mwfm", "--blocked-by", "nope", "--json"], runner_exit(4, 52))

      assert_kata_error(
        KataAdapter.add_dependency("mwfm", "nope", @config),
        "ISSUE_NOT_FOUND",
        false,
        exit_code: 4,
        stderr_byte_count: 52
      )
    end
  end

  ## annotate/3

  describe "annotate/3 (AC-005-5)" do
    test "appends the comment and returns a typed Comment" do
      expect_kata(
        ["comment", "j04d", "--body", "Work Log: phase develop done", "--json"],
        ok(%{"changed" => true, "comment" => %{"body" => "Work Log: phase develop done"}})
      )

      assert {:ok,
              %Comment{provider_issue_id: "j04d", status: "comment_added", provider_metadata: %{}}} =
               KataAdapter.annotate("j04d", "Work Log: phase develop done", @config)
    end

    test "a comment kata did not add is not reported as added" do
      expect_kata(["comment", "j04d", "--body", "x", "--json"], ok(%{"changed" => false}))

      assert_kata_error(KataAdapter.annotate("j04d", "x", @config), "BR_CONTRACT_MISMATCH", false)
    end

    test "refuses a blank body and an invalid reference before running anything" do
      for body <- ["", "  \n", nil] do
        assert {:error, %ProviderError{code: "INVALID_TRANSITION_COMMENT"}} =
                 KataAdapter.annotate("j04d", body, @config)
      end

      assert {:error, %ProviderError{code: "INVALID_TASK_ID"}} =
               KataAdapter.annotate("", "body", @config)
    end

    test "returns success only when kata reports it" do
      expect_kata(["comment", "j04d", "--body", "x", "--json"], runner_exit(4, 52))

      assert_kata_error(KataAdapter.annotate("j04d", "x", @config), "ISSUE_NOT_FOUND", false,
        exit_code: 4,
        stderr_byte_count: 52
      )
    end
  end

  ## create/2

  describe "create/2 (AC-005-6)" do
    setup %{temp_dir: temp_dir} do
      put_fake_kata_on_path(temp_dir)

      task_provider = Application.fetch_env!(:foreman_server, :task_provider)

      Application.put_env(
        :foreman_server,
        :task_provider,
        Keyword.put(task_provider, :providers, [])
      )

      ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)
      on_exit(fn -> Application.put_env(:foreman_server, :task_provider, task_provider) end)

      project_id = "kata-create-#{System.unique_integer([:positive])}"

      expect(KataRunnerMock, :cmd, fn ["--version"], _cwd, [] -> {:ok, "kata v0.23.0\n"} end)
      assert :ok = TaskProviderRegistry.register_for_project(project_id, KataAdapter, @config)

      {:ok, project_id: project_id}
    end

    test "creates the issue from the attrs and returns it", %{project_id: project_id} do
      created =
        kata_issue(%{
          "short_id" => "4sjq",
          "title" => "Add login",
          "body" => "OAuth flow",
          "priority" => 0,
          "metadata" => %{"foreman.task_id" => "tsk-1"}
        })

      expect_kata(
        [
          "create",
          "--idempotency-key",
          "dedupe-1",
          "--json",
          "--body",
          "OAuth flow",
          "--priority",
          "0",
          "--label",
          "foreman-exec",
          "--label",
          "bug",
          "--meta",
          "foreman.task_id=tsk-1",
          "--meta",
          "foreman.command_id=cmd-1",
          "--meta",
          "foreman.task_type=feature",
          "--",
          "Add login"
        ],
        ok(mutation(created, "issue.created"))
      )

      attrs = %{
        task_id: "tsk-1",
        command_id: "cmd-1",
        title: "Add login",
        description: "OAuth flow",
        priority: 0,
        task_type: "feature",
        dedupe_key: "dedupe-1",
        labels: ["foreman-exec", "bug"]
      }

      assert {:ok, %Issue{} = issue} = KataAdapter.create(project_id, attrs)
      assert issue.id == "4sjq"
      assert issue.title == "Add login"
      assert issue.description == "OAuth flow"
      assert issue.priority == 0
      assert issue.metadata["metadata"] == %{"foreman.task_id" => "tsk-1"}
    end

    test "omits the optional flags and keys the create on the command id", %{
      project_id: project_id
    } do
      expect_kata(
        [
          "create",
          "--idempotency-key",
          "cmd-1",
          "--json",
          "--meta",
          "foreman.task_id=tsk-1",
          "--meta",
          "foreman.command_id=cmd-1",
          "--",
          "-a title that starts with a dash"
        ],
        ok(
          mutation(kata_issue(%{"title" => "-a title that starts with a dash"}), "issue.created")
        )
      )

      attrs = %{task_id: "tsk-1", command_id: "cmd-1", title: "-a title that starts with a dash"}

      assert {:ok, %Issue{title: "-a title that starts with a dash", priority: nil}} =
               KataAdapter.create(project_id, attrs)
    end

    test "a replayed create (changed: false) returns the original issue", %{
      project_id: project_id
    } do
      expect(KataRunnerMock, :cmd, fn ["create" | _], @cwd, [] ->
        ok(%{"changed" => false, "event" => nil, "issue" => kata_issue(%{"short_id" => "4sjq"})})
      end)

      assert {:ok, %Issue{id: "4sjq"}} =
               KataAdapter.create(project_id, %{task_id: "t", command_id: "c", title: "x"})
    end

    test "refuses invalid attrs before running anything", %{project_id: project_id} do
      valid = %{task_id: "t", command_id: "c", title: "x"}

      for {attrs, code} <- [
            {Map.put(valid, :title, ""), "INVALID_TITLE"},
            {Map.delete(valid, :task_id), "INVALID_TITLE"},
            {Map.put(valid, :command_id, ""), "INVALID_TITLE"},
            {Map.put(valid, :priority, 5), "INVALID_PRIORITY"},
            {Map.put(valid, :priority, "1"), "INVALID_PRIORITY"},
            {Map.put(valid, :labels, ["a,b"]), "VALIDATION_FAILED"},
            {Map.put(valid, :labels, "bug"), "VALIDATION_FAILED"},
            {Map.put(valid, :task_type, 3), "INVALID_ISSUE_TYPE"}
          ] do
        assert {:error, %ProviderError{code: ^code, retryable?: false}} =
                 KataAdapter.create(project_id, attrs)
      end
    end

    test "returns success only when kata reports it", %{project_id: project_id} do
      expect(KataRunnerMock, :cmd, fn ["create" | _], @cwd, [] -> runner_exit(5, 200) end)

      assert_kata_error(
        KataAdapter.create(project_id, %{task_id: "t", command_id: "c", title: "x"}),
        "BR_ERROR_ENVELOPE",
        false,
        exit_code: 5,
        stderr_byte_count: 200
      )

      expect(KataRunnerMock, :cmd, fn ["create" | _], @cwd, [] ->
        ok(%{"changed" => true, "issue" => %{"title" => "x"}})
      end)

      assert_kata_error(
        KataAdapter.create(project_id, %{task_id: "t", command_id: "c", title: "x"}),
        "SCHEMA_VALIDATION_FAILED",
        false,
        missing_fields: ["short_id", "status"]
      )
    end

    test "an unregistered project is a typed validation error, not a guess" do
      assert_kata_error(
        KataAdapter.create("no-such-project", %{task_id: "t", command_id: "c", title: "x"}),
        "VALIDATION_FAILED",
        false
      )
    end
  end

  ## Error envelope (T029-TEST): every path keyed on the failing verb and exit code

  describe "error envelope: verb and exit code mapping (AC-007-1, AC-007-2)" do
    @mapping [
      # {verb, exit status, code, retryable?}
      {"claim", 5, "CLAIMED_BY_OTHER", false},
      {"unassign", 5, "CLAIMED_BY_OTHER", false},
      {"comment", 5, "BR_ERROR_ENVELOPE", false},
      {"close", 5, "BR_ERROR_ENVELOPE", false},
      {"create", 5, "BR_ERROR_ENVELOPE", false},
      {"edit", 5, "BR_ERROR_ENVELOPE", false},
      {"show", 4, "ISSUE_NOT_FOUND", false},
      {"claim", 4, "ISSUE_NOT_FOUND", false},
      {"edit", 3, "VALIDATION_FAILED", false},
      {"close", 3, "VALIDATION_FAILED", false},
      {"ready", 7, "BR_TIMEOUT_SUBPROCESS", true},
      {"claim", 7, "BR_TIMEOUT_SUBPROCESS", true},
      {"ready", 8, "BR_TIMEOUT_SUBPROCESS", true},
      {"show", 1, "BR_ERROR_ENVELOPE", false},
      {"show", 2, "BR_ERROR_ENVELOPE", false},
      {"close", 6, "BR_ERROR_ENVELOPE", false},
      {"show", 127, "BR_ERROR_ENVELOPE", false},
      {"claim", 137, "BR_ERROR_ENVELOPE", false}
    ]

    for {verb, exit_code, code, retryable?} <- @mapping do
      test "kata #{verb} exiting #{exit_code} is #{code}, retryable? #{retryable?}" do
        {:error, runner_error} = runner_exit(unquote(exit_code), 77)

        error =
          BuildProviderError.from_runner_error([unquote(verb), "abc4", "--json"], runner_error)

        assert_kata_error({:error, error}, unquote(code), unquote(retryable?),
          exit_code: unquote(exit_code),
          stderr_byte_count: 77
        )
      end
    end

    test "a runner timeout keeps its code, is retryable and has no exit code" do
      {:error, runner_error} = runner_timeout(12)

      error = BuildProviderError.from_runner_error(["ready", "--unowned", "--json"], runner_error)

      assert_kata_error({:error, error}, "BR_TIMEOUT_SUBPROCESS", true, stderr_byte_count: 12)
    end

    test "a missing working directory keeps WORKSPACE_NOT_FOUND" do
      {:error, runner_error} = runner_workspace_missing()

      error = BuildProviderError.from_runner_error(["ready", "--json"], runner_error)

      assert_kata_error({:error, error}, "WORKSPACE_NOT_FOUND", false)
    end

    test "a port that closed without an exit status stays a generic non-retryable envelope" do
      {:error, runner_error} = runner_port_closed()

      error = BuildProviderError.from_runner_error(["show", "abc4", "--json"], runner_error)

      assert_kata_error({:error, error}, "BR_ERROR_ENVELOPE", false, stderr_byte_count: 4)
    end

    test "the same exit status maps differently for different verbs" do
      {:error, five} = runner_exit(5)

      assert BuildProviderError.from_runner_error(["claim", "a"], five).code == "CLAIMED_BY_OTHER"

      assert BuildProviderError.from_runner_error(["unassign", "a"], five).code ==
               "CLAIMED_BY_OTHER"

      assert BuildProviderError.from_runner_error(["comment", "a"], five).code ==
               "BR_ERROR_ENVELOPE"
    end
  end

  describe "error envelope: adapter paths (T029-TEST)" do
    test "kata claim exit 5" do
      expect_kata(["claim", "j04d", "--if-unowned", "--json"], runner_exit(5, 143))

      assert_kata_error(KataAdapter.claim("j04d", nil, @config), "CLAIMED_BY_OTHER", false,
        exit_code: 5,
        stderr_byte_count: 143
      )
    end

    test "kata unassign exit 5" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "ldangelo")))
      expect_kata(["reopen", "j04d", "--json"], ok(%{"changed" => false}))
      expect(KataRunnerMock, :cmd, fn ["comment" | _], @cwd, [] -> ok(%{"changed" => true}) end)
      expect(KataRunnerMock, :cmd, fn ["unassign" | _], @cwd, [] -> runner_exit(5, 154) end)

      assert_kata_error(
        KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
        "CLAIMED_BY_OTHER",
        false,
        exit_code: 5,
        stderr_byte_count: 154
      )
    end

    test "kata comment exit 5" do
      expect(KataRunnerMock, :cmd, fn ["comment" | _], @cwd, [] -> runner_exit(5, 120) end)

      assert_kata_error(KataAdapter.annotate("j04d", "body", @config), "BR_ERROR_ENVELOPE", false,
        exit_code: 5,
        stderr_byte_count: 120
      )
    end

    test "exit 4" do
      expect(KataRunnerMock, :cmd, fn ["show" | _], @cwd, [] -> runner_exit(4, 52) end)

      assert_kata_error(KataAdapter.get("zzzz", @config), "ISSUE_NOT_FOUND", false,
        exit_code: 4,
        stderr_byte_count: 52
      )
    end

    test "exit 3" do
      expect(KataRunnerMock, :cmd, fn ["edit" | _], @cwd, [] -> runner_exit(3, 60) end)

      assert_kata_error(KataAdapter.set_priority("mwfm", 1, @config), "VALIDATION_FAILED", false,
        exit_code: 3,
        stderr_byte_count: 60
      )
    end

    test "exit 7 and exit 8" do
      for exit_code <- [7, 8] do
        expect(KataRunnerMock, :cmd, fn ["ready" | _], @cwd, [] -> runner_exit(exit_code, 33) end)

        assert_kata_error(KataAdapter.list_ready(@config, []), "BR_TIMEOUT_SUBPROCESS", true,
          exit_code: exit_code,
          stderr_byte_count: 33
        )
      end
    end

    test "runner timeout" do
      expect(KataRunnerMock, :cmd, fn ["ready" | _], @cwd, [] -> runner_timeout() end)

      assert_kata_error(KataAdapter.list_ready(@config, []), "BR_TIMEOUT_SUBPROCESS", true)
    end

    test "signal death" do
      expect(KataRunnerMock, :cmd, fn ["ready" | _], @cwd, [] -> runner_exit(137, 0) end)

      assert_kata_error(KataAdapter.list_ready(@config, []), "BR_ERROR_ENVELOPE", false,
        exit_code: 137
      )
    end

    test "unparseable stdout" do
      for stdout <- ["", "not json", "{\"issues\": [", "[]", "42", "null", "\"text\""] do
        expect(KataRunnerMock, :cmd, fn ["ready" | _], @cwd, [] -> {:ok, stdout} end)

        assert_kata_error(KataAdapter.list_ready(@config, []), "BR_PARSE_ERROR", false)
      end
    end

    test "a changed: false close is an already-terminal success" do
      expect(KataRunnerMock, :cmd, fn ["close" | _], @cwd, [] ->
        ok(%{"changed" => false, "event" => nil})
      end)

      assert KataAdapter.complete("j04d", %{run_id: "run-1", commit_sha: "abc123"}, @config) ==
               {:ok, :already_terminal}
    end

    test "the claimed-by-other guard of fail/3 names no owner and carries only the closed keys" do
      expect_kata(["status", "j04d", "--json"], ok(status("ldangelo", "owner-name-xyz")))

      error =
        assert_kata_error(
          KataAdapter.fail("j04d", failure_token("run-1", "boom"), @config),
          "CLAIMED_BY_OTHER",
          false
        )

      refute inspect(error) =~ "owner-name-xyz"
      refute Map.has_key?(error.context, :current_assignee_present?)
      refute Map.has_key?(error.context, :current_owner)
    end
  end

  describe "error envelope through the real SystemKataRunner (stderr is never read)" do
    setup %{temp_dir: temp_dir} do
      stub(KataRunnerMock, :cmd, &SystemKataRunner.cmd/3)
      {:ok, config: %{cwd: temp_dir}}
    end

    test "a claim kata refuses with the owner named on stderr leaks nothing of it", %{
      temp_dir: temp_dir,
      config: config
    } do
      stderr =
        ~S|{"error":{"kind":"conflict","code":"already_claimed","message":"issue is already assigned to SECRET-OWNER","exit_code":5,"data":{"current_owner":"SECRET-OWNER"}}}|

      with_fake_kata(temp_dir, "printf '%s' '#{stderr}' >&2\nexit 5", fn ->
        error =
          assert_kata_error(
            KataAdapter.claim("j04d", nil, config),
            "CLAIMED_BY_OTHER",
            false,
            exit_code: 5,
            stderr_byte_count: byte_size(stderr)
          )

        refute inspect(error) =~ "SECRET-OWNER"
        refute inspect(error) =~ "already_claimed"
        refute inspect(error) =~ "current_owner"
      end)
    end

    test "a successful kata call is decoded through the real runner", %{
      temp_dir: temp_dir,
      config: config
    } do
      payload = Jason.encode!(%{"issues" => [ready_record(%{"short_id" => "j04d"})]})

      with_fake_kata(temp_dir, "printf '%s' '#{payload}'", fn ->
        assert {:ok, [%Issue{id: "j04d"}]} = KataAdapter.list_ready(config, [])
      end)
    end

    test "a missing working directory is WORKSPACE_NOT_FOUND", %{temp_dir: temp_dir} do
      with_fake_kata(temp_dir, "echo unreachable", fn ->
        assert_kata_error(
          KataAdapter.list_ready(%{cwd: Path.join(temp_dir, "missing")}, []),
          "WORKSPACE_NOT_FOUND",
          false
        )
      end)
    end

    test "kata exiting 4 on show is ISSUE_NOT_FOUND", %{temp_dir: temp_dir, config: config} do
      with_fake_kata(temp_dir, "echo '{\"error\":{}}' >&2\nexit 4", fn ->
        assert_kata_error(KataAdapter.get("zzzz", config), "ISSUE_NOT_FOUND", false,
          exit_code: 4,
          stderr_byte_count: byte_size("{\"error\":{}}\n")
        )
      end)
    end
  end

  describe "BuildProviderError (AC-007-1, AC-007-2, AC-007-3)" do
    @codes_from_code_map ~w(
      ISSUE_NOT_FOUND VALIDATION_FAILED SCHEMA_VALIDATION_FAILED BR_ERROR_ENVELOPE
      BR_TIMEOUT_SUBPROCESS BR_TIMEOUT_QUEUE BR_PARSE_ERROR BR_CONTRACT_MISMATCH
      WORKSPACE_NOT_FOUND INVALID_TASK_ID INVALID_PRIORITY INVALID_TITLE INVALID_ISSUE_TYPE
      INVALID_TRANSITION_COMMENT DEPENDENCY_CYCLE NOT_IN_WORKSPACE BR_DATABASE_LOCKED
    )

    test "a known code maps to itself with the retryable flag CodeMap holds for it" do
      for code <- @codes_from_code_map do
        input = ProviderErrorInput.from_local(code, "msg", "hint", false)
        from_code_map = CodeMap.build_provider_error(input, nil, 0)

        error = BuildProviderError.build_provider_error(input, nil, 0)

        assert error.code == from_code_map.code
        assert error.code == code
        assert error.retryable? == from_code_map.retryable?, "retryable? differs for #{code}"
      end
    end

    test "the message and hint are the caller's, in Kata terms, not CodeMap's" do
      input =
        ProviderErrorInput.from_local("BR_PARSE_ERROR", "Kata output broke.", "Do x.", false)

      error = BuildProviderError.build_provider_error(input, nil, 0)

      assert error.message == "Kata output broke."
      assert error.hint == "Do x."
    end

    test "CLAIMED_BY_OTHER is never retryable, overriding the CodeMap default" do
      input = ProviderErrorInput.from_local("CLAIMED_BY_OTHER", "msg", "hint", true)

      assert BuildProviderError.build_provider_error(input, nil, 0).retryable? == false
    end

    test "redacted_fields is the Kata literal for every code, CodeMap's per-code list never copied" do
      for code <- ["CLAIMED_BY_OTHER" | @codes_from_code_map] do
        error =
          code
          |> ProviderErrorInput.from_local("msg", nil, false)
          |> BuildProviderError.build_provider_error(nil, 0)

        assert error.context.redacted_fields == ["assignee", "description"], code
      end
    end

    test "an unrecognized code degrades to BR_ERROR_ENVELOPE: no raise, no raw string, no new code" do
      for unknown <- ["NOT_A_CODE", :some_atom_code, "kata_specific"] do
        input = ProviderErrorInput.from_local(unknown, "Kata said something odd.", nil, false)

        assert %ProviderError{} = error = BuildProviderError.build_provider_error(input, 9, 5)
        assert error.code == "BR_ERROR_ENVELOPE"
        assert error.retryable? == false
        assert error.message == "Kata said something odd."
        assert error.context.id == to_string(unknown)
        assert error.context.exit_code == 9
      end
    end

    test "every error carries command.binary kata, the id, the exit code and the stderr byte count" do
      error =
        "ISSUE_NOT_FOUND"
        |> ProviderErrorInput.from_local("m", nil, false)
        |> BuildProviderError.build_provider_error(4, 321)

      assert error.context == %{
               id: "ISSUE_NOT_FOUND",
               command: %{binary: "kata"},
               exit_code: 4,
               stderr_byte_count: 321,
               sanitized?: true,
               redacted_fields: ["assignee", "description"],
               missing_fields: []
             }

      assert Enum.sort(Map.keys(error.context)) == @closed_context_keys
      assert Enum.sort(BuildProviderError.context_keys()) == @closed_context_keys
    end

    test "missing_fields names absent payload fields" do
      error =
        "SCHEMA_VALIDATION_FAILED"
        |> ProviderErrorInput.from_local("m", nil, false, ["short_id", "title"])
        |> BuildProviderError.build_provider_error(nil, 0)

      assert error.context.missing_fields == ["short_id", "title"]
    end

    test "rejects a negative stderr byte count and a non-integer exit code" do
      input = ProviderErrorInput.from_local("BR_ERROR_ENVELOPE", "m", nil, false)

      assert_raise FunctionClauseError, fn ->
        apply(BuildProviderError, :build_provider_error, [input, nil, -1])
      end

      assert_raise FunctionClauseError, fn ->
        apply(BuildProviderError, :build_provider_error, [input, "5", 0])
      end
    end
  end

  ## T019: one construction site

  describe "single ProviderError construction site (AC-007-4, T019)" do
    @kata_files [
      "kata_adapter.ex",
      "kata_runner.ex",
      "system_kata_runner.ex",
      "kata_adapter/build_provider_error.ex"
    ]

    test "no Kata module but BuildProviderError creates a ProviderError" do
      for file <- @kata_files -- ["kata_adapter/build_provider_error.ex"] do
        assert construction_lines(Path.join(@lib_root, file)) == [],
               "#{file} builds a ProviderError itself instead of calling BuildProviderError"
      end
    end

    test "BuildProviderError creates exactly one" do
      assert [_one] =
               construction_lines(Path.join(@lib_root, "kata_adapter/build_provider_error.ex"))
    end

    test "the scanner finds every way of building a ProviderError and ignores patterns" do
      constructing = [
        "ProviderError.new(\"X\", \"m\")",
        "ForemanServer.TaskProviders.ProviderError.new(\"X\", \"m\")",
        "struct(ProviderError, code: \"X\")",
        "struct!(ProviderError, code: \"X\")",
        "%ProviderError{code: \"X\", message: \"m\", hint: nil, retryable?: false, context: %{}}"
      ]

      for expression <- constructing do
        source = "defmodule Fixture do\n  def build, do: #{expression}\nend\n"

        assert construction_lines_in(source) == [2], "scanner missed: #{expression}"
      end

      patterns = """
      defmodule Fixture do
        def match(%ProviderError{code: "X", context: %{exit_code: code}} = error), do: {code, error}
        def retry(%ProviderError{retryable?: true}), do: :retry
        def update(error), do: %{error | context: %{}}
      end
      """

      assert construction_lines_in(patterns) == []
    end
  end

  ## Helpers

  defp expect_kata(argv, reply) do
    expect(KataRunnerMock, :cmd, fn actual_argv, cwd, opts ->
      assert actual_argv == argv
      assert cwd == @cwd
      assert opts == []
      reply
    end)
  end

  defp ok(payload), do: {:ok, Jason.encode!(payload)}

  defp assert_kata_error(result, code, retryable?, opts \\ []) do
    assert {:error, %ProviderError{} = error} = result

    assert error.code == code
    assert error.retryable? == retryable?
    assert Enum.sort(Map.keys(error.context)) == @closed_context_keys
    assert error.context.command == %{binary: "kata"}
    assert error.context.sanitized? == true
    assert error.context.redacted_fields == ["assignee", "description"]
    assert error.context.exit_code == Keyword.get(opts, :exit_code)
    assert error.context.stderr_byte_count == Keyword.get(opts, :stderr_byte_count, 0)
    assert error.context.missing_fields == Keyword.get(opts, :missing_fields, [])
    refute inspect(error.context) =~ "current_owner"

    error
  end

  # The errors below are shaped exactly as `SystemKataRunner` returns them.
  defp runner_exit(exit_code, stderr_byte_count \\ 0) do
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

  defp runner_timeout(stderr_byte_count \\ 0) do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_TIMEOUT_SUBPROCESS",
         "Kata command timed out while the subprocess was running.",
         "Retry the command after checking Kata responsiveness.",
         false
       ),
       nil,
       stderr_byte_count
     )}
  end

  defp runner_workspace_missing do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "WORKSPACE_NOT_FOUND",
         "Kata working directory does not exist.",
         "Verify the project path before retrying.",
         false
       ),
       nil,
       0
     )}
  end

  defp runner_port_closed do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_ERROR_ENVELOPE",
         "Kata CLI port closed without an exit status.",
         nil,
         false
       ),
       nil,
       4
     )}
  end

  defp kata_issue(overrides \\ %{}) do
    Map.merge(
      %{
        "source_actor" => "alice",
        "verification" => "legacy",
        "id" => 3,
        "uid" => "01M7SJBGQSWGVAJKVM2F82ZQ27",
        "project_id" => 2,
        "project_uid" => "01M7SJAKPPH5JV4W15VR8J71VE",
        "short_id" => "zq27",
        "title" => "Third task",
        "body" => "third body",
        "status" => "open",
        "author" => "alice",
        "metadata" => %{},
        "revision" => 1,
        "created_at" => "2026-11-19T09:31:40.665Z",
        "updated_at" => "2026-11-19T09:31:40.665Z"
      },
      overrides
    )
  end

  defp ready_record(overrides) do
    kata_issue(
      Map.merge(
        %{
          "qualified_id" => "ws#zq27",
          "web_url" => "http://127.0.0.1:65448/kata?issue=01M7SJBGQSWGVAJKVM2F82ZQ27#direct=1"
        },
        overrides
      )
    )
  end

  defp show_payload(issue, opts \\ []) do
    labels = Keyword.get(opts, :labels, [])

    %{
      "kata_api_version" => 1,
      "issue" => issue,
      "comments" => [],
      "comments_truncated" => false,
      "links" => Keyword.get(opts, :links, []),
      "labels" =>
        if(is_list(labels),
          do: Enum.map(labels, &%{"issue_id" => 3, "label" => &1, "author" => "alice"}),
          else: labels
        ),
      "web_url" => "http://127.0.0.1:65448/kata?issue=#{issue["uid"]}#direct=1"
    }
  end

  defp link(type, {from_short, from_uid}, {to_short, to_uid}) do
    %{
      "id" => 1,
      "type" => type,
      "from" => %{
        "uid" => from_uid,
        "short_id" => from_short,
        "project" => "ws",
        "status" => "open"
      },
      "to" => %{"uid" => to_uid, "short_id" => to_short, "project" => "ws", "status" => "open"}
    }
  end

  defp mutation(issue, event_type, changed \\ true) do
    %{
      "kata_api_version" => 1,
      "changed" => changed,
      "issue" => issue,
      "event" => %{"type" => event_type, "actor" => "ldangelo"}
    }
  end

  defp status(actor, owner) do
    base = %{
      "kata_api_version" => 1,
      "issue" => "j04d",
      "issue_status" => "open",
      "actor" => actor,
      "actor_source" => "user",
      "hold" => if(owner, do: "assigned", else: "unassigned")
    }

    if owner, do: Map.put(base, "owner", owner), else: base
  end

  defp failure_token(run_id, reason) do
    %{
      run_id: run_id,
      artifact_path: "artifacts/out.md",
      reason: reason,
      transition_comment: "foreman-run:#{run_id}:artifacts/out.md"
    }
  end

  defp failure_key(run_id, body) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "foreman-fail:#{run_id}:#{hash}"
  end

  defp close_message(artifact_path) do
    message = "foreman-run:run-1:#{artifact_path}"

    if String.length(message) >= 40,
      do: message,
      else: message <> " - closed by the Foreman task runner"
  end

  defp put_fake_kata_on_path(temp_dir) do
    bin_dir = Path.join(temp_dir, "bin")
    File.mkdir_p!(bin_dir)
    script = Path.join(bin_dir, "kata")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp with_fake_kata(temp_dir, body, fun) do
    original_path = System.get_env("PATH") || ""
    script = Path.join(temp_dir, "kata")
    File.write!(script, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(script, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  # Lines of `ProviderError` constructions: `ProviderError.new/2,3`, `struct(!)(ProviderError, ..)`
  # and a struct literal with every enforced key (a pattern can name fewer).
  @enforced_keys [:code, :message, :hint, :retryable?, :context]

  defp construction_lines(file), do: file |> File.read!() |> construction_lines_in()

  defp construction_lines_in(source) do
    {_ast, lines} =
      source
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn node, acc ->
        if construction?(node), do: {node, [node_line(node) | acc]}, else: {node, acc}
      end)

    Enum.reverse(lines)
  end

  defp construction?({{:., _, [{:__aliases__, _, aliases}, :new]}, _, _args}),
    do: provider_error_alias?(aliases)

  defp construction?({struct_fun, _, [{:__aliases__, _, aliases} | _rest]})
       when struct_fun in [:struct, :struct!],
       do: provider_error_alias?(aliases)

  defp construction?({:%, _, [{:__aliases__, _, aliases}, {:%{}, _, pairs}]}) do
    provider_error_alias?(aliases) and Enum.all?(@enforced_keys, &Keyword.has_key?(pairs, &1))
  end

  defp construction?(_node), do: false

  defp provider_error_alias?(aliases), do: List.last(aliases) == :ProviderError

  defp node_line({_, meta, _}), do: meta[:line]
end
