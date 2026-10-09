defmodule ForemanServer.Jobsite.Executor do
  @moduledoc """
  One `GenServer` per jobsite id, event-sourcing every state transition
  through `CommandGateway.dispatch_system/2` on stream `jobsite:<id>`.

  Ordering rule, applied uniformly: side effects happen first, the event
  records them. The worktree is created on disk and then
  `jobsite.worktree.provision` records the real path; the container is
  started and then `jobsite.sandbox.provision` records the real id. A
  dispatch rejection after a successful side effect tears the side effect
  back down and fails the jobsite with `:dispatch_rejected` — the event is
  never fabricated. The one inversion is `jobsite.iteration.start`,
  dispatched BEFORE the agent spawns, so a crash mid-agent leaves an open
  iteration that `resume/1` can see and redo.
  """

  use GenServer
  require Logger

  alias ForemanServer.CommandGateway

  alias ForemanServer.Aggregate

  alias ForemanServer.Jobsite.{
    AgentRunner,
    Context,
    Control,
    Engine,
    Error,
    Git,
    Hooks,
    IterationResult,
    Options,
    Program,
    Result,
    Sandboxes,
    Step,
    Worktree
  }

  alias ForemanServer.Jobsite.Executor.Observer

  @default_completion_signal "<promise>COMPLETE</promise>"
  @default_idle_timeout_seconds 600
  @default_completion_timeout_seconds 60

  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(jobsite_id, opts) do
    GenServer.start_link(__MODULE__, {jobsite_id, opts}, name: via_tuple(jobsite_id))
  end

  @spec pid_for(String.t()) :: pid() | nil
  def pid_for(jobsite_id) do
    case Registry.lookup(ForemanServer.Jobsite.Registry, jobsite_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via_tuple(jobsite_id), do: {:via, Registry, {ForemanServer.Jobsite.Registry, jobsite_id}}

  @impl true
  def init({jobsite_id, opts}) do
    {:ok, %{jobsite_id: jobsite_id, opts: opts}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, %{jobsite_id: jobsite_id, opts: opts} = state) do
    reply_to = Keyword.get(opts, :reply_to)

    outcome =
      if Keyword.get(opts, :resume?, false),
        do: resume(jobsite_id, opts),
        else: run(jobsite_id, opts)

    if reply_to, do: send(reply_to, {:jobsite, jobsite_id, outcome})

    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------
  # Fresh run
  # ---------------------------------------------------------------------

  @spec run(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(jobsite_id, opts) do
    with {:ok, spec} <- build_spec(jobsite_id, opts),
         {:ok, _} <-
           dispatch(jobsite_id, "jobsite.start", "start", start_payload(jobsite_id, spec)) do
      execute(jobsite_id, spec)
    else
      {:error, %Error{} = error} ->
        dispatch(jobsite_id, "jobsite.fail", "terminal", fail_payload(error))
        {:error, error}
    end
  end

  defp build_spec(_jobsite_id, opts) do
    with :ok <- Options.validate(opts),
         {:ok, agent} <- fetch(opts, :agent, :prompt_source_missing, "agent"),
         {:ok, {sandbox_provider, sandbox_config}} <-
           fetch(opts, :sandbox, :sandbox_create_failed, "sandbox"),
         :ok <- Hooks.validate(Keyword.get(opts, :hooks)) do
      {:ok,
       %{
         opts: opts,
         agent: agent,
         sandbox_provider: sandbox_provider,
         sandbox_config: sandbox_config,
         repo_path: Keyword.get(opts, :repo_path, File.cwd!()),
         strategy: Keyword.get(opts, :strategy, :head),
         max_iterations: Keyword.get(opts, :max_iterations, 1),
         signals:
           normalize_signals(Keyword.get(opts, :completion_signal, @default_completion_signal)),
         idle_ms: Keyword.get(opts, :idle_timeout_seconds, @default_idle_timeout_seconds) * 1000,
         completion_ms:
           Keyword.get(opts, :completion_timeout_seconds, @default_completion_timeout_seconds) *
             1000,
         hooks: Keyword.get(opts, :hooks),
         output_opts: Keyword.get(opts, :output),
         resume_session: Keyword.get(opts, :resume_session)
       }}
    end
  end

  defp fetch(opts, key, code, label) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Error.new(code, "#{label} is required", %{key: key})}
    end
  end

  defp execute(jobsite_id, spec) do
    program = build_program(jobsite_id, spec)
    ctx = %Context{jobsite_id: jobsite_id, repo_path: spec.repo_path}
    observer_state = %{jobsite_id: jobsite_id, sandbox_attempt: 0}

    case Engine.run_program(program, ctx,
           observer: Observer,
           observer_state: observer_state,
           intent: fn -> Control.intent(jobsite_id) end
         ) do
      {:ok, final_ctx, _observer_state} ->
        dispatch(jobsite_id, "jobsite.complete", "terminal", %{
          iterations_run: length(final_ctx.iterations),
          branch: final_ctx.worktree.branch
        })

        {:ok, build_result(jobsite_id, final_ctx)}

      {:error, %Error{} = error, ctx, _observer_state} ->
        fail(jobsite_id, ctx.worktree, ctx.sandbox, error)

      {:interrupted, kind, reason, ctx, _observer_state} ->
        handle_interrupt(jobsite_id, kind, reason, ctx.sandbox, ctx.worktree, ctx.iterations)
    end
  end

  # Translates validated `Jobsite.run/1` options into the fixed step
  # sequence a fresh run always executes: provision the worktree, run any
  # `on_worktree_ready` hooks, provision the sandbox, run any
  # `on_sandbox_ready` hooks (host then sandbox), iterate the agent, commit
  # whatever it produced, and release both resources. Resume (see
  # `resume_from_state/3` below) does not go through this — it rebuilds its
  # own, narrower sequence directly from persisted aggregate state and
  # reuses `iterate/11`/`do_iterate/11` (kept below for exactly that caller).
  defp build_program(jobsite_id, spec) do
    worktree_opts = %{
      repo_path: spec.repo_path,
      strategy: spec.strategy,
      path: Keyword.get(spec.opts, :path),
      base: Keyword.get(spec.opts, :base),
      exclude_paths: Keyword.get(spec.opts, :exclude_paths, []),
      copy_to_worktree: Keyword.get(spec.opts, :copy_to_worktree, [])
    }

    agent_opts = %{
      agent: spec.agent,
      prompt: Keyword.get(spec.opts, :prompt),
      prompt_file: Keyword.get(spec.opts, :prompt_file),
      prompt_args: Keyword.get(spec.opts, :prompt_args, %{}),
      max_iterations: spec.max_iterations,
      completion_signals: spec.signals,
      idle_timeout_seconds: div(spec.idle_ms, 1000),
      completion_timeout_seconds: div(spec.completion_ms, 1000),
      resume_session: spec.resume_session,
      output: spec.output_opts
    }

    steps =
      [%Step{kind: :worktree, id: "worktree", opts: worktree_opts}] ++
        hook_steps(spec.hooks, :host, :on_worktree_ready) ++
        [
          %Step{
            kind: :sandbox,
            id: "sandbox",
            opts: %{provider: spec.sandbox_provider, config: spec.sandbox_config}
          }
        ] ++
        hook_steps(spec.hooks, :host, :on_sandbox_ready) ++
        hook_steps(spec.hooks, :sandbox, :on_sandbox_ready) ++
        [
          %Step{kind: :agent, id: "agent", opts: agent_opts},
          %Step{
            kind: :commit,
            id: "commit",
            opts: %{message: "Jobsite #{jobsite_id}"}
          }
        ] ++
        push_steps(Keyword.get(spec.opts, :push, false)) ++
        [%Step{kind: :release, id: "release", opts: %{sandbox?: true, worktree?: true}}]

    %Program{steps: steps}
  end

  defp hook_steps(nil, _target, _phase), do: []

  defp hook_steps(hooks, target, phase) do
    hooks
    |> Map.get(target, %{})
    |> Map.get(phase, [])
    |> Enum.with_index()
    |> Enum.map(fn {%{command: cmd}, i} ->
      %Step{
        kind: :hook,
        id: "hook:#{target}:#{phase}:#{i}",
        opts: %{command: cmd, target: target}
      }
    end)
  end

  defp build_result(jobsite_id, ctx) do
    last = List.last(ctx.iterations)

    %Result{
      jobsite_id: jobsite_id,
      iterations: ctx.iterations,
      branch: ctx.worktree.branch,
      commits: ctx.commits,
      status: last.status,
      text: last.text,
      output: ctx.output,
      session_id: last.session_id,
      worktree_path: ctx.worktree.path,
      merged?: ctx.merged?,
      preserved_path: ctx.preserved_path
    }
  end

  defp fail(jobsite_id, worktree, sandbox, %Error{} = error) do
    cleanup(jobsite_id, sandbox, worktree)
    dispatch(jobsite_id, "jobsite.fail", "terminal", fail_payload(error))
    {:error, error}
  end

  # Pause keeps the worktree (only the sandbox is released); cancel discards
  # everything via the same `cleanup/3` a hard failure uses.
  defp handle_interrupt(jobsite_id, :pause, reason, sandbox, _worktree, iterations) do
    last_index =
      case List.last(iterations) do
        nil -> 0
        result -> result.index
      end

    # A pause recorded before the engine reached its sandbox step interrupts with no
    # sandbox yet: there is nothing to close or release then, only the worktree to keep.
    if sandbox do
      sandbox.provider.close(sandbox.state)

      dispatch(jobsite_id, "jobsite.sandbox.release", "sandbox-release", %{
        container_id: sandbox.container_id
      })
    end

    # A jobsite can be paused again after a resume, so each pause needs its own id.
    dispatch(jobsite_id, "jobsite.pause", "pause-#{System.unique_integer([:positive])}", %{
      reason: reason,
      iteration_index: last_index
    })

    Control.clear(jobsite_id)
    {:ok, :paused}
  end

  defp handle_interrupt(jobsite_id, :cancel, reason, sandbox, worktree, _iterations) do
    cleanup(jobsite_id, sandbox, worktree)
    dispatch(jobsite_id, "jobsite.cancel", "terminal", %{reason: reason})
    Control.clear(jobsite_id)
    {:ok, :cancelled}
  end

  # `iterate/11`/`do_iterate/11` below are kept solely for
  # `resume_from_state/3`'s direct use — the fresh-run path above goes
  # through `Engine.run_program/3` instead. `extract_output/8` (output
  # re-prompt retries) and `provision_worktree/2`/`provision_sandbox/3` had
  # no other caller and were removed with the fresh-run path they served;
  # resume does not support `:output` (same as before this extraction).
  defp iterate(
         jobsite_id,
         sandbox,
         agent,
         prompt,
         index,
         max_iterations,
         signals,
         idle_ms,
         completion_ms,
         resume_session,
         acc
       ) do
    case Control.intent(jobsite_id) do
      :none ->
        do_iterate(
          jobsite_id,
          sandbox,
          agent,
          prompt,
          index,
          max_iterations,
          signals,
          idle_ms,
          completion_ms,
          resume_session,
          acc
        )

      {kind, reason} ->
        {:interrupted, kind, reason, acc}
    end
  end

  defp do_iterate(
         jobsite_id,
         sandbox,
         agent,
         prompt,
         index,
         max_iterations,
         signals,
         idle_ms,
         completion_ms,
         resume_session,
         acc
       ) do
    with {:ok, _} <-
           dispatch(jobsite_id, "jobsite.iteration.start", "iteration:#{index}:start", %{
             index: index,
             resumed_session_id: resume_session
           }) do
      runner_opts = [
        index: index,
        resume_session: resume_session,
        idle_timeout_ms: idle_ms,
        completion_timeout_ms: completion_ms,
        completion_signals: signals,
        intent_fun: fn -> Control.intent(jobsite_id) end
      ]

      case AgentRunner.run(agent, prompt, sandbox, runner_opts) do
        {:ok, %IterationResult{status: :cancelled} = result} ->
          dispatch(jobsite_id, "jobsite.iteration.complete", "iteration:#{index}:done", %{
            index: index,
            status: "cancelled",
            text: result.text,
            text_truncated?: result.text_truncated?,
            session_id: result.session_id,
            usage: result.usage,
            signalled?: result.signalled?,
            matched_signal: result.matched_signal
          })

          acc = acc ++ [result]

          case Control.intent(jobsite_id) do
            {kind, reason} -> {:interrupted, kind, reason, acc}
            :none -> {:interrupted, :cancel, "interrupted", acc}
          end

        {:ok, %IterationResult{} = result} ->
          with {:ok, _} <-
                 dispatch(jobsite_id, "jobsite.iteration.complete", "iteration:#{index}:done", %{
                   index: index,
                   status: Atom.to_string(result.status),
                   text: result.text,
                   text_truncated?: result.text_truncated?,
                   session_id: result.session_id,
                   usage: result.usage,
                   signalled?: result.signalled?,
                   matched_signal: result.matched_signal
                 }) do
            acc = acc ++ [result]

            cond do
              result.signalled? ->
                {:ok, acc}

              index >= max_iterations ->
                {:ok, acc}

              true ->
                iterate(
                  jobsite_id,
                  sandbox,
                  agent,
                  prompt,
                  index + 1,
                  max_iterations,
                  signals,
                  idle_ms,
                  completion_ms,
                  result.session_id,
                  acc
                )
            end
          end

        {:error, %Error{} = error} ->
          dispatch(jobsite_id, "jobsite.iteration.fail", "iteration:#{index}:done", %{
            index: index,
            code: Atom.to_string(error.code),
            message: error.message,
            details: error.details
          })

          {:error, error}
      end
    end
  end

  # The remote is fixed here, never caller-supplied: a spec can only ask for a
  # push, not choose where it goes.
  @push_remote "origin"

  defp push_steps(true), do: [%Step{kind: :push, id: "push", opts: %{remote: @push_remote}}]
  defp push_steps(false), do: []

  # Resume has no program, so the persisted `push?` flag (set from the start
  # event) is what makes a resumed run publish its branch like a fresh one.
  defp maybe_push(%{push?: true}, %{branch: branch, path: path}) when is_binary(branch),
    do: Git.push(path, @push_remote, branch)

  defp maybe_push(%{push?: true}, _worktree),
    do: {:error, Error.new(:push_failed, "nothing to push: the run has no named branch", %{})}

  defp maybe_push(%{push?: false}, _worktree), do: :ok

  defp commit_and_record(jobsite_id, worktree) do
    with {:ok, _} <- Git.commit_all(worktree.path, "Jobsite #{jobsite_id}"),
         {:ok, commits} <- Git.commits_between(worktree.path, worktree.base_sha, "HEAD"),
         {:ok, _} <-
           dispatch(jobsite_id, "jobsite.commits.record", "commits", %{commits: commits}) do
      {:ok, commits}
    end
  end

  defp release_all(jobsite_id, sandbox, worktree) do
    with :ok <- sandbox.provider.close(sandbox.state),
         {:ok, _} <-
           dispatch(jobsite_id, "jobsite.sandbox.release", "sandbox-release", %{
             container_id: sandbox.container_id
           }),
         {:ok, release} <- Worktree.close(worktree),
         {:ok, _} <-
           dispatch(jobsite_id, "jobsite.worktree.release", "worktree-release", %{
             merged?: release.merged?,
             preserved_path: release.preserved_path
           }) do
      {:ok, release}
    end
  end

  defp cleanup(_jobsite_id, sandbox, worktree) do
    if sandbox do
      case sandbox.provider.close(sandbox.state) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Jobsite cleanup: sandbox close failed: #{inspect(reason)}")
      end
    end

    if worktree do
      case Worktree.discard(worktree) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Jobsite cleanup: worktree discard failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------
  # Resume
  # ---------------------------------------------------------------------

  @spec resume(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def resume(jobsite_id, opts) do
    {state, _version} = Aggregate.load(ForemanServer.Aggregates.Jobsite, "jobsite:" <> jobsite_id)
    do_resume(jobsite_id, state, opts)
  end

  defp do_resume(jobsite_id, %{exists?: false}, _opts) do
    {:error,
     Error.new(:jobsite_not_found, "jobsite #{jobsite_id} does not exist", %{
       jobsite_id: jobsite_id
     })}
  end

  defp do_resume(jobsite_id, %{terminal?: true, status: status}, _opts) do
    {:error,
     Error.new(:not_resumable, "jobsite #{jobsite_id} is already #{status}", %{
       jobsite_id: jobsite_id,
       status: status
     })}
  end

  defp do_resume(jobsite_id, agg_state, opts) do
    if File.dir?(agg_state.worktree_path) do
      resume_from_state(jobsite_id, agg_state, opts)
    else
      {:error,
       Error.new(:worktree_vanished, "worktree #{agg_state.worktree_path} no longer exists", %{
         path: agg_state.worktree_path
       })}
    end
  end

  # `resume/1`'s whole point is to work with no caller-supplied options: the
  # agent and sandbox provider are rebuilt from what `JobsiteStarted`
  # persisted, not re-supplied. The one piece deliberately NOT replayed is
  # the original prompt — only `prompt_digest` is persisted, not the prompt
  # text itself, so a resumed iteration sends a plain continuation prompt
  # and relies on `resume_session` for the agent's own conversation memory.
  defp resume_from_state(jobsite_id, agg_state, opts) do
    with {:ok, sandbox_provider} <- Sandboxes.resolve(agg_state.sandbox_provider),
         {:ok, agent} <- agent_from_state(agg_state.agent) do
      sandbox_config = agg_state.sandbox_config || %{}

      worktree = %Worktree{
        repo_path: agg_state.repo_path,
        path: agg_state.worktree_path,
        branch: agg_state.branch,
        strategy: strategy_from_string(agg_state.strategy),
        base_sha: agg_state.base_sha,
        target_branch: agg_state.target_branch
      }

      with {:ok, sandbox} <-
             Worktree.create_sandbox(worktree,
               sandbox: {sandbox_provider, sandbox_config},
               jobsite_id: jobsite_id
             ),
           {:ok, _} <-
             dispatch(
               jobsite_id,
               "jobsite.sandbox.provision",
               "sandbox:#{agg_state.sandbox_attempt + 1}",
               %{
                 provider: sandbox_provider.name(),
                 sandbox_repo_path: sandbox.sandbox_repo_path,
                 container_id: sandbox.container_id
               }
             ) do
        resume_index = agg_state.iteration_index + 1
        prompt_text = Keyword.get(opts, :prompt, "Continue.")
        prior_iterations = prior_iteration_results(agg_state)

        with {:ok, _} <- maybe_fail_open_iteration(jobsite_id, agg_state),
             {:ok, fresh_iterations} <-
               iterate(
                 jobsite_id,
                 sandbox,
                 agent,
                 prompt_text,
                 resume_index,
                 max(agg_state.max_iterations, resume_index),
                 agg_state.completion_signals,
                 Keyword.get(opts, :idle_timeout_seconds, @default_idle_timeout_seconds) * 1000,
                 Keyword.get(
                   opts,
                   :completion_timeout_seconds,
                   @default_completion_timeout_seconds
                 ) * 1000,
                 agg_state.session_id,
                 []
               ),
             {:ok, commits} <- commit_and_record(jobsite_id, worktree),
             :ok <- maybe_push(agg_state, worktree),
             {:ok, release} <- release_all(jobsite_id, sandbox, worktree) do
          iterations = prior_iterations ++ fresh_iterations
          last = List.last(iterations)

          dispatch(jobsite_id, "jobsite.complete", "terminal", %{
            iterations_run: length(iterations),
            branch: worktree.branch
          })

          {:ok,
           %Result{
             jobsite_id: jobsite_id,
             iterations: iterations,
             branch: worktree.branch,
             commits: commits,
             status: last.status,
             text: last.text,
             session_id: last.session_id,
             worktree_path: worktree.path,
             merged?: release.merged?,
             preserved_path: release.preserved_path
           }}
        else
          {:error, %Error{} = error} ->
            cleanup(jobsite_id, sandbox, worktree)
            dispatch(jobsite_id, "jobsite.fail", "terminal", fail_payload(error))
            {:error, error}

          {:interrupted, kind, reason, fresh_iterations} ->
            handle_interrupt(
              jobsite_id,
              kind,
              reason,
              sandbox,
              worktree,
              prior_iterations ++ fresh_iterations
            )
        end
      end
    end
  end

  defp agent_from_state(agent_map) do
    with {:ok, approval_mode} <-
           approval_mode_from_state(Aggregate.get(agent_map, :approval_mode)) do
      {:ok,
       %ForemanServer.Jobsite.Agent{
         provider: Aggregate.get(agent_map, :provider) |> to_existing_atom(),
         model: Aggregate.get(agent_map, :model),
         effort: Aggregate.get(agent_map, :effort) |> to_existing_atom(),
         provider_options: Aggregate.get(agent_map, :provider_options, %{}),
         binary: Aggregate.get(agent_map, :binary),
         approval_mode: approval_mode
       }}
    end
  end

  # Explicit table, not String.to_existing_atom/1: on a cold resume (fresh VM) these
  # atoms may not be loaded yet.
  @approval_modes %{
    "default" => :default,
    "prompt" => :prompt,
    "auto_edit" => :auto_edit,
    "auto_approve" => :auto_approve
  }

  defp approval_mode_from_state(nil), do: {:ok, nil}
  defp approval_mode_from_state(mode) when is_atom(mode), do: {:ok, mode}

  defp approval_mode_from_state(mode) when is_binary(mode) do
    case Map.fetch(@approval_modes, mode) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         Error.new(:resume_state_invalid, "persisted agent approval_mode is not recognised", %{
           approval_mode: mode
         })}
    end
  end

  defp to_existing_atom(nil), do: nil
  defp to_existing_atom(value) when is_atom(value), do: value
  defp to_existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp maybe_fail_open_iteration(jobsite_id, %{iteration_open?: true, iteration_index: index}) do
    dispatch(jobsite_id, "jobsite.iteration.fail", "iteration:#{index}:interrupted", %{
      index: index,
      code: "agent_interrupted",
      message: "iteration interrupted by executor crash or pause"
    })
  end

  defp maybe_fail_open_iteration(_jobsite_id, _agg_state), do: {:ok, nil}

  # Merges the completed-before-crash iterations recorded on the aggregate
  # with a synthesized record for an iteration that was open (in flight) at
  # crash/pause time, so `Result.iterations` reflects the full history across
  # a resume boundary, not just what this resume attempt itself produced.
  defp prior_iteration_results(%{
         iterations: records,
         iteration_open?: true,
         iteration_index: index
       }) do
    Enum.map(records, &iteration_result_from_map/1) ++
      [%IterationResult{index: index, status: :failed, text: ""}]
  end

  defp prior_iteration_results(%{iterations: records}) do
    Enum.map(records, &iteration_result_from_map/1)
  end

  defp iteration_result_from_map(record) do
    %IterationResult{
      index: Map.fetch!(record, :index),
      status: status_atom(Map.fetch!(record, :status)),
      text: Map.get(record, :text) || "",
      text_truncated?: Map.get(record, :text_truncated?, false),
      session_id: Map.get(record, :session_id),
      usage: Map.get(record, :usage) || %{},
      signalled?: Map.get(record, :signalled?, false),
      matched_signal: Map.get(record, :matched_signal)
    }
  end

  defp status_atom(status) when is_atom(status), do: status
  defp status_atom(status) when is_binary(status), do: String.to_existing_atom(status)

  defp strategy_from_string("head"), do: :head
  defp strategy_from_string("merge_to_head"), do: :merge_to_head
  defp strategy_from_string("branch:" <> name), do: {:branch, name}
  defp strategy_from_string(other), do: other

  # ---------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------

  defp start_payload(jobsite_id, spec) do
    %{
      jobsite_id: jobsite_id,
      repo_path: spec.repo_path,
      strategy: strategy_to_string(spec.strategy),
      agent: %{
        provider: Atom.to_string(spec.agent.provider),
        model: spec.agent.model,
        effort: spec.agent.effort && Atom.to_string(spec.agent.effort),
        binary: spec.agent.binary,
        approval_mode: spec.agent.approval_mode && Atom.to_string(spec.agent.approval_mode),
        provider_options: spec.agent.provider_options
      },
      sandbox_provider: spec.sandbox_provider.name(),
      sandbox_config: spec.sandbox_config,
      max_iterations: spec.max_iterations,
      completion_signals: spec.signals,
      name: Keyword.get(spec.opts, :name),
      push: Keyword.get(spec.opts, :push, false) == true
    }
  end

  defp strategy_to_string(:head), do: "head"
  defp strategy_to_string(:merge_to_head), do: "merge_to_head"
  defp strategy_to_string({:branch, name}), do: "branch:" <> name

  defp fail_payload(%Error{} = error) do
    %{code: Atom.to_string(error.code), message: error.message, details: error.details}
  end

  defp normalize_signals(nil), do: []
  defp normalize_signals(signal) when is_binary(signal), do: [signal]
  defp normalize_signals(signals) when is_list(signals), do: signals

  defp dispatch(jobsite_id, type, suffix, payload) do
    command = %{
      type: type,
      # The command type is part of the id: `CommandRouter` deduplicates by command_id,
      # and a shared "terminal" suffix let a pause swallow the `jobsite.complete` /
      # `jobsite.fail` / `jobsite.cancel` of the resumed run, leaving it `paused` forever.
      command_id: "jobsite:#{jobsite_id}:#{type}:#{suffix}",
      aggregate_id: "jobsite:#{jobsite_id}",
      payload: Map.put(payload, :jobsite_id, jobsite_id)
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.error(
          "Jobsite #{jobsite_id} dispatch #{type} (#{suffix}) rejected: #{inspect(reason)}"
        )

        {:error, Error.new(:dispatch_rejected, "dispatch #{type} rejected", %{reason: reason})}
    end
  end
end
