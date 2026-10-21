defmodule ForemanServer.Review.EvaluatorAgentTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Review.{Archive, Error, Gap, Subject, Verdict}
  alias ForemanServer.Review.Evaluator.Agent
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "review evaluator stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [:model, :reasoning_effort, :sandbox_mode, :approval_mode],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, _context) do
      {pid, mode} = Application.fetch_env!(:foreman_server, :review_evaluator_test_stub)
      send(pid, {:request, request})

      case mode do
        {:reply, text} ->
          {:ok,
           [
             Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => text}),
             Event.new!(provider: :pi, type: :run_completed, payload: %{})
           ]}

        :fail ->
          {:ok,
           [
             Event.new!(provider: :pi, type: :run_failed, payload: %{"text" => "boom"})
           ]}
      end
    end

    @impl true
    def cancel(_run_id, _context), do: :ok
  end

  @valid %{
    "verdict" => "partially_met",
    "scores" => %{"correctness" => 4, "tests" => 2, "documentation" => 3, "robustness" => 5},
    "summary" => "Works but untested.",
    "gaps" => [
      %{
        "title" => "Add tests",
        "description" => "Cover Foo.bar/1 in test/foo_test.exs.",
        "dimension" => "tests",
        "severity" => "major"
      }
    ]
  }

  defp block(map), do: "Review done.\n\n```json\n" <> Jason.encode!(map) <> "\n```\n"

  describe "parse_verdict/1" do
    test "a well-formed block becomes a fully typed verdict" do
      assert {:ok, %Verdict{} = verdict} = Agent.parse_verdict(block(@valid))
      assert verdict.verdict == :partially_met
      assert verdict.scores == %{correctness: 4, tests: 2, documentation: 3, robustness: 5}
      assert verdict.summary == "Works but untested."
      assert verdict.error_code == nil

      assert [
               %Gap{
                 title: "Add tests",
                 dimension: :tests,
                 severity: :major,
                 description: "Cover Foo.bar/1 in test/foo_test.exs."
               }
             ] = verdict.gaps
    end

    test "the LAST json block wins" do
      first = block(%{@valid | "verdict" => "not_met"})

      assert {:ok, %Verdict{verdict: :met}} =
               Agent.parse_verdict(first <> block(%{@valid | "verdict" => "met", "gaps" => []}))
    end

    test "empty gaps are valid" do
      assert {:ok, %Verdict{gaps: []}} = Agent.parse_verdict(block(%{@valid | "gaps" => []}))
    end

    @malformed_cases [
      "no block",
      "undecodable json",
      "non-object json",
      "unknown verdict",
      "undetermined verdict",
      "score zero",
      "score six",
      "float score",
      "missing dimension score",
      "extra score key",
      "missing summary",
      "missing gaps",
      "gap missing dimension",
      "gap unknown dimension",
      "gap unknown severity",
      "gap empty title"
    ]

    for name <- @malformed_cases do
      test "rejects: #{name}" do
        assert {:error, %Error{code: :evaluator_malformed_output}} =
                 Agent.parse_verdict(malformed_text(unquote(name), @valid))
      end
    end
  end

  defp malformed_text("no block", _), do: "I think it is fine."
  defp malformed_text("undecodable json", _), do: "```json\n{nope\n```"
  defp malformed_text("non-object json", _), do: "```json\n[1]\n```"
  defp malformed_text("unknown verdict", v), do: block(%{v | "verdict" => "great"})
  defp malformed_text("undetermined verdict", v), do: block(%{v | "verdict" => "undetermined"})
  defp malformed_text("score zero", v), do: block(put_in(v, ["scores", "tests"], 0))
  defp malformed_text("score six", v), do: block(put_in(v, ["scores", "tests"], 6))
  defp malformed_text("float score", v), do: block(put_in(v, ["scores", "tests"], 3.5))

  defp malformed_text("missing dimension score", v),
    do: block(update_in(v, ["scores"], &Map.delete(&1, "tests")))

  defp malformed_text("extra score key", v), do: block(put_in(v, ["scores", "style"], 3))
  defp malformed_text("missing summary", v), do: block(Map.delete(v, "summary"))
  defp malformed_text("missing gaps", v), do: block(Map.delete(v, "gaps"))

  defp malformed_text("gap missing dimension", v),
    do: block(%{v | "gaps" => [Map.delete(hd(v["gaps"]), "dimension")]})

  defp malformed_text("gap unknown dimension", v),
    do: block(%{v | "gaps" => [%{hd(v["gaps"]) | "dimension" => "style"}]})

  defp malformed_text("gap unknown severity", v),
    do: block(%{v | "gaps" => [%{hd(v["gaps"]) | "severity" => "critical"}]})

  defp malformed_text("gap empty title", v),
    do: block(%{v | "gaps" => [%{hd(v["gaps"]) | "title" => " "}]})

  describe "evaluate/1" do
    setup %{tmp_dir: tmp} do
      journal = Path.join(tmp, "journal")
      File.mkdir_p!(journal)
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      archive = Path.join(tmp, "archive")

      :ok =
        Archive.init(archive, %{
          "kind" => "run",
          "subject_id" => "run-1",
          "diff_status" => "captured"
        })

      File.write!(Path.join(archive, "request.md"), "Add /healthz")

      envs = [
        {:jido_harness, :providers, %{pi: Stub}},
        {:jido_harness, :provider_config, %{pi: %{retention: %{journal_dir: journal}}}},
        {:foreman_server, :review,
         Keyword.merge(Application.get_env(:foreman_server, :review, []),
           agent: %{provider: :pi, model: "m-test", effort: :high},
           evaluator_timeout_ms: 20_000
         )}
      ]

      saved = for {app, key, _} <- envs, do: {app, key, Application.get_env(app, key)}
      for {app, key, value} <- envs, do: Application.put_env(app, key, value)

      on_exit(fn ->
        for {app, key, value} <- saved do
          if value == nil,
            do: Application.delete_env(app, key),
            else: Application.put_env(app, key, value)
        end

        Application.delete_env(:foreman_server, :review_evaluator_test_stub)

        for info <- Jido.Harness.Run.list() do
          unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
          Jido.Harness.Run.prune(info.run_id)
        end
      end)

      subject = %Subject{
        kind: :run,
        subject_id: "run-1",
        project_id: "p",
        repo_path: repo,
        archive_dir: archive,
        status: "completed",
        request_title: "Healthz",
        request_text: "Add /healthz"
      }

      {:ok, subject: subject, repo: repo, archive: archive}
    end

    test "sends a read-only configured request and turns the reply into a verdict", ctx do
      Application.put_env(
        :foreman_server,
        :review_evaluator_test_stub,
        {self(), {:reply, block(@valid)}}
      )

      assert {:ok, %Verdict{verdict: :partially_met, gaps: [%Gap{}]}} =
               Agent.evaluate(ctx.subject)

      assert_received {:request, request}
      assert request.sandbox_mode == :read_only
      assert request.approval_mode == :default
      assert request.model == "m-test"
      assert request.reasoning_effort == :high
      assert request.runtime_timeout_ms == 20_000
      assert request.prompt =~ Path.join(ctx.archive, "diff.patch")
      assert request.prompt =~ "Add /healthz"

      transcript = File.read!(Path.join(ctx.archive, "evaluator-transcript.jsonl"))
      assert transcript =~ "run_completed"
      assert transcript =~ "Review done."
    end

    test "the reviewer never runs inside the project checkout or its archive (foreman-qp5d3)", ctx do
      # Default layout: the archive lives under the project's `.foreman/`.
      archive = Path.join([ctx.repo, ".foreman", "sessions", "run", "run-1"])
      :ok = Archive.init(archive, %{"kind" => "run", "subject_id" => "run-1"})
      {_, 0} = System.cmd("git", ["init", "-q", ctx.repo])
      subject = %{ctx.subject | archive_dir: archive}

      Application.put_env(
        :foreman_server,
        :review_evaluator_test_stub,
        {self(), {:reply, block(@valid)}}
      )

      assert {:ok, %Verdict{}} = Agent.evaluate(subject)
      assert_received {:request, request}

      refute String.starts_with?(Path.expand(request.cwd) <> "/", Path.expand(ctx.repo) <> "/")
      refute String.starts_with?(Path.expand(request.cwd) <> "/", Path.expand(archive) <> "/")

      # Nothing for an auto-commit hook to commit to: not a git work tree.
      {_, status} = System.cmd("git", ["-C", request.cwd, "rev-parse", "--git-dir"], stderr_to_stdout: true)
      assert status != 0
      assert File.dir?(request.cwd)
    end

    test "malformed reviewer output is surfaced, transcript still archived", ctx do
      Application.put_env(
        :foreman_server,
        :review_evaluator_test_stub,
        {self(), {:reply, "looks good"}}
      )

      assert {:error, %Error{code: :evaluator_malformed_output}} = Agent.evaluate(ctx.subject)
      assert File.exists?(Path.join(ctx.archive, "evaluator-transcript.jsonl"))
    end

    test "a failed provider run is :evaluator_failed", ctx do
      Application.put_env(:foreman_server, :review_evaluator_test_stub, {self(), :fail})

      assert {:error, %Error{code: :evaluator_failed, details: %{status: :failed}}} =
               Agent.evaluate(ctx.subject)
    end

    test "an unregistered provider is :evaluator_failed", ctx do
      Application.put_env(:foreman_server, :review_evaluator_test_stub, {self(), :fail})
      review = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review, :agent, %{provider: :nonesuch})
      )

      assert {:error, %Error{code: :evaluator_failed}} = Agent.evaluate(ctx.subject)
    end

    test "a missing archive is the archive's error, not a verdict", ctx do
      subject = %{ctx.subject | archive_dir: Path.join(ctx.archive, "nope")}
      assert {:error, %Error{code: code}} = Agent.evaluate(subject)
      assert code in [:archive_missing, :archive_malformed]
    end
  end
end
