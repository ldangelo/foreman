defmodule ForemanServer.ProviderRegistry do
  @moduledoc "Provider adapter registry. v1 production execution requires the Pi SDK adapter."

  @pi_tools MapSet.new(~w(read edit write bash open_in_nvim intercom todo lsp subagent))

  @type adapter :: %{
          id: String.t(),
          production_ready: boolean(),
          supported_tools: MapSet.t(String.t()),
          worker_protocol: String.t()
        }

  @spec resolve(map()) :: {:ok, adapter()} | {:error, term()}
  def resolve(workflow) when is_map(workflow) do
    provider = workflow |> provider_name() |> normalize_provider()

    with {:ok, adapter} <- fetch_adapter(provider),
         :ok <- enforce_v1_production(adapter),
         :ok <-
           validate_tools(
             adapter,
             Map.get(workflow, :tool_names, Map.get(workflow, "tool_names", []))
           ) do
      {:ok, adapter}
    end
  end

  @spec adapters() :: [adapter()]
  def adapters do
    [
      %{
        id: "pi_sdk",
        production_ready: true,
        supported_tools: @pi_tools,
        worker_protocol: "worker_http_v1"
      },
      %{
        id: "mock",
        production_ready: false,
        supported_tools: MapSet.new([]),
        worker_protocol: "test_only"
      }
    ]
  end

  defp provider_name(workflow) do
    Map.get(workflow, :provider) || Map.get(workflow, "provider") || provider_from_model(workflow) ||
      "pi_sdk"
  end

  defp provider_from_model(workflow) do
    model = Map.get(workflow, :model) || Map.get(workflow, "model")
    if is_binary(model) and String.starts_with?(model, "pi/"), do: "pi_sdk", else: nil
  end

  defp normalize_provider(provider) when provider in [:pi, :pi_sdk], do: "pi_sdk"
  defp normalize_provider(provider) when is_binary(provider), do: provider
  defp normalize_provider(_), do: "pi_sdk"

  defp fetch_adapter(provider) do
    case Enum.find(adapters(), &(&1.id == provider)) do
      nil ->
        {:error,
         {:unsupported_provider, provider,
          "Pi SDK is the only required production adapter for v1"}}

      adapter ->
        {:ok, adapter}
    end
  end

  defp enforce_v1_production(%{id: "pi_sdk", production_ready: true}), do: :ok

  defp enforce_v1_production(adapter) do
    {:error,
     {:adapter_not_production_ready, adapter.id,
      "Pi SDK is the only required production adapter for v1"}}
  end

  defp validate_tools(_adapter, tools) when tools in [nil, []], do: :ok

  defp validate_tools(adapter, tools) when is_list(tools) do
    unsupported = Enum.reject(tools, &MapSet.member?(adapter.supported_tools, &1))

    case unsupported do
      [] ->
        :ok

      values ->
        {:error,
         {:unsupported_tools, values,
          "Use Pi-compatible tools or remove unsupported tool requirements"}}
    end
  end

  defp validate_tools(_adapter, _tools),
    do: {:error, {:invalid_tools, "tool_names must be a list"}}
end
