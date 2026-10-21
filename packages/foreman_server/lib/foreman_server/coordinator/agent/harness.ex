defmodule ForemanServer.Coordinator.Agent.Harness do
  @moduledoc """
  Production coordinator agent: a provider agent run through the harness
  (`DetachedRun`, the same shape as `Review.Evaluator.Agent`), emitting one
  fenced JSON block that `Coordinator.ActionSource` parses (spike S1, outcome A).

  The agent gets no Foreman tools and no MCP: the run is `sandbox_mode:
  :read_only`, started in an empty scratch directory (not the repository), with
  pi's extensions/skills/context files/MCP/session switched off. Its ONLY effect
  is the text it returns; Foreman validates and executes it.

  Options (`opts`): `:provider` (atom, default `:pi`), `:model`, `:effort`,
  `:timeout_ms`, `:project_id`. A malformed reply is repaired ONCE: the same
  prompt is run again with the parse error appended; a second malformed reply is
  `{:error, %Error{code: :malformed_output}}` and nothing executes. A provider
  that cannot start or ends abnormally is `{:error, %Error{code: :agent_failed}}`,
  a timeout `:agent_timeout`: a recorded turn failure, never a crash.
  """
  @behaviour ForemanServer.Coordinator.Agent

  alias ForemanServer.AgentRuntime.JidoHarness.DetachedRun
  alias ForemanServer.Coordinator.{ActionSource, Context, Error, Turn}
  alias Jido.Harness.{RunRequest, RunResult}

  @await_slack_ms 5_000
  @default_timeout_ms 180_000

  # pi flags the harness adapter exposes: nothing from the user's pi setup may
  # reach the coordinator (S1 section 3: `pi` otherwise connects every MCP server
  # in ~/.pi/agent/mcp.json and could read files through its default tools).
  @pi_isolation %{
    no_extensions: true,
    no_skills: true,
    no_context_files: true,
    no_session: true,
    extra_args: ["--no-mcp"]
  }

  @impl true
  @spec turn(Context.t(), keyword()) :: {:ok, Turn.t()} | {:error, Error.t()}
  def turn(%Context{} = context, opts) do
    case attempt(context.text, opts) do
      {:error, %Error{code: :malformed_output} = first} ->
        attempt(repair_prompt(context.text, first), opts)

      other ->
        other
    end
  end

  defp attempt(prompt, opts) do
    with {:ok, request} <- build_request(prompt, opts),
         {:ok, %RunResult{} = result} <- run(request, opts) do
      finish(result)
    end
  end

  defp repair_prompt(prompt, %Error{message: message}) do
    prompt <>
      "\n\n# YOUR PREVIOUS REPLY WAS REJECTED\n" <>
      "Reason: #{message}.\nAnswer again. End with exactly one fenced ```json block of the form " <>
      ~s({"reply": "...", "actions": []}) <> " and nothing after it."
  end

  @doc false
  @spec build_request(String.t(), keyword()) :: {:ok, RunRequest.t()} | {:error, Error.t()}
  def build_request(prompt, opts) do
    provider = Keyword.get(opts, :provider, :pi)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    attrs = %{
      prompt: prompt,
      provider: provider,
      cwd: scratch_dir(Keyword.get(opts, :project_id, "default")),
      model: Keyword.get(opts, :model),
      reasoning_effort: effort(Keyword.get(opts, :effort)),
      approval_mode: :default,
      sandbox_mode: :read_only,
      runtime_timeout_ms: timeout,
      idle_timeout_ms: timeout,
      provider_options: provider_options(provider)
    }

    case RunRequest.new(attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error,
         Error.new(:agent_failed, "invalid coordinator run request", %{reason: inspect(reason)})}
    end
  end

  # Project settings store the effort as a string; `RunRequest` wants the atom.
  defp effort(value) when value in [:low, :medium, :high], do: value
  defp effort("low"), do: :low
  defp effort("medium"), do: :medium
  defp effort("high"), do: :high
  defp effort(_other), do: nil

  defp provider_options(:pi), do: @pi_isolation
  defp provider_options(_provider), do: %{}

  defp scratch_dir(project_id) do
    safe =
      project_id |> String.replace(~r/[^A-Za-z0-9_.-]/, "_") |> String.replace(~r/\A\.+/, "_")

    dir = Path.join([System.tmp_dir!(), "foreman-coordinator", safe])
    File.mkdir_p!(dir)
    dir
  end

  defp run(%RunRequest{} = request, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case DetachedRun.start_run(request.provider, request, []) do
      {:ok, run_id} ->
        await(run_id, request.provider, timeout)

      {:error, reason} ->
        {:error,
         Error.new(:agent_failed, "coordinator provider failed to start", %{
           provider: request.provider,
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
         Error.new(:agent_timeout, "coordinator run did not complete", %{
           provider: provider,
           run_id: run_id,
           reason: inspect(reason)
         })}
    end
  end

  defp finish(%RunResult{status: :completed, text: text}), do: ActionSource.parse(text)

  defp finish(%RunResult{} = result) do
    {:error,
     Error.new(:agent_failed, "coordinator run ended #{result.status}", %{
       provider: result.provider,
       status: result.status,
       error: inspect(result.error)
     })}
  end
end
