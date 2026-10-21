defmodule ForemanServer.Coordinator.Executor do
  @moduledoc """
  The single choke point where coordinator actions become side effects.

  The model proposes, Foreman disposes: `run/2` receives already-normalised
  `Coordinator.Action`s (or the rejection of a raw one), checks `Coordinator.Policy`
  and the caps, and only then calls Foreman, always through
  `Coordinator.Dispatch` (closed command allowlist) or a domain facade
  (`Threads.Actions`, `ProjectMemory`). Nothing else in the coordinator may
  call `CommandGateway`.

  Every action yields exactly one outcome, recorded as a
  `CoordinatorActionRecorded` event so the NEXT turn sees what happened: status
  `executed | proposed | rejected | failed` with a reason. A rejected action
  never aborts the turn.

  Idempotency: command ids are pure functions of the action id (itself a hash of
  project, trigger message and action content), so re-running an interrupted
  turn re-issues identical commands and `CommandRouter` appends nothing twice.
  An action already recorded `executed`/`proposed` is not executed again.

  Enforcement, not advice: `propose_before_start` forces every thread this module
  creates to stay `open` (a proposal) whatever the model emitted; the active
  thread cap, per-turn caps and the project's daily thread cap reject visibly.
  """

  require Logger

  alias ForemanServer.Coordinator.{
    Action,
    Commands,
    Dispatch,
    MemoryGuard,
    Policy,
    Redact,
    WorkflowSelector
  }

  alias ForemanServer.{ProjectionStore, ProjectMemory}

  @terminal_thread_statuses ~w(completed failed cancelled)

  defmodule Ctx do
    @moduledoc "Everything one turn's execution needs; built by the Runner."
    @enforce_keys [:project_id, :turn_id, :trigger_key, :authority]
    defstruct [
      :project_id,
      :turn_id,
      :trigger_key,
      :authority,
      operator_texts: [],
      tuning: %ForemanServer.Coordinator.Tuning{},
      workflows: [],
      recorded: %{},
      gateway: ForemanServer.CommandGateway,
      threads: ForemanServer.Threads,
      thread_actions: ForemanServer.Threads.Actions,
      max_actions: 10,
      max_threads_per_turn: 5
    ]
  end

  @type item :: {:ok, Action.t()} | {:invalid, term(), term()}
  @type outcome :: %{
          action_id: String.t(),
          kind: String.t(),
          params: map(),
          status: String.t(),
          reason: String.t() | nil,
          result_ref: map() | nil
        }

  @doc "Run every item in order and record each outcome."
  @spec run([item()], Ctx.t()) :: [outcome()]
  def run(items, %Ctx{} = ctx) when is_list(items) do
    {outcomes, _state} =
      items
      |> Enum.with_index()
      |> Enum.reduce({[], %{started: 0}}, fn {item, index}, {acc, state} ->
        {outcome, state} = run_one(item, index, ctx, state)
        {[outcome | acc], state}
      end)

    Enum.reverse(outcomes)
  end

  @doc "Operator-visible summary of outcomes that need attention (or nil)."
  @spec notice([outcome()]) :: String.t() | nil
  def notice(outcomes) do
    lines =
      Enum.flat_map(outcomes, fn
        %{status: "rejected", kind: kind, reason: reason} -> ["I did not run #{kind}: #{reason}"]
        %{status: "failed", kind: kind, reason: reason} -> ["#{kind} failed: #{reason}"]
        %{status: "proposed"} = o -> [proposal_text(o)]
        _ -> []
      end)

    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------- one action

  defp run_one({:invalid, raw, reason}, index, ctx, state) do
    id = Action.rejected_id(raw, ctx.project_id, ctx.trigger_key)

    outcome =
      record(ctx, %{
        action_id: id,
        kind: Action.raw_kind(raw),
        params: %{},
        status: "rejected",
        reason: reason_text(reason),
        result_ref: nil
      })

    _ = index
    {outcome, state}
  end

  defp run_one({:ok, %Action{} = action}, index, ctx, state) do
    cond do
      index >= ctx.max_actions ->
        {reject(ctx, action, {:action_cap_exceeded, ctx.max_actions}), state}

      replayed?(ctx, action) ->
        {replayed_outcome(ctx, action), state}

      true ->
        case Policy.authorize(action, ctx) do
          :ok ->
            {status, reason, result_ref, started} = safe_handle(action, ctx, state)

            outcome =
              record(ctx, %{
                action_id: action.id,
                kind: Atom.to_string(action.kind),
                params: action.params,
                status: status,
                reason: reason && reason_text(reason),
                result_ref: result_ref
              })

            {outcome, %{state | started: state.started + started}}

          {:error, reason} ->
            {reject(ctx, action, reason), state}
        end
    end
  end

  defp reject(ctx, action, reason) do
    record(ctx, %{
      action_id: action.id,
      kind: Atom.to_string(action.kind),
      params: action.params,
      status: "rejected",
      reason: reason_text(reason),
      result_ref: nil
    })
  end

  defp replayed?(ctx, action),
    do: match?(%{status: s} when s in ["executed", "proposed"], Map.get(ctx.recorded, action.id))

  defp replayed_outcome(ctx, action) do
    r = Map.fetch!(ctx.recorded, action.id)

    %{
      action_id: action.id,
      kind: r.kind,
      params: r.params,
      status: r.status,
      reason: r.reason,
      result_ref: r.result_ref
    }
  end

  # A crash inside a handler is recorded as a failed action, never raised: the
  # turn still completes and the operator sees what did not happen.
  defp safe_handle(action, ctx, state) do
    handle(action, ctx, state)
  rescue
    exception ->
      Logger.error(
        "coordinator executor: #{action.kind} crashed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      {"failed", {:exception, exception.__struct__}, nil, 0}
  end

  defp record(ctx, attrs) do
    case Commands.record_action(ctx.gateway, ctx.project_id, ctx.turn_id, attrs) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "coordinator: could not record action #{attrs.action_id}: #{inspect(other)}"
        )
    end

    attrs
  end

  # ------------------------------------------------------------------ handlers

  defp handle(%Action{kind: :answer, params: %{"text" => text}} = a, ctx, _state),
    do: reply(ctx, "answer:" <> a.id, text)

  defp handle(%Action{kind: :ask, params: params} = a, ctx, _state) do
    options =
      case params do
        %{"options" => opts} -> "\n" <> Enum.map_join(opts, "\n", &("- " <> &1))
        _ -> ""
      end

    reply(ctx, "ask:" <> a.id, params["question"] <> options)
  end

  defp handle(%Action{kind: :start_thread} = a, ctx, state), do: start_thread(a, ctx, state)
  defp handle(%Action{kind: :propose_threads} = a, ctx, state), do: propose_threads(a, ctx, state)

  defp handle(%Action{kind: :approve_proposed} = a, ctx, state),
    do: approve_proposed(a, ctx, state)

  defp handle(%Action{kind: :route_followup, params: p} = a, ctx, _state),
    do: route(ctx, a.id, p["thread_id"], p["message"])

  defp handle(%Action{kind: :remember, params: p}, ctx, _state), do: remember(ctx, p)
  defp handle(%Action{kind: :forget, params: p}, ctx, _state), do: forget(ctx, p)
  defp handle(%Action{kind: :set_tuning} = a, ctx, _state), do: set_tuning(a, ctx)

  defp handle(%Action{kind: kind} = a, ctx, _state) when kind in [:add_repo, :schedule] do
    handlers =
      :foreman_server |> Application.get_env(:coordinator, []) |> Keyword.get(:handlers, %{})

    case Map.get(handlers, kind) do
      nil -> {"rejected", {:unsupported, kind}, nil, 0}
      module -> module.handle(a, ctx)
    end
  end

  defp reply(ctx, message_id, text) do
    attrs = %{role: "coordinator", kind: "reply", text: text, turn_id: ctx.turn_id}

    case Commands.append(ctx.gateway, ctx.project_id, message_id, attrs) do
      {:ok, _} -> {"executed", nil, nil, 0}
      other -> {"failed", {:append_failed, other}, nil, 0}
    end
  end

  # -------------------------------------------------------------------- threads

  defp start_thread(%Action{params: p} = a, ctx, state) do
    with {:ok, reuse} <- reuse_target(ctx, p) do
      case reuse do
        {:thread, thread_id} ->
          {status, reason, ref, _} = route(ctx, a.id, thread_id, brief(p))
          {status, reason, put_ref(ref, "reused_thread", true), 0}

        :none ->
          create_one(ctx, a.id, 0, p, :start, state)
      end
    else
      {:error, reason} -> {"rejected", reason, nil, 0}
    end
  end

  defp propose_threads(%Action{params: %{"threads" => threads}} = a, ctx, state) do
    if length(threads) > ctx.max_threads_per_turn do
      {"rejected", {:cap_exceeded, :threads_per_turn, ctx.max_threads_per_turn}, nil, 0}
    else
      results =
        threads
        |> Enum.with_index()
        |> Enum.map(fn {spec, index} -> create_one(ctx, a.id, index, spec, :propose, state) end)

      summarize_proposals(results)
    end
  end

  defp summarize_proposals(results) do
    proposed = for {"proposed", _, ref, _} <- results, do: ref
    failures = for {status, reason, _, _} <- results, status != "proposed", do: reason

    cond do
      proposed == [] ->
        {"rejected", List.first(failures), nil, 0}

      true ->
        ref = %{
          "task_ids" => Enum.flat_map(proposed, & &1["task_ids"]),
          "threads" => Enum.flat_map(proposed, & &1["threads"])
        }

        reason =
          if failures == [], do: nil, else: {:partial, length(failures), List.first(failures)}

        {"proposed", reason, ref, 0}
    end
  end

  # One thread: select workflow -> caps -> task.create -> (approve | stay open).
  defp create_one(ctx, action_id, index, spec, mode, state) do
    with {:ok, workflow} <- WorkflowSelector.select(spec, ctx.workflows),
         :ok <- check_caps(ctx, state, mode),
         task_id = task_id(action_id, index),
         :ok <- create_task(ctx, task_id, spec, workflow) do
      ref = %{
        "task_ids" => [task_id],
        "threads" => [%{"task_id" => task_id, "title" => spec["title"], "workflow" => workflow}]
      }

      if mode == :start and not ctx.tuning.propose_before_start do
        approve(ctx, task_id, ref)
      else
        reason = if mode == :start, do: :propose_before_start, else: nil
        {"proposed", reason, ref, 0}
      end
    else
      {:error, reason} -> {"rejected", reason, nil, 0}
    end
  end

  defp approve(ctx, task_id, ref) do
    command = %{
      command_id: "coord:task.approve:" <> task_id,
      aggregate_id: "task:" <> task_id,
      type: "task.approve",
      payload: %{task_id: task_id, approved_by: "coordinator:" <> ctx.project_id}
    }

    case Dispatch.system(ctx.gateway, command) do
      {:ok, spec} ->
        {"executed", nil, Map.put(ref, "run_id", run_id_of(spec)), 1}

      other ->
        # The task exists and stays open: visible as a proposal the operator can approve.
        {"proposed", {:approval_failed, other}, ref, 0}
    end
  end

  # The gateway returns the event spec string-keyed when it comes from the log
  # and atom-keyed when freshly built; accept both.
  defp run_id_of(%{} = spec) do
    payload = Map.get(spec, :payload) || Map.get(spec, "payload") || %{}
    Map.get(payload, :run_id) || Map.get(payload, "run_id")
  end

  defp run_id_of(_), do: nil

  defp create_task(ctx, task_id, spec, workflow) do
    text = fn key -> Redact.text(ctx.project_id, spec[key]) end

    payload =
      %{
        task_id: task_id,
        project_id: ctx.project_id,
        title: text.("title"),
        description: text.("prompt"),
        prompt: text.("prompt"),
        task_type: spec["task_type"] || "task",
        workflow_type: workflow,
        status: "open",
        source: "coordinator",
        provider_tracked: false
      }
      |> then(fn payload ->
        if spec["bead_id"], do: Map.put(payload, :external_id, spec["bead_id"]), else: payload
      end)

    command = %{
      command_id: "coord:task.create:" <> task_id,
      aggregate_id: "task:" <> task_id,
      type: "task.create",
      payload: payload
    }

    case Dispatch.system(ctx.gateway, command) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:task_create_failed, reason}}
      {:error, reason, detail} -> {:error, {:task_create_failed, {reason, detail}}}
    end
  end

  defp task_id(action_id, index) do
    digest = :crypto.hash(:sha256, "#{action_id}:#{index}") |> Base.encode16(case: :lower)
    "coord-" <> binary_part(digest, 0, 16)
  end

  # Caps apply only when something would start.
  defp check_caps(_ctx, _state, :propose), do: :ok

  defp check_caps(ctx, state, :start) do
    cap = ctx.tuning.max_active_threads

    cond do
      state.started >= ctx.max_threads_per_turn ->
        {:error, {:cap_exceeded, :threads_per_turn, ctx.max_threads_per_turn}}

      ctx.tuning.propose_before_start ->
        :ok

      is_integer(cap) and active_threads(ctx) + state.started >= cap ->
        {:error, {:cap_exceeded, :active_threads, cap}}

      daily_cap_reached?(ctx) ->
        {:error,
         {:cap_exceeded, :daily_thread_cap,
          ProjectionStore.project_limits(ctx.project_id).daily_thread_cap}}

      true ->
        :ok
    end
  end

  defp active_threads(ctx) do
    ctx.project_id
    |> ctx.threads.list(resolved: false, limit: 500)
    |> Enum.count(&(&1.status not in @terminal_thread_statuses))
  end

  defp daily_cap_reached?(ctx) do
    case ProjectionStore.project_limits(ctx.project_id) do
      %{cap_reached?: true} -> true
      _ -> false
    end
  end

  defp reuse_target(ctx, params) do
    if ctx.tuning.reuse_threads, do: find_reusable(ctx, params), else: {:ok, :none}
  end

  defp find_reusable(ctx, params) do
    case params do
      %{"reuse_thread_id" => id} ->
        case ctx.threads.get(id) do
          {:ok, %{project_id: pid}} when pid != ctx.project_id ->
            {:error, {:out_of_project, id}}

          {:ok, %{} = thread} ->
            if live?(thread), do: {:ok, {:thread, id}}, else: bead_match(ctx, params)

          {:error, _} ->
            bead_match(ctx, params)
        end

      _ ->
        bead_match(ctx, params)
    end
  end

  defp bead_match(ctx, %{"bead_id" => bead_id}) do
    match =
      ctx.project_id
      |> ctx.threads.list(resolved: false, limit: 500)
      |> Enum.find(fn thread ->
        live?(thread) and bead_of(thread) == bead_id
      end)

    if match, do: {:ok, {:thread, match.id}}, else: {:ok, :none}
  end

  defp bead_match(_ctx, _params), do: {:ok, :none}

  defp bead_of(%{task_id: task_id}) when is_binary(task_id) do
    case ProjectionStore.task_projection(task_id) do
      %{external_id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp bead_of(_), do: nil

  defp live?(%{status: status, resolved: resolved}),
    do: not resolved and status not in @terminal_thread_statuses

  defp brief(%{"title" => title, "prompt" => prompt}), do: title <> "\n\n" <> prompt

  defp approve_proposed(%Action{params: %{"task_ids" => ids}}, ctx, state) do
    proposed = proposed_task_ids(ctx)

    {approved, skipped, _started} =
      Enum.reduce(ids, {[], [], state.started}, fn id, {ok, skip, started} ->
        case approve_one(ctx, id, proposed, started) do
          {:approved, ref} ->
            {[ref | ok], skip, started + 1}

          {:skipped, reason} ->
            {ok, [%{"task_id" => id, "reason" => reason_text(reason)} | skip], started}
        end
      end)

    approved = Enum.reverse(approved)
    skipped = Enum.reverse(skipped)

    if approved == [] do
      {"rejected", first_skip_reason(skipped), %{"skipped" => skipped}, 0}
    else
      {"executed", nil, %{"approved" => approved, "skipped" => skipped}, length(approved)}
    end
  end

  defp first_skip_reason([%{"reason" => reason} | _]), do: {:none_approved, reason}
  defp first_skip_reason([]), do: :none_approved

  defp approve_one(ctx, id, proposed, started) do
    task = ProjectionStore.task_projection(id)

    cond do
      not MapSet.member?(proposed, id) ->
        {:skipped, {:not_a_proposal, id}}

      is_nil(task) or Map.get(task, :project_id) != ctx.project_id ->
        {:skipped, {:out_of_project, id}}

      Map.get(task, :status) != "open" ->
        {:skipped, {:not_open, Map.get(task, :status)}}

      true ->
        with :ok <- check_caps(ctx, %{started: started}, :start) do
          case approve(ctx, id, %{"task_id" => id}) do
            {"executed", _, ref, _} -> {:approved, ref}
            {_, reason, _, _} -> {:skipped, reason}
          end
        else
          {:error, reason} -> {:skipped, reason}
        end
    end
  end

  defp proposed_task_ids(ctx) do
    ctx.recorded
    |> Map.values()
    |> Enum.filter(&(&1.status == "proposed" and is_map(&1.result_ref)))
    |> Enum.flat_map(&Map.get(&1.result_ref, "task_ids", []))
    |> MapSet.new()
  end

  defp route(ctx, action_id, thread_id, text) do
    text = Redact.text(ctx.project_id, text)

    case ctx.threads.get(thread_id) do
      {:ok, %{project_id: pid}} when pid != ctx.project_id ->
        {"rejected", {:out_of_project, thread_id}, nil, 0}

      {:ok, _thread} ->
        case ctx.thread_actions.follow_up(thread_id, text, message_id: "coord-" <> action_id) do
          {:ok, %{message_id: message_id}} ->
            {"executed", nil, %{"thread_id" => thread_id, "message_id" => message_id}, 0}

          {:error, {:not_steerable, status}} ->
            {"rejected", {:thread_not_steerable, status}, nil, 0}

          {:error, {:needs_new_run, _info}} ->
            {"rejected", {:thread_not_steerable, "finished: start a new thread instead"}, nil, 0}

          {:error, :thread_resolved} ->
            {"rejected", {:thread_not_steerable, "resolved"}, nil, 0}

          {:error, other} ->
            {"failed", {:follow_up_failed, other}, nil, 0}
        end

      {:error, :thread_not_found} ->
        {"rejected", {:thread_not_found, thread_id}, nil, 0}
    end
  end

  defp put_ref(nil, _key, _value), do: nil
  defp put_ref(ref, key, value), do: Map.put(ref, key, value)

  # --------------------------------------------------------------------- memory

  defp remember(ctx, %{"name" => name, "content" => content} = p) do
    with :ok <- MemoryGuard.check(content <> "\n" <> Map.get(p, "description", "")) do
      attrs = %{name: name, description: Map.get(p, "description"), content: content}
      author = %{kind: :agent, ref: "coordinator:" <> ctx.project_id}

      case ProjectMemory.write(ctx.project_id, attrs, author) do
        {:ok, topic} -> {"executed", nil, %{"memory" => topic.name}, 0}
        {:error, error} -> {"failed", {:memory_write_failed, error.code}, nil, 0}
      end
    else
      {:error, :merge_automation} -> {"rejected", {:forbidden_memory, :merge_automation}, nil, 0}
    end
  end

  defp forget(ctx, %{"name" => name}) do
    case ProjectMemory.forget(ctx.project_id, name, %{
           kind: :agent,
           ref: "coordinator:" <> ctx.project_id
         }) do
      {:ok, _} -> {"executed", nil, %{"memory" => name}, 0}
      {:error, error} -> {"failed", {:memory_forget_failed, error.code}, nil, 0}
    end
  end

  # --------------------------------------------------------------------- tuning

  defp set_tuning(%Action{params: %{"key" => key, "value" => value} = p} = a, ctx) do
    current = ctx.tuning

    with :ok <- check_value(key, value),
         :ok <- check_quote(loosens?(key, value, current), p, ctx) do
      settings = settings_for(key, value, ctx)

      command = %{
        command_id: "coord:tuning:" <> a.id,
        aggregate_id: "project:" <> ctx.project_id,
        type: "project.update",
        payload: Map.put(settings, :project_id, ctx.project_id)
      }

      case Dispatch.system(ctx.gateway, command) do
        {:ok, _} ->
          {"executed", nil,
           %{"tuning" => key, "value" => value, "settings" => stringify(settings)}
           |> remember_tuning(ctx, key, value, p), 0}

        other ->
          {"failed", {:tuning_failed, other}, nil, 0}
      end
    else
      {:error, reason} -> {"rejected", reason, nil, 0}
    end
  end

  defp check_value("max_active_threads", value)
       when is_nil(value) or (is_integer(value) and value in 1..50), do: :ok

  defp check_value("max_active_threads", value),
    do: {:error, {:invalid_tuning_value, "max_active_threads", value}}

  defp check_value(key, value)
       when key in ["propose_before_start", "reuse_threads"] and is_boolean(value), do: :ok

  defp check_value(key, value), do: {:error, {:invalid_tuning_value, key, value}}

  # Tightening needs no justification; loosening must be backed by operator words.
  defp loosens?("propose_before_start", false, _current), do: true
  defp loosens?("propose_before_start", _value, _current), do: false
  defp loosens?("max_active_threads", nil, _current), do: true

  defp loosens?("max_active_threads", value, %{max_active_threads: cap}) when is_integer(cap),
    do: value > cap

  defp loosens?("max_active_threads", _value, _current), do: false
  defp loosens?("reuse_threads", _value, _current), do: false

  defp check_quote(false, _params, _ctx), do: :ok

  defp check_quote(true, params, ctx) do
    if Policy.quote_verified?(params["quote"], ctx.operator_texts),
      do: :ok,
      else: {:error, :quote_required}
  end

  defp settings_for("propose_before_start", value, _ctx),
    do: %{coordinator_propose_before_start: value}

  defp settings_for("reuse_threads", value, _ctx), do: %{coordinator_reuse_threads: value}

  defp settings_for("max_active_threads", value, ctx) do
    base = %{coordinator_max_active_threads: value}

    # "max N at a time" also becomes the project's aggregate-enforced run limit,
    # but only ever tightens it: the coordinator cannot raise a project cap.
    case {value, ProjectionStore.project_settings(ctx.project_id)} do
      {n, %{max_concurrent_runs: current}}
      when is_integer(n) and (is_nil(current) or n < current) ->
        Map.put(base, :max_concurrent_runs, n)

      _ ->
        base
    end
  end

  defp remember_tuning(ref, ctx, key, value, params) do
    note = "Operator preference: #{key} = #{inspect(value)}." <> quote_line(params["quote"])

    attrs = %{
      name: "coordinator-tuning-" <> String.replace(key, "_", "-"),
      description: "Coordinator tuning: #{key}",
      content: note
    }

    case ProjectMemory.write(ctx.project_id, attrs, %{
           kind: :agent,
           ref: "coordinator:" <> ctx.project_id
         }) do
      {:ok, topic} -> Map.put(ref, "memory", topic.name)
      {:error, _} -> ref
    end
  end

  defp quote_line(nil), do: ""
  defp quote_line(quote), do: " Operator said: \"" <> quote <> "\""

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  # -------------------------------------------------------------------- reasons

  defp reason_text({:unsupported, :add_repo}),
    do:
      "adding repositories is not available through the coordinator in this Foreman build; add it from the CLI"

  defp reason_text({:unsupported, :schedule}),
    do: "scheduling is not available through the coordinator in this Foreman build"

  defp reason_text({:not_permitted, kind, :machine_turn}),
    do:
      "#{kind} needs an operator message; this turn was triggered by a report or machine message"

  defp reason_text({:unknown_workflow, name, valid}),
    do: "unknown workflow #{inspect(name)}; valid workflows: #{Enum.join(valid, ", ")}"

  defp reason_text(:no_workflow),
    do: "no workflow could be chosen; name one of the listed workflows or give a task_type"

  defp reason_text(:quote_required),
    do: "this needs the operator's exact words (quote) from their message"

  defp reason_text(:propose_before_start),
    do: "propose_before_start is on: created as a proposal awaiting approval"

  defp reason_text({:cap_exceeded, which, n}), do: "cap_exceeded: #{which} #{n}"

  defp reason_text({:out_of_project, id}),
    do: "out_of_project: #{id} does not belong to this project"

  defp reason_text({:invalid_action, reason}),
    do: "invalid action: " <> inspect(reason, limit: 12)

  defp reason_text(other) when is_binary(other), do: String.slice(other, 0, 300)

  defp reason_text(other),
    do: other |> inspect(limit: 12, printable_limit: 200) |> String.slice(0, 300)

  defp proposal_text(%{result_ref: %{"threads" => threads}}) when is_list(threads) do
    lines =
      Enum.map(threads, fn t ->
        "- #{t["title"]} (task #{t["task_id"]}, workflow #{t["workflow"]})"
      end)

    "Proposed threads waiting for your approval:\n" <>
      Enum.join(lines, "\n") <> "\nReply \"go ahead\" to start them."
  end

  defp proposal_text(_), do: "Proposed work is waiting for your approval."
end
