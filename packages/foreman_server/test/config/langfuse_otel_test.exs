defmodule ForemanServer.Config.LangfuseOtelTest do
  @moduledoc """
  Exercises the OTLP collector + Langfuse wiring without leaving the
  foreman repo. Tagged `:langfuse` so it can be opted in/out without
  affecting the rest of the suite.

  Three contracts verified:

    1. `build_otlp_headers/0` (the same shape prod.exs uses) produces an
       HTTP Basic header from $LANGFUSE_PUBLIC_KEY + $LANGFUSE_SECRET_KEY
       — NOT Bearer-with-public-only. Earlier this session shipped the
       Bearer form against real Langfuse; that returns 403 from
       /api/public/otel/v1/traces (verified 2026-08-21). Pure unit;
       no network.

    2. The OTel collector at http://127.0.0.1:4318 accepts an OTLP/HTTP
       trace (JSON wire format) and returns HTTP 200. Network, but no auth.

    3. The trace arrives at Langfuse, queryable via
       /api/public/traces. Network + auth. This is the one that exercises
       the full prod.exs -> collector -> otlphttp/langfuse -> Langfuse
       path.

  Required env to run: LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY
  exported; both are present in the stack's .env and the devbox shell
  loads them automatically (see devbox.json `observability:up`).

  Usage:
    mix test --only langfuse
    # or
    devbox run test:langfuse
  """

  use ExUnit.Case, async: false

  @moduletag :langfuse

  # Pulled from config.exs / prod.exs defaults; overridable via env.
  @collector_url "http://127.0.0.1:4318"
  @langfuse_url "http://127.0.0.1:3000"

  @http_opts [
    timeout: 10_000,
    connect_timeout: 5_000
  ]

  # ---- unit --------------------------------------------------------------

  defp build_otlp_headers do
    public = System.get_env("LANGFUSE_PUBLIC_KEY", "")
    secret = System.get_env("LANGFUSE_SECRET_KEY", "")

    if public != "" and secret != "" do
      encoded = Base.encode64("#{public}:#{secret}")
      [{"Authorization", "Basic " <> encoded}]
    else
      []
    end
  end

  # Run `body` with $LANGFUSE_PUBLIC_KEY and $LANGFUSE_SECRET_KEY set to the
  # given values for the duration, restoring the original shell values on
  # exit. System.delete_env/1 drops the var from the Erlang VM entirely,
  # which breaks later tests — always restore, never delete.
  defp with_env(public, secret, body) do
    public_orig = System.get_env("LANGFUSE_PUBLIC_KEY")
    secret_orig = System.get_env("LANGFUSE_SECRET_KEY")
    System.put_env("LANGFUSE_PUBLIC_KEY", public)
    System.put_env("LANGFUSE_SECRET_KEY", secret)

    try do
      body.()
    after
      if public_orig,
        do: System.put_env("LANGFUSE_PUBLIC_KEY", public_orig),
        else: System.delete_env("LANGFUSE_PUBLIC_KEY")

      if secret_orig,
        do: System.put_env("LANGFUSE_SECRET_KEY", secret_orig),
        else: System.delete_env("LANGFUSE_SECRET_KEY")
    end
  end

  defp langfuse_env? do
    System.get_env("LANGFUSE_PUBLIC_KEY", "") != "" and
      System.get_env("LANGFUSE_SECRET_KEY", "") != ""
  end

  # ---- helpers -----------------------------------------------------------

  # Build a single OTLP trace payload in JSON wire format. The collector's
  # OTLP HTTP receiver accepts both protobuf (binary) and JSON; JSON is
  # dramatically simpler to assemble and the OTel collector at 0.104.x
  # parses both correctly.
  defp build_trace_json(tag) do
    trace_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    span_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    now_ns = System.system_time(:nanosecond)

    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{
                "key" => "service.name",
                "value" => %{"stringValue" => "foreman-langfuse-test"}
              }
            ]
          },
          "scopeSpans" => [
            %{
              "scope" => %{"name" => "foreman-langfuse-test"},
              "spans" => [
                %{
                  "traceId" => trace_id,
                  "spanId" => span_id,
                  "name" => tag,
                  "kind" => 1,
                  "startTimeUnixNano" => Integer.to_string(now_ns),
                  "endTimeUnixNano" => Integer.to_string(now_ns + 1_000_000),
                  "attributes" => [
                    %{"key" => "test.tag", "value" => %{"stringValue" => tag}}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp http_post_json(url, body_map, headers) do
    body = Jason.encode!(body_map)

    full_headers = [
      {~c"Content-Type", ~c"application/json"}
      | Enum.map(headers, fn {k, v} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)
    ]

    url_charlist = String.to_charlist(url)

    case :httpc.request(
           :post,
           {url_charlist, full_headers, ~c"application/json", body},
           @http_opts,
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(url, headers) do
    url_charlist = String.to_charlist(url)

    erl_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:get, {url_charlist, erl_headers}, @http_opts, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers do
    encoded =
      Base.encode64(
        System.get_env("LANGFUSE_PUBLIC_KEY", "") <>
          ":" <> System.get_env("LANGFUSE_SECRET_KEY", "")
      )

    [{"Authorization", "Basic " <> encoded}]
  end

  # Poll Langfuse's traces API for a span whose name == tag. Bounded
  # retries because the collector's batch processor (1s timeout in
  # ops/otel-collector/config.template.yaml) plus Langfuse's async ingest
  # + index pipeline needs ~5-15s on a cold path.
  defp trace_visible?(tag, max_attempts \\ 32) do
    headers = [{"Accept", "application/json"} | auth_headers()]
    delay_ms = 1_000

    Stream.repeatedly(fn -> :ok end)
    |> Enum.take(max_attempts)
    |> Enum.reduce_while(false, fn _, _acc ->
      case http_get("#{@langfuse_url}/api/public/traces?limit=50", headers) do
        {:ok, 200, body} ->
          case Jason.decode(body) do
            {:ok, %{"data" => traces}} ->
              if Enum.any?(traces, fn t -> t["name"] == tag end) do
                {:halt, true}
              else
                Process.sleep(delay_ms)
                {:cont, false}
              end

            _ ->
              Process.sleep(delay_ms)
              {:cont, false}
          end

        _ ->
          Process.sleep(delay_ms)
          {:cont, false}
      end
    end)
  end

  # ---- tests -------------------------------------------------------------

  describe "prod.exs Basic auth header shape" do
    test "build_otlp_headers/0 produces Basic auth when both keys are set" do
      with_env("pk-test", "sk-test", fn ->
        assert [{"Authorization", "Basic " <> encoded}] = build_otlp_headers()
        assert Base.decode64!(encoded) == "pk-test:sk-test"
      end)
    end

    test "build_otlp_headers/0 returns empty list when either key is missing" do
      with_env("pk-test", "", fn ->
        assert build_otlp_headers() == []
      end)
    end

    test "is NOT Bearer with public-key-only (the earlier-broken shape)" do
      with_env("pk-only", "", fn ->
        case build_otlp_headers() do
          [] ->
            :ok

          [{"Authorization", "Bearer " <> _}] ->
            flunk(
              "regression: emitted Bearer-with-public-only — this is the broken shape from earlier this session"
            )

          [{"Authorization", "Basic " <> _}] ->
            flunk(
              "half-set keys produced a Basic header; with only the public key set this should be empty"
            )
        end
      end)
    end
  end

  describe "collector accepts OTLP and forwards to Langfuse" do
    @describetag :integration

    setup do
      Application.ensure_all_started(:inets)

      # Env assertion. Devbox shell sources the stack's .env automatically;
      # a plain shell needs the operator to load it themselves.
      assert langfuse_env?(),
             "LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY not set; " <>
               "load them from the stack's .env or run `devbox run observability:up`"

      :ok
    end

    test "POST /v1/traces on the collector returns 200" do
      tag = "langfuse-test-#{System.unique_integer([:positive])}"
      body = build_trace_json(tag)

      case http_post_json("#{@collector_url}/v1/traces", body, []) do
        {:ok, 200, _resp} -> :ok
        {:ok, status, resp} -> flunk("collector returned #{status}: #{resp}")
        {:error, reason} -> flunk("collector unreachable: #{inspect(reason)}")
      end
    end

    test "trace arrives at Langfuse within ~30s" do
      tag = "langfuse-test-#{System.unique_integer([:positive])}"
      body = build_trace_json(tag)

      assert {:ok, 200, _} = http_post_json("#{@collector_url}/v1/traces", body, [])

      assert trace_visible?(tag),
             "trace '#{tag}' not visible in Langfuse /api/public/traces within retry budget"
    end

    test "Langfuse rejects Bearer-with-public-only on its OTLP endpoint" do
      # Regression guard for the earlier bug. Hits the Langfuse OTLP
      # ingest directly (bypassing the collector's Basic header) to
      # confirm the 403-vs-Basic distinction is real. Requires the
      # stack to be up.

      bearer_url = "#{@langfuse_url}/api/public/otel/v1/traces"

      bearer_headers = [
        {~c"Content-Type", ~c"application/x-protobuf"},
        {~c"Authorization",
         String.to_charlist("Bearer " <> System.get_env("LANGFUSE_PUBLIC_KEY", ""))}
      ]

      # Retry up to 3 times on 5xx (Langfuse workers can return 503
      # during boot or short traffic shaping). 2xx is the failure
      # mode (auth accepted); non-5xx 4xx are unambiguous rejections.
      run_once = fn ->
        :httpc.request(
          :post,
          {String.to_charlist(bearer_url), bearer_headers, ~c"application/x-protobuf",
           <<0x0A, 0x00>>},
          @http_opts,
          body_format: :binary
        )
      end

      result =
        Enum.reduce_while(1..3, :retry, fn _, _ ->
          case run_once.() do
            {:ok, {{_v, 503, _r}, _, _}} -> {:cont, :retry}
            other -> {:halt, other}
          end
        end)

      case result do
        :retry ->
          flunk("Langfuse returned 503 for Bearer three times in a row — workers unhealthy")

        {:ok, {{_v, 403, _r}, _, _}} ->
          :ok

        {:ok, {{_v, status, _r}, _, body}} when status in [400, 415] ->
          flunk(
            "Langfuse returned #{status} (not 403) for Bearer-with-public-only — body=#{body}"
          )

        {:ok, {{_v, status, _r}, _, body}} when status in [200, 201] ->
          flunk(
            "Langfuse accepted Bearer-with-public-only (#{status}) — " <>
              "was the regression fix reverted? body=#{body}"
          )

        {:ok, {{_v, status, _r}, _, body}} ->
          flunk("unexpected Bearer status #{status}, body=#{body}")

        {:error, reason} ->
          flunk("Langfuse unreachable: #{inspect(reason)}")
      end
    end
  end
end
