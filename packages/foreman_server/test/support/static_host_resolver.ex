defmodule ForemanServer.TestSupport.StaticHostResolver do
  @moduledoc """
  A `host_resolver` for tests (`config :foreman_server, :messaging, host_resolver:`,
  the module `ForemanServer.Messaging.Providers.Webhook` asks): no DNS, so a test
  never waits on the network's resolver and `.test` names (which never resolve
  for real) can be webhook hosts.

  Every name resolves to `203.0.113.10` (TEST-NET-3: public as far as the
  webhook rules go, and unroutable) unless the table below says otherwise.
  """

  @table %{
    "internal.test" => {:ok, [{10, 0, 0, 5}]},
    "metadata.test" => {:ok, [{169, 254, 169, 254}]},
    "loopback6.test" => {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]},
    "mixed.test" => {:ok, [{203, 0, 113, 10}, {192, 168, 1, 9}]},
    "down.test" => {:error, :nxdomain}
  }

  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(host), do: Map.get(@table, host, {:ok, [{203, 0, 113, 10}]})
end
