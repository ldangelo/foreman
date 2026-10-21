defmodule ForemanServer.Webhooks.GithubSignalsTest do
  @moduledoc """
  The optional webhook accelerator (spike S4): `check_run`, `check_suite`,
  review, review-comment, thread and PR-comment deliveries ask the PrWatcher to
  re-read the PR they name. Payload shapes follow GitHub's documented webhook
  schema; live deliveries are UNVERIFIED (docs/spikes/S4.md section 9).
  """
  use ExUnit.Case, async: false

  alias ForemanServer.PrAssociate
  alias ForemanServer.PrWatcher
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Webhooks.Github

  setup do
    run = Support.start_run!(complete: true)
    {:ok, _} = PrAssociate.store(run.run_id, run.pr_url)
    test_pid = self()

    fetch = fn url ->
      send(test_pid, {:fetched, url})
      {:ok, Support.status()}
    end

    start_supervised!({PrWatcher, fetch_fun: fetch})
    {:ok, Map.put(run, :repo_url, String.replace_suffix(run.pr_url, "/pull/1", ""))}
  end

  defp html(url), do: %{"html_url" => url}

  describe "each signal refreshes the owning PR" do
    test "check_run completed names its PR through repository.html_url + number", ctx do
      payload = %{
        "action" => "completed",
        "check_run" => %{
          "pull_requests" => [%{"number" => 1, "url" => "https://api.github.com/x"}]
        },
        "repository" => html(ctx.repo_url)
      }

      assert :ok = Github.process(payload)
      assert_receive {:fetched, url}, 5_000
      assert url == ctx.pr_url
    end

    test "check_suite completed", ctx do
      payload = %{
        "action" => "completed",
        "check_suite" => %{"pull_requests" => [%{"number" => 1}]},
        "repository" => html(ctx.repo_url)
      }

      assert :ok = Github.process(payload)
      assert_receive {:fetched, _}, 5_000
    end

    test "pull_request_review submitted (it also carries action and pull_request)", ctx do
      payload = %{
        "action" => "submitted",
        "review" => %{"state" => "changes_requested"},
        "pull_request" => html(ctx.pr_url)
      }

      assert :ok = Github.process(payload)
      assert_receive {:fetched, _}, 5_000
    end

    test "pull_request_review_comment created", ctx do
      payload = %{
        "action" => "created",
        "comment" => %{"body" => "nit"},
        "pull_request" => html(ctx.pr_url)
      }

      assert :ok = Github.process(payload)
      assert_receive {:fetched, _}, 5_000
    end

    test "pull_request_review_thread resolved", ctx do
      assert :ok =
               Github.process(%{
                 "action" => "resolved",
                 "thread" => %{},
                 "pull_request" => html(ctx.pr_url)
               })

      assert_receive {:fetched, _}, 5_000
    end

    test "issue_comment created on a PR", ctx do
      issue = %{"html_url" => ctx.pr_url, "pull_request" => %{"url" => "x"}}

      assert :ok =
               Github.process(%{
                 "action" => "created",
                 "issue" => issue,
                 "comment" => %{"body" => "hi"}
               })

      assert_receive {:fetched, _}, 5_000
    end

    test "a push to the PR branch (synchronize) refreshes", ctx do
      assert :ok =
               Github.process(%{"action" => "synchronize", "pull_request" => html(ctx.pr_url)})

      assert_receive {:fetched, _}, 5_000
    end
  end

  describe "everything else is ignored, unchanged behaviour included" do
    test "a PR no run owns is ignored and nothing is fetched", ctx do
      other = ctx.repo_url <> "/pull/99"
      payload = %{"action" => "submitted", "review" => %{}, "pull_request" => html(other)}

      assert :ignored = Github.process(payload)
      refute_receive {:fetched, _}, 100
    end

    test "a fork check_run has an empty pull_requests list: ignored", ctx do
      payload = %{
        "action" => "completed",
        "check_run" => %{"pull_requests" => []},
        "repository" => html(ctx.repo_url)
      }

      assert :ignored = Github.process(payload)
    end

    test "an issue_comment on a plain issue (no pull_request key) is ignored" do
      payload = %{
        "action" => "created",
        "issue" => %{"html_url" => "https://github.com/a/b/issues/1"},
        "comment" => %{}
      }

      assert :ignored = Github.process(payload)
    end

    test "an unhandled review action is swallowed, not read as a PR state change", ctx do
      # `pull_request` + `review` + an action no clause lists must not reach the
      # state-change clause (GitHub sends the same keys there).
      payload = %{
        "action" => "closed",
        "review" => %{},
        "pull_request" => Map.put(html(ctx.pr_url), "merged", true)
      }

      assert :ignored = Github.process(payload)
      assert {:ok, []} = Github.build_refresh_targets(payload)
    end

    test "a plain pull_request closed/merged still produces the run.pr.update command", ctx do
      payload = %{
        "action" => "closed",
        "pull_request" => %{
          "html_url" => ctx.pr_url,
          "merged" => true,
          "head" => %{"sha" => "h", "ref" => "b"},
          "base" => %{"ref" => "main"}
        }
      }

      assert :none = Github.build_refresh_targets(payload)

      assert {:ok, [%{type: "run.pr.update", payload: %{pr_status: :merged}}]} =
               Github.build_commands(payload)
    end

    test "without a running watcher a signal is ignored, not an error", ctx do
      stop_supervised!(PrWatcher)
      payload = %{"action" => "submitted", "review" => %{}, "pull_request" => html(ctx.pr_url)}
      assert :ignored = Github.process(payload)
    end
  end
end
