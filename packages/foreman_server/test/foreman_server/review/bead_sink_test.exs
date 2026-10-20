defmodule ForemanServer.Review.BeadSinkTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.BeadSink
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Gap
  alias ForemanServer.Review.Subject
  alias ForemanServer.Review.Verdict
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.SystemBrRunner
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @moduletag :tmp_dir

  @db "/abs/review/beads.db"
  @project "proj-review"
  @archive "/archive/run/run-1"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ProjectionStoreReset.reset!()
    previous_provider_config = Application.get_env(:foreman_server, :task_provider, [])
    previous_review = Application.get_env(:foreman_server, :review, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_provider_config)
      Application.put_env(:foreman_server, :review, previous_review)
      ProjectionStoreReset.reset!()
      stop_schema_cache()
    end)

    :ok
  end

  describe "publish/2 without a bead" do
    test "returns an empty result and never invokes br" do
      # The default stub for this suite flunks on any BrRunnerMock call; the
      # project is not even registered, so any provider lookup would error too.
      assert {:ok, %{gap_bead_ids: [], note: nil}} =
               BeadSink.publish(subject(bead_id: nil), verdict(gaps: [gap(:major, "A")]))
    end
  end

  describe "publish/2 with a bead but no project_id" do
    test "skips the bead step with a note and never resolves a provider or invokes br" do
      assert {:ok, %{gap_bead_ids: [], note: "no project_id: bead step skipped"}} =
               BeadSink.publish(
                 subject(project_id: nil, bead_id: "bead-src"),
                 verdict(gaps: [gap(:major, "A")])
               )
    end
  end

  describe "publish/2 comment + gap beads" do
    test "posts the verdict comment and files one labelled bead per gap", %{tmp_dir: tmp} do
      register_project!()
      install_stub([])

      gaps = [gap(:major, "Missing route"), gap(:minor, "Docs stale")]
      v = verdict(gaps: gaps)

      assert {:ok, %{gap_bead_ids: ["bead-for-Missing route", "bead-for-Docs stale"], note: nil}} =
               BeadSink.publish(subject(), v)

      expected_body = Verdict.to_markdown(v) <> "\n\nFull analysis: #{@archive}/analysis.md"
      assert_received {:br, :comment, %{id: "bead-src", body: ^expected_body}}

      assert_received {:br, :create, major}
      assert_received {:br, :create, minor}
      refute_received {:br, :create, _}

      assert major.title == "Missing route"
      assert major.type == "bug"
      assert major.priority == 1
      assert minor.title == "Docs stale"
      assert minor.type == "chore"
      assert minor.priority == 3
      assert major.labels == ["foreman-exec", "foreman-gap"]
      assert minor.labels == ["foreman-exec", "foreman-gap"]

      # The gap bead is dispatched to a fresh agent: the description must stand alone.
      assert major.description =~ "Missing route description"
      assert major.description =~ "bead-src"
      assert major.description =~ "run-1"
      assert major.description =~ @archive

      {:ok, %{"foreman" => ctx_major}} = Jason.decode(major.agent_context)
      {:ok, %{"foreman" => ctx_minor}} = Jason.decode(minor.agent_context)
      assert ctx_major["task_id"] == "review:run:run-1"
      assert ctx_major["command_id"] == "review:run-1:gap:1"
      assert ctx_minor["command_id"] == "review:run-1:gap:2"

      # Translate the exact payloads through the real br runner.
      # The fake br prints one argv element per line; the message spans several.
      comment_argv = argv_for(tmp, {:comments_add, %{id: "bead-src", body: expected_body}})
      assert ["comments", "add", "bead-src", "--message" | message_lines] = comment_argv
      assert List.last(message_lines) == "--json"

      assert message_lines |> Enum.drop(-1) |> Enum.join("\n") ==
               expected_body |> String.split("\n", trim: true) |> Enum.join("\n")
      create_argv = argv_for(tmp, {:create, major})
      assert ["--labels", "foreman-exec,foreman-gap"] = slice_after(create_argv, "--labels")
      assert Enum.at(create_argv, 0) == "create"
    end

    test "a source bead an earlier review filed as a gap bead yields zero gap beads but one comment" do
      register_project!()
      install_stub([])
      record_review_filing_gap_bead!("bead-src")

      assert {:ok, %{gap_bead_ids: [], note: note}} =
               BeadSink.publish(subject(), verdict(gaps: [gap(:major, "A"), gap(:minor, "B")]))

      assert note == "gap creation suppressed: source bead is itself a foreman-gap bead"
      assert_received {:br, :comment, %{id: "bead-src"}}
      refute_received {:br, :create, _}
    end

    test "a source bead no review listed as a gap bead still gets gap beads" do
      register_project!()
      install_stub([])
      record_review_filing_gap_bead!("some-other-bead")

      assert {:ok, %{gap_bead_ids: ["bead-for-A"], note: nil}} =
               BeadSink.publish(subject(), verdict(gaps: [gap(:major, "A")]))

      assert_received {:br, :comment, %{id: "bead-src"}}
      assert_received {:br, :create, %{title: "A"}}
    end

    test "a cancelled subject posts the comment but files no gap beads" do
      register_project!()
      install_stub([])

      assert {:ok, %{gap_bead_ids: [], note: note}} =
               BeadSink.publish(
                 subject(status: "cancelled"),
                 verdict(gaps: [gap(:major, "A")])
               )

      assert note =~ "cancelled"
      assert_received {:br, :comment, %{id: "bead-src"}}
      refute_received {:br, :create, _}
    end

    test "zero gaps posts the comment only" do
      register_project!()
      install_stub([])

      assert {:ok, %{gap_bead_ids: [], note: nil}} = BeadSink.publish(subject(), verdict(gaps: []))

      assert_received {:br, :comment, %{id: "bead-src"}}
      refute_received {:br, :create, _}
    end

    test "an undetermined verdict never files gap beads" do
      register_project!()
      install_stub([])

      v = verdict(verdict: :undetermined, gaps: [gap(:major, "A")], error_code: :evaluator_failed)

      assert {:ok, %{gap_bead_ids: [], note: nil}} = BeadSink.publish(subject(), v)
      assert_received {:br, :comment, _}
      refute_received {:br, :create, _}
    end

    test "gap beads beyond :max_gap_beads are not filed and the note says so" do
      register_project!()
      install_stub([])
      put_review(max_gap_beads: 2)

      gaps = for n <- 1..3, do: gap(:major, "G#{n}")

      assert {:ok, %{gap_bead_ids: ["bead-for-G1", "bead-for-G2"], note: note}} =
               BeadSink.publish(subject(), verdict(gaps: gaps))

      assert note =~ "1 gap(s) beyond max_gap_beads=2 not filed"
      refute_received {:br, :create, %{title: "G3"}}
    end

    test "one failing gap does not stop the rest and is named in the note" do
      register_project!()
      install_stub(fail_titles: ["G2"])

      gaps = for n <- 1..3, do: gap(:major, "G#{n}")

      assert {:ok, %{gap_bead_ids: ["bead-for-G1", "bead-for-G3"], note: note}} =
               BeadSink.publish(subject(), verdict(gaps: gaps))

      assert note =~ "gap bead creation failed"
      assert note =~ "gap 2"
    end

    test "every gap failing is a :bead_write_failed error" do
      register_project!()
      install_stub(fail_titles: ["G1", "G2"])

      gaps = for n <- 1..2, do: gap(:major, "G#{n}")

      assert {:error, %Error{code: :bead_write_failed}} =
               BeadSink.publish(subject(), verdict(gaps: gaps))
    end

    test "a failed comment is :bead_write_failed and no gap bead is created" do
      register_project!()
      install_stub(comment: :error)

      assert {:error, %Error{code: :bead_write_failed}} =
               BeadSink.publish(subject(), verdict(gaps: [gap(:major, "A")]))

      refute_received {:br, :create, _}
    end

    test "an unregistered project is :bead_unresolved with no br invocation" do
      assert {:error, %Error{code: :bead_unresolved}} =
               BeadSink.publish(
                 subject(project_id: "proj-unknown"),
                 verdict(gaps: [gap(:major, "A")])
               )
    end

    test "an oversized comment is cut on a UTF-8 boundary and still ends with the archive pointer" do
      register_project!()
      install_stub([])
      put_review(max_comment_bytes: 300)

      v = verdict(summary: String.duplicate("é", 1_000), gaps: [])

      assert {:ok, _} = BeadSink.publish(subject(), v)
      assert_received {:br, :comment, %{body: body}}

      assert byte_size(body) <= 300
      assert String.valid?(body)
      assert String.ends_with?(body, "Full analysis: #{@archive}/analysis.md")
      assert body =~ "truncated"
    end
  end

  ## Helpers

  defp subject(overrides \\ []) do
    struct!(
      Subject,
      Keyword.merge(
        [
          kind: :run,
          subject_id: "run-1",
          project_id: @project,
          repo_path: "/repo",
          archive_dir: @archive,
          status: "completed",
          bead_id: "bead-src",
          request_title: "Add a route",
          request_text: "Add /healthz"
        ],
        overrides
      )
    )
  end

  defp verdict(overrides) do
    struct!(
      Verdict,
      Keyword.merge(
        [
          verdict: :partially_met,
          scores: %{correctness: 3, tests: 2, documentation: 4, robustness: 3},
          summary: "Mostly done.",
          gaps: []
        ],
        overrides
      )
    )
  end

  defp gap(severity, title) do
    %Gap{
      title: title,
      description: "#{title} description",
      dimension: :tests,
      severity: severity
    }
  end

  # Records a real review (through the command gateway, as the Analyzer does)
  # whose `gap_bead_ids` contains `bead_id`, and waits until it is projected.
  defp record_review_filing_gap_bead!(bead_id) do
    subject_id = "review-src-#{System.unique_integer([:positive])}"
    id = "review:run:" <> subject_id

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "review.record",
               command_id: id,
               aggregate_id: id,
               payload: %{
                 subject_kind: "run",
                 subject_id: subject_id,
                 project_id: @project,
                 bead_id: "bead-origin",
                 verdict: "partially_met",
                 scores: %{"correctness" => 3},
                 summary: "filed a gap",
                 gap_bead_ids: [bead_id],
                 archive_path: nil,
                 analysis_path: nil,
                 evaluator: "stub",
                 error_code: nil,
                 at: DateTime.to_iso8601(DateTime.utc_now())
               }
             })

    assert await(fn -> ProjectionStore.gap_bead?(bead_id) || nil end)
  end

  defp await(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        await(fun, tries - 1)

      other ->
        other
    end
  end

  defp put_review(overrides) do
    current = Application.get_env(:foreman_server, :review, [])
    Application.put_env(:foreman_server, :review, Keyword.merge(current, overrides))
  end

  defp register_project! do
    assert :ok = Registry.register_for_project(@project, BeadsAdapter, %{database_path: @db})
  end

  # opts: comment: :error, fail_titles: [..]
  defp install_stub(opts) do
    test = self()
    fail_titles = Keyword.get(opts, :fail_titles, [])

    stub(BrRunnerMock, :cmd, fn
      {:schema, %{schema: name}}, _cfg, _opts ->
        {:ok, %{stdout: Jason.encode!(schema_document(name))}}

      {:comments_add, payload}, _cfg, _opts ->
        send(test, {:br, :comment, payload})

        case Keyword.get(opts, :comment) do
          :error -> {:error, %{stdout: "", stderr: "db locked", exit_code: 1}}
          nil -> {:ok, %{stdout: "", stderr: "", exit_code: 0}}
        end

      {:create, payload}, _cfg, _opts ->
        send(test, {:br, :create, payload})

        if payload.title in fail_titles do
          {:error, %{stdout: "", stderr: "create refused", exit_code: 1}}
        else
          body =
            issue_payload(%{
              "id" => "bead-for-" <> payload.title,
              "title" => payload.title,
              "priority" => payload.priority,
              "labels" => payload.labels
            })

          {:ok, %{stdout: Jason.encode!(body), stderr: "", exit_code: 0}}
        end
    end)

    start_supervised!(JsonSchemaCache)
  end

  defp issue_payload(overrides) do
    Map.merge(
      %{
        "id" => "bead-default",
        "title" => "Default issue",
        "status" => "open",
        "priority" => 2,
        "dependencies" => [],
        "dependents" => [],
        "assignee" => nil,
        "description" => nil,
        "notes" => nil,
        "design" => nil,
        "labels" => [],
        "metadata" => %{}
      },
      overrides
    )
  end

  defp argv_for(tmp_dir, request) do
    script = Path.join(tmp_dir, "br")

    File.write!(script, """
    #!/bin/sh
    set -eu
    for arg in "$@"; do
      printf '%s\\n' "$arg"
    done
    """)

    File.chmod!(script, 0o755)
    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", tmp_dir <> ":" <> original_path)

    try do
      assert {:ok, %{stdout: stdout}} = SystemBrRunner.cmd(request, %{database_path: @db})
      stdout |> String.split("\n", trim: true) |> drop_db()
    after
      System.put_env("PATH", original_path)
    end
  end

  # argv looks like [sub..., "--db", path, ...]; drop the db pair so tests state the meaningful part.
  defp drop_db(argv) do
    case Enum.find_index(argv, &(&1 == "--db")) do
      nil -> argv
      i -> List.delete_at(List.delete_at(argv, i), i)
    end
  end

  defp slice_after(argv, flag) do
    i = Enum.find_index(argv, &(&1 == flag))
    Enum.slice(argv, i, 2)
  end

  defp stop_schema_cache do
    case Process.whereis(:foreman_server_json_schema_cache) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp schema_document("ready-issue") do
    %{
      "type" => "object",
      "required" => ~w(id title status priority dependencies assignee description notes design labels metadata),
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "priority" => %{"type" => "integer"},
        "dependencies" => %{"type" => "array"},
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
      }
    }
  end

  defp schema_document("issue-details") do
    required =
      ~w(id title status priority dependencies dependents assignee description notes design labels metadata)

    properties = %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"},
      "dependencies" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/issue"}},
      "dependents" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/issue"}},
      "assignee" => %{"type" => ["string", "null"]},
      "description" => %{"type" => ["string", "null"]},
      "notes" => %{"type" => ["string", "null"]},
      "design" => %{"type" => ["string", "null"]},
      "labels" => %{"type" => "array"},
      "metadata" => %{"type" => "object"}
    }

    %{
      "$defs" => %{
        "issue" => %{"type" => "object", "required" => required, "properties" => properties}
      },
      "type" => "object",
      "required" => required,
      "properties" => properties
    }
  end

  defp schema_document("error") do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{"code" => %{"type" => "string"}, "message" => %{"type" => "string"}}
    }
  end

  defp schema_document("commands") do
    %{
      "type" => "object",
      "metadata" => %{"contractVersion" => "br.capabilities.v1"},
      "properties" => %{"commands" => %{"type" => "array"}}
    }
  end
end
