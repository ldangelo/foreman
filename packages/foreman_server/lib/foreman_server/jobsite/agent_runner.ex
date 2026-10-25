defmodule ForemanServer.Jobsite.AgentRunner do
  @moduledoc """
  Runs a single agent iteration against a sandbox via `Jido.Harness.Run`.

  Idle timeout is harness-enforced, never consumer-enforced:
  `Jido.Harness.CursorStream.build/4` returns `{[], cursor}` plus
  `Process.sleep` while a run is live but silent, so a stream consumer cannot
  itself observe idleness — that is `RunRequest.idle_timeout_ms`'s job, and
  its watchdog lives inside the harness's own RunWorker. Two racing
  processes — a stream consumer (detects a completion signal as text
  accumulates) and an awaiter (`Run.await/2`) — race via a `receive`: before
  any signal, the receive blocks indefinitely; after a signal, it switches to
  a `completion_timeout_ms` grace window, reset on further progress, so
  trailing output (a usage event, an output tag) is still captured. A clean
  `{:result, _}` always wins the race, so a healthy run pays nothing for this.
  """

  require Logger

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.Jobsite.{Error, IterationResult, Sandbox}
  alias Jido.Harness.{Run, RunRequest, RunResult}

  @default_idle_timeout_ms 600_000
  @default_completion_timeout_ms 60_000
  @spawn_retries 3
  @spawn_failure_signature "Cannot set effective group to"

  @spec run(ForemanServer.Jobsite.Agent.t(), String.t(), Sandbox.t(), keyword()) ::
          {:ok, IterationResult.t()} | {:error, Error.t()}
  def run(agent, prompt, %Sandbox{} = sandbox, opts \\ []) do
    agent
    |> run_with_spawn_retry(prompt, sandbox, opts, @spawn_retries)
    |> redact_result(agent.secrets)
  end

  # erlexec (the harness's process driver) starts each agent with `setpgid(0, 0)`
  # in the child while the parent also calls `setpgid(child, child)`. On macOS
  # the two race, and the child then dies with "Cannot set effective group to
  # 0: Operation not permitted" and exit status 1 BEFORE it execs the agent
  # (reproduced with a bare fork/setpgid loop: ~0.2% of spawns under CPU load).
  # The agent never ran, so repeating the spawn is side-effect free; any other
  # failure, including every real agent exit, is returned untouched.
  defp run_with_spawn_retry(agent, prompt, sandbox, opts, retries_left) do
    case run_iteration_once(agent, prompt, sandbox, opts) do
      {:error, %Error{details: %{spawn_failed?: true}}} when retries_left > 0 ->
        Logger.warning("agent process failed to spawn (setpgid race); retrying the iteration")
        run_with_spawn_retry(agent, prompt, sandbox, opts, retries_left - 1)

      other ->
        other
    end
  end

  # Agent output reaches events and archives only through the result text, so
  # the resolved project secrets are redacted at this single exit (E4-S2).
  defp redact_result({:ok, %IterationResult{text: text} = result}, secrets)
       when is_binary(text) and secrets != [],
       do:
         {:ok,
          %IterationResult{
            result
            | text: ForemanServer.Overwatch.WorkerLogPolicy.redact(text, secrets)
          }}

  defp redact_result(result, _secrets), do: result

  defp run_iteration_once(agent, prompt, %Sandbox{} = sandbox, opts) do
    index = Keyword.get(opts, :index, 1)
    resume_session = Keyword.get(opts, :resume_session)
    fork_session = Keyword.get(opts, :fork_session)
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)
    runtime_timeout_ms = Keyword.get(opts, :runtime_timeout_ms, :infinity)

    completion_timeout_ms =
      Keyword.get(opts, :completion_timeout_ms, @default_completion_timeout_ms)

    signals = Keyword.get(opts, :completion_signals, [])
    on_event = Keyword.get(opts, :on_event)
    intent_fun = Keyword.get(opts, :intent_fun)

    env = merged_env(agent, sandbox)

    {system_prompt, prompt} =
      ForemanServer.ProjectContext.deliver(
        Keyword.get(opts, :system_prompt),
        agent.provider,
        prompt
      )

    {provider_session_id, fork_provider_options} =
      resolve_session_opts(agent.provider, resume_session, fork_session)

    with {:ok, cli_path} <-
           sandbox.provider.agent_cli_path(
             sandbox.state,
             agent.binary || to_string(agent.provider),
             env
           ),
         {:ok, request} <-
           build_request(
             agent,
             prompt,
             system_prompt,
             sandbox,
             provider_session_id,
             fork_provider_options,
             cli_path,
             idle_timeout_ms,
             runtime_timeout_ms,
             env
           ) do
      case Run.start(agent.provider, request) do
        {:ok, run_id} ->
          run_iteration(
            run_id,
            index,
            signals,
            completion_timeout_ms,
            on_event,
            intent_fun,
            Keyword.get(opts, :archive_dir),
            agent.secrets
          )

        {:error, reason} ->
          {:error, Error.new(:agent_start_failed, "failed to start agent run", %{reason: reason})}
      end
    end
  end

  defp merged_env(agent, sandbox) do
    sandbox_env = sandbox.config |> Kernel.||(%{}) |> Map.get(:env, %{})

    sandbox_env
    |> stringify_map()
    |> Map.merge(stringify_map(agent.env))
  end

  defp stringify_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp resolve_session_opts(_provider, resume_session, _fork_session)
       when is_binary(resume_session) and resume_session != "" do
    {resume_session, %{}}
  end

  defp resolve_session_opts(:pi, nil, fork_session)
       when is_binary(fork_session) and fork_session != "" do
    {nil, %{fork_session: fork_session}}
  end

  defp resolve_session_opts(:claude, nil, fork_session)
       when is_binary(fork_session) and fork_session != "" do
    {fork_session, %{fork_session: true}}
  end

  defp resolve_session_opts(_provider, _resume_session, _fork_session), do: {nil, %{}}

  defp build_request(
         agent,
         prompt,
         system_prompt,
         sandbox,
         provider_session_id,
         fork_opts,
         cli_path,
         idle_ms,
         runtime_ms,
         env
       ) do
    provider_options =
      agent.provider_options
      |> Map.merge(fork_opts)
      |> maybe_put(:cli_path, cli_path)

    attrs = [
      prompt: prompt,
      provider: agent.provider,
      # The harness spawns the agent CLI (the sandbox's shim) as a HOST process and
      # validates that this directory exists on the host. The in-container path
      # (`sandbox_repo_path`, e.g. /workspace) does not; the Docker shim sets it
      # itself with `exec -w`.
      cwd: sandbox.worktree.path,
      model: agent.model,
      reasoning_effort: agent.effort,
      provider_session_id: provider_session_id,
      idle_timeout_ms: idle_ms,
      runtime_timeout_ms: runtime_ms,
      env: env,
      provider_options: provider_options
    ]

    attrs = if system_prompt, do: Keyword.put(attrs, :system_prompt, system_prompt), else: attrs

    attrs =
      if agent.approval_mode,
        do: Keyword.put(attrs, :approval_mode, agent.approval_mode),
        else: attrs

    case RunRequest.new(attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, Error.new(:agent_start_failed, "invalid run request", %{reason: reason})}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @intent_poll_ms 500

  defp run_iteration(
         run_id,
         index,
         signals,
         completion_timeout_ms,
         on_event,
         intent_fun,
         archive_dir,
         secrets
       ) do
    case Run.stream(run_id) do
      {:ok, stream} ->
        parent = self()
        consumer = spawn_consumer(stream, signals, on_event, parent)
        awaiter = spawn_awaiter(run_id, parent, archive_dir, secrets)
        result = wait(run_id, index, signals, completion_timeout_ms, "", nil, intent_fun)
        Process.exit(consumer, :kill)
        Process.exit(awaiter, :kill)
        result

      {:error, reason} ->
        {:error,
         Error.new(:agent_start_failed, "failed to attach to run stream", %{reason: reason})}
    end
  end

  defp spawn_consumer(stream, signals, on_event, parent) do
    spawn(fn ->
      Enum.reduce(stream, "", fn event, acc_text ->
        if is_function(on_event, 1), do: on_event.(event)

        acc_text = acc_text <> event_text(event)
        send(parent, {:text, acc_text})

        case find_signal(acc_text, signals) do
          nil ->
            acc_text

          matched ->
            send(parent, {:signal, matched})
            acc_text
        end
      end)
    end)
  end

  # The awaiter is the one place every harness `RunResult` (success or failed
  # status) passes through, so the session archive is written here, before the
  # result is handed to `wait/6`. Capture never fails the iteration.
  defp spawn_awaiter(run_id, parent, archive_dir, secrets) do
    spawn(fn ->
      result = Run.await(run_id, :infinity)

      case result do
        {:ok, %RunResult{} = run_result} ->
          _ = ForemanServer.Review.Capture.put_iteration(archive_dir, run_result, secrets)

        _other ->
          :ok
      end

      send(parent, {:result, result})
    end)
  end

  defp event_text(%{type: type, payload: %{"text" => text}})
       when type in [:output_text_delta, :output_text_final] and is_binary(text),
       do: text

  defp event_text(_event), do: ""

  defp find_signal(_text, []), do: nil

  defp find_signal(text, signals) do
    Enum.find(signals, fn signal -> String.contains?(text, signal) end)
  end

  # Before a signal: no local deadline from completion_timeout_ms — idle
  # timeout is the harness's job — but when `intent_fun` is given, a short
  # poll tick checks it even before any signal, so an external pause/cancel
  # interrupts an iteration already in flight, not only the gap between
  # iterations. After a signal: a `completion_timeout_ms` grace window,
  # reset by any further progress, so trailing output is still captured.
  defp wait(
         run_id,
         index,
         signals,
         completion_timeout_ms,
         latest_text,
         matched_signal,
         intent_fun
       ) do
    timeout = poll_timeout(matched_signal, completion_timeout_ms, intent_fun)

    receive do
      {:text, text} ->
        wait(run_id, index, signals, completion_timeout_ms, text, matched_signal, intent_fun)

      {:signal, matched} ->
        wait(
          run_id,
          index,
          signals,
          completion_timeout_ms,
          latest_text,
          matched_signal || matched,
          intent_fun
        )

      # A harness result carries its own failure in `status: :failed` +
      # `error` — it is NOT an `{:error, _}` return — so without this clause a
      # run whose agent died (bad credentials, rejected model, non-zero exit)
      # became a "completed" iteration with empty text. A signal that already
      # matched means the agent logically finished, so only an unsignalled
      # failure is one.
      {:result, {:ok, %RunResult{} = result}} ->
        resolve_run_result(result, index, matched_signal, latest_text, signals)

      {:result, {:error, reason}} ->
        {:error, Error.new(:agent_failed, "agent run failed", %{reason: reason})}
    after
      timeout ->
        case {matched_signal, intent_check(intent_fun)} do
          {nil, :none} ->
            wait(
              run_id,
              index,
              signals,
              completion_timeout_ms,
              latest_text,
              matched_signal,
              intent_fun
            )

          {_signal, :none} ->
            Run.cancel(run_id)
            {:ok, hanging_result(index, latest_text, matched_signal)}

          {_signal, {:cancel, _reason}} ->
            Run.cancel(run_id)
            await_cancelled_agent(run_id)
            {:ok, cancelled_result(index, latest_text, matched_signal)}

          {_signal, _pause} ->
            Run.cancel(run_id)
            {:ok, cancelled_result(index, latest_text, matched_signal)}
        end
    end
  end

  # `Run.cancel/1` reports the run cancelled as soon as it has signalled the agent, which the
  # harness then takes its time to stop. The executor sweeps the worktree for the agent's tool
  # processes next, and they are orphans (what `OrphanReaper` matches) only once the agent is gone.
  defp await_cancelled_agent(run_id) do
    case Driver.await_exit(run_id) do
      :ok ->
        :ok

      {:error, :timeout} ->
        Logger.warning(
          "agent run #{run_id} was still running when the cancel wait ran out; its tool processes may outlive the jobsite"
        )
    end
  end

  # The stream consumer and the result awaiter are separate processes messaging this one, so
  # the result can overtake the consumer's `{:signal, _}`: on a busy machine the run's result
  # arrives first and the signal the agent really printed is never seen, the iteration comes
  # back unsignalled and the loop pays for another agent run. The result carries the run's
  # whole text, so look for the signal there too.
  @doc false
  @spec resolve_run_result(RunResult.t(), pos_integer(), String.t() | nil, String.t(), [
          String.t()
        ]) ::
          {:ok, IterationResult.t()} | {:error, Error.t()}
  def resolve_run_result(%RunResult{} = result, index, matched_signal, latest_text, signals) do
    matched_signal = matched_signal || find_signal(result.text || "", signals)

    case result do
      %RunResult{status: :failed} when is_nil(matched_signal) ->
        {:error, failed_result_error(result)}

      _ ->
        {:ok, build_result(result, index, matched_signal, latest_text)}
    end
  end

  # The harness reports an idle/runtime timeout as a failed result whose
  # error category is `:timeout`; keep that distinct from any other failure.
  defp failed_result_error(%RunResult{error: %{category: :timeout} = error} = result) do
    Error.new(:agent_idle_timeout, error.message, %{
      reason: error,
      session_id: result.provider_session_id
    })
  end

  defp failed_result_error(%RunResult{error: error} = result) do
    Error.new(:agent_failed, (error && error.message) || "agent run failed", %{
      reason: error,
      session_id: result.provider_session_id,
      spawn_failed?: spawn_failed?(result)
    })
  end

  # The child's stderr (erlexec's own `perror` line) arrives as a harness
  # provider event. The session id is NOT a usable signal here: a resumed
  # iteration is handed its session id up front, so the result carries one
  # even though the agent never started.
  defp spawn_failed?(%RunResult{events: events}) when is_list(events) do
    Enum.any?(events, fn
      %{payload: %{"stream" => "stderr", "data" => data}} when is_binary(data) ->
        String.contains?(data, @spawn_failure_signature)

      _event ->
        false
    end)
  end

  defp spawn_failed?(_result), do: false

  defp poll_timeout(nil, _completion_timeout_ms, nil), do: :infinity
  defp poll_timeout(nil, _completion_timeout_ms, _intent_fun), do: @intent_poll_ms

  defp poll_timeout(_matched_signal, completion_timeout_ms, _intent_fun),
    do: completion_timeout_ms

  defp intent_check(nil), do: :none
  defp intent_check(fun) when is_function(fun, 0), do: fun.()

  defp build_result(%RunResult{} = result, index, matched_signal, latest_text) do
    text = if result.text != "", do: result.text, else: latest_text

    status =
      cond do
        matched_signal != nil -> :signalled
        true -> result.status
      end

    %IterationResult{
      index: index,
      status: status,
      text: text,
      text_truncated?: result.text_truncated?,
      session_id: result.provider_session_id,
      usage: result.usage,
      signalled?: matched_signal != nil,
      matched_signal: matched_signal
    }
  end

  defp hanging_result(index, latest_text, matched_signal) do
    %IterationResult{
      index: index,
      status: :hanging,
      text: latest_text,
      signalled?: matched_signal != nil,
      matched_signal: matched_signal
    }
  end

  defp cancelled_result(index, latest_text, matched_signal) do
    %IterationResult{
      index: index,
      status: :cancelled,
      text: latest_text,
      signalled?: matched_signal != nil,
      matched_signal: matched_signal
    }
  end
end
