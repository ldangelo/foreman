defmodule ForemanServer.Messaging.HttpClient do
  @moduledoc "Minimal JSON HTTP client used by chat provider adapters."

  @spec post_json(String.t(), map(), [{String.t(), String.t()}], non_neg_integer()) ::
          {:ok, %{status: non_neg_integer(), body: String.t()}} | {:error, term()}
  def post_json(url, body, headers \\ [], timeout_ms \\ 5_000)
      when is_binary(url) and is_map(body) and is_integer(timeout_ms) do
    :ok = ensure_inets_started()
    json = Jason.encode!(body)

    request = {
      String.to_charlist(url),
      Enum.map([{"content-type", "application/json"} | headers], fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end),
      ~c"application/json",
      json
    }

    case :httpc.request(:post, request, [timeout: timeout_ms], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_inets_started do
    case Application.ensure_all_started(:inets) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
