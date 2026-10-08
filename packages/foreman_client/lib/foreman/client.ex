# A standalone client for a running foreman_server's /api/jobsites.
#
# Load it from a script with
#
#     Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])
#
# and run the script with plain `elixir` (no Foreman checkout, no database). It
# needs Erlang/OTP 27 or newer (it uses the built-in `:json`) and nothing else:
# HTTP is OTP's `:httpc`.
#
# Configuration, read once by `Foreman.Client.new/1`:
#
#     FOREMAN_API_URL    default http://127.0.0.1:4766
#     FOREMAN_API_TOKEN  required — the server's bearer token
#
# Every call returns `{:ok, body}` or `{:error, reason}`, where a non-2xx
# response is `{:error, {status, body}}` and a connection failure is
# `{:error, {:transport, reason}}`. `body` is the decoded JSON object (string
# keys), or the raw response text when the server did not send JSON.
#
# The server runs the jobsite, not this script: the repo is a registered
# `project_id` on the server, the prompt is sent as text, and nothing in a spec
# can execute code on the server. Anything this script does itself (calling
# Jira or `gh`, deciding how many jobsites to start, reading results) runs
# here, on your machine.
#
# JSON null: `:json` encodes the atom `:null` as `null` and any other atom as a
# string, so never put `nil` in a spec — leave the key out instead.

defmodule Foreman.Client do
  @moduledoc false

  defstruct [:base_url, :token]

  @terminal ["completed", "failed", "cancelled"]
  @not_found_grace_ms 10_000

  @doc "Build a client from options or the environment (see the top of this file)."
  def new(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    base_url = Keyword.get(opts, :url) || System.get_env("FOREMAN_API_URL") || "http://127.0.0.1:4766"

    token =
      Keyword.get(opts, :token) || System.get_env("FOREMAN_API_TOKEN") ||
        raise ArgumentError, "FOREMAN_API_TOKEN is not set (or pass token: ...)"

    %__MODULE__{base_url: String.trim_trailing(base_url, "/"), token: token}
  end

  @doc "Start a jobsite from a spec map (string keys). Returns `{:ok, id}`."
  def start(client, spec) when is_map(spec) do
    with {:ok, %{"id" => id}} <- request(client, :post, "/api/jobsites", spec), do: {:ok, id}
  end

  def get(client, id), do: request(client, :get, "/api/jobsites/#{id}")

  def list(client) do
    with {:ok, %{"jobsites" => jobsites}} <- request(client, :get, "/api/jobsites"), do: {:ok, jobsites}
  end

  def pause(client, id, reason), do: request(client, :post, "/api/jobsites/#{id}/pause", %{"reason" => reason})
  def cancel(client, id, reason), do: request(client, :post, "/api/jobsites/#{id}/cancel", %{"reason" => reason})
  def resume(client, id), do: request(client, :post, "/api/jobsites/#{id}/resume", %{})

  @doc """
  Merge a COMPLETED jobsite's branch into `into`, which must be the branch
  currently checked out in the server's copy of the repo (the server refuses
  anything else). Merges change that checkout, so run them one at a time.
  """
  def merge(client, id, into), do: request(client, :post, "/api/jobsites/#{id}/merge", %{"into" => into})

  @doc """
  Poll until the jobsite is `completed`, `failed`, `cancelled` or `paused`, and
  return `{:ok, jobsite}` (inspect `"status"`). Options: `:interval_ms`
  (default 2000), `:timeout_ms` (default one hour; `:infinity` to wait forever).
  A timeout is `{:error, :timeout}` — the jobsite keeps running on the server.
  """
  def wait(client, id, opts \\ []) do
    interval = Keyword.get(opts, :interval_ms, 2_000)
    timeout = Keyword.get(opts, :timeout_ms, 3_600_000)
    deadline = if timeout == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + timeout
    do_wait(client, id, interval, deadline, System.monotonic_time(:millisecond))
  end

  defp do_wait(client, id, interval, deadline, started_at) do
    case get(client, id) do
      {:ok, %{"status" => status} = jobsite} when status in @terminal or status == "paused" ->
        {:ok, jobsite}

      {:ok, _still_running} ->
        if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          do_wait(client, id, interval, deadline, started_at)
        end

      # A just-created jobsite is not in the read model for a moment, so a 404 is
      # retried briefly. After the grace period it is a real "no such jobsite"
      # (a mistyped id) and is returned rather than waited on for the full timeout.
      {:error, {404, _}} = not_found ->
        if System.monotonic_time(:millisecond) - started_at < @not_found_grace_ms do
          Process.sleep(interval)
          do_wait(client, id, interval, deadline, started_at)
        else
          not_found
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Start a jobsite and wait for it. `{:ok, jobsite}` only when it COMPLETED;
  any other end state is `{:error, {:jobsite, jobsite}}` so a failed or paused
  run cannot be mistaken for success.
  """
  def run(client, spec, wait_opts \\ []) do
    with {:ok, id} <- start(client, spec),
         {:ok, jobsite} <- wait(client, id, wait_opts) do
      case jobsite do
        %{"status" => "completed"} -> {:ok, jobsite}
        other -> {:error, {:jobsite, other}}
      end
    end
  end

  # -- HTTP ---------------------------------------------------------------

  defp request(%__MODULE__{} = client, method, path, body \\ nil) do
    url = client.base_url <> path
    headers = [{~c"authorization", String.to_charlist("Bearer " <> client.token)}, {~c"accept", ~c"application/json"}]

    http_request =
      case method do
        :get ->
          {String.to_charlist(url), headers}

        :post ->
          {String.to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(:json.encode(body || %{}))}
      end

    case :httpc.request(method, http_request, http_options(url), body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} -> decode(status, response)
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp http_options("https://" <> _ = url) do
    host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      timeout: 30_000,
      connect_timeout: 10_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: host,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp http_options(_http_url), do: [timeout: 30_000, connect_timeout: 10_000]

  defp decode(status, response) do
    body =
      try do
        :json.decode(response)
      catch
        _kind, _reason -> response
      end

    if status in 200..299, do: {:ok, body}, else: {:error, {status, body}}
  end
end
