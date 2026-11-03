defmodule ForemanServerWeb.Workspace.ThreadView do
  @moduledoc """
  The thread pane's view model: pure functions over `ForemanServer.Overview` cards and
  `ForemanServer.Threads.Turn` lists. No process, clock or IO; the caller passes the time.

  `log/3` turns the turns of `ForemanServer.Threads.Transcript.full/2` into what the pane
  shows. The pane asks for a small grouping gap so the trailing agent output is final at
  once, which yields one turn per output line; reading wants those lines together, so
  adjacent agent output of one source (stdout, stderr, a jobsite iteration) is merged into one
  block, and only the newest `tail/0` blocks are kept. Anything else, an operator steer, a
  lifecycle line, a verdict, is its own block and ends the run of output around it.

  `find_card/2` picks the selected thread among the cards of a project's Overview, which is
  also what keeps another project's thread, an unknown id or a bad id from ever being read.
  `age/2` is the sidebar's short age (`5m`, `3h`, `2d`).
  """

  alias ForemanServer.Overview
  alias ForemanServer.Overview.ThreadCard
  alias ForemanServer.Threads.Turn

  @tail 100
  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  defmodule Block do
    @moduledoc """
    One rendered unit of a thread's conversation: a turn, or the output lines merged into it.
    `seq` is the first merged turn's, `turns` how many turns the block stands for.
    """
    @enforce_keys [:seq, :role, :kind, :source, :at, :text, :turns]
    defstruct [:seq, :role, :kind, :source, :at, :text, :turns]

    @type t :: %__MODULE__{
            seq: non_neg_integer(),
            role: Turn.role(),
            kind: Turn.kind(),
            source: String.t(),
            at: integer() | nil,
            text: String.t(),
            turns: pos_integer()
          }
  end

  defmodule Log do
    @moduledoc """
    What the pane shows of a thread's conversation: the newest blocks, how many earlier turns
    it leaves out, and whether the thread is over (`terminal?`: no more output will come).
    """
    @enforce_keys [:blocks, :dropped_turns, :terminal?]
    defstruct [:blocks, :dropped_turns, :terminal?]

    @type t :: %__MODULE__{
            blocks: [Block.t()],
            dropped_turns: non_neg_integer(),
            terminal?: boolean()
          }
  end

  @doc "How many blocks the pane keeps."
  @spec tail() :: pos_integer()
  def tail, do: @tail

  @doc """
  The pane's log for `turns` (in `seq` order): adjacent `:agent`/`:text` turns of one `source`
  merged into one block (texts joined with a newline), the newest `limit` blocks kept, and
  `dropped_turns` counting the TURNS (not blocks) of the blocks left out.
  """
  @spec log([Turn.t()], boolean(), pos_integer()) :: Log.t()
  def log(turns, terminal?, limit \\ @tail)
      when is_list(turns) and is_boolean(terminal?) and is_integer(limit) and limit > 0 do
    blocks = merge(turns)
    {dropped, shown} = Enum.split(blocks, max(length(blocks) - limit, 0))

    %Log{
      blocks: shown,
      dropped_turns: Enum.sum_by(dropped, & &1.turns),
      terminal?: terminal?
    }
  end

  # Output of one source runs together; any other turn stands alone, so it ends the run
  # around it (a steer between two stdout lines keeps them in two blocks).
  defp merge(turns) do
    turns
    |> Enum.chunk_by(&chunk_key/1)
    |> Enum.map(&block/1)
  end

  defp chunk_key(%Turn{role: :agent, kind: :text, source: source}), do: {:output, source}
  defp chunk_key(%Turn{seq: seq}), do: {:turn, seq}

  defp block([%Turn{} = first | _] = chunk) do
    %Block{
      seq: first.seq,
      role: first.role,
      kind: first.kind,
      source: first.source,
      at: first.at,
      text: Enum.map_join(chunk, "\n", & &1.text),
      turns: length(chunk)
    }
  end

  @doc "The card of `thread_id` among the cards of the Overview's groups, or nil."
  @spec find_card(Overview.t(), String.t()) :: ThreadCard.t() | nil
  def find_card(%Overview{groups: groups}, thread_id) when is_binary(thread_id) do
    groups
    |> Map.values()
    |> Enum.concat()
    |> Enum.find(&(&1.thread_id == thread_id))
  end

  @doc """
  Time since `updated_at` (unix ms) at `now_ms` as `now`, `5m`, `3h` or `2d`; nil for a
  thread without a time. A time ahead of the clock reads `now`.
  """
  @spec age(integer() | nil, integer()) :: String.t() | nil
  def age(nil, _now_ms), do: nil

  def age(updated_at, now_ms) when is_integer(updated_at) and is_integer(now_ms) do
    elapsed = max(now_ms - updated_at, 0)

    cond do
      elapsed < @minute -> "now"
      elapsed < @hour -> "#{div(elapsed, @minute)}m"
      elapsed < @day -> "#{div(elapsed, @hour)}h"
      true -> "#{div(elapsed, @day)}d"
    end
  end
end
