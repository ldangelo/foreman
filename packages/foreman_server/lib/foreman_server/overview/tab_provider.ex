defmodule ForemanServer.Overview.TabProvider do
  @moduledoc """
  Behaviour for a project Overview tab.

  `tab/0` names the tab (`:library`, `:scheduled`, ...) and `rows/1` returns its
  rows for a project: JSON-safe, string-keyed maps. Providers are registered in
  `config :foreman_server, :overview, tab_providers: [Module, ...]`; the Pull
  requests provider is built in. A tab with no registered provider is reported
  as `available: false` - honest capability reporting, not an empty list.

  A provider that raises is isolated by `Overview.Tabs`: only its own tab is
  reported unavailable (a `tab/0` that raises is logged and skipped). Each tab
  has exactly one provider: two providers naming the same tab, including a
  configured one shadowing a built-in, make `Tabs.build/1` raise `ArgumentError`.
  """

  @callback tab() :: atom()
  @callback rows(project_id :: String.t()) :: [map()]
end
