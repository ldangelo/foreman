defmodule ForemanServerWeb.GithubWebhookControllerTest do
  # `POST /webhooks/github` was unauthenticated: anyone who could reach the port
  # could append PR events to runs. These tests sign real bodies with real HMACs and
  # drive the full endpoint, so they fail if the raw-body cache, the plug, or the
  # route wiring is broken — not just if the comparison function is.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.PrAssociate

  @secret "whsec-test-secret"

  setup do
    previous = Application.get_env(:foreman_server, :github_webhook_secret)
    Application.put_env(:foreman_server, :github_webhook_secret, @secret)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :github_webhook_secret),
        else: Application.put_env(:foreman_server, :github_webhook_secret, previous)
    end)

    run_id = "run-gh-ctl-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-gh-ctl", task_id: "task-gh-ctl"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    {:ok, ^run_id} = PrAssociate.store(run_id, pr_url)

    %{run_id: run_id, pr_url: pr_url}
  end

  defp body(pr_url) do
    Jason.encode!(%{
      "action" => "closed",
      "pull_request" => %{
        "html_url" => pr_url,
        "merged" => true,
        "head" => %{"sha" => "abc123", "ref" => "foreman/task/run"},
        "base" => %{"ref" => "main"}
      }
    })
  end

  defp sign(raw, secret \\ @secret),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

  defp deliver(raw, headers) do
    conn = put_req_header(build_conn(), "content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post("/webhooks/github", raw)
  end

  defp pr_updated(run_id) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == "PrUpdated"))
  end

  test "a correctly signed delivery is accepted and appended to the owning run", ctx do
    raw = body(ctx.pr_url)

    conn = deliver(raw, [{"x-hub-signature-256", sign(raw)}])

    assert json_response(conn, 202) == %{"status" => "ok"}
    assert [_one] = pr_updated(ctx.run_id)
  end

  test "an unsigned delivery is rejected and appends nothing", ctx do
    conn = deliver(body(ctx.pr_url), [])

    assert %{"reason" => "signature_missing"} = json_response(conn, 401)
    assert pr_updated(ctx.run_id) == []
  end

  test "a signature made with the wrong secret is rejected", ctx do
    raw = body(ctx.pr_url)

    conn = deliver(raw, [{"x-hub-signature-256", sign(raw, "attacker-secret")}])

    assert %{"reason" => "signature_mismatch"} = json_response(conn, 401)
    assert pr_updated(ctx.run_id) == []
  end

  test "a valid signature over a DIFFERENT body is rejected (tampering)", ctx do
    signed = body(ctx.pr_url)
    tampered = String.replace(signed, "abc123", "evil999")

    conn = deliver(tampered, [{"x-hub-signature-256", sign(signed)}])

    assert %{"reason" => "signature_mismatch"} = json_response(conn, 401)
    assert pr_updated(ctx.run_id) == []
  end

  test "a malformed signature header is distinguished from a wrong one", ctx do
    raw = body(ctx.pr_url)

    assert %{"reason" => "signature_malformed"} =
             json_response(deliver(raw, [{"x-hub-signature-256", "md5=deadbeef"}]), 401)

    assert %{"reason" => "signature_malformed"} =
             json_response(deliver(raw, [{"x-hub-signature-256", "sha256="}]), 401)
  end

  test "the legacy SHA-1 header is not honoured", ctx do
    raw = body(ctx.pr_url)
    sha1 = "sha1=" <> Base.encode16(:crypto.mac(:hmac, :sha, @secret, raw), case: :lower)

    conn = deliver(raw, [{"x-hub-signature", sha1}])

    assert %{"reason" => "signature_missing"} = json_response(conn, 401)
  end

  test "with no secret configured nothing is accepted, even a plausible signature", ctx do
    Application.delete_env(:foreman_server, :github_webhook_secret)
    raw = body(ctx.pr_url)

    conn = deliver(raw, [{"x-hub-signature-256", sign(raw)}])

    assert %{"reason" => "webhook_secret_not_configured"} = json_response(conn, 503)
    assert pr_updated(ctx.run_id) == []
  end

  test "a signed delivery for a PR no run owns is accepted but ignored", ctx do
    raw = body("https://github.com/acme/repo/pull/8888888")

    conn = deliver(raw, [{"x-hub-signature-256", sign(raw)}])

    assert json_response(conn, 202) == %{"status" => "ignored"}
    assert pr_updated(ctx.run_id) == []
  end

  test "a signed redelivery does not append a second event", ctx do
    raw = body(ctx.pr_url)
    headers = [{"x-hub-signature-256", sign(raw)}]

    assert json_response(deliver(raw, headers), 202)
    assert json_response(deliver(raw, headers), 202)

    assert [_one] = pr_updated(ctx.run_id)
  end
end
