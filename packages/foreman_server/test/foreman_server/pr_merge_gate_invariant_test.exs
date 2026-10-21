defmodule ForemanServer.PrMergeGateInvariantTest do
  @moduledoc """
  E9 invariant: nothing the PR-watch epic adds can merge or approve a PR. The merge
  gate (`merge_approve`, `run.pr.merge`) stays a human decision. Main's operator
  allowlists legitimately contain those two types for that gate, so this does not
  look there. It looks at everything reachable *from this epic*:

    * the operator commands the Run aggregate declares for PR watching
      (`PrWatch.operator_types/0`) and every command type it handles;
    * every system command the watcher, auto-fix policy, fix plan and PR creation
      can issue (all command-type and `gh` argument literals in their source);
    * every advertised MCP tool and every command type the MCP tool module names.

  The scanners are plain functions, and each is proven able to fail by feeding it a
  fake.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run.PrWatch
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.MCP.Tools
  alias ForemanServer.PrWatcher.AutoFix

  @lib Path.expand("../../lib/foreman_server", __DIR__)

  # Source of everything that issues commands or runs `gh` on behalf of PR watching.
  @emitter_sources [
    "pr_watcher.ex",
    "pr_watcher/auto_fix.ex",
    "pr_watcher/observer.ex",
    "pr_fix.ex",
    "pr_fix/prompt.ex",
    "pr_create.ex",
    # the `gh pr create` that PrCreate delegates to
    "workflow/auto_pr.ex",
    "pr_monitor.ex",
    "pr_watch_fold.ex",
    "aggregates/run/pr_watch.ex"
  ]

  # -- the predicates ------------------------------------------------------------

  @doc false
  # A command type or `gh` argument that merges or approves a PR.
  def merges_or_approves?(literal) when is_binary(literal) do
    literal in ~w(merge_approve run.pr.merge merge approve --approve --squash --rebase --admin) or
      literal =~ ~r/(^|\.)merge(\.|$)/
  end

  @doc false
  def merge_tool_name?(name) when is_binary(name), do: name =~ ~r/merge|approve/i

  @doc false
  # Every string literal in `source` that is shaped like a command type or CLI
  # argument (lowercase words joined by `.`/`_`, or a `--flag`), outside docs and
  # comments. Reading the AST (not grepping text) keeps prose out and sees
  # literals however they are built into a map or an argv list.
  def command_literals(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{doc, _, _}]}, acc when doc in [:moduledoc, :doc, :typedoc] ->
          {nil, acc}

        literal, acc when is_binary(literal) ->
          {literal,
           if(literal =~ ~r/^(--)?[a-z][a-z_-]*(\.[a-z_]+)*$/, do: [literal | acc], else: acc)}

        other, acc ->
          {other, acc}
      end)

    acc |> Enum.uniq() |> Enum.sort()
  end

  defp offenders(literals), do: Enum.filter(literals, &merges_or_approves?/1)

  defp source_literals(relative_path),
    do: @lib |> Path.join(relative_path) |> File.read!() |> command_literals()

  # -- the scanners can fail -------------------------------------------------------

  describe "the predicates and scanners are not vacuous" do
    test "the merge-gate types and gh merge/approve arguments are recognised" do
      for bad <-
            ~w(merge_approve run.pr.merge merge approve --approve --squash --rebase --admin pr.merge) do
        assert merges_or_approves?(bad), bad
      end

      for fine <-
            ~w(run.pr.fix_ci run.pr.watch_stop run.pr.create run.pr.checks pr view create auto_approve) do
        refute merges_or_approves?(fine), fine
      end
    end

    test "a source that dispatches or shells out a merge is caught, prose about merging is not" do
      dispatching = ~S|defmodule A do def f, do: %{type: "run.pr.merge", payload: %{}} end|

      shelling =
        ~S|defmodule A do def f, do: System.cmd("gh", ["pr", "merge", url, "--squash"]) end|

      approving = ~S|defmodule A do def f, do: %{type: "merge_approve"} end|

      prose = ~S|
        defmodule A do
          @moduledoc "never calls run.pr.merge or merge_approve"
          @doc "merge"
          def f, do: %{type: "run.pr.fix_ci"}
        end
      |

      assert ["run.pr.merge"] = offenders(command_literals(dispatching))
      assert ["--squash", "merge"] = offenders(command_literals(shelling))
      assert ["merge_approve"] = offenders(command_literals(approving))
      assert [] = offenders(command_literals(prose))
    end

    test "a fake merge tool name and a fake operator type are caught" do
      assert merge_tool_name?("foreman_pr_merge")
      assert merge_tool_name?("foreman_run_approve")
      refute merge_tool_name?("foreman_pr_fix")

      assert ["run.pr.merge"] = offenders(["run.pr.merge" | PrWatch.operator_types()])
    end
  end

  # -- the invariant ---------------------------------------------------------------

  test "no PR-watch operator command, and no command the aggregate handles, merges or approves" do
    refute Enum.empty?(PrWatch.operator_types())
    assert offenders(PrWatch.operator_types()) == []
    assert offenders(PrWatch.command_types()) == []
  end

  for path <- @emitter_sources do
    test "#{path} names no merge or approve command and runs no gh merge/approve" do
      assert offenders(source_literals(unquote(path))) == []
    end
  end

  test "the emitter source list is real: each file exists and names PR command types" do
    for path <- @emitter_sources do
      assert File.regular?(Path.join(@lib, path)), path
    end

    assert "run.pr.fix_exhausted" in source_literals("pr_watcher/auto_fix.ex")
    assert "gh" in source_literals("workflow/auto_pr.ex")
    assert "run.pr.watch_stop" in source_literals("pr_watcher/observer.ex")
  end

  test "every command the auto-fix policy can request is a PR-watch fix command, never the gate" do
    settings = %{"kinds" => ["ci", "comments", "conflicts"], "max_attempts" => 2}
    record = %{watching: true, fix: %{in_flight: nil, exhausted: %{}, attempts: %{}}}

    base = %{head_sha: "s", head_branch: "b", base_branch: "main"}

    statuses =
      for extra <- [
            %{status: :conflicted, checks_state: :failing},
            %{status: :open, checks_state: :failing},
            %{status: :open, review_decision: :changes_requested}
          ],
          do: struct!(PrStatus, Map.merge(base, extra))

    requested =
      for status <- statuses,
          {:request, %{type: type}} <- [AutoFix.decide("r", "u", status, record, settings, 1)],
          do: type

    assert Enum.sort(requested) ==
             ["run.pr.address_comments", "run.pr.fix_ci", "run.pr.resolve_conflicts"]

    assert Enum.all?(requested, &(&1 in PrWatch.operator_types()))
    assert offenders(requested) == []
  end

  describe "MCP" do
    test "no advertised tool is named for merging or approving" do
      names = Enum.map(Tools.list_tools(), & &1.name)

      assert length(names) > 10
      assert Enum.filter(names, &merge_tool_name?/1) == []
    end

    test "the MCP tool module names no merge-gate command type" do
      assert offenders(source_literals("mcp/tools.ex")) == []
    end
  end
end
