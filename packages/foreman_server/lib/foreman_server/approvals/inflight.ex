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

  A terminal run event wakes that run's waiters with a denial
  (`{:deny, "run_ended"}`), so no pending request outlives its agent.
  """

  use GenServer

  alias ForemanServer.Approvals.Config
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
  for permission, or `nil` when the permission endpoint's URL is unknown.
  """
  @spec claude_options(String.t()) :: keyword() | nil
  def claude_options(run_id) when is_binary(run_id) and run_id != "" do
    case Config.inflight_base_url() do
      nil ->
        nil

      base ->
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
      :ok -> {:ok, %{waiters: %{}}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
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
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiters = for {key, {_, r} = v} <- state.waiters, r != ref, into: %{}, do: {key, v}
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp run_id(data) when is_map(data), do: Map.get(data, :run_id) || Map.get(data, "run_id")
  defp run_id(_), do: nil

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
