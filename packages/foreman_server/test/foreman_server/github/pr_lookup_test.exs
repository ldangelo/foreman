defmodule ForemanServer.GitHub.PrLookupTest do
  @moduledoc """
  `GitHub.PrLookup` (TRD-004, precondition P-2): the PR GitHub already has for a head and a
  base. `gh` is replaced by the injectable runner; the answers are what `gh pr list --json
  url,number,state,headRefOid,isCrossRepository` printed in the probes (gh 2.103.3): `--head`
  matches a branch NAME whatever repository the PR's head is in, so a fork's PR of the same
  branch name comes back with `isCrossRepository: true`, and `--state closed` returns merged
  PRs too.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.GitHub.PrLookup
  alias ForemanServer.GitHub.PrLookup.Pr

  @head "foreman/run-1/implement"
  @base "main"
  @cwd "/work/checkout"
  @tip "0123456789abcdef0123456789abcdef01234567"
  @other "fedcba9876543210fedcba9876543210fedcba98"
  @url "https://github.com/acme/widgets/pull/7"

  # A runner that answers `reply` and tells the test what it was asked.
  defp runner(reply) do
    parent = self()

    fn executable, args, opts ->
      send(parent, {:ran, executable, args, opts})
      reply
    end
  end

  defp item(attrs \\ %{}) do
    Map.merge(
      %{
        "url" => @url,
        "number" => 7,
        "state" => "OPEN",
        "headRefOid" => @tip,
        "isCrossRepository" => false
      },
      attrs
    )
  end

  defp fork(attrs \\ %{}) do
    item(
      Map.merge(
        %{
          "url" => "https://github.com/acme/widgets/pull/8",
          "number" => 8,
          "isCrossRepository" => true
        },
        attrs
      )
    )
  end

  defp answer(items), do: {Jason.encode!(items), 0}

  defp unusable_item(:no_url), do: Map.delete(item(), "url")
  defp unusable_item(:blank_url), do: item(%{"url" => ""})
  defp unusable_item(:no_number), do: Map.delete(item(), "number")
  defp unusable_item(:text_number), do: item(%{"number" => "7"})
  defp unusable_item(:zero_number), do: item(%{"number" => 0})
  defp unusable_item(:no_state), do: Map.delete(item(), "state")
  defp unusable_item(:unknown_state), do: item(%{"state" => "DRAFT"})
  defp unusable_item(:no_head), do: Map.delete(item(), "headRefOid")
  defp unusable_item(:blank_head), do: item(%{"headRefOid" => "  "})
  defp unusable_item(:numeric_head), do: item(%{"headRefOid" => 12})
  defp unusable_item(:no_cross_flag), do: Map.delete(item(), "isCrossRepository")
  defp unusable_item(:text_cross_flag), do: item(%{"isCrossRepository" => "false"})
  defp unusable_item(:null_cross_flag), do: item(%{"isCrossRepository" => nil})
  defp unusable_item(:not_an_object), do: "https://github.com/acme/widgets/pull/7"

  defp find(state, reply, opts \\ []) do
    PrLookup.find(
      state,
      @head,
      @base,
      [cwd: @cwd, command_runner: runner(reply)] ++ opts
    )
  end

  describe "the question asked" do
    test "gh pr list for the head and the base, in the checkout, with the fields the answer is judged on" do
      assert :none = find(:open, answer([]))

      assert_received {:ran, "gh", args, opts}

      assert args == [
               "pr",
               "list",
               "--state",
               "open",
               "--head",
               @head,
               "--base",
               @base,
               "--json",
               "url,number,state,headRefOid,isCrossRepository",
               "--limit",
               "100"
             ]

      assert opts[:cd] == @cwd
      assert opts[:stderr_to_stdout] == true
    end

    test "the closed state is asked as --state closed" do
      assert :none = find(:closed, answer([]))
      assert_received {:ran, "gh", args, _opts}
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--state", "closed"])
    end

    test "find_open/3 is find/4 for the open state" do
      reply = answer([item()])

      assert PrLookup.find_open(@head, @base,
               cwd: @cwd,
               command_runner: runner(reply),
               expected_head: @tip
             ) ==
               find(:open, reply, expected_head: @tip)

      assert_received {:ran, "gh", args, _opts}
      assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--state", "open"])
    end

    test "the wait for gh is bounded only when the caller asks for it" do
      slow = fn _executable, _args, _opts ->
        Process.sleep(2_000)
        answer([])
      end

      assert {:error, {:timeout, 20}} =
               PrLookup.find(:open, @head, @base, cwd: @cwd, command_runner: slow, timeout_ms: 20)
    end
  end

  describe "an open PR of this repository" do
    test "is the answer when its head is the expected one" do
      assert {:ok, %Pr{url: @url, number: 7, state: :open, head_sha: @tip}} =
               find(:open, answer([item()]), expected_head: @tip)
    end

    test "heads are compared as commit SHAs: case and surrounding whitespace do not matter" do
      reply = answer([item(%{"headRefOid" => " " <> String.upcase(@tip) <> "\n"})])

      assert {:ok, %Pr{head_sha: @tip}} = find(:open, reply, expected_head: String.upcase(@tip))
    end

    test "the PR with the expected head is found behind one with another head" do
      reply =
        answer([
          item(%{
            "url" => "https://github.com/acme/widgets/pull/6",
            "number" => 6,
            "headRefOid" => @other
          }),
          item()
        ])

      assert {:ok, %Pr{number: 7}} = find(:open, reply, expected_head: @tip)
    end

    test "another head is a mismatch that names the PR and both heads, and the PR is not returned" do
      assert {:error, {:pr_lookup_mismatch, @url, @tip, @other}} =
               find(:open, answer([item(%{"headRefOid" => @other})]), expected_head: @tip)
    end

    test "without an expected head the first PR is the answer, whatever its head" do
      reply =
        answer([
          item(%{"headRefOid" => @other}),
          item(%{"url" => "https://github.com/acme/widgets/pull/9", "number" => 9})
        ])

      assert {:ok, %Pr{number: 7, head_sha: @other}} = find(:open, reply)
    end

    test "no PR is none" do
      assert :none = find(:open, answer([]), expected_head: @tip)
      assert :none = find(:open, answer([]))
    end
  end

  describe "a fork's PR of the same branch name" do
    test "is not the answer, though its head is the expected one" do
      assert :none = find(:open, answer([fork(%{"headRefOid" => @tip})]), expected_head: @tip)
      assert :none = find(:open, answer([fork()]))
    end

    test "is not a mismatch when its head is another one: it is dropped before heads are compared" do
      assert :none = find(:open, answer([fork(%{"headRefOid" => @other})]), expected_head: @tip)
    end

    test "does not hide this repository's PR, whichever comes first" do
      for items <- [[fork(), item()], [item(), fork()]] do
        assert {:ok, %Pr{url: @url}} = find(:open, answer(items), expected_head: @tip)
        assert {:ok, %Pr{url: @url}} = find(:open, answer(items))
      end
    end
  end

  describe "the closed state" do
    test "returns a closed or a merged PR of this repository (a merged PR comes back under --state closed)" do
      assert {:ok, %Pr{state: :closed, url: @url}} =
               find(:closed, answer([item(%{"state" => "CLOSED"})]))

      assert {:ok, %Pr{state: :merged, url: @url}} =
               find(:closed, answer([item(%{"state" => "MERGED"})]))
    end

    test "drops a fork's closed or merged PR" do
      assert :none = find(:closed, answer([fork(%{"state" => "MERGED"})]))
      assert :none = find(:closed, answer([fork(%{"state" => "CLOSED"})]))
    end

    test "compares heads like the open state when it is given one" do
      reply = answer([item(%{"state" => "MERGED", "headRefOid" => @other})])

      assert {:error, {:pr_lookup_mismatch, @url, @tip, @other}} =
               find(:closed, reply, expected_head: @tip)
    end
  end

  describe "an answer that cannot be used" do
    test "a non-zero exit is gh_failed with gh's trimmed output" do
      assert {:error, {:gh_failed, 4, "gh: To get started with GitHub CLI, run: gh auth login"}} =
               find(:open, {"gh: To get started with GitHub CLI, run: gh auth login\n", 4})
    end

    test "text that is not JSON is unparsable and carries the start of the text" do
      assert {:error, {:unparsable_pr_list, "not json at all"}} =
               find(:open, {"not json at all\n", 0})

      assert {:error, {:unparsable_pr_list, ""}} = find(:open, {"", 0})

      {:error, {:unparsable_pr_list, text}} = find(:open, {String.duplicate("x", 500), 0})
      assert String.length(text) == 200
    end

    test "JSON that is not a list is an unexpected payload carrying it" do
      assert {:error, {:unexpected_pr_list_payload, %{"message" => "Not Found"}}} =
               find(:open, {~s({"message": "Not Found"}), 0})

      assert {:error, {:unexpected_pr_list_payload, nil}} = find(:open, {"null", 0})
    end

    @unusable_items [
      no_url: "without a url",
      blank_url: "with a blank url",
      no_number: "without a number",
      text_number: "with a number that is not an integer",
      zero_number: "with number 0",
      no_state: "without a state",
      unknown_state: "with a state it does not know",
      no_head: "without a headRefOid",
      blank_head: "with a blank headRefOid",
      numeric_head: "with a headRefOid that is not text",
      no_cross_flag: "without isCrossRepository",
      text_cross_flag: "with isCrossRepository that is not a boolean",
      null_cross_flag: "with isCrossRepository null",
      not_an_object: "that is not an object"
    ]

    for {kind, description} <- @unusable_items do
      test "an item #{description} makes the whole answer an unexpected payload" do
        bad = unusable_item(unquote(kind))

        assert {:error, {:unexpected_pr_list_payload, [^bad]}} =
                 find(:open, answer([bad]), expected_head: @tip)
      end
    end

    test "one unusable item rejects the answer even behind a usable PR: nothing is skipped" do
      bad = %{"url" => "https://github.com/acme/widgets/pull/9"}

      assert {:error, {:unexpected_pr_list_payload, [_usable, ^bad]}} =
               find(:open, answer([item(), bad]), expected_head: @tip)
    end

    test "a gh that cannot be run is the runner's own error, never an answer" do
      missing = fn _executable, _args, _opts -> raise ErlangError, original: :enoent end

      assert {:error, {:command_not_run, "gh", :enoent}} =
               PrLookup.find(:open, @head, @base, cwd: @cwd, command_runner: missing)

      other = fn _executable, _args, _opts -> :ok end

      assert {:error, {:unexpected_runner_result, :ok}} =
               PrLookup.find(:open, @head, @base, cwd: @cwd, command_runner: other)
    end
  end

  describe "the arguments" do
    test "only the open and the closed state can be asked" do
      for state <- [:merged, :all, "open", nil] do
        assert_raise FunctionClauseError, fn ->
          PrLookup.find(state, @head, @base, cwd: @cwd, command_runner: runner(answer([])))
        end
      end
    end

    test "a blank head or base cannot be asked" do
      for {head, base} <- [{"", @base}, {@head, ""}, {nil, @base}, {@head, nil}] do
        assert_raise FunctionClauseError, fn ->
          PrLookup.find(:open, head, base, cwd: @cwd, command_runner: runner(answer([])))
        end
      end
    end

    test "the checkout is required and must be a path: a missing, blank or nil cwd raises" do
      for opts <- [[], [cwd: ""], [cwd: nil]] do
        assert_raise ArgumentError, ~r/opts\[:cwd\]/, fn ->
          PrLookup.find(:open, @head, @base, [command_runner: runner(answer([]))] ++ opts)
        end
      end

      refute_received {:ran, _, _, _}
    end

    test "an expected head that is blank, nil or not text raises: an absent one is omitted" do
      for expected <- ["", "  ", nil, 12, :sha] do
        assert_raise ArgumentError, ~r/expected_head/, fn ->
          find(:open, answer([]), expected_head: expected)
        end
      end

      refute_received {:ran, _, _, _}
    end
  end
end
