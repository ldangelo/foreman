defmodule ForemanServer.Workflow.BeadsTreeCompletionTest do
  @moduledoc """
  TRD-004-TEST, unit level (TRD-2026-72f477ca; PRD-2026-72f477ca AC-008-1,
  AC-008-2, AC-005-2, AC-010-2): `Workflow.BeadsTreeCompletion` judges a Beads
  tree on the bead graph alone.

  The graph is `test/fixtures/br/show_tree_*.json`: verbatim `br show` output of
  a real epic -> 2 stories -> 3 tasks tree (see that directory's README), once
  with one task closed, one `in_progress`, one `open`, and once with every
  descendant closed and the root epic still open. Ids are derived from the
  fixtures, never hard-coded. The runner is `BrRunnerMock`, so every `br` call
  the module makes is observed. Where a test needs a graph the real `br` was not
  asked for (a bigger tree, a diamond, a cycle) the fixture is transformed in the
  test and says so; output real `br` cannot produce (not JSON, wrong shape) is
  hand-written.

  The run-level propagation (the run ends `RunFailed`, the task fails, the
  unfinished children reach the artifact) is in `run_executor_command_test.exs`
  ("an implement-trd-beads epic tree decides the run's outcome").
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.AgentRuntime.JidoHarness.FailureCause
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TestSupport.BrFixtures
  alias ForemanServer.Workflow.BeadsTreeCompletion

  setup :verify_on_exit!

  @database_path "/tmp/beads-tree-completion-test/.beads/beads.db"

  # The fixture tree: its root, the ids of each level, the bead that is blocked by
  # a task but is not a descendant, and every descendant's status in `state`
  # (`"incomplete"` | `"complete"`) with its title.
  defp tree(state) do
    [epic] = BrFixtures.decode!("show_tree_#{state}_epic.json")
    stories = BrFixtures.decode!("show_tree_#{state}_stories.json")
    tasks = BrFixtures.decode!("show_tree_#{state}_tasks.json")

    descendants =
      for issue <- stories ++ tasks,
          into: %{},
          do: {issue["id"], %{status: issue["status"], title: issue["title"]}}

    task_ids = Enum.map(tasks, & &1["id"])

    [outside] =
      for issue <- tasks,
          %{"dependency_type" => "blocks", "id" => id} <- Map.get(issue, "dependents", []),
          id not in task_ids,
          do: id

    %{
      root: epic["id"],
      epic: epic,
      stories: Enum.sort(Enum.map(stories, & &1["id"])),
      tasks: Enum.sort(task_ids),
      story_issues: stories,
      task_issues: tasks,
      outside: outside,
      descendants: descendants
    }
  end

  defp not_closed(%{descendants: descendants}),
    do:
      for({id, %{status: status}} <- descendants, status != "closed", into: %{}, do: {id, status})

  # Answers every `br show` with `levels` (sorted ids asked for => decoded answer)
  # and reports each call to the test process. A level the tree does not have fails
  # the test: the module asked for something that is not there.
  defp stub_levels!(levels) do
    test_pid = self()

    stub(BrRunnerMock, :cmd, fn {:show, %{flags: flags}}, project_config, opts ->
      send(test_pid, {:br_show, flags, project_config, opts})

      case Map.fetch(levels, Enum.sort(flags)) do
        {:ok, answer} -> {:ok, %{stdout: Jason.encode!(answer), stderr: "", exit_code: 0}}
        :error -> flunk("br show of #{inspect(flags)} is not a level of the tree")
      end
    end)
  end

  defp levels(%{} = tree),
    do: %{
      [tree.root] => [tree.epic],
      tree.stories => tree.story_issues,
      tree.tasks => tree.task_issues
    }

  defp stub_tree!(tree), do: stub_levels!(levels(tree))

  defp context(root), do: %{"bead_id" => root, "beads_database_path" => @database_path}

  defp tmp_artifact(content) do
    path =
      Path.join(System.tmp_dir!(), "beads-tree-artifact-#{System.unique_integer([:positive])}.md")

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "AC-008-1: an unfinished tree fails the run, naming the unfinished children" do
    test "incomplete_descendants/2 returns exactly the descendants that are not closed" do
      tree = tree("incomplete")
      stub_tree!(tree)

      assert {:ok, incomplete} =
               BeadsTreeCompletion.incomplete_descendants(@database_path, tree.root)

      expected = not_closed(tree)

      # A vacuous fixture would pass anything: two stories, an open task and an
      # in_progress task are unfinished, one task is closed.
      assert map_size(expected) == 4
      assert Enum.sort(Map.values(expected)) == ["in_progress", "open", "open", "open"]

      assert Map.new(incomplete, &{&1.id, &1.status}) == expected
      assert Enum.all?(incomplete, &(&1.title == tree.descendants[&1.id].title))

      # The root itself and the bead outside the tree are not named.
      ids = Enum.map(incomplete, & &1.id)
      refute tree.root in ids
      refute tree.outside in ids
    end

    test "verify/2 fails with a typed cause that names each unfinished child and its status" do
      tree = tree("incomplete")
      stub_tree!(tree)

      assert {:error, %FailureCause{code: :incomplete_children, detail: detail}} =
               BeadsTreeCompletion.verify(context(tree.root), nil)

      assert detail =~ "4 descendant bead(s) of #{tree.root} are not closed"

      for {id, status} <- not_closed(tree), do: assert(detail =~ "#{id} (#{status})")

      closed = for {id, %{status: "closed"}} <- tree.descendants, do: id
      assert [_ | _] = closed
      for id <- closed, do: refute(detail =~ id)
      refute detail =~ tree.outside
    end

    test "the unfinished children, with titles, are appended to the phase artifact after the agent's report" do
      tree = tree("incomplete")
      stub_tree!(tree)
      artifact = tmp_artifact("agent report\n")

      assert {:error, %FailureCause{code: :incomplete_children}} =
               BeadsTreeCompletion.verify(context(tree.root), artifact)

      report = File.read!(artifact)
      assert String.starts_with?(report, "agent report\n")
      assert report =~ "## Incomplete children of #{tree.root}"

      for {id, status} <- not_closed(tree) do
        assert report =~ "- `#{id}` (#{status}): #{tree.descendants[id].title}"
      end

      for {id, %{status: "closed", title: title}} <- tree.descendants do
        refute report =~ id
        refute report =~ title
      end
    end

    test "a long list is cut in the one-line reason and complete in the artifact" do
      tree = tree("incomplete")

      # Derived from the real fixtures: twelve more unfinished tasks under story one.
      bulk =
        for n <- 1..12,
            do: %{"id" => "bulk-#{n}", "title" => "Bulk #{n}", "status" => "open"}

      [story_one, story_two] = tree.story_issues

      story_one =
        Map.update!(story_one, "dependents", fn dependents ->
          dependents ++ Enum.map(bulk, &Map.put(&1, "dependency_type", "parent-child"))
        end)

      stub_levels!(%{
        [tree.root] => [tree.epic],
        tree.stories => [story_one, story_two],
        Enum.sort(tree.tasks ++ Enum.map(bulk, & &1["id"])) =>
          tree.task_issues ++ Enum.map(bulk, &Map.put(&1, "dependents", []))
      })

      artifact = tmp_artifact("")

      assert {:error, %FailureCause{code: :incomplete_children, detail: detail}} =
               BeadsTreeCompletion.verify(context(tree.root), artifact)

      assert detail =~ "16 descendant bead(s) of #{tree.root} are not closed"
      assert detail =~ "and 8 more (all of them are listed in the phase artifact)"

      report = File.read!(artifact)
      for n <- 1..12, do: assert(report =~ "`bulk-#{n}`")
    end
  end

  describe "AC-008-2: completion is judged by child-bead state, not the epic's status field" do
    test "every descendant closed while the root epic is still open completes" do
      tree = tree("complete")
      stub_tree!(tree)

      # The scenario the AC names: the root epic itself was never closed.
      assert tree.epic["status"] == "open"
      assert not_closed(tree) == %{}

      assert :ok = BeadsTreeCompletion.verify(context(tree.root), nil)
    end

    test "the root's own status is never consulted: a closed root over open children still fails" do
      tree = tree("incomplete")
      stub_tree!(%{tree | epic: Map.put(tree.epic, "status", "closed")})

      assert {:error, %FailureCause{code: :incomplete_children}} =
               BeadsTreeCompletion.verify(context(tree.root), nil)
    end

    test "a `blocks` edge out of the tree does not make the outside bead part of it" do
      tree = tree("complete")
      stub_tree!(tree)

      # The bead blocked by one of the tasks is `open` and is listed among that
      # task's dependents, yet it is not a descendant: the tree is complete.
      assert Enum.any?(tree.task_issues, fn issue ->
               Enum.any?(
                 issue["dependents"],
                 &(&1["id"] == tree.outside and &1["status"] == "open" and
                     &1["dependency_type"] == "blocks")
               )
             end)

      assert {:ok, []} = BeadsTreeCompletion.incomplete_descendants(@database_path, tree.root)
    end

    test "a bead reachable through two parents, or a cycle back to the root, is visited once" do
      tree = tree("incomplete")
      [story_one, story_two] = tree.story_issues
      [shared | _] = for %{"id" => id} <- story_two["dependents"], do: id

      # Derived from the real fixtures: story one ALSO lists story two's task as a
      # child, and that task lists the root epic as one of ITS children.
      shared_entry = Enum.find(story_two["dependents"], &(&1["id"] == shared))
      story_one = Map.update!(story_one, "dependents", &(&1 ++ [shared_entry]))

      loop = %{
        "id" => tree.root,
        "title" => "the root",
        "status" => "open",
        "dependency_type" => "parent-child"
      }

      task_issues =
        Enum.map(tree.task_issues, fn
          %{"id" => ^shared} = issue -> Map.put(issue, "dependents", [loop])
          issue -> issue
        end)

      stub_levels!(%{
        [tree.root] => [tree.epic],
        tree.stories => [story_one, story_two],
        tree.tasks => task_issues
      })

      assert {:ok, incomplete} =
               BeadsTreeCompletion.incomplete_descendants(@database_path, tree.root)

      ids = Enum.map(incomplete, & &1.id)

      assert ids == Enum.uniq(ids)
      refute tree.root in ids
      assert Enum.sort(ids) == Enum.sort(Map.keys(not_closed(tree)))
    end
  end

  describe "AC-005-2 / AC-010-2: the graph is read as it is NOW, whoever changed it" do
    test "nothing is remembered between verifications: beads a human closed in between count" do
      incomplete = tree("incomplete")
      complete = tree("complete")

      # One tree captured in two states: same ids.
      assert incomplete.root == complete.root

      test_pid = self()

      stub(BrRunnerMock, :cmd, fn {:show, %{flags: flags}}, _config, _opts ->
        send(test_pid, {:br_show, flags})
        graph = Process.get(:graph_state, incomplete)

        {:ok,
         %{
           stdout: Jason.encode!(Map.fetch!(levels(graph), Enum.sort(flags))),
           stderr: "",
           exit_code: 0
         }}
      end)

      # First attempt: the tree is unfinished.
      assert {:error, %FailureCause{code: :incomplete_children}} =
               BeadsTreeCompletion.verify(context(incomplete.root), nil)

      # Between attempts a human closes everything that was left (`br update
      # <id> --status closed`, outside the run). Beads close like any other: the
      # module has no notion of who closed one.
      Process.put(:graph_state, complete)

      assert :ok = BeadsTreeCompletion.verify(context(incomplete.root), nil)

      # Both attempts walked the whole tree: a root read, a stories read, a tasks read.
      for _attempt <- 1..2, _level <- 1..3, do: assert_received({:br_show, _flags})
      refute_received {:br_show, _flags}
    end
  end

  describe "a tree that cannot be read is not a finished tree" do
    test "br failing (here: an id it does not know) fails the run with the br error named" do
      expect(BrRunnerMock, :cmd, fn {:show, %{flags: ["tst-1"]}}, _config, _opts ->
        {:error,
         %{stdout: BrFixtures.read!("show_tree_missing_id.json"), stderr: "", exit_code: 3}}
      end)

      assert {:error, %FailureCause{code: :beads_tree_unreadable, detail: detail}} =
               BeadsTreeCompletion.verify(context("tst-1"), nil)

      assert detail =~ "BEADS_TREE_UNREADABLE"
      assert detail =~ "ISSUE_NOT_FOUND: Issue not found: nope-0"
    end

    test "br timing out or dying without output fails the run" do
      expect(BrRunnerMock, :cmd, fn _request, _config, _opts ->
        {:error, %{stdout: "", stderr: "", exit_code: nil, reason: :timeout}}
      end)

      assert {:error, %FailureCause{code: :beads_tree_unreadable, detail: detail}} =
               BeadsTreeCompletion.verify(context("tst-1"), nil)

      assert detail =~ ":timeout"
    end

    test "output that is not JSON, not a list, or short of an asked-for bead fails the run" do
      # Hand-written: real br cannot be made to emit these.
      for {stdout, expected} <- [
            {"this is not json", "not JSON"},
            {~s({"id": "tst-1"}), "br show returned"},
            {"[]", "did not return tst-1"}
          ] do
        expect(BrRunnerMock, :cmd, fn _request, _config, _opts ->
          {:ok, %{stdout: stdout, stderr: "", exit_code: 0}}
        end)

        assert {:error, %FailureCause{code: :beads_tree_unreadable, detail: detail}} =
                 BeadsTreeCompletion.verify(context("tst-1"), nil)

        assert detail =~ expected
      end
    end

    test "a runner answer of an unknown shape fails the run, never passes it" do
      expect(BrRunnerMock, :cmd, fn _request, _config, _opts -> :surprise end)

      assert {:error, %FailureCause{code: :beads_tree_unreadable, detail: detail}} =
               BeadsTreeCompletion.verify(context("tst-1"), nil)

      assert detail =~ "unexpected shape: :surprise"
    end

    test "a parent-child dependent without id/title/status fails the run" do
      expect(BrRunnerMock, :cmd, fn _request, _config, _opts ->
        stdout =
          Jason.encode!([
            %{
              "id" => "tst-1",
              "dependents" => [%{"id" => "tst-2", "dependency_type" => "parent-child"}]
            }
          ])

        {:ok, %{stdout: stdout, stderr: "", exit_code: 0}}
      end)

      assert {:error, %FailureCause{code: :beads_tree_unreadable, detail: detail}} =
               BeadsTreeCompletion.verify(context("tst-1"), nil)

      assert detail =~ "lacks id/title/status"
    end
  end

  describe "what is asked of br, and of whom" do
    test "one `br show` per tree level, against the frozen database, with a bounded timeout" do
      tree = tree("complete")
      stub_tree!(tree)

      assert :ok = BeadsTreeCompletion.verify(context(tree.root), nil)

      assert_received {:br_show, [root], %{database_path: @database_path}, [timeout_ms: 30_000]}
      assert root == tree.root
      assert_received {:br_show, stories, %{database_path: @database_path}, _opts}
      assert Enum.sort(stories) == tree.stories
      assert_received {:br_show, tasks, %{database_path: @database_path}, _opts}
      assert Enum.sort(tasks) == tree.tasks
      refute_received {:br_show, _flags, _config, _opts}
    end

    test "a run that is not a Beads-tree run (no frozen bead_id) is not checked and br is not called" do
      # No expectation is set: any br call raises Mox.UnexpectedCallError.
      assert :ok = BeadsTreeCompletion.verify(%{"trd_path" => "docs/TRD/x.md"}, nil)
      assert :ok = BeadsTreeCompletion.verify(%{}, "/tmp/artifact.md")
    end

    test "a frozen bead_id without a database path, or a blank bead_id, is unverifiable, not passed" do
      assert {:error, %FailureCause{code: :beads_tree_unverifiable, detail: detail}} =
               BeadsTreeCompletion.verify(%{"bead_id" => "tst-1"}, nil)

      assert detail =~ "beads_database_path"

      assert {:error, %FailureCause{code: :beads_tree_unverifiable, detail: detail}} =
               BeadsTreeCompletion.verify(
                 %{"bead_id" => "", "beads_database_path" => @database_path},
                 nil
               )

      assert detail =~ "bead_id"
    end
  end
end
