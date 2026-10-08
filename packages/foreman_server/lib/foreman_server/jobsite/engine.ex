defmodule ForemanServer.Jobsite.Engine do
  @moduledoc """
  Runs a `ForemanServer.Jobsite.Program` against a
  `ForemanServer.Jobsite.Context`, reducing its steps in order. Shared by
  `ForemanServer.Jobsite.Executor` (script front-end, step 14/19) and
  `ForemanServer.Workflow.RunExecutor` via `ForemanServer.Workflow.Lowering`
  (manifest front-end, step 21/23) — both compile to the same `Program`
  shape so this module never knows which produced it.

  | kind | opts keys | effect |
  |---|---|---|
  | `:worktree` | `repo_path, strategy, path, base, exclude_paths, copy_to_worktree, provided` | `Worktree.create/1`; reuses `ctx.worktree` when already provisioned; `provided` (set by the observer's `step_started/3`) is a worktree the observer already provisioned and wins over both |
  | `:sandbox` | `provider, config` | `Worktree.create_sandbox/2`; sets `ctx.sandbox` |
  | `:hook` | `command, target (:host \\| :sandbox)` | runs the command; non-zero aborts the program |
  | `:agent` | `runner, prompt, prompt_file, prompt_args, max_iterations, completion_signals, idle_timeout_seconds, completion_timeout_seconds, resume_session, output, launch` | the iteration loop; observer's `step_completed/4` fires once per iteration; `launch` is forwarded to the runner untouched |
  | `:exec` | `cmd, cwd, timeout_ms` | `Sandbox.exec/3`; non-zero is data, not failure |
  | `:commit` | `message, defer?` | `Git.commit_all/3`, skipped when `defer?`, reported as `{:commit, :no_worktree}` when the program has no worktree |
  | `:gate` | any | a checkpoint: the engine performs no check of its own, it reports `{:gate, opts}` to the observer's `step_completed/4`, whose `{:error, _}` is the gate failing |
  | `:push` | `remote` | `Git.push/3` of the worktree's named branch; a failure fails the program (`:push_failed`) |
  | `:release` | `sandbox?, worktree?` | closes the requested resources |

  A step whose `opts` carry `uninterruptible: true` is never preceded by an
  `:intent` check: the steps that finish a unit of work (a phase's gate and
  commit) must not be separated from the step that produced the work.

  Ordering rule, inherited from the executor this replaces: side effects
  happen first, `step_completed/4` is how an observer records them — a
  rejection there (an `{:error, _}` from the observer, e.g. a dispatch
  rejection) halts the program exactly like a step failure, but the side
  effect itself is never undone by the engine; that is the observer's job
  (mirroring `Jobsite.Executor.fail/4`'s pre-engine cleanup).

  Every failure — a step's own, or an observer's rejection — is then offered
  to the observer's optional `step_failed/4`, which may keep it a failure,
  replace the error, or turn it into an interruption (how a manifest run
  maps "the agent died because an operator paused the run" to a pause).

  `opts`: `:observer` (module, required), `:observer_state` (term, passed to
  every callback and threaded forward), `:intent` (0-arity function
  consulted before each interruptible step and between agent iterations —
  `:none` or `{kind, reason}`), `:resume_from` (how many leading steps to
  skip, for a program resuming after a crash).

  The observer's final state is part of every outcome: a front-end that
  keeps its own run state in it (`RunExecutor`) reads it back from there.
  """

  alias ForemanServer.Jobsite.{
    Context,
    Error,
    IterationResult,
    Output,
    Prompt,
    Sandbox,
    Step,
    Worktree
  }

  @type outcome ::
          {:ok, Context.t(), term()}
          | {:error, Error.t(), Context.t(), term()}
          | {:interrupted, atom(), String.t(), Context.t(), term()}

  # What a single step returns internally: no context on error (the failing
  # step's context is the one the loop already holds), but always the
  # observer state as of the failure.
  @typep step_outcome ::
           {:ok, Context.t(), term()}
           | {:error, Error.t(), term()}
           | {:interrupted, atom(), String.t(), Context.t(), term()}

  @spec run_program(ForemanServer.Jobsite.Program.t(), Context.t(), keyword()) :: outcome()
  def run_program(%ForemanServer.Jobsite.Program{steps: steps} = program, %Context{} = ctx, opts) do
    observer = Keyword.fetch!(opts, :observer)
    observer_state = Keyword.get(opts, :observer_state)
    intent_fun = Keyword.get(opts, :intent, fn -> :none end)
    resume_from = Keyword.get(opts, :resume_from, 0)

    case validate_runner_capabilities(program) do
      :ok ->
        steps
        |> Enum.drop(resume_from)
        |> run_steps(ctx, observer, observer_state, intent_fun)

      {:error, %Error{} = error} ->
        {:error, error, ctx, observer_state}
    end
  end

  # Rejected before any step runs: a runner whose `capabilities().iterations
  # == :one` cannot honor `max_iterations > 1` or a non-empty completion
  # signal list (it has no loop and performs no signal matching) — the
  # supported path for a manifest phase that must loop is a second `:agent`
  # step in the lowered program, each still one Overwatch-tracked worker.
  defp validate_runner_capabilities(%ForemanServer.Jobsite.Program{steps: steps}) do
    Enum.reduce_while(steps, :ok, fn
      %Step{kind: :agent, opts: opts}, :ok ->
        runner = Map.get(opts, :runner, ForemanServer.Jobsite.Runners.Direct)

        if runner.capabilities().iterations == :one and
             (Map.get(opts, :max_iterations, 1) > 1 or
                Map.get(opts, :completion_signals, []) != []) do
          {:halt,
           {:error,
            Error.new(
              :runner_capability,
              "runner #{inspect(runner)} supports only one iteration and no completion signal matching",
              %{runner: runner, max_iterations: Map.get(opts, :max_iterations, 1)}
            )}}
        else
          {:cont, :ok}
        end

      _step, :ok ->
        {:cont, :ok}
    end)
  end

  defp run_steps([], ctx, _observer, observer_state, _intent_fun), do: {:ok, ctx, observer_state}

  defp run_steps([step | rest], ctx, observer, observer_state, intent_fun) do
    case check_intent(step, intent_fun) do
      {kind, reason} ->
        {:interrupted, kind, reason, ctx, observer_state}

      :none ->
        case run_step(step, ctx, observer, observer_state, intent_fun) do
          {:ok, ctx2, observer_state2} ->
            run_steps(rest, ctx2, observer, observer_state2, intent_fun)

          {:error, %Error{} = error, observer_state2} ->
            step_failed(step, error, ctx, observer, observer_state2)

          {:interrupted, _kind, _reason, _ctx, _observer_state} = interrupted ->
            interrupted
        end
    end
  end

  defp check_intent(%Step{opts: %{uninterruptible: true}}, _intent_fun), do: :none
  defp check_intent(%Step{}, intent_fun), do: intent_fun.()

  # `step_failed/4` is optional: an observer that has nothing to do on
  # failure (`Jobsite.Executor`'s, which cleans up after the engine returns)
  # simply omits it.
  defp step_failed(step, error, ctx, observer, observer_state) do
    if Code.ensure_loaded?(observer) and function_exported?(observer, :step_failed, 4) do
      case observer.step_failed(step, error, ctx, observer_state) do
        {:ok, observer_state2} ->
          {:error, error, ctx, observer_state2}

        {:error, %Error{} = replacement, observer_state2} ->
          {:error, replacement, ctx, observer_state2}

        {:interrupted, kind, reason, observer_state2} ->
          {:interrupted, kind, reason, ctx, observer_state2}
      end
    else
      {:error, error, ctx, observer_state}
    end
  end

  # `step_started/3` may return a third element: opts to merge into THIS
  # step only. It is how an observer hands the step something it can only
  # compute at run time (a worktree it provisioned, an agent launch spec
  # built from run state) without the program having to know it up front.
  @spec start_step(Step.t(), Context.t(), module(), term()) ::
          {:ok, Step.t(), term()} | {:error, Error.t(), term()}
  defp start_step(step, ctx, observer, observer_state) do
    case observer.step_started(step, ctx, observer_state) do
      {:ok, observer_state2} ->
        {:ok, step, observer_state2}

      {:ok, observer_state2, %{} = overrides} ->
        {:ok, %Step{step | opts: Map.merge(step.opts, overrides)}, observer_state2}

      {:error, %Error{} = error} ->
        {:error, error, observer_state}
    end
  end

  # ---------------------------------------------------------------------
  # :worktree
  # ---------------------------------------------------------------------

  @spec run_step(Step.t(), Context.t(), module(), term(), (-> :none | {atom(), String.t()})) ::
          step_outcome()
  defp run_step(%Step{kind: :worktree} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      case {Map.get(step.opts, :provided), ctx.worktree} do
        {%Worktree{} = worktree, _} ->
          complete(
            step,
            %Context{ctx | worktree: worktree},
            observer,
            observer_state,
            {:worktree, worktree, :provided}
          )

        {nil, %Worktree{} = worktree} ->
          complete(
            step,
            %Context{ctx | worktree: worktree},
            observer,
            observer_state,
            {:worktree, worktree, :reused}
          )

        {nil, nil} ->
          worktree_opts =
            step.opts
            |> Map.take([:repo_path, :strategy, :path, :base, :exclude_paths, :copy_to_worktree])
            |> Map.put_new(:repo_path, ctx.repo_path)
            |> Map.to_list()

          case Worktree.create(worktree_opts) do
            {:ok, worktree} ->
              complete(
                step,
                %Context{ctx | worktree: worktree},
                observer,
                observer_state,
                {:worktree, worktree, :created}
              )

            {:error, %Error{} = err} ->
              {:error, err, observer_state}
          end
      end
    end
  end

  # ---------------------------------------------------------------------
  # :sandbox
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :sandbox} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      provider = Map.fetch!(step.opts, :provider)
      config = Map.get(step.opts, :config, %{})

      sandbox_opts = [sandbox: {provider, config}, jobsite_id: ctx.jobsite_id]

      case Worktree.create_sandbox(ctx.worktree, sandbox_opts) do
        {:ok, sandbox} ->
          complete(
            step,
            %Context{ctx | sandbox: sandbox},
            observer,
            observer_state,
            {:sandbox, sandbox}
          )

        {:error, %Error{} = err} ->
          {:error, err, observer_state}
      end
    end
  end

  # ---------------------------------------------------------------------
  # :hook — a single setup command; non-zero exit is fatal (unlike :exec).
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :hook} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      command = Map.fetch!(step.opts, :command)
      target = Map.get(step.opts, :target, :sandbox)

      exec_outcome =
        case target do
          :host -> run_host_command(command, ctx.worktree.path)
          :sandbox -> Sandbox.exec(ctx.sandbox, command)
        end

      case exec_outcome do
        {:ok, %{exit_code: 0} = result} ->
          complete(step, ctx, observer, observer_state, {:hook, result})

        {:ok, %{exit_code: code} = result} ->
          {:error,
           Error.new(:hook_failed, "hook exited non-zero", %{
             command: command,
             exit_code: code,
             output: result.stdout
           }), observer_state}

        {:error, %Error{} = err} ->
          {:error, err, observer_state}
      end
    end
  end

  # ---------------------------------------------------------------------
  # :exec — non-zero exit is data, not a program failure.
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :exec} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      cmd = Map.fetch!(step.opts, :cmd)
      exec_opts = step.opts |> Map.take([:cwd, :timeout_ms]) |> Map.to_list()

      case Sandbox.exec(ctx.sandbox, cmd, exec_opts) do
        {:ok, result} -> complete(step, ctx, observer, observer_state, {:exec, result})
        {:error, %Error{} = err} -> {:error, err, observer_state}
      end
    end
  end

  # ---------------------------------------------------------------------
  # :commit
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :commit} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      cond do
        Map.get(step.opts, :defer?, false) ->
          complete(step, ctx, observer, observer_state, {:commit, :deferred})

        is_nil(ctx.worktree) ->
          complete(step, ctx, observer, observer_state, {:commit, :no_worktree})

        true ->
          message = Map.fetch!(step.opts, :message)

          case ForemanServer.Jobsite.Git.commit_all(ctx.worktree.path, message) do
            {:ok, outcome} -> complete(step, ctx, observer, observer_state, {:commit, outcome})
            {:error, %Error{} = err} -> {:error, err, observer_state}
          end
      end
    end
  end

  # ---------------------------------------------------------------------
  # :push — publishes the run's named branch to a server-chosen remote, after
  # the commit. A failure is the program's failure, not data: the commits stay
  # on the branch in the repository, and the jobsite fails with `:push_failed`.
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :push} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      case ctx.worktree do
        %{branch: branch, path: path} when is_binary(branch) ->
          remote = Map.fetch!(step.opts, :remote)

          case ForemanServer.Jobsite.Git.push(path, remote, branch) do
            :ok -> complete(step, ctx, observer, observer_state, {:push, remote, branch})
            {:error, %Error{} = err} -> {:error, err, observer_state}
          end

        _no_named_branch ->
          {:error, Error.new(:push_failed, "nothing to push: the run has no named branch", %{}),
           observer_state}
      end
    end
  end

  # ---------------------------------------------------------------------
  # :gate — a checkpoint. What a gate checks is front-end vocabulary (for a
  # workflow phase, `requiredFile:` discovery against run state the engine
  # has no view of), so the check lives in the observer's `step_completed/4`
  # and the engine only guarantees WHEN it runs: after the agent, before the
  # commit.
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :gate} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      complete(step, ctx, observer, observer_state, {:gate, step.opts})
    end
  end

  # ---------------------------------------------------------------------
  # :release
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :release} = step, ctx, observer, observer_state, _intent_fun) do
    with {:ok, step, observer_state} <- start_step(step, ctx, observer, observer_state) do
      close_sandbox? = Map.get(step.opts, :sandbox?, true)
      close_worktree? = Map.get(step.opts, :worktree?, false)

      sandbox_release =
        if close_sandbox? and ctx.sandbox do
          ctx.sandbox.provider.close(ctx.sandbox.state)
        else
          :skipped
        end

      worktree_release =
        if close_worktree? and ctx.worktree do
          Worktree.close(ctx.worktree)
        else
          {:ok, nil}
        end

      case worktree_release do
        {:ok, release_info} ->
          complete(step, ctx, observer, observer_state, {:release, sandbox_release, release_info})

        {:error, %Error{} = err} ->
          {:error, err, observer_state}
      end
    end
  end

  # ---------------------------------------------------------------------
  # :agent — the iteration loop. `step_completed/4` fires once per
  # iteration (not once for the whole step), so an observer can record
  # per-iteration progress exactly as it did before this extraction.
  # ---------------------------------------------------------------------

  defp run_step(%Step{kind: :agent} = step, ctx, observer, observer_state, intent_fun) do
    case Prompt.resolve(agent_prompt_opts(step.opts), ctx.sandbox, %{}) do
      {:ok, prompt_text} ->
        iterate_agent(step, ctx, observer, observer_state, intent_fun, prompt_text, 1, [])

      {:error, %Error{} = error} ->
        {:error, error, observer_state}
    end
  end

  defp agent_prompt_opts(opts) do
    opts
    |> Map.take([:prompt, :prompt_file, :prompt_args])
    |> Map.to_list()
  end

  # The one deliberate inversion inherited from `Jobsite.Executor`:
  # `step_started/3` is called BEFORE the agent spawns (not once before the
  # whole multi-iteration step), carrying `iteration_index`/`resume_session`
  # in the step's own opts, so an observer can dispatch an
  # "iteration starting" event the same way `jobsite.iteration.start` used
  # to be dispatched — a crash mid-agent then leaves that event as the
  # durable marker resume detects. Whatever the observer returns as
  # overrides applies to this iteration's step, which is what the runner
  # reads.
  defp iterate_agent(step, ctx, observer, observer_state, intent_fun, prompt, index, acc) do
    resume_session = if index == 1, do: Map.get(step.opts, :resume_session), else: ctx.session_id

    iteration_step = %Step{
      step
      | opts: Map.merge(step.opts, %{iteration_index: index, resume_session: resume_session})
    }

    with {:ok, iteration_step, observer_state} <-
           start_step(iteration_step, ctx, observer, observer_state) do
      run_agent_iteration(
        iteration_step,
        ctx,
        observer,
        observer_state,
        intent_fun,
        prompt,
        index,
        resume_session,
        acc
      )
    end
  end

  defp run_agent_iteration(
         step,
         ctx,
         observer,
         observer_state,
         intent_fun,
         prompt,
         index,
         resume_session,
         acc
       ) do
    max_iterations = Map.get(step.opts, :max_iterations, 1)
    agent = Map.fetch!(step.opts, :agent)
    runner = Map.get(step.opts, :runner, ForemanServer.Jobsite.Runners.Direct)
    signals = Map.get(step.opts, :completion_signals, [])
    idle_ms = Map.get(step.opts, :idle_timeout_seconds, 600) * 1000
    completion_ms = Map.get(step.opts, :completion_timeout_seconds, 60) * 1000

    runner_opts =
      [
        index: index,
        resume_session: resume_session,
        idle_timeout_ms: idle_ms,
        completion_timeout_ms: completion_ms,
        completion_signals: signals,
        intent_fun: intent_fun,
        run_id: ctx.jobsite_id,
        cwd: (ctx.worktree && ctx.worktree.path) || (ctx.sandbox && ctx.sandbox.worktree.path)
      ]
      |> put_launch(step.opts)

    case runner.run(agent, prompt, ctx.sandbox, runner_opts) do
      {:ok, %IterationResult{status: :cancelled} = result} ->
        ctx = %Context{
          ctx
          | iterations: ctx.iterations ++ [result],
            session_id: result.session_id || ctx.session_id
        }

        case observer.step_completed(step, ctx, {:agent_iteration, result}, observer_state) do
          {:ok, ctx, observer_state2} ->
            case intent_fun.() do
              {kind, reason} -> {:interrupted, kind, reason, ctx, observer_state2}
              :none -> {:interrupted, :cancel, "interrupted", ctx, observer_state2}
            end

          {:error, %Error{} = err} ->
            {:error, err, observer_state}
        end

      {:ok, %IterationResult{} = result} ->
        ctx = %Context{
          ctx
          | iterations: ctx.iterations ++ [result],
            session_id: result.session_id || ctx.session_id
        }

        case observer.step_completed(step, ctx, {:agent_iteration, result}, observer_state) do
          {:ok, ctx, observer_state2} ->
            acc = acc ++ [result]

            cond do
              result.signalled? ->
                finish_agent_step(step, ctx, observer, observer_state2, acc)

              index >= max_iterations ->
                finish_agent_step(step, ctx, observer, observer_state2, acc)

              true ->
                iterate_agent(
                  step,
                  ctx,
                  observer,
                  observer_state2,
                  intent_fun,
                  prompt,
                  index + 1,
                  acc
                )
            end

          {:error, %Error{} = err} ->
            {:error, err, observer_state}
        end

      {:error, %Error{} = error} ->
        dispatch_iteration_failure(step, ctx, observer, observer_state, error)
    end
  end

  defp put_launch(runner_opts, step_opts) do
    case Map.fetch(step_opts, :launch) do
      {:ok, launch} -> Keyword.put(runner_opts, :launch, launch)
      :error -> runner_opts
    end
  end

  defp dispatch_iteration_failure(step, ctx, observer, observer_state, error) do
    case observer.step_completed(step, ctx, {:agent_iteration_failed, error}, observer_state) do
      {:ok, _ctx, observer_state2} -> {:error, error, observer_state2}
      {:error, %Error{} = err} -> {:error, err, observer_state}
    end
  end

  defp finish_agent_step(step, ctx, observer, observer_state, iterations) do
    case Map.get(step.opts, :output) do
      nil -> complete(step, ctx, observer, observer_state, {:agent, iterations})
      %Output{} = spec -> extract_output(step, ctx, observer, observer_state, spec, iterations, 0)
    end
  end

  defp extract_output(step, ctx, observer, observer_state, spec, iterations, attempt) do
    last = List.last(iterations)

    case Output.extract(spec, last.text) do
      {:ok, value} ->
        ctx = %Context{ctx | output: value}
        complete(step, ctx, observer, observer_state, {:agent, iterations})

      {:error, %Error{} = error} when attempt < spec.max_retries ->
        retry_prompt =
          "Your previous output failed: #{error.message}. Re-emit it inside <#{spec.tag}> tags."

        retry_index = length(iterations) + 1

        retry_step = %Step{
          step
          | opts:
              Map.merge(step.opts, %{
                iteration_index: retry_index,
                resume_session: last.session_id
              })
        }

        with {:ok, retry_step, observer_state} <-
               start_step(retry_step, ctx, observer, observer_state) do
          agent = Map.fetch!(step.opts, :agent)
          runner = Map.get(step.opts, :runner, ForemanServer.Jobsite.Runners.Direct)

          case runner.run(
                 agent,
                 retry_prompt,
                 ctx.sandbox,
                 resume_session: last.session_id,
                 idle_timeout_ms: Map.get(step.opts, :idle_timeout_seconds, 600) * 1000,
                 completion_timeout_ms:
                   Map.get(step.opts, :completion_timeout_seconds, 60) * 1000,
                 index: retry_index
               ) do
            {:ok, %IterationResult{} = retried} ->
              ctx = %Context{
                ctx
                | iterations: ctx.iterations ++ [retried],
                  session_id: retried.session_id || ctx.session_id
              }

              case observer.step_completed(
                     retry_step,
                     ctx,
                     {:agent_iteration, retried},
                     observer_state
                   ) do
                {:ok, ctx, observer_state2} ->
                  extract_output(
                    step,
                    ctx,
                    observer,
                    observer_state2,
                    spec,
                    iterations ++ [retried],
                    attempt + 1
                  )

                {:error, %Error{} = err} ->
                  {:error, err, observer_state}
              end

            {:error, %Error{} = error} ->
              dispatch_iteration_failure(retry_step, ctx, observer, observer_state, error)
          end
        end

      {:error, %Error{} = err} ->
        {:error, err, observer_state}
    end
  end

  defp complete(step, ctx, observer, observer_state, result) do
    case observer.step_completed(step, ctx, result, observer_state) do
      {:ok, ctx, observer_state2} -> {:ok, ctx, observer_state2}
      {:error, %Error{} = err} -> {:error, err, observer_state}
    end
  end

  defp run_host_command(command, cwd) do
    case System.cmd("sh", ["-c", command], cd: cwd, stderr_to_stdout: true) do
      {output, code} -> {:ok, %{exit_code: code, stdout: output, stderr: ""}}
    end
  end
end
