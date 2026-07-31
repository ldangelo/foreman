defmodule ForemanServer.Webhooks.Github do
  @moduledoc "Processes GitHub pull request webhooks for PR lifecycle reconciliation."

  alias ForemanServer.PrMonitor.GhWebhookHandler

  @type option :: {:command_handler, module()}

  @spec process(map(), [option()]) :: {:ok, map()} | {:error, term()}
  def process(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    GhWebhookHandler.handle(payload, Keyword.get(opts, :command_handler))
  end

  @spec verify_signature(String.t(), String.t(), String.t()) :: boolean()
  defdelegate verify_signature(body, signature_header, secret), to: GhWebhookHandler

  @spec build_signature(String.t(), String.t()) :: String.t()
  defdelegate build_signature(body, secret), to: GhWebhookHandler
end
