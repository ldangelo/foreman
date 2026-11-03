defmodule ForemanServerWeb.Workspace.ThreadView do
  @moduledoc """
  The thread pane's view model: pure functions over `ForemanServer.Overview` cards and
  `ForemanServer.Threads.Turn` lists. No process, clock or IO; the caller passes the time.

  `log/3` assembles the conversation from the turns of
  `ForemanServer.Threads.Transcript.full(thread_id, chunks: true)`, one turn per stored output
  chunk exactly as the harness produced it. Consecutive stdout (or stderr) chunks with no other
  turn between them are one run and become ONE block; anything else (an operator steer, a
  lifecycle line, a verdict, a jobsite iteration) is a block of its own and ends the run around
  it. The text of a run is built from its chunks:

    * MESSAGE COLLAPSE: a model streams a message as delta chunks and then sends the whole
      message once more as a final chunk. When a chunk equals (both sides trimmed) the
      concatenation of the `k >= 1` chunks right before it, those `k` deltas are dropped and the
      chunk is kept as a MESSAGE. `k = 1` only counts when the chunk does not end with a
      newline: a newline-terminated chunk is command or stderr output, never a delta, so two
      identical `"ok\\n"` lines stay two lines.
    * Every other chunk is concatenated as it came, with no separator: stderr and command
      output carry their own newlines, deltas their own spacing (a message still streaming, or
      one that never gets a final, reads as the text it is).
    * A message is set apart from its neighbours by a blank line (`"\\n\\n"`, the newlines
      trailing the part before it trimmed first), so two messages in a row stay two paragraphs.

  A block's `seq` is its first chunk's, also when that chunk is a delta that later collapses
  into its final: the element keeps its id while the message grows into place.

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
  # The sources of output chunks; every other source is a whole turn.
  @chunk_sources ~w(stdout stderr)

  defmodule Block do
    @moduledoc """
    One rendered unit of a thread's conversation: a turn, or the run of output chunks
    assembled into it. `seq` and `at` are the first turn's, `turns` how many turns the block
    stands for (the chunks of a run, collapsed deltas included).
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
    it leaves out, how many stored output entries were not readable at all (`omitted_entries`:
    the store's window dropped them, or the read was shorter than the window), and whether the
    thread is over (`terminal?`: no more output will come).
    """
    @enforce_keys [:blocks, :dropped_turns, :omitted_entries, :terminal?]
    defstruct [:blocks, :dropped_turns, :omitted_entries, :terminal?]

    @type t :: %__MODULE__{
            blocks: [Block.t()],
            dropped_turns: non_neg_integer(),
            omitted_entries: non_neg_integer(),
            terminal?: boolean()
          }
  end

  @doc "How many blocks the pane keeps."
  @spec tail() :: pos_integer()
  def tail, do: @tail

  @doc """
  The pane's log for `turns` (chunk turns in `seq` order, see the moduledoc): runs of output
  chunks assembled into one block each, the newest `limit` blocks kept, and `dropped_turns`
  counting the TURNS (not blocks) of the blocks left out.

  Options: `:limit` (blocks kept, default `tail/0`) and `:omitted_entries` (default 0): how many
  stored output entries the transcript could not read, `Transcript.Full.omitted_entries`, which
  the log carries so the pane can say the start of the conversation is gone. Anything else
  raises.
  """
  @spec log([Turn.t()], boolean(), keyword()) :: Log.t()
  def log(turns, terminal?, opts \\ []) when is_list(turns) and is_boolean(terminal?) do
    opts = Keyword.validate!(opts, limit: @tail, omitted_entries: 0)

    build_log(
      turns,
      terminal?,
      Keyword.fetch!(opts, :limit),
      Keyword.fetch!(opts, :omitted_entries)
    )
  end

  defp build_log(turns, terminal?, limit, omitted)
       when is_integer(limit) and limit > 0 and is_integer(omitted) and omitted >= 0 do
    blocks = turns |> Enum.chunk_by(&run_key/1) |> Enum.map(&block/1)
    {dropped, shown} = Enum.split(blocks, max(length(blocks) - limit, 0))

    %Log{
      blocks: shown,
      dropped_turns: Enum.sum_by(dropped, & &1.turns),
      omitted_entries: omitted,
      terminal?: terminal?
    }
  end

  # Output chunks of one source run together; any other turn stands alone, so it ends the run
  # around it (a steer between a message's deltas and its final keeps them in two blocks).
  defp run_key(%Turn{role: :agent, kind: :text, source: source}) when source in @chunk_sources,
    do: {:output, source}

  defp run_key(%Turn{seq: seq}), do: {:turn, seq}

  defp block([%Turn{} = first | _] = run) do
    %Block{
      seq: first.seq,
      role: first.role,
      kind: first.kind,
      source: first.source,
      at: first.at,
      text: text(run),
      turns: length(run)
    }
  end

  defp text([%Turn{role: :agent, kind: :text, source: source} | _] = run)
       when source in @chunk_sources,
       do: run |> Enum.map(& &1.text) |> assemble()

  defp text([%Turn{text: text}]), do: text

  # The parts of a run, oldest first: `{:chunks, text}` (chunks concatenated as they came) and
  # `{:message, text}`. `pending` holds the chunks since the last message, newest first.
  defp assemble(chunks) do
    {parts, pending} =
      Enum.reduce(chunks, {[], []}, fn chunk, {parts, pending} ->
        case repeated(chunk, pending) do
          nil -> {parts, [chunk | pending]}
          k -> {[{:message, chunk} | flush(parts, Enum.drop(pending, k))], []}
        end
      end)

    parts |> flush(pending) |> Enum.reverse() |> Enum.map(&elem(&1, 1)) |> join()
  end

  defp flush(parts, []), do: parts

  defp flush(parts, pending),
    do: [{:chunks, pending |> Enum.reverse() |> IO.iodata_to_binary()} | parts]

  # Chunk parts are always next to a message (two of them would have been one), so every
  # boundary is a blank line; the part before it loses the newlines it ended with.
  defp join(texts) do
    {init, last} = Enum.split(texts, -1)
    IO.iodata_to_binary([Enum.map(init, &[String.trim_trailing(&1, "\n"), "\n\n"]), last])
  end

  # How many of the newest `pending` chunks (newest first) `chunk` repeats as a message: their
  # concatenation, trimmed, equals the chunk, trimmed. nil when it repeats none. Each step
  # strips one chunk off the end of what the final still has to explain, so a chunk that does
  # not end with the newest pending one costs one comparison.
  defp repeated(chunk, pending) do
    case String.trim(chunk) do
      "" -> nil
      final -> strip(final, pending, 1, not String.ends_with?(chunk, "\n"))
    end
  end

  defp strip(_rest, [], _k, _single?), do: nil

  defp strip(rest, [newest | older], k, single?) do
    # the trim takes the trailing whitespace of the run's last chunk and the leading
    # whitespace of its first one
    part = if k == 1, do: String.trim_trailing(newest), else: newest

    cond do
      String.trim_leading(part) == rest and (k > 1 or single?) ->
        k

      part != "" and byte_size(part) < byte_size(rest) and String.ends_with?(rest, part) ->
        strip(binary_part(rest, 0, byte_size(rest) - byte_size(part)), older, k + 1, single?)

      true ->
        nil
    end
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
