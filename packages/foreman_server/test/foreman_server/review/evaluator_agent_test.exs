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
      send(pid, {:scratch_present, File.dir?(request.cwd)})

      case resolve(mode) do
        # Tokens the attempt spent before it ended, ahead of whatever it then did.
        {:spent, input, inner} ->
          with {:ok, events} <- outcome(inner), do: {:ok, [usage_event(input) | events]}

        # One `:usage` event per assistant message, as pi reports them: the harness's
        # `RunResult.usage` keeps only the last of them.
        {:messages, inputs, inner} ->
          with {:ok, events} <- outcome(inner),
               do: {:ok, Enum.map(inputs, &usage_event/1) ++ events}

        # What the reviewer's working directory is WHILE it runs there: the directory is gone
        # once the review ends (foreman-5k19m), so a check made afterwards proves nothing.
        {:inspect_scratch, inner} ->
          {_, status} =
            System.cmd("git", ["-C", request.cwd, "rev-parse", "--git-dir"],
              stderr_to_stdout: true
            )

          send(pid, {:scratch_git_status, status})
          outcome(inner)

        other ->
          outcome(other)
      end
    end

    # `{:sequence, counter, modes}`: the n-th run takes the n-th mode, the last one repeats.
    defp resolve({:sequence, counter, modes}) do
      index = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      Enum.at(modes, index) || List.last(modes)
    end

    defp resolve(mode), do: mode

    defp usage_event(input),
      do: Event.new!(provider: :pi, type: :usage, payload: %{"input" => input, "output" => 1})

    defp outcome({:reply, text}) do
      {:ok,
       [
         Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => text}),
         Event.new!(provider: :pi, type: :run_completed, payload: %{})
       ]}
    end

    # Pi's shape (`Adapters.Pi.map_event/1`): one `turn_started` .. `turn_completed` per model
    # call. A turn that wrote text ends in an `output_text_final`; one that only thought has none.
    defp outcome({:turns, turns}) do
      events =
        Enum.flat_map(turns, fn
          {:text, text} ->
            turn(Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => text}))

          :thinking ->
            turn(Event.new!(provider: :pi, type: :thinking_delta, payload: %{"text" => "hmm"}))
        end)

      {:ok, events ++ [Event.new!(provider: :pi, type: :run_completed, payload: %{})]}
    end

    defp outcome(:fail) do
      {:ok, [Event.new!(provider: :pi, type: :run_failed, payload: %{"text" => "boom"})]}
    end

    # pi reports a provider failure (429, overloaded, ...) as `run_failed` carrying the
    # provider's message under "error" (`Jido.Harness.Adapters.Pi.map_event/1`).
    defp outcome({:run_failed, error}) do
      {:ok, [Event.new!(provider: :pi, type: :run_failed, payload: %{"error" => error})]}
    end

    # A CLI that wrote to stderr and exited non-zero (`CLIStream.decode/4`).
    defp outcome({:stderr_then_failed, lines, error}) do
      {:ok,
       Enum.map(lines, fn line ->
         Event.new!(
           provider: :pi,
           type: :provider_event,
           payload: %{"stream" => "stderr", "data" => line}
         )
       end) ++ [Event.new!(provider: :pi, type: :run_failed, payload: %{"error" => error})]}
    end

    # The adapter itself gives up, as `CLIStream.run/8` does when the process cannot start.
    defp outcome({:adapter_error, error}), do: {:error, error}

    # Produces nothing, ever: only the harness run's own timers end it.
    defp outcome(mode) when mode in [:hang, :hang_slow_cancel],
      do: {:ok, Stream.repeatedly(fn -> Process.sleep(60_000) end)}

    defp turn(inner_event) do
      [
        Event.new!(provider: :pi, type: :turn_started, payload: %{}),
        inner_event,
        Event.new!(provider: :pi, type: :turn_completed, payload: %{})
      ]
    end

    @impl true
    def cancel(_run_id, _context) do
      {_pid, mode} = Application.fetch_env!(:foreman_server, :review_evaluator_test_stub)
      # Holds the harness run past `await_run`'s deadline (timeout + slack) so the caller
      # gives up while the run is still finishing.
      if mode == :hang_slow_cancel, do: Process.sleep(6_000)
      :ok
    end
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

    test "the reviewer never runs inside the project checkout or its archive (foreman-qp5d3)",
         ctx do
      # Default layout: the archive lives under the project's `.foreman/`.
      archive = Path.join([ctx.repo, ".foreman", "sessions", "run", "run-1"])
      :ok = Archive.init(archive, %{"kind" => "run", "subject_id" => "run-1"})
      {_, 0} = System.cmd("git", ["init", "-q", ctx.repo])
      subject = %{ctx.subject | archive_dir: archive}

      Application.put_env(
        :foreman_server,
        :review_evaluator_test_stub,
        {self(), {:inspect_scratch, {:reply, block(@valid)}}}
      )

      assert {:ok, %Verdict{}} = Agent.evaluate(subject)
      assert_received {:request, request}

      refute String.starts_with?(Path.expand(request.cwd) <> "/", Path.expand(ctx.repo) <> "/")
      refute String.starts_with?(Path.expand(request.cwd) <> "/", Path.expand(archive) <> "/")

      # Nothing for an auto-commit hook to commit to: not a git work tree, checked while the
      # reviewer ran in it (the directory is removed when the review ends).
      assert_received {:scratch_git_status, status}
      assert status != 0
      assert_received {:scratch_present, true}
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

    test "an unregistered provider is :evaluator_failed and the error names it and why", ctx do
      Application.put_env(:foreman_server, :review_evaluator_test_stub, {self(), :fail})
      review = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review, :agent, %{provider: :nonesuch})
      )

      assert {:error, %Error{code: :evaluator_failed, message: message}} =
               Agent.evaluate(ctx.subject)

      assert message =~ "nonesuch"
      assert message =~ "not registered"
    end

    test "a missing archive is the archive's error, not a verdict", ctx do
      subject = %{ctx.subject | archive_dir: Path.join(ctx.archive, "nope")}
      assert {:error, %Error{code: code}} = Agent.evaluate(subject)
      assert code in [:archive_missing, :archive_malformed]
    end

    # foreman-uxfwb: a review recorded `undetermined` said only "reviewer run ended failed"
    # (`Verdict.summary` is the error's message and nothing else reached the record), so the
    # cause of the one live failure was unknowable. Every :evaluator_failed path must put the
    # underlying reason in the message, because the message is what gets recorded.
    @rate_limit ~s|429 {"type":"error","error":{"type":"rate_limit_error","message":"Token Plan rate limit reached: Upgrade your Token Plan (2062)"},"request_id":"abc"}|

    defp put_mode(mode),
      do: Application.put_env(:foreman_server, :review_evaluator_test_stub, {self(), mode})

    defp put_timeout(ms) do
      review = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review, :evaluator_timeout_ms, ms)
      )
    end

    test "a provider 429 is named in the error, is retryable, and reaches the transcript", ctx do
      put_mode({:run_failed, @rate_limit})

      assert {:error, %Error{code: :evaluator_failed, message: message, details: details} = error} =
               Agent.evaluate(ctx.subject)

      assert message =~ "reviewer run ended failed"
      assert message =~ "429"
      assert message =~ "rate_limit_error"
      assert message =~ "Token Plan rate limit reached"
      assert details.status == :failed
      assert Error.retryable?(error)

      transcript = File.read!(Path.join(ctx.archive, "evaluator-transcript.jsonl"))
      assert transcript =~ "rate_limit_error"
    end

    test "a non-zero exit carries its status and the stderr the process left", ctx do
      put_mode(
        {:stderr_then_failed, ["loading config\n", "Error: ENOSPC: no space left on device\n"],
         ~s(%{"exit_status" => 1, "reason" => "{:exit_status, 256}"})}
      )

      assert {:error, %Error{code: :evaluator_failed, message: message} = error} =
               Agent.evaluate(ctx.subject)

      assert message =~ "exit_status"
      assert message =~ "ENOSPC: no space left on device"
      refute Error.retryable?(error)
    end

    test "a reviewer that outlives its runtime timeout says it timed out", ctx do
      put_mode(:hang)
      put_timeout(150)

      assert {:error, %Error{code: :evaluator_failed, message: message} = error} =
               Agent.evaluate(ctx.subject)

      assert message =~ "timeout exceeded"
      refute Error.retryable?(error)
      assert File.exists?(Path.join(ctx.archive, "evaluator-transcript.jsonl"))
    end

    test "an adapter that gives up keeps the adapter's reason", ctx do
      put_mode(
        {:adapter_error,
         Jido.Harness.Error.execution("could not start pi: enoent", provider: :pi)}
      )

      assert {:error, %Error{code: :evaluator_failed, message: message}} =
               Agent.evaluate(ctx.subject)

      assert message =~ "could not start pi: enoent"
    end

    # `await_run` gives up at timeout + slack. The run may still be finishing: its own
    # failure (the harness's timeout) is the reason, "did not complete" alone is not.
    @tag timeout: 30_000
    test "a caller that stops waiting archives what the run produced and says why", ctx do
      put_mode(:hang_slow_cancel)
      put_timeout(100)

      assert {:error, %Error{code: :evaluator_failed, message: message}} =
               Agent.evaluate(ctx.subject)

      assert message =~ "did not complete"
      assert message =~ "timeout"
      assert File.exists?(Path.join(ctx.archive, "evaluator-transcript.jsonl"))
    end

    test "a reply with no verdict block quotes what the reviewer said", ctx do
      put_mode({:reply, "I'll read the archived files."})

      assert {:error, %Error{code: :evaluator_malformed_output, message: message}} =
               Agent.evaluate(ctx.subject)

      assert message =~ "reply has no fenced json block"
      assert message =~ "I'll read the archived files."
    end

    test "a secret in a provider error never reaches the message", ctx do
      System.put_env("REVIEW_EVAL_TEST_API_KEY", "hunter2-secret-value")
      on_exit(fn -> System.delete_env("REVIEW_EVAL_TEST_API_KEY") end)
      put_mode({:run_failed, "401 invalid x-api-key hunter2-secret-value"})

      assert {:error, %Error{message: message}} = Agent.evaluate(ctx.subject)
      assert message =~ "401"
      refute message =~ "hunter2-secret-value"
    end

    # foreman-uxfwb: 32 reviewers started together all failed on a provider 429, and a lone
    # reviewer succeeded 30 s later. A rate limit is retried once after
    # `evaluator_retry_backoff_ms`; nothing else is, and the retry is part of the record.
    defp put_backoff(ms) do
      review = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review, :evaluator_retry_backoff_ms, ms)
      )
    end

    defp sequence(modes) do
      counter = :counters.new(1, [])
      put_mode({:sequence, counter, modes})
    end

    defp count_requests do
      Stream.repeatedly(fn ->
        receive do
          {:request, _request} -> :seen
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 == :seen))
      |> length()
    end

    test "a rate-limited review is retried once and the verdict records the retry", ctx do
      put_backoff(0)

      sequence([
        {:spent, 100, {:run_failed, @rate_limit}},
        {:spent, 40, {:reply, block(@valid)}}
      ])

      assert {:ok, %Verdict{verdict: :partially_met, notes: [note], usage: usage}} =
               Agent.evaluate(ctx.subject)

      assert note =~ "retried once"
      assert note =~ "429"
      assert note =~ "rate_limit_error"
      assert count_requests() == 2
      # Both attempts spent tokens; the failed one is not hidden.
      assert usage.input_tokens == 140
    end

    test "a rate limit that outlasts the retry is an error that notes the retry", ctx do
      put_backoff(0)

      sequence([
        {:spent, 100, {:run_failed, @rate_limit}},
        {:spent, 7, {:run_failed, @rate_limit}}
      ])

      assert {:error,
              %Error{
                code: :evaluator_failed,
                message: message,
                details: %{notes: [note], usage: %{usage: usage}}
              }} = Agent.evaluate(ctx.subject)

      assert message =~ "429"
      assert note =~ "retried once"
      # One retry, never a third attempt.
      assert count_requests() == 2
      assert usage.input_tokens == 107
    end

    test "a failure that is not a rate limit is not retried", ctx do
      put_backoff(0)
      sequence([{:stderr_then_failed, ["boom\n"], "exit 1"}, {:reply, block(@valid)}])

      assert {:error, %Error{code: :evaluator_failed} = error} = Agent.evaluate(ctx.subject)
      refute Map.has_key?(error.details, :notes)
      assert count_requests() == 1
    end

    test "malformed output is not retried", ctx do
      put_backoff(0)
      sequence([{:reply, "no verdict here"}, {:reply, block(@valid)}])

      assert {:error, %Error{code: :evaluator_malformed_output}} = Agent.evaluate(ctx.subject)
      assert count_requests() == 1
    end

    test "the retry waits out the configured backoff", ctx do
      put_backoff(300)
      sequence([{:run_failed, @rate_limit}, {:reply, block(@valid)}])

      {micros, result} = :timer.tc(fn -> Agent.evaluate(ctx.subject) end)

      assert {:ok, %Verdict{}} = result
      assert micros >= 300_000
    end

    # foreman-5z2u9: `RunResult.usage` is the harness's last-write-wins merge of every usage
    # payload, so for pi (usage per message) it holds the LAST message only. The reviewer's
    # spend is the sum of its messages, as the worker door records it.
    test "the reviewer's usage is the sum of every message of a pi run", ctx do
      put_mode({:messages, [100, 50, 25], {:reply, block(@valid)}})

      assert {:ok, %Verdict{usage: usage}} = Agent.evaluate(ctx.subject)
      assert usage.input_tokens == 175
      assert usage.output_tokens == 3
    end

    test "a failed review reports the same summed spend on its error", ctx do
      put_mode({:messages, [100, 50], :fail})

      assert {:error, %Error{details: %{usage: %{usage: usage}}}} = Agent.evaluate(ctx.subject)
      assert usage.input_tokens == 150
    end

    # foreman-5k19m: the reviewer's scratch working directory
    # (`<tmp>/foreman-review/<kind>/<id>`) was created for every review and never removed.
    test "the scratch directory exists while the reviewer runs and is gone after the verdict",
         ctx do
      put_mode({:reply, block(@valid)})

      assert {:ok, %Verdict{}} = Agent.evaluate(ctx.subject)

      assert_received {:scratch_present, true}
      assert_received {:request, request}
      refute File.exists?(request.cwd)
    end

    test "the scratch directory is removed when the review ends in an error", ctx do
      for mode <- [{:reply, "no verdict here"}, :fail] do
        put_mode(mode)

        assert {:error, %Error{}} = Agent.evaluate(ctx.subject)

        assert_received {:request, request}
        refute File.exists?(request.cwd)
      end
    end

    test "one scratch directory serves both attempts and goes after the retry", ctx do
      put_backoff(0)
      sequence([{:run_failed, @rate_limit}, {:reply, block(@valid)}])

      assert {:ok, %Verdict{}} = Agent.evaluate(ctx.subject)

      # The first attempt's failure did not remove the directory the retry runs in.
      assert_received {:scratch_present, true}
      assert_received {:scratch_present, true}
      assert_received {:request, request}
      refute File.exists?(request.cwd)
    end

    test "a request that cannot be built leaves no scratch directory behind", ctx do
      review = Application.get_env(:foreman_server, :review)
      agent = %{provider: :pi, model: "m-test", effort: :not_an_effort}
      Application.put_env(:foreman_server, :review, Keyword.put(review, :agent, agent))

      assert {:error, %Error{code: :evaluator_failed, message: message}} =
               Agent.evaluate(ctx.subject)

      assert message =~ "invalid reviewer run request"

      refute File.exists?(
               Path.join([System.tmp_dir!(), "foreman-review", "run", ctx.subject.subject_id])
             )
    end

    # foreman-lze33: with `pi` on MiniMax the reviewer sometimes ended its last turn on a
    # thinking block and no text. `RunResult.text` was then an earlier turn's words, the review
    # was recorded `undetermined`, and nothing was wrong with the work. A final turn that wrote
    # no text gets the one retry; a reply that holds text but no verdict does not.
    @narration "I will read the archived files."

    test "a final turn that wrote no text is retried once and the verdict records why", ctx do
      put_backoff(0)

      sequence([
        {:spent, 100, {:turns, [{:text, @narration}, :thinking]}},
        {:spent, 40, {:reply, block(@valid)}}
      ])

      assert {:ok, %Verdict{verdict: :partially_met, notes: [note], usage: usage}} =
               Agent.evaluate(ctx.subject)

      assert note =~ "retried once"
      assert note =~ "its final turn wrote no text"
      assert note =~ @narration
      assert count_requests() == 2
      # Both attempts spent tokens; the silent one is not hidden.
      assert usage.input_tokens == 140
    end

    test "a reviewer that thinks and writes nothing at all is retried too", ctx do
      put_backoff(0)
      sequence([{:turns, [:thinking]}, {:reply, block(@valid)}])

      assert {:ok, %Verdict{notes: [note]}} = Agent.evaluate(ctx.subject)
      assert note =~ "reply empty"
      assert count_requests() == 2
    end

    test "a final turn that stays silent twice is an error that notes the one retry", ctx do
      put_backoff(0)
      sequence([{:turns, [{:text, @narration}, :thinking]}])

      assert {:error,
              %Error{
                code: :evaluator_malformed_output,
                message: message,
                details: %{notes: [note]}
              }} = Agent.evaluate(ctx.subject)

      assert message =~ "reply has no fenced json block"
      assert message =~ "its final turn wrote no text"
      assert note =~ "retried once"
      # One retry, never a third attempt.
      assert count_requests() == 2
    end

    test "a final turn that wrote text without a verdict is the reviewer's own output", ctx do
      put_backoff(0)

      sequence([
        {:turns, [{:text, @narration}, {:text, "No verdict from me."}]},
        {:reply, block(@valid)}
      ])

      assert {:error, %Error{code: :evaluator_malformed_output, message: message} = error} =
               Agent.evaluate(ctx.subject)

      assert message =~ "No verdict from me."
      refute message =~ "its final turn wrote no text"
      refute Map.has_key?(error.details, :notes)
      assert count_requests() == 1
    end
  end
end
