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

  @spec build(String.t()) :: t()
  def build(project_id) when is_binary(project_id) do
    registered = Map.new(providers(), fn module -> {module.tab(), module} end)
    extra = Map.keys(registered) -- @tab_names

    Map.new(@tab_names ++ extra, fn name ->
      case Map.fetch(registered, name) do
        {:ok, module} -> {name, rows(module, name, project_id)}
        :error -> {name, %{available: false, rows: []}}
      end
    end)
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
