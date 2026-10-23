defmodule Jido.Harness.Adapters.CLIMapper.ClaudeStream do
  @moduledoc false

  alias Jido.Harness.Adapters.Helpers
  alias Jido.Harness.Event

  @doc "Maps one Claude-compatible stream record to zero or more harness events."
  @spec map(atom(), term(), keyword()) :: [Event.t()]
  def map(provider, event, options \\ [])

  def map(provider, %{"type" => "system", "subtype" => "init"} = raw, _options) do
    [
      Helpers.event(
        provider,
        :run_started,
        raw["session_id"],
        %{"cwd" => raw["cwd"], "model" => raw["model"], "tools" => raw["tools"] || []},
        raw
      )
    ]
  end

  def map(provider, %{"type" => "assistant"} = raw, options) do
    sid = raw["session_id"]
    emit_text? = Keyword.get(options, :assistant_text?, false)

    raw
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.flat_map(&content_block(provider, &1, sid, raw, emit_text?))
  end

  # Streaming-input runs: `--replay-user-messages` re-emits each stdin message
  # (`isReplay`, our `uuid`) when the model takes it, i.e. consumption.
  def map(provider, %{"type" => "user", "isReplay" => true} = raw, options) do
    if Keyword.get(options, :live_input, false) do
      text = replay_text(get_in(raw, ["message", "content"]))

      [
        Helpers.event(
          provider,
          :input_accepted,
          raw["session_id"],
          %{"kind" => "message", "input_id" => raw["uuid"], "text" => text},
          raw
        )
      ]
    else
      []
    end
  end

  def map(provider, %{"type" => "user"} = raw, _options) do
    sid = raw["session_id"]

    raw
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.flat_map(&content_block(provider, &1, sid, raw, false))
  end

  def map(provider, %{"type" => "stream_event", "event" => event} = raw, _options) do
    sid = raw["session_id"]
    delta = event["delta"] || %{}

    case {event["type"], delta["type"]} do
      {"content_block_delta", "text_delta"} -> maybe_text(provider, :output_text_delta, sid, delta["text"], raw)
      {"content_block_delta", "thinking_delta"} -> maybe_text(provider, :thinking_delta, sid, delta["thinking"], raw)
      {"message_stop", _} -> [Helpers.event(provider, :turn_completed, sid, %{}, raw)]
      _ -> []
    end
  end

  def map(provider, %{"type" => "result", "is_error" => true} = raw, _options) do
    failed_result(provider, raw)
  end

  # Streaming-input runs: a `result` ends a TURN, not the process (more stdin may
  # follow). `:input_idle` carries what `:run_completed` would; the run worker
  # closes stdin when nothing is pending and the exit then completes the run.
  def map(provider, %{"type" => "result", "subtype" => "success"} = raw, options) do
    if Keyword.get(options, :live_input, false),
      do: live_result(provider, raw),
      else: completed_result(provider, raw)
  end

  def map(provider, %{"type" => "result"} = raw, _options) do
    failed_result(provider, raw)
  end

  def map(provider, raw, _options) do
    [Helpers.event(provider, :provider_event, session_id(raw), %{"type" => event_type(raw), "mapped" => false}, raw)]
  end

  defp completed_result(provider, raw) do
    sid = raw["session_id"]

    usage_event(provider, sid, raw["usage"], raw) ++
      maybe_text(provider, :output_text_final, sid, raw["result"], raw) ++
      [Helpers.event(provider, :run_completed, sid, result_payload(raw), raw)]
  end

  defp live_result(provider, raw) do
    sid = raw["session_id"]

    usage_event(provider, sid, raw["usage"], raw) ++
      maybe_text(provider, :output_text_final, sid, raw["result"], raw) ++
      [Helpers.event(provider, :input_idle, sid, result_payload(raw), raw)]
  end

  defp result_payload(raw),
    do: %{
      "num_turns" => raw["num_turns"],
      "duration_ms" => raw["duration_ms"],
      "cost_usd" => raw["total_cost_usd"]
    }

  defp replay_text(content) when is_binary(content), do: content

  defp replay_text(content) when is_list(content),
    do: content |> Enum.map(&(is_map(&1) && &1["text"])) |> Enum.filter(&is_binary/1) |> Enum.join("")

  defp replay_text(_content), do: nil

  defp content_block(provider, %{"type" => "text", "text" => text}, sid, raw, true),
    do: maybe_text(provider, :output_text_delta, sid, text, raw)

  defp content_block(provider, %{"type" => "thinking", "thinking" => text}, sid, raw, _emit_text?),
    do: maybe_text(provider, :thinking_delta, sid, text, raw)

  defp content_block(provider, %{"type" => "tool_use"} = block, sid, raw, _emit_text?) do
    [
      Helpers.event(
        provider,
        :tool_call,
        sid,
        %{"name" => block["name"], "input" => block["input"] || %{}, "call_id" => block["id"]},
        raw
      )
    ]
  end

  defp content_block(provider, %{"type" => "tool_result"} = block, sid, raw, _emit_text?) do
    [
      Helpers.event(
        provider,
        :tool_result,
        sid,
        %{
          "output" => block["content"],
          "call_id" => block["tool_use_id"],
          "is_error" => block["is_error"] || false
        },
        raw
      )
    ]
  end

  defp content_block(_provider, _block, _sid, _raw, _emit_text?), do: []

  defp usage_event(_provider, _sid, nil, _raw), do: []

  defp usage_event(provider, sid, usage, raw) when is_map(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    payload = Map.put_new(usage, "total_tokens", input + output)
    [Helpers.event(provider, :usage, sid, payload, raw)]
  end

  defp failed_result(provider, raw) do
    sid = raw["session_id"]

    usage_event(provider, sid, raw["usage"], raw) ++
      [
        Helpers.event(
          provider,
          :run_failed,
          sid,
          %{"error" => raw["error"] || raw["result"] || "#{provider} failed", "subtype" => raw["subtype"]},
          raw
        )
      ]
  end

  defp maybe_text(_provider, _type, _sid, text, _raw) when not is_binary(text) or text == "", do: []
  defp maybe_text(provider, type, sid, text, raw), do: [Helpers.event(provider, type, sid, %{"text" => text}, raw)]
  defp session_id(raw) when is_map(raw), do: raw["session_id"] || raw["thread_id"]
  defp session_id(_raw), do: nil
  defp event_type(raw) when is_map(raw), do: raw["type"] || "unknown"
  defp event_type(_raw), do: "unknown"
end
