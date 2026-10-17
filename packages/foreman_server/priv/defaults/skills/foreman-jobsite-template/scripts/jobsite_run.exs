#!/usr/bin/env elixir
# Start ONE jobsite spec and wait for it, using only :httpc and OTP :json -- no
# foreman_client, no Mix.install, no network fetch of the package. This is the
# fallback smoke runner: prefer the generated <name>.exs (which uses
# Foreman.Client) and reach for this only when Mix.install cannot fetch
# foreman_client where you are testing.
#
#   export FOREMAN_API_TOKEN=...
#   elixir jobsite_run.exs path/to/jobsite.spec.json [timeout_seconds]
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.
#
# Prints the jobsite id immediately, then the terminal state. Exit 0 only on
# "completed": failed / cancelled / paused / timeout all exit 1 with last_error
# printed, so a green exit always means the work actually landed.

{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)

defmodule Runner do
  @terminal ["completed", "failed", "cancelled", "paused"]
  # Same grace `Foreman.Client` allows for a just-created jobsite to become readable
  # (`packages/foreman_client/lib/foreman/client.ex:36`), so the fallback runner does not
  # behave differently from the primary one.
  @not_found_grace_s 10

  def run(base, token, spec, timeout_s) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/json"}
    ]

    req =
      {String.to_charlist(base <> "/api/jobsites"), headers, ~c"application/json",
       IO.iodata_to_binary(:json.encode(spec))}

    case :httpc.request(:post, req, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, resp}} when status in 200..299 ->
        case decode(resp) do
          %{"id" => id} ->
            IO.puts("started #{id}")

            wait(
              base,
              headers,
              id,
              System.monotonic_time(:second) + timeout_s,
              System.monotonic_time(:second)
            )

          other ->
            IO.puts(:stderr, "accepted but no id in the response: #{inspect(other)}")
            1
        end

      {:ok, {{_, status, _}, _, resp}} ->
        IO.puts(:stderr, "HTTP #{status}: #{inspect(decode(resp))}")
        1

      {:error, why} ->
        IO.puts(:stderr, "cannot reach #{base}: #{inspect(why)}")
        IO.puts(:stderr, "is foreman_server up, and is jobsites.allow_remote_start true?")
        1
    end
  end

  defp wait(base, headers, id, deadline, started_at) do
    req = {String.to_charlist(base <> "/api/jobsites/#{id}"), headers}

    case :httpc.request(:get, req, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case decode(resp) do
          %{"status" => s} = j when s in @terminal ->
            IO.puts(
              "status=#{s} branch=#{inspect(Map.get(j, "branch"))} commits=#{length(Map.get(j, "commits") || [])}"
            )

            if e = Map.get(j, "last_error"), do: IO.puts(:stderr, "last_error: #{inspect(e)}")
            if o = Map.get(j, "output"), do: IO.puts("--- output ---\n#{o}")
            if(s == "completed", do: 0, else: 1)

          %{"status" => s} ->
            if System.monotonic_time(:second) >= deadline do
              IO.puts(
                :stderr,
                "timed out while #{s} (the jobsite is still running on the server: #{id})"
              )

              1
            else
              Process.sleep(2_000)
              wait(base, headers, id, deadline, started_at)
            end

          other ->
            IO.puts(:stderr, "unexpected body: #{inspect(other)}")
            1
        end

      # A just-created jobsite is not in the read model for a moment, so a 404 is retried --
      # but only for the grace window. Without the cap, a mistyped or already-purged id is
      # polled for the FULL timeout (1800 s by default) and then exits 1 having printed
      # nothing at all, which reads as a hang rather than as "no such jobsite".
      {:ok, {{_, 404, _}, _, _}} ->
        cond do
          System.monotonic_time(:second) - started_at >= @not_found_grace_s ->
            IO.puts(:stderr, "no such jobsite: #{id} (404 persisted past the grace window)")
            1

          System.monotonic_time(:second) >= deadline ->
            IO.puts(:stderr, "timed out before jobsite #{id} became readable")
            1

          true ->
            Process.sleep(2_000)
            wait(base, headers, id, deadline, started_at)
        end

      {:ok, {{_, status, _}, _, resp}} ->
        IO.puts(:stderr, "HTTP #{status} while polling: #{inspect(decode(resp))}")
        1

      {:error, why} ->
        IO.puts(:stderr, "poll failed: #{inspect(why)}")
        1
    end
  end

  defp decode(resp) do
    try do
      :json.decode(resp)
    catch
      _, _ -> resp
    end
  end
end

[spec_path | rest] = System.argv()

spec =
  case spec_path |> File.read!() |> :json.decode() do
    %{} = m ->
      m

    other ->
      IO.puts(:stderr, "spec must be a JSON object, got: #{inspect(other)}")
      System.halt(1)
  end

base = String.trim_trailing(System.get_env("FOREMAN_API_URL") || "http://127.0.0.1:4766", "/")
token = System.get_env("FOREMAN_API_TOKEN") || raise ArgumentError, "FOREMAN_API_TOKEN is not set"

timeout_s =
  case rest |> List.first() |> then(&if is_nil(&1), do: "1800", else: &1) |> Integer.parse() do
    {n, ""} when is_integer(n) and n > 0 -> n
    _ -> raise ArgumentError, "timeout argument must be a positive integer number of seconds"
  end

System.halt(Runner.run(base, token, spec, timeout_s))
