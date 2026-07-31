defmodule ForemanServer.PrAssociate do
  alias ForemanServer.CommandRouter

  @moduledoc """
  Command-boundary helper for associating a completed run with a PR URL.

  Dispatches `pr.associate` through `CommandRouter` (which handles event
  persistence) and returns a stable `association_id`.
  """

  @doc """
  Associates a completed run with a PR URL.

  `pr_number` is derived from the URL if not supplied.  Accepts:
  - full GitHub PR URLs: `https://github.com/owner/repo/pull/123`
  - bare numeric identities: `"123"` (used when URL is unavailable)

  Returns `{:ok, association_id}` on success.
  """
  @spec store(run_id :: String.t(), pr_url :: String.t(), pr_number :: String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def store(run_id, pr_url, pr_number \\ nil) do
    derived = extract_pr_number(pr_url)

    pr_number =
      cond do
        pr_number != nil -> pr_number
        derived != nil -> derived
        true -> {:error, {:invalid_pr_url, pr_url}}
      end

    case pr_number do
      {:error, _} = error ->
        error

      _ ->
        command_id = "pr-assoc:#{run_id}:#{pr_url}"

        payload = %{
          run_id: run_id,
          pr_url: pr_url,
          pr_number: pr_number
        }

        case CommandRouter.handle(%{
               command_id: command_id,
               command_type: "pr.associate",
               payload: payload
             }) do
          {:ok, %{event: %{event_type: "PrAssociated"}}} ->
            {:ok, "#{run_id}:#{pr_url}"}

          {:error, {:duplicate_idempotency_key, _}} ->
            # Idempotent: already associated with this exact run+URL.
            {:ok, "#{run_id}:#{pr_url}"}

          {:error, _} = error ->
            error
        end
    end
  end

  # ─── Private ────────────────────────────────────────────────────────────────

  @doc false
  @spec extract_pr_number(String.t()) :: String.t() | nil
  def extract_pr_number(pr_url) when is_binary(pr_url) do
    cond do
      # Full GitHub PR URL: https://github.com/owner/repo/pull/123
      match = Regex.run(~r"/pull/(\d+)(?:[/?#]|$)", pr_url) ->
        List.last(match)

      # Bare numeric identity: "123"
      Regex.match?(~r/^\d+$/, pr_url) ->
        pr_url

      true ->
        nil
    end
  end
end
