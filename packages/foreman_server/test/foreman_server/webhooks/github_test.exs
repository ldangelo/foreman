defmodule ForemanServer.Webhooks.GithubTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Webhooks.Github

  describe "process/1 — pull_request events" do
    test "closed action with merged:true routes a run.pr.update with :merged status" do
      payload = %{
        "action" => "closed",
        "run_id" => "r-merged-1",
        "pull_request" => %{
          "merged" => true,
          "html_url" => "https://github.com/org/repo/pull/42",
          "head" => %{"sha" => "abc123", "ref" => "feature/x"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, command} = Github.build_command(payload)
      assert command.type == "run.pr.update"
      assert command.aggregate_id == "run:r-merged-1"
      assert command.payload.run_id == "r-merged-1"
      assert command.payload.pr_url == "https://github.com/org/repo/pull/42"
      assert command.payload.pr_status == :merged
      assert command.payload.head_sha == "abc123"
      assert command.payload.base_branch == "main"
      assert command.payload.phase == "merge_pending"
    end

    test "closed action with merged:false routes a run.pr.update with :closed status" do
      payload = %{
        "action" => "closed",
        "run_id" => "r-closed-1",
        "pull_request" => %{
          "merged" => false,
          "html_url" => "https://github.com/org/repo/pull/43",
          "head" => %{"sha" => "def456", "ref" => "feature/y"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, command} = Github.build_command(payload)
      assert command.payload.pr_status == :closed
      assert command.payload.phase == "pr_closed"
    end

    test "reopened action routes a run.pr.update with :open status" do
      payload = %{
        "action" => "reopened",
        "run_id" => "r-reopen-1",
        "pull_request" => %{
          "html_url" => "https://github.com/org/repo/pull/44",
          "head" => %{"sha" => "ghi789", "ref" => "feature/z"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, command} = Github.build_command(payload)
      assert command.payload.pr_status == :open
      assert command.payload.phase == "pr_open"
    end

    test "mergeable_state dirty routes a run.pr.update with :conflicted status" do
      payload = %{
        "action" => "synchronize",
        "run_id" => "r-conflict-1",
        "pull_request" => %{
          "html_url" => "https://github.com/org/repo/pull/45",
          "mergeable_state" => "dirty",
          "head" => %{"sha" => "h0h0h0", "ref" => "feature/a"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, command} = Github.build_command(payload)
      assert command.payload.pr_status == :conflicted
      assert command.payload.phase == "pr_conflict"
    end
  end

  describe "process/1 — ignore paths" do
    test "non-map payload returns :ignored" do
      assert Github.process("not-a-map") == :ignored
      assert Github.process(nil) == :ignored
    end

    test "unsupported pull_request action returns :ignore from build_command" do
      payload = %{
        "action" => "assigned",
        "pull_request" => %{
          "html_url" => "https://github.com/org/repo/pull/46",
          "head" => %{"sha" => "f1f1f1"},
          "base" => %{"ref" => "main"}
        }
      }

      assert Github.build_command(payload) == :ignore
    end

    test "payload missing run_id and pr_url returns :missing" do
      payload = %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => true,
          "head" => %{"sha" => "xx"},
          "base" => %{"ref" => "main"}
        }
      }

      assert Github.build_command(payload) == :ignored
    end
  end
end
