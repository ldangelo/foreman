defmodule ForemanServer.Agents.LitellmRouter do
  @moduledoc """
  LiteLLM router with model="auto" capability routing.

  Reads `:litellm` and `:langfuse` configuration from the application
  environment and exposes a `route/2` helper that produces a request
  envelope for a given capability (e.g. `:code_generation`, `:chat`,
  `:embedding`).

  The "auto" model value tells LiteLLM to pick the best underlying
  model for each capability at request time, so the caller never has
  to know which provider is currently serving `:code` vs `:chat`.

  TRD-2026-4212be7e / LGL-T001 / TRD-042.
  """
  require Logger

  @doc "LiteLLM HTTP endpoint (default `http://localhost:4000`)."
  def endpoint, do: Application.get_env(:foreman_server, :litellm)[:endpoint] || "http://localhost:4000"

  @doc ~S(LiteLLM model name; `"auto"` defers selection to LiteLLM per capability.)
  def model, do: Application.get_env(:foreman_server, :litellm)[:model] || "auto"

  @doc "Langfuse HTTP endpoint (default `http://localhost:3000`)."
  def langfuse_endpoint,
    do: Application.get_env(:foreman_server, :langfuse)[:endpoint] || "http://localhost:3000"

  @doc """
  Build a request envelope for the given `capability` (an atom such as
  `:code_generation`, `:chat`, or `:embedding`).

  ## Options

    * `:max_tokens` — cap on the response size (default `1024`).
    * `:temperature` — sampling temperature (default `nil`, deferred
      to LiteLLM).
  """
  def route(capability, opts \\ []) do
    Logger.info("Routing LLM request: capability=#{capability}")

    %{
      endpoint: endpoint(),
      langfuse_endpoint: langfuse_endpoint(),
      model: model(),
      capability: capability,
      max_tokens: Keyword.get(opts, :max_tokens, 1024),
      temperature: Keyword.get(opts, :temperature)
    }
  end
end