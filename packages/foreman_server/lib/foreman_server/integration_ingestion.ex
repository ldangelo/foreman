defmodule ForemanServer.IntegrationIngestion do
  @moduledoc "Idempotent server-side command ingestion for sentinel, Jira, and GitHub triggers."

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore}

  @sources ~w(sentinel jira github)

  @spec ingest(map()) :: {:ok, map()} | {:error, term()}
  def ingest(input) when is_map(input) do
    with {:ok, attrs} <- normalize(input) do
      task_payload = task_payload(attrs)

      case dedupe_state(attrs, task_payload) do
        :new ->
          with {:ok, ingested} <- append_ingested(attrs, task_payload),
               {:ok, command} <- dispatch_task_command(attrs, task_payload) do
            {:ok,
             %{
               duplicate: false,
               ingestion: ingested,
               command: command,
               task_id: task_payload.task_id,
               dedupe_key: attrs.dedupe_key,
               projection: ProjectionStore.snapshot()
             }}
          end

        {:dedupe_without_task, existing} ->
          with {:ok, command} <- dispatch_task_command(attrs, task_payload) do
            {:ok,
             %{
               duplicate: false,
               recovered: true,
               existing: existing,
               command: command,
               task_id: task_payload.task_id,
               dedupe_key: attrs.dedupe_key,
               projection: ProjectionStore.snapshot()
             }}
          end

        {:duplicate, existing} ->
          {:ok, %{duplicate: true, existing: existing, projection: ProjectionStore.snapshot()}}
      end
    end
  end

  def ingest(_input), do: {:error, :invalid_integration_input}

  defp normalize(input) do
    with {:ok, source} <- required_source(fetch(input, :source)),
         {:ok, project_id} <- required_binary(fetch(input, :project_id), :project_id),
         {:ok, external_id} <- required_binary(fetch(input, :external_id), :external_id),
         {:ok, event_type} <- required_binary(fetch(input, :event_type), :event_type),
         {:ok, dedupe_key} <- dedupe_key(source, input, external_id, event_type),
         {:ok, external_link} <- external_link(source, input),
         :ok <- sentinel_threshold(source, input) do
      {:ok,
       %{
         source: source,
         project_id: project_id,
         external_id: external_id,
         event_type: event_type,
         occurred_at: fetch(input, :occurred_at) || DateTime.utc_now(),
         payload: fetch(input, :payload) || %{},
         dedupe_key: dedupe_key,
         title: title(source, input, external_id, event_type),
         external_link: external_link,
         task_type: task_type(source),
         severity: fetch(input, :severity),
         threshold: fetch(input, :threshold),
         count: fetch(input, :count)
       }}
    end
  end

  defp dedupe_state(%{dedupe_key: dedupe_key}, %{task_id: task_id}) do
    snapshot = ProjectionStore.snapshot()

    case get_in(snapshot, [:integration_dedupe, dedupe_key]) do
      nil ->
        :new

      existing ->
        if Map.has_key?(snapshot.tasks, task_id) do
          {:duplicate, existing}
        else
          {:dedupe_without_task, existing}
        end
    end
  end

  defp append_ingested(attrs, task_payload) do
    EventStore.append(%{
      stream_id: "integration:#{attrs.dedupe_key}",
      event_type: "IntegrationCommandIngested",
      payload: %{
        source: attrs.source,
        external_id: attrs.external_id,
        project_id: attrs.project_id,
        event_type: attrs.event_type,
        occurred_at: attrs.occurred_at,
        payload: attrs.payload,
        idempotency_key: attrs.dedupe_key,
        dedupe_key: attrs.dedupe_key,
        external_link: attrs.external_link,
        task_id: task_payload.task_id,
        command_type: "task.create"
      },
      metadata: %{
        source: "integration-ingestion",
        correlation_id: attrs.dedupe_key,
        idempotency_key: attrs.dedupe_key
      }
    })
  end

  defp dispatch_task_command(attrs, task_payload) do
    CommandRouter.handle(%{
      command_id: "integration:#{attrs.dedupe_key}",
      command_type: "task.create",
      correlation_id: attrs.dedupe_key,
      payload: task_payload,
      metadata: %{
        source: "integration:#{attrs.source}",
        correlation_id: attrs.dedupe_key,
        idempotency_key: attrs.dedupe_key
      }
    })
  end

  defp task_payload(attrs) do
    %{
      task_id: stable_task_id(attrs),
      project_id: attrs.project_id,
      title: attrs.title,
      status: "open",
      task_type: attrs.task_type,
      source: attrs.source,
      external_id: attrs.external_id,
      external_link: attrs.external_link,
      dedupe_key: attrs.dedupe_key,
      integration_event_type: attrs.event_type,
      dependencies: []
    }
  end

  defp stable_task_id(%{source: source, dedupe_key: dedupe_key}) do
    digest =
      :crypto.hash(:sha256, dedupe_key) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    "#{source}-#{digest}"
  end

  defp title("sentinel", input, external_id, _event_type) do
    fetch(input, :title) || "Bug: sentinel detected repeated failure #{external_id}"
  end

  defp title(source, input, external_id, event_type) do
    fetch(input, :title) || "#{String.capitalize(source)} #{event_type}: #{external_id}"
  end

  defp external_link(source, input) when source in ["jira", "github"] do
    case fetch(input, :external_link) || fetch(input, :url) do
      link when is_binary(link) and link != "" -> {:ok, link}
      _ -> {:error, {:missing_or_invalid, :external_link}}
    end
  end

  defp external_link(_source, input),
    do: {:ok, fetch(input, :external_link) || fetch(input, :url)}

  defp task_type("sentinel"), do: "bug"
  defp task_type(_source), do: "external"

  defp dedupe_key(_source, input, _external_id, _event_type) do
    case fetch(input, :idempotency_key) || fetch(input, :dedupe_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> source_dedupe_key(input)
    end
  end

  defp source_dedupe_key(input) do
    case {fetch(input, :source), fetch(input, :site), fetch(input, :repo),
          fetch(input, :project_id), fetch(input, :external_id), fetch(input, :event_id),
          fetch(input, :fingerprint), fetch(input, :transition_id), fetch(input, :event_type)} do
      {"jira", site, _repo, _project, issue, _event_id, _fingerprint, transition, _event_type}
      when is_binary(site) and is_binary(issue) and is_binary(transition) ->
        {:ok, "jira:#{site}:#{issue}:#{transition}"}

      {"github", _site, repo, _project, _external_id, event_id, _fingerprint, _transition,
       _event_type}
      when is_binary(repo) and is_binary(event_id) ->
        {:ok, "github:#{repo}:#{event_id}"}

      {"github", site, _repo, _project, _external_id, event_id, _fingerprint, _transition,
       _event_type}
      when is_binary(site) and is_binary(event_id) ->
        {:ok, "github:#{site}:#{event_id}"}

      {"sentinel", _site, _repo, project, _external_id, _event_id, fingerprint, _transition,
       _event_type}
      when is_binary(project) and is_binary(fingerprint) ->
        {:ok, "sentinel:#{project}:#{fingerprint}"}

      {"sentinel", _site, _repo, project, external_id, _event_id, _fingerprint, _transition,
       _event_type}
      when is_binary(project) and is_binary(external_id) ->
        {:ok, "sentinel:#{project}:#{external_id}"}

      _ ->
        {:error, {:missing_or_invalid, :idempotency_key}}
    end
  end

  defp sentinel_threshold("sentinel", input) do
    count = fetch(input, :count) || 0
    threshold = fetch(input, :threshold) || 1

    if is_integer(count) and is_integer(threshold) and count >= threshold do
      :ok
    else
      {:error, {:threshold_not_reached, count: count, threshold: threshold}}
    end
  end

  defp sentinel_threshold(_source, _input), do: :ok

  defp required_source(source) when source in @sources, do: {:ok, source}
  defp required_source(nil), do: {:error, {:missing_or_invalid, :source}}
  defp required_source(""), do: {:error, {:missing_or_invalid, :source}}
  defp required_source(source), do: {:error, {:unsupported_integration_source, source}}

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
