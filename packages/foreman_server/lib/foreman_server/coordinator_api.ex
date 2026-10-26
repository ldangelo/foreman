defmodule ForemanServer.CoordinatorAPI do
  @moduledoc """
  Shared boundary for the HTTP and MCP surfaces of the project coordinator
  conversation.

  * `post_message/3` dispatches `coordinator.message` through the operator
    gateway and returns the accepted message's `seq` (idempotent per
    `message_id`).
  * `read_page/3` and `wait_page/3` return a whitelisted, STRING-keyed page of
    the conversation. No projection map is serialised as-is: every key that
    leaves the server is listed here. The page carries the coordinator `"status"`
    and `"pending_messages"` from one status snapshot: `"idle"` alone does not
    mean the posted message was answered, since between two turns the status is
    `"idle"` while a message is still pending.
  * `status_view/1` and `restart/1` expose the coordinator's health.
  """

  alias ForemanServer.{CommandGateway, ProjectionStore}

  @default_limit 50
  @max_limit 200
  @max_wait_ms 25_000
  @default_mcp_per_minute 6

  @message_keys [
    :seq,
    :message_id,
    :role,
    :kind,
    :text,
    :source,
    :report_key,
    :turn_id,
    :suppressed,
    :at
  ]
  @thread_ref_keys [:task_id, :run_id, :jobsite_id]
  @error_keys [:turn_id, :code, :message, :at]
  @open_turn_keys [:turn_id, :attempt, :trigger_message_ids, :started_at, :status]

  @type error ::
          :project_not_found
          | {:project_archived, String.t()}
          | {:message_too_large, non_neg_integer(), pos_integer()}
          | {:invalid, atom()}
          | :rate_limited

  @doc "Max page size."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc "Default page size."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "Max long-poll wait in ms."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc """
  Dispatches an operator message. `source` is chosen by the CALLER SURFACE (the
  HTTP controller restricts it to cli|http|dashboard, the MCP tool pins "mcp").
  Returns `{:ok, %{message_id, seq}}`.
  """
  @spec post_message(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def post_message(project_id, %{text: text, source: source} = attrs, opts \\ []) do
    message_id = Map.get(attrs, :message_id) || generate_message_id()

    with :ok <- check_rate(project_id, message_id, source, opts),
         {:ok, _} <- dispatch_message(project_id, message_id, text, source),
         {:ok, seq} <- find_seq(project_id, message_id) do
      {:ok, %{message_id: message_id, seq: seq}}
    end
  end

  defp dispatch_message(project_id, message_id, text, source) do
    command = %{
      command_id: "coordinator-message-#{project_id}-#{message_id}",
      aggregate_id: "coordinator:" <> project_id,
      type: "coordinator.message",
      payload: %{project_id: project_id, message_id: message_id, text: text, source: source}
    }

    case CommandGateway.dispatch_operator(command) do
      {:ok, _} -> {:ok, :dispatched}
      {:error, {:project_not_found, _}} -> {:error, :project_not_found}
      {:error, {:project_archived, id}} -> {:error, {:project_archived, id}}
      {:error, {:message_too_large, bytes, max}} -> {:error, {:message_too_large, bytes, max}}
      {:error, {:missing_or_invalid, field}} -> {:error, {:invalid, field}}
      {:error, {:invalid_source, _}} -> {:error, {:invalid, :source}}
      {:error, other} -> {:error, {:invalid, error_atom(other)}}
    end
  end

  defp error_atom({tag, _}) when is_atom(tag), do: tag
  defp error_atom(tag) when is_atom(tag), do: tag
  defp error_atom(_), do: :command

  defp find_seq(project_id, message_id) do
    case ProjectionStore.coordinator_state(project_id) do
      {:ok, conv} ->
        case Enum.find(conv.messages, &(&1.message_id == message_id)) do
          %{seq: seq} -> {:ok, seq}
          nil -> {:error, {:invalid, :message_id}}
        end

      {:error, :project_not_found} ->
        {:error, :project_not_found}
    end
  end

  # Stateless per-project limit for MCP-sourced messages: counts the
  # conversation's own "mcp" operator messages in the last minute, so it
  # survives restarts and needs no extra process. A repeated message_id is a
  # no-op and is never rate limited.
  defp check_rate(project_id, message_id, "mcp", opts) do
    limit =
      Keyword.get_lazy(opts, :mcp_per_minute, fn ->
        :foreman_server
        |> Application.get_env(:coordinator, [])
        |> Keyword.get(:mcp_messages_per_minute, @default_mcp_per_minute)
      end)

    case ProjectionStore.coordinator_state(project_id) do
      {:ok, conv} ->
        cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

        recent =
          Enum.count(conv.messages, fn m ->
            m.role == "operator" and m.source == "mcp" and recent?(m.at, cutoff)
          end)

        if Enum.any?(conv.messages, &(&1.message_id == message_id)) or recent < limit,
          do: :ok,
          else: {:error, :rate_limited}

      {:error, :project_not_found} ->
        {:error, :project_not_found}
    end
  end

  defp check_rate(_project_id, _message_id, _source, _opts), do: :ok

  defp recent?(at, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
      _ -> false
    end
  end

  defp recent?(_, _), do: false

  @doc """
  Reads one page (no waiting) plus the coordinator status, string-keyed.
  `opts`: `:after` (default 0), `:limit` (default #{@default_limit}).
  """
  @spec read_page(String.t(), keyword()) :: {:ok, map()} | {:error, :project_not_found}
  def read_page(project_id, opts \\ []) do
    with {:ok, page} <- ProjectionStore.coordinator_conversation(project_id, opts),
         {:ok, status} <- ProjectionStore.coordinator_status(project_id) do
      {:ok, page_view(page, status)}
    end
  end

  @doc """
  Long-poll read: returns as soon as the page has messages, or an empty page
  once `wait_ms` elapsed. Subscribes BEFORE the first read so an append between
  read and wait cannot be lost; the wait is a `receive ... after` timeout.
  """
  @spec wait_page(String.t(), keyword(), non_neg_integer()) ::
          {:ok, map()} | {:error, :project_not_found}
  def wait_page(project_id, opts, 0), do: read_page(project_id, opts)

  def wait_page(project_id, opts, wait_ms) when wait_ms > 0 do
    with :ok <- ProjectionStore.subscribe(replay_existing: false) do
      deadline = System.monotonic_time(:millisecond) + wait_ms
      poll(project_id, opts, deadline)
    end
  end

  defp poll(project_id, opts, deadline) do
    with {:ok, view} <- read_page(project_id, opts) do
      remaining = deadline - System.monotonic_time(:millisecond)

      cond do
        view["messages"] != [] or remaining <= 0 -> {:ok, view}
        true -> await_append(project_id, opts, deadline, remaining, view)
      end
    end
  end

  defp await_append(project_id, opts, deadline, remaining, view) do
    receive do
      {:projection_event, %{event_type: "CoordinatorMessageAppended", data: data}} ->
        if event_project_id(data) == project_id,
          do: poll(project_id, opts, deadline),
          else: await_append(project_id, opts, deadline, deadline_left(deadline), view)

      {:projection_event, _other} ->
        await_append(project_id, opts, deadline, deadline_left(deadline), view)
    after
      max(remaining, 0) -> {:ok, view}
    end
  end

  defp deadline_left(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp event_project_id(data) when is_map(data),
    do: Map.get(data, :project_id) || Map.get(data, "project_id")

  defp event_project_id(_), do: nil

  @doc "Status of the coordinator, string-keyed."
  @spec status_view(String.t()) :: {:ok, map()} | {:error, :project_not_found}
  def status_view(project_id) do
    with {:ok, status} <- ProjectionStore.coordinator_status(project_id) do
      {:ok, status_map(status)}
    end
  end

  @doc "Dispatches `coordinator.restart` (by: \"http\") and returns the status."
  @spec restart(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def restart(project_id, by) do
    command = %{
      command_id: "coordinator-restart-#{project_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "coordinator:" <> project_id,
      type: "coordinator.restart",
      payload: %{project_id: project_id, by: by}
    }

    case CommandGateway.dispatch_operator(command) do
      {:ok, _} -> status_view(project_id)
      {:error, {:project_not_found, _}} -> {:error, :project_not_found}
      {:error, {:project_archived, id}} -> {:error, {:project_archived, id}}
      {:error, other} -> {:error, {:invalid, error_atom(other)}}
    end
  end

  # ------------------------------------------------------------ whitelisting

  defp page_view(page, status) do
    %{
      "messages" => Enum.map(page.messages, &message_view/1),
      "next_cursor" => page.next_cursor,
      "has_more" => page.has_more,
      "truncated_before_seq" => page.truncated_before_seq,
      "status" => Atom.to_string(status.status),
      "pending_messages" => status.pending_messages
    }
  end

  defp message_view(message) do
    @message_keys
    |> Map.new(fn key -> {Atom.to_string(key), Map.get(message, key)} end)
    |> Map.put("thread_ref", thread_ref_view(Map.get(message, :thread_ref)))
  end

  defp thread_ref_view(ref) when is_map(ref) do
    Map.new(@thread_ref_keys, fn key -> {Atom.to_string(key), fetch(ref, key)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp thread_ref_view(_), do: nil

  defp status_map(status) do
    %{
      "status" => Atom.to_string(status.status),
      "open_turn" => whitelist(status.open_turn, @open_turn_keys),
      "consecutive_failures" => status.consecutive_failures,
      "last_error" => whitelist(status.last_error, @error_keys),
      "pending_messages" => status.pending_messages,
      "last_activity_at" => status.last_activity_at
    }
  end

  defp whitelist(map, keys) when is_map(map),
    do: Map.new(keys, fn key -> {Atom.to_string(key), fetch(map, key)} end)

  defp whitelist(_, _), do: nil

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp generate_message_id,
    do: "msg-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
