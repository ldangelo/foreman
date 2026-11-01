defmodule ForemanServer.TestSupport.FileServerSampler do
  @moduledoc """
  Diagnostic for foreman-83cf1: a test that stalls for the 60 s ExUnit timeout inside
  `:file.call` (the VM-wide `:file_server_2`) leaves no evidence of what the file server was
  doing, and on CI the VM is gone afterwards.

  `start/1` (called from a `setup`) starts a process under `start_supervised!/1` that samples
  `:file_server_2` every second and keeps only the last few snapshots in memory. It prints
  nothing while the test is healthy. If the test is still running `:dump_after_ms` (45 s) after
  it started, i.e. shortly before the default 60 s timeout kills it, it prints every kept
  snapshot to stderr, once, each line prefixed with `foreman-83cf1:`. Grep CI logs for that
  prefix.

  A watchdog is used rather than `on_exit`: ExUnit enforces `@tag timeout` by killing the test
  process, and `on_exit` callbacks only run after that, when the stuck state is already gone.
  Stopping the test (normally or by the timeout kill) stops the supervised sampler, so a test
  that finishes in time never dumps.

  The sampler only observes. It uses `Process.info/2` and `:erlang.statistics/1` (BIFs, no file
  server calls), so it cannot itself block on the thing it watches, and every sampling step is
  wrapped so it can never fail the test it is attached to. It dumps VM facts only.
  """

  use GenServer

  @prefix "foreman-83cf1:"
  @info_keys [:current_stacktrace, :message_queue_len, :status]

  @type snapshot :: %{
          at_ms: non_neg_integer(),
          pid: pid() | nil,
          info: keyword() | nil,
          run_queue: non_neg_integer()
        }

  @type opt ::
          {:target, atom()}
          | {:owner, pid()}
          | {:interval_ms, pos_integer()}
          | {:dump_after_ms, pos_integer()}
          | {:keep, pos_integer()}

  @doc """
  Starts the sampler under the calling test's supervisor. Call from a `setup` (the calling
  process is the test process, which is the `:owner` whose stacktrace is dumped too).
  """
  @spec start([opt()]) :: :ok
  def start(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    ExUnit.Callbacks.start_supervised!({__MODULE__, opts})
    :ok
  end

  @spec child_spec([opt()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      target: Keyword.get(opts, :target, :file_server_2),
      owner: Keyword.get(opts, :owner),
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      dump_after_ms: Keyword.get(opts, :dump_after_ms, 45_000),
      keep: Keyword.get(opts, :keep, 5),
      started_at: System.monotonic_time(:millisecond),
      snapshots: [],
      dumped?: false
    }

    send(self(), :sample)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = state |> sample() |> maybe_dump()
    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Newest first; only `keep` are retained.
  defp sample(state) do
    snapshot = take_snapshot(state)
    %{state | snapshots: Enum.take([snapshot | state.snapshots], state.keep)}
  rescue
    _ -> state
  end

  defp take_snapshot(state) do
    pid = Process.whereis(state.target)

    %{
      at_ms: System.monotonic_time(:millisecond) - state.started_at,
      pid: pid,
      info: pid && Process.info(pid, @info_keys),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  defp maybe_dump(%{dumped?: false} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    if elapsed >= state.dump_after_ms do
      dump(state, elapsed)
      %{state | dumped?: true}
    else
      state
    end
  end

  defp maybe_dump(state), do: state

  defp dump(state, elapsed) do
    lines =
      [
        "#{@prefix} test still running after #{elapsed}ms (ExUnit timeout is near); " <>
          "#{inspect(state.target)} state follows (last #{length(state.snapshots)} samples, oldest first)",
        "#{@prefix} schedulers_online=#{:erlang.system_info(:schedulers_online)} " <>
          "run_queue_now=#{:erlang.statistics(:run_queue)}"
      ] ++
        Enum.flat_map(Enum.reverse(state.snapshots), &snapshot_lines(&1, state.target)) ++
        owner_lines(state.owner)

    IO.puts(:stderr, Enum.join(lines, "\n"))
  rescue
    _ -> :ok
  end

  defp snapshot_lines(%{pid: nil} = snap, target) do
    ["#{@prefix} t=#{snap.at_ms}ms run_queue=#{snap.run_queue} #{inspect(target)} not registered"]
  end

  defp snapshot_lines(%{info: nil} = snap, target) do
    [
      "#{@prefix} t=#{snap.at_ms}ms run_queue=#{snap.run_queue} #{inspect(target)} #{inspect(snap.pid)} dead"
    ]
  end

  defp snapshot_lines(snap, _target) do
    info = snap.info

    [
      "#{@prefix} t=#{snap.at_ms}ms run_queue=#{snap.run_queue} " <>
        "message_queue_len=#{info[:message_queue_len]} status=#{info[:status]} " <>
        "stacktrace:"
      | Enum.map(
          info[:current_stacktrace] || [],
          &"#{@prefix}     #{Exception.format_stacktrace_entry(&1)}"
        )
    ]
  end

  defp owner_lines(owner) when is_pid(owner) do
    case Process.info(owner, [:current_stacktrace, :status]) do
      nil ->
        []

      info ->
        ["#{@prefix} test process #{inspect(owner)} status=#{info[:status]} stacktrace:"] ++
          Enum.map(
            info[:current_stacktrace],
            &"#{@prefix}     #{Exception.format_stacktrace_entry(&1)}"
          )
    end
  end

  defp owner_lines(_), do: []
end
