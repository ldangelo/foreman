defmodule ForemanServer.Approvals.Inflight do
  @moduledoc """
  In-flight tool approvals for Claude (bead foreman-exofh; design
  `docs/plans/inflight-approvals.md`).

  `claude --permission-prompt-tool` sends every permission prompt of a headless
  session to an MCP tool and waits for its reply. Foreman serves that tool at
  `POST /agent-permission/:run_id` (`ForemanServerWeb.AgentPermissionController`).
  The controller records a `tool.request` (delivery `inflight`) and BLOCKS in
  `await/3`; the operator's `tool.approve` / `tool.deny` is delivered by
  `ForemanServer.Approvals.Deliverer` through `respond/5`, which wakes it. The
  agent's call then proceeds (or is told it was denied) inside the same session.

  This module owns three things:

    * the waiter registry (`register/3`, `await/3`, `unregister/3`, `respond/5`, `cancel_run/3`);
      a waiter that dies is dropped, `respond/5` for a request nobody waits for is
      `{:error, :no_live_request}` (the Deliverer records it as `delivery_failed`);
    * the per-run credential: `token/1` is an HMAC of the run id under the
      endpoint's `secret_key_base`, `valid_token?/2` checks it in constant time.
      The token opens ONE run's prompt tool; it is not the operator token;
    * `claude_options/1`, the `mcp_config` + `cli_path` (wrapper script) pair the
      workflow door hands the claude adapter.

  No request outlives its agent (bead foreman-u0646). A request still `requested` whose
  agent can no longer be answered is expired (`ForemanServer.Approvals.TimeoutPolicy.expire_tool_call/4`),
  so the operator is never offered a decision that reaches nobody, and a late one is refused with
  `{:tool_call_expired, reason}`:

    * `"server_restart"` - when this process starts: the waiter registry is empty, so every
      in-flight request in the projection is left over from a previous server run (post-hoc and
      live requests are not in-flight and are left alone);
    * `"run_ended"` - on a terminal run event, for every in-flight request of that run, whether or
      not anyone still waits for it (its waiters are also woken with `{:deny, "run_ended"}`);
    * `"client_gone"` - when a registered waiter dies without releasing its request (the
      connection was killed).
  """

  use GenServer

  require Logger

  alias ForemanServer.Approvals.{ClaudeCli, Config, TimeoutPolicy}
  alias ForemanServer.ProjectionStore

  @server_name "foreman_permission"
  @tool_name "approve"
  @terminal_events ~w(RunCompleted RunFailed RunCancelled)

  @type decision :: {:approve, nil} | {:deny, String.t() | nil}

  @doc "MCP server name claude sees (`mcp__<server>__<tool>`)."
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc "Tool name of the permission prompt."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Full `--permission-prompt-tool` value."
  @spec prompt_tool() :: String.t()
  def prompt_tool, do: "mcp__#{@server_name}__#{@tool_name}"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Bearer token for `run_id`."
  @spec token(String.t()) :: String.t()
  def token(run_id) when is_binary(run_id) and run_id != "" do
    mac = :crypto.mac(:hmac, :sha256, secret(), "agent-permission:" <> run_id)
    Base.url_encode64(mac, padding: false)
  end

  @doc "Constant-time check of a presented token for `run_id`."
  @spec valid_token?(String.t(), term()) :: boolean()
  def valid_token?(run_id, presented) when is_binary(run_id) and is_binary(presented),
    do: Plug.Crypto.secure_compare(token(run_id), presented)

  def valid_token?(_run_id, _presented), do: false

  @doc """
  `[mcp_config: map, provider_options: map]` that makes a claude run ask Foreman
  for permission, or `nil`, which leaves the run on the post-hoc phase-pause path, when the
  permission endpoint's URL is unknown or the claude CLI does not know `--permission-prompt-tool`
  (`ForemanServer.Approvals.ClaudeCli`, bead foreman-dc618; logged as a warning).
  """
  @spec claude_options(String.t()) :: keyword() | nil
  def claude_options(run_id) when is_binary(run_id) and run_id != "" do
    case Config.inflight_base_url() do
      nil ->
        nil

      base ->
        if prompt_tool_supported?() do
          [
            mcp_config: %{
              @server_name => %{
                "type" => "http",
                "url" =>
                  base <> "/agent-permission/" <> URI.encode(run_id, &URI.char_unreserved?/1),
                "headers" => %{"Authorization" => "Bearer " <> token(run_id)}
              }
            },
            provider_options: %{cli_path: wrapper_path()}
          ]
        end
    end
  end

  # The wrapper adds `--permission-prompt-tool`, and a CLI that rejects it fails the phase at launch
  # with an opaque exit status. Only a CLI that says it does not know the flag is refused: when the
  # probe cannot tell, asking in flight is what ran before the probe existed.
  defp prompt_tool_supported? do
    case ClaudeCli.permission_prompt_tool() do
      :supported ->
        true

      {:unsupported, executable} ->
        Logger.warning(
          "approvals: #{executable} does not know --permission-prompt-tool, so tool approvals " <>
            "of claude approval_mode: prompt phases pause and re-run the phase instead of asking " <>
            "in flight; upgrade the claude CLI to ask in flight"
        )

        false

      {:unknown, reason} ->
        Logger.warning(
          "approvals: could not tell whether the claude CLI knows --permission-prompt-tool " <>
            "(#{inspect(reason)}); asking in flight"
        )

        true
    end
  end

  @doc """
  The script that starts claude with `--permission-prompt-tool` (`priv/bin/foreman-claude-permission`).
  The harness adapter Foreman runs has no option for that flag, so it is handed this script
  as its `cli_path`.
  """
  @spec wrapper_path() :: String.t()
  def wrapper_path,
    do: Path.join([:code.priv_dir(:foreman_server), "bin", "foreman-claude-permission"])

  @doc "Register the calling process as the waiter of `run_id`/`tool_call_id` (before requesting)."
  @spec register(String.t(), String.t(), GenServer.server()) :: :ok
  def register(run_id, tool_call_id, server \\ __MODULE__),
    do: GenServer.call(server, {:register, run_id, tool_call_id, self()})

  @doc """
  Block until a decision for a registered request arrives or `timeout_ms` elapses
  (`:timeout`). The caller stays registered (so a decision that follows its own
  timeout handling is still delivered); `unregister/3` ends it.
  """
  @spec await(String.t(), String.t(), non_neg_integer()) :: decision() | :timeout
  def await(run_id, tool_call_id, timeout_ms) do
    key = {run_id, tool_call_id}

    receive do
      {:inflight_decision, ^key, decision} -> decision
    after
      timeout_ms -> :timeout
    end
  end

  @doc "Drop the calling process's registration for `run_id`/`tool_call_id` (idempotent)."
  @spec unregister(String.t(), String.t(), GenServer.server()) :: :ok
  def unregister(run_id, tool_call_id, server \\ __MODULE__),
    do: GenServer.call(server, {:unregister, {run_id, tool_call_id}})

  @doc "Deliver an operator decision to the blocked call."
  @spec respond(String.t(), String.t(), :approve | :deny, String.t() | nil, GenServer.server()) ::
          :ok | {:error, :no_live_request}
  def respond(run_id, tool_call_id, decision, reason \\ nil, server \\ __MODULE__)
      when decision in [:approve, :deny],
      do: GenServer.call(server, {:respond, {run_id, tool_call_id}, {decision, reason}})

  @doc "Wake every waiter of `run_id` with `{:deny, reason}`; returns how many."
  @spec cancel_run(String.t(), String.t(), GenServer.server()) :: non_neg_integer()
  def cancel_run(run_id, reason, server \\ __MODULE__),
    do: GenServer.call(server, {:cancel_run, run_id, reason})

  @impl true
  def init(:ok) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{waiters: %{}}, {:continue, :expire_orphans}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  # The registry is empty at start, so every in-flight request still `requested` was left by a
  # previous server run and its agent died with it. A new request registers its waiter before it is
  # recorded and `register/3` is served only after this returns, so none of them is a live one.
  @impl true
  def handle_continue(:expire_orphans, state) do
    for %{delivery: "inflight"} = call <- ProjectionStore.pending_needs_you().tool_calls do
      expire(call.run_id, call.tool_call_id, "server_restart")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:register, run_id, tool_call_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.waiters[{run_id, tool_call_id}], {pid, ref})}
  end

  def handle_call({:unregister, key}, _from, state) do
    case Map.pop(state.waiters, key) do
      {nil, _} ->
        {:reply, :ok, state}

      {{_pid, ref}, waiters} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | waiters: waiters}}
    end
  end

  def handle_call({:respond, key, {decision, reason}}, _from, state) do
    case Map.pop(state.waiters, key) do
      {nil, _waiters} ->
        {:reply, {:error, :no_live_request}, state}

      {{pid, ref}, waiters} ->
        Process.demonitor(ref, [:flush])
        send(pid, {:inflight_decision, key, {decision, reason}})
        {:reply, :ok, %{state | waiters: waiters}}
    end
  end

  def handle_call({:cancel_run, run_id, reason}, _from, state) do
    {mine, rest} = Enum.split_with(state.waiters, fn {{rid, _}, _} -> rid == run_id end)

    for {key, {pid, ref}} <- mine do
      Process.demonitor(ref, [:flush])
      send(pid, {:inflight_decision, key, {:deny, reason}})
    end

    {:reply, length(mine), %{state | waiters: Map.new(rest)}}
  end

  @impl true
  def handle_info({:projection_event, %{event_type: type, data: data}}, state)
      when type in @terminal_events do
    case run_id(data) do
      nil ->
        {:noreply, state}

      run_id ->
        {:reply, _count, state} = handle_call({:cancel_run, run_id, "run_ended"}, nil, state)

        # A woken waiter expires its own request the same way (the first expiry is recorded); this
        # also expires the ones nobody waits for any more.
        for %{delivery: "inflight"} = call <- ProjectionStore.run_approvals(run_id) do
          expire(run_id, call.tool_call_id, "run_ended")
        end

        {:noreply, state}
    end
  end

  # A registered waiter that dies was released by neither `unregister/3` nor a decision (both
  # demonitor it), so the agent's connection is gone and its request is orphaned.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {gone, waiters} = Enum.split_with(state.waiters, fn {_key, {_pid, r}} -> r == ref end)

    for {{run_id, tool_call_id}, _waiter} <- gone, do: expire(run_id, tool_call_id, "client_gone")

    {:noreply, %{state | waiters: Map.new(waiters)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp run_id(data) when is_map(data), do: Map.get(data, :run_id) || Map.get(data, "run_id")
  defp run_id(_), do: nil

  defp expire(run_id, tool_call_id, reason) do
    case TimeoutPolicy.expire_tool_call(run_id, tool_call_id, reason) do
      {:ok, _expired_or_already_decided} ->
        :ok

      {:error, why} ->
        Logger.error(
          "approvals: could not expire the orphaned request #{run_id}/#{tool_call_id} (#{reason}): #{inspect(why)}"
        )
    end
  end

  defp secret do
    case Application.get_env(:foreman_server, ForemanServerWeb.Endpoint)[:secret_key_base] do
      key when is_binary(key) and byte_size(key) >= 32 ->
        key

      other ->
        raise ArgumentError,
              "Endpoint secret_key_base must be set for in-flight approvals, got: #{inspect(other)}"
    end
  end
end
