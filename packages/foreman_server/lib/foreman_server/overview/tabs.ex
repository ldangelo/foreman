defmodule ForemanServer.Overview.Tabs do
  @moduledoc """
  Tab data of the Overview: `pull_requests`, `library`, `scheduled`.

  Each tab is `%{available: boolean(), rows: [map()]}` (plus `error: String.t()`
  when its provider failed). `pull_requests` is provided by
  `Overview.Tabs.PullRequests`; `library` by `Overview.Tabs.Library`. `scheduled`
  is served by another epic (E11) that registers through `config :foreman_server,
  :overview, tab_providers: [...]`; until then it reports `available: false`.
  """

  require Logger

  alias ForemanServer.Overview.Tabs.{Library, PullRequests}

  @tab_names [:pull_requests, :library, :scheduled]

  @type tab :: %{
          required(:available) => boolean(),
          required(:rows) => [map()],
          optional(:error) => String.t()
        }
  @type t :: %{atom() => tab()}

  @doc "Tab names in display order."
  @spec names() :: [atom()]
  def names, do: @tab_names

  @doc "Providers: the built-in Pull requests and Library providers plus configured ones."
  @spec providers() :: [module()]
  def providers do
    configured =
      Application.get_env(:foreman_server, :overview, []) |> Keyword.get(:tab_providers, [])

    [PullRequests, Library | List.wrap(configured)]
  end

  @doc """
  Builds every tab for a project. Raises `ArgumentError` when two providers
  (built-in or configured) name the same tab: a silent override would hide one
  of them.
  """
  @spec build(String.t()) :: t()
  def build(project_id) when is_binary(project_id) do
    registered = providers() |> Enum.flat_map(&register/1) |> unique_by_tab()
    extra = Map.keys(registered) -- @tab_names

    Map.new(@tab_names ++ extra, fn name ->
      case Map.fetch(registered, name) do
        {:ok, module} -> {name, rows(module, name, project_id)}
        :error -> {name, %{available: false, rows: []}}
      end
    end)
  end

  defp unique_by_tab(entries) do
    Enum.reduce(entries, %{}, fn {name, module}, acc ->
      case acc do
        %{^name => existing} ->
          raise ArgumentError,
                "Overview tab #{inspect(name)} is provided by both #{inspect(existing)} " <>
                  "and #{inspect(module)}; each tab needs exactly one provider"

        _ ->
          Map.put(acc, name, module)
      end
    end)
  end

  # A provider whose `tab/0` raises has no tab name to report a failure under:
  # it is dropped (logged) so the other tabs still build.
  defp register(module) do
    [{module.tab(), module}]
  rescue
    error ->
      Logger.warning(
        "Overview tab provider #{inspect(module)} tab/0 failed: #{Exception.message(error)}"
      )

      []
  end

  defp rows(module, name, project_id) do
    %{available: true, rows: module.rows(project_id)}
  rescue
    error ->
      Logger.warning(
        "Overview tab #{name} (#{inspect(module)}) failed: #{Exception.message(error)}"
      )

      %{available: false, rows: [], error: "provider_failed"}
  end

  @spec to_dto(t()) :: %{String.t() => map()}
  def to_dto(tabs) do
    Map.new(tabs, fn {name, tab} ->
      dto = %{"available" => tab.available, "rows" => tab.rows}
      dto = if tab[:error], do: Map.put(dto, "error", tab.error), else: dto
      {Atom.to_string(name), dto}
    end)
  end
end
