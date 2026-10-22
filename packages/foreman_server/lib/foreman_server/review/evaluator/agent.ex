defmodule ForemanServer.Review.Evaluator.Agent do
  @moduledoc """
  Production evaluator: runs a fixed, separately configured reviewer agent
  (`config :foreman_server, :review, agent:`) read-only over the archived
  session and parses its single fenced JSON verdict strictly.

  The reviewer may answer `met`, `partially_met` or `not_met` only;
  `undetermined` is reserved for the analyzer's own failure records and is
  rejected here as malformed.
  """
  @behaviour ForemanServer.Review.Evaluator

  alias ForemanServer.AgentRuntime.JidoHarness.DetachedRun
  alias ForemanServer.Review.{Archive, Error, Gap, Prompt, Subject, Verdict}
  alias ForemanServer.Usage
  alias Jido.Harness.{RunRequest, RunResult}

  @dimension_atoms %{
    "correctness" => :correctness,
    "tests" => :tests,
    "documentation" => :documentation,
    "robustness" => :robustness
  }
  @verdict_atoms %{"met" => :met, "partially_met" => :partially_met, "not_met" => :not_met}
  @severity_atoms %{"major" => :major, "minor" => :minor}
  @dimensions Map.keys(@dimension_atoms)
  @await_slack_ms 5_000
  @transcript_file "evaluator-transcript.jsonl"
  @json_block ~r/```json[ \t]*\r?\n(.*?)\r?\n[ \t]*```/s

  @impl true
  @spec evaluate(Subject.t()) :: {:ok, Verdict.t()} | {:error, Error.t()}
  def evaluate(%Subject{} = subject) do
    cfg = config()

    with {:ok, manifest} <- Archive.read_manifest(subject.archive_dir),
         {:ok, prompt} <- render(subject, manifest),
         {:ok, request} <- build_request(prompt, subject, cfg),
         {:ok, result} <- run(cfg.provider, request, cfg.timeout) do
      archive_transcript(subject.archive_dir, result)
      finish(result, cfg)
    end
  end

  @doc """
  Strictly parse the reviewer's reply text. The LAST fenced `json` block is
  used; anything not exactly the documented shape is
  `{:error, %Error{code: :evaluator_malformed_output}}`.
  """
  @spec parse_verdict(String.t()) :: {:ok, Verdict.t()} | {:error, Error.t()}
  def parse_verdict(text) when is_binary(text) do
    with {:ok, json} <- last_json_block(text),
         {:ok, decoded} <- decode(json),
         {:ok, verdict} <- build_verdict(decoded) do
      {:ok, verdict}
    end
  end

  # ---------------------------------------------------------------- run

  defp render(subject, manifest) do
    {:ok, Prompt.render(subject, manifest)}
  rescue
    exception ->
      {:error,
       Error.new(:evaluator_failed, "could not render reviewer prompt", %{
         reason: Exception.message(exception)
       })}
  end

  # The reviewer runs in a scratch directory, NEVER the project checkout (nor
  # the archive, which lives under the checkout's `.foreman/`): `sandbox_mode:
  # :read_only` is not honoured by every provider, and `pi`'s auto-commit hook
  # committed the archive files into the project's main branch (foreman-qp5d3).
  # Outside any git work tree there is nothing for such a hook to commit to; the
  # prompt hands the reviewer absolute paths to everything it needs to read.
  @doc false
  @spec scratch_dir(Subject.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def scratch_dir(%Subject{kind: kind, subject_id: subject_id}) do
    safe = fn value ->
      value
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.replace(~r/\A\.+/, "_")
    end

    dir = Path.join([System.tmp_dir!(), "foreman-review", safe.(kind), safe.(subject_id)])

    case File.mkdir_p(dir) do
      :ok ->
        {:ok, dir}

      {:error, reason} ->
        {:error,
         Error.new(:evaluator_failed, "could not create reviewer scratch directory", %{
           path: dir,
           reason: inspect(reason)
         })}
    end
  end

  @doc false
  @spec build_request(String.t(), Subject.t(), map()) ::
          {:ok, RunRequest.t()} | {:error, Error.t()}
  def build_request(prompt, subject, cfg) do
    with {:ok, cwd} <- scratch_dir(subject) do
      new_request(prompt, cwd, cfg)
    end
  end

  defp new_request(prompt, cwd, cfg) do
    attrs = %{
      prompt: prompt,
      provider: cfg.provider,
      cwd: cwd,
      model: cfg.model,
      reasoning_effort: cfg.effort,
      approval_mode: :default,
      sandbox_mode: :read_only,
      runtime_timeout_ms: cfg.timeout,
      idle_timeout_ms: cfg.timeout
    }

    case RunRequest.new(attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error,
         Error.new(:evaluator_failed, "invalid reviewer run request", %{reason: inspect(reason)})}
    end
  end

  defp run(provider, request, timeout) do
    case DetachedRun.start_run(provider, request, []) do
      {:ok, run_id} ->
        await(run_id, provider, timeout)

      {:error, reason} ->
        {:error,
         Error.new(:evaluator_failed, "reviewer provider failed to start", %{
           provider: provider,
           reason: inspect(reason)
         })}
    end
  end

  defp await(run_id, provider, timeout) do
    case DetachedRun.await_run(run_id, timeout + @await_slack_ms) do
      {:ok, %RunResult{} = result} ->
        {:ok, result}

      {:error, reason} ->
        _ = DetachedRun.cancel_run(run_id)

        {:error,
         Error.new(:evaluator_failed, "reviewer run did not complete", %{
           provider: provider,
           run_id: run_id,
           reason: inspect(reason)
         })}
    end
  end

  # The reviewer spent tokens whether or not its reply parsed, so usage rides
  # on the verdict AND on the error details (read by the analyzer).
  defp finish(%RunResult{} = result, cfg) do
    usage = Usage.normalize(cfg.provider, result.usage, nil)
    provider = to_string(cfg.provider)

    case finish(result) do
      {:ok, %Verdict{} = verdict} ->
        {:ok, %Verdict{verdict | usage: usage, model: cfg.model, usage_provider: provider}}

      {:error, %Error{} = error} ->
        spent = %{usage: usage, model: cfg.model, provider: provider}
        {:error, %Error{error | details: Map.put(error.details || %{}, :usage, spent)}}
    end
  end

  defp finish(%RunResult{status: :completed, text: text}), do: parse_verdict(text)

  defp finish(%RunResult{} = result) do
    {:error,
     Error.new(:evaluator_failed, "reviewer run ended #{result.status}", %{
       provider: result.provider,
       run_id: result.run_id,
       status: result.status,
       error: inspect(result.error)
     })}
  end

  # Best effort: a failed transcript write is already logged and recorded in
  # the manifest's capture_errors by Archive.write_file/3 and must not hide
  # the verdict.
  defp archive_transcript(dir, %RunResult{events: events}) do
    _ = Archive.write_file(dir, @transcript_file, Enum.map(events, &Archive.encode_event/1))
    :ok
  end

  defp config do
    review = Application.get_env(:foreman_server, :review, [])
    agent = Keyword.get(review, :agent) || %{}

    %{
      provider: Map.get(agent, :provider) || :claude,
      model: Map.get(agent, :model),
      effort: Map.get(agent, :effort),
      timeout: Keyword.get(review, :evaluator_timeout_ms, 900_000)
    }
  end

  # -------------------------------------------------------------- parse

  defp last_json_block(text) do
    case Regex.scan(@json_block, text) do
      [] -> malformed("reply has no fenced json block")
      blocks -> {:ok, blocks |> List.last() |> Enum.at(1)}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:ok, _other} ->
        malformed("json block is not an object")

      {:error, error} ->
        malformed("json block does not decode", %{reason: Exception.message(error)})
    end
  end

  defp build_verdict(decoded) do
    with :ok <- exact_keys(decoded, ~w(verdict scores summary gaps), "verdict"),
         {:ok, verdict} <- verdict(decoded["verdict"]),
         {:ok, scores} <- scores(decoded["scores"]),
         {:ok, summary} <- non_empty(decoded["summary"], "summary"),
         {:ok, gaps} <- gaps(decoded["gaps"]) do
      {:ok, %Verdict{verdict: verdict, scores: scores, summary: summary, gaps: gaps}}
    end
  end

  defp verdict(value), do: enum(value, @verdict_atoms, "verdict")

  defp scores(%{} = scores) do
    with :ok <- exact_keys(scores, @dimensions, "scores") do
      Enum.reduce_while(scores, {:ok, %{}}, fn
        {dim, score}, {:ok, acc} when is_integer(score) and score in 1..5 ->
          {:cont, {:ok, Map.put(acc, Map.fetch!(@dimension_atoms, dim), score)}}

        {dim, score}, _ ->
          {:halt, malformed("score outside 1..5", %{dimension: dim, value: inspect(score)})}
      end)
    end
  end

  defp scores(_), do: malformed("scores is not an object")

  defp gaps(gaps) when is_list(gaps) do
    gaps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {gap, index}, {:ok, acc} ->
      case gap(gap, index) do
        {:ok, gap} -> {:cont, {:ok, [gap | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp gaps(_), do: malformed("gaps is not a list")

  defp gap(%{} = gap, index) do
    with :ok <- exact_keys(gap, ~w(title description dimension severity), "gaps[#{index}]"),
         {:ok, title} <- non_empty(gap["title"], "gaps[#{index}].title"),
         {:ok, description} <- non_empty(gap["description"], "gaps[#{index}].description"),
         {:ok, dimension} <- enum(gap["dimension"], @dimension_atoms, "gaps[#{index}].dimension"),
         {:ok, severity} <- enum(gap["severity"], @severity_atoms, "gaps[#{index}].severity") do
      {:ok,
       %Gap{title: title, description: description, dimension: dimension, severity: severity}}
    end
  end

  defp gap(_, index), do: malformed("gaps[#{index}] is not an object")

  defp enum(value, allowed, field) do
    case allowed do
      %{^value => atom} -> {:ok, atom}
      _ -> malformed("invalid #{field}", %{value: inspect(value)})
    end
  end

  defp non_empty(value, field) do
    if is_binary(value) and String.trim(value) != "",
      do: {:ok, value},
      else: malformed("#{field} is missing or empty")
  end

  defp exact_keys(map, expected, label) do
    actual = map |> Map.keys() |> Enum.sort()
    wanted = Enum.sort(expected)

    if actual == wanted,
      do: :ok,
      else:
        malformed("#{label} has wrong keys", %{
          missing: wanted -- actual,
          unexpected: actual -- wanted
        })
  end

  defp malformed(message, details \\ %{}),
    do: {:error, Error.new(:evaluator_malformed_output, message, details)}
end
