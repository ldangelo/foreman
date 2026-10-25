defmodule ForemanServer.Coordinator.SetupProposalTest do
  # Pure: the formatter reads recommendations and nothing else.
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.SetupProposal
  alias ForemanServer.Projects.Recommendations.Recommendation

  defp rec(id, severity, opts \\ []) do
    %Recommendation{
      id: id,
      severity: severity,
      title: Keyword.get(opts, :title, "Title of #{id}"),
      detail: Keyword.get(opts, :detail, "Detail of #{id}."),
      fix: Keyword.get(opts, :fix)
    }
  end

  defp command_fix, do: %{kind: :command, type: "project.update", payload: %{project_id: "p"}}
  defp manual_fix, do: %{kind: :manual, text: "Do it by hand."}

  defp many(count, opts \\ []),
    do: for(n <- 1..count, do: rec("item.#{String.pad_leading("#{n}", 2, "0")}", :warn, opts))

  defp listed(text), do: Regex.scan(~r/^\d+\. \[/m, text) |> length()

  test "no recommendations is one line" do
    assert SetupProposal.format("p", []) == "Project looks ready: no setup recommendations."
  end

  test "items are numbered with stable ids, ordered action > warn > info, stable within a severity" do
    text =
      SetupProposal.format("p", [
        rec("b.info", :info),
        rec("z.warn", :warn),
        rec("a.warn", :warn),
        rec("c.action", :action)
      ])

    positions =
      for id <- ~w(c.action z.warn a.warn b.info),
          do: {id, :binary.match(text, id) |> elem(0)}

    assert positions == Enum.sort_by(positions, &elem(&1, 1))
    assert text =~ "1. [action] c.action - Title of c.action: Detail of c.action."
    assert text =~ "2. [warn] z.warn - "
    assert text =~ "4. [info] b.info - "
  end

  test "only an item with a Foreman command offers apply, at its own number" do
    text =
      SetupProposal.format("p", [
        rec("fix.me", :action, fix: command_fix()),
        rec("advice.only", :warn, fix: manual_fix()),
        rec("no.fix", :info)
      ])

    assert text =~ "1. [action] fix.me"
    assert text =~ "   Reply \"apply 1\" to have Foreman run this fix (project.update)."
    assert length(Regex.scan(~r/Reply "apply \d+"/, text)) == 1
    assert text =~ "Reply \"apply N\" to apply an item that offers a fix"
    assert text =~ "send /setup for a fresh list"
    assert text =~ "foreman project recommend p"
  end

  test "the same recommendations give the same bytes" do
    recs = [rec("a", :action, fix: command_fix()), rec("b", :info)]
    assert SetupProposal.format("p", recs) == SetupProposal.format("p", recs)
  end

  test "more than ten items list ten and count the rest in a visible marker" do
    text = SetupProposal.format("my-project", many(15))

    assert listed(text) == 10
    assert text =~ "[+5 more: foreman project recommend my-project]"
    assert text =~ "item.10"
    refute text =~ "item.11"
    assert byte_size(text) <= SetupProposal.max_bytes()
  end

  test "exactly ten items need no marker" do
    text = SetupProposal.format("p", many(10, detail: "short"))
    assert listed(text) == 10
    refute text =~ "more:"
  end

  test "the byte cap holds: items that do not fit are dropped from the end and counted" do
    text = SetupProposal.format("p", many(15, detail: String.duplicate("long detail ", 60)))

    shown = listed(text)
    assert shown < 10
    assert byte_size(text) <= SetupProposal.max_bytes()
    assert text =~ "[+#{15 - shown} more: foreman project recommend p]"
  end

  test "the cap holds for the largest possible project id and detail" do
    project_id = String.duplicate("x", 255)
    recs = many(12, title: String.duplicate("t", 500), detail: String.duplicate("d", 5_000))
    text = SetupProposal.format(project_id, recs)

    assert byte_size(text) <= SetupProposal.max_bytes()
    assert listed(text) >= 1
  end

  test "detail is one clipped line and multibyte text is never cut mid-character" do
    detail = "first line\n\nsecond   line " <> String.duplicate("é", 400)
    text = SetupProposal.format("p", [rec("x", :warn, detail: detail)])

    assert text =~ "first line second line "
    assert text =~ "…"
    assert String.valid?(text)
    refute text =~ "first line\n"
  end

  test "secret-looking text is redacted" do
    text =
      SetupProposal.format("p", [
        rec("x", :warn, detail: "found API_KEY=sk-live-abcdef0123456789 in the repo")
      ])

    refute text =~ "sk-live-abcdef0123456789"
    assert text =~ "[REDACTED]"
  end

  describe "request?/1" do
    defp message(attrs), do: Map.merge(%{role: "operator", source: "cli", text: "/setup"}, attrs)

    test "exactly /setup from the operator through a trusted source" do
      assert SetupProposal.request?(message(%{}))
      assert SetupProposal.request?(message(%{text: "  /setup \n"}))
      assert SetupProposal.request?(message(%{source: nil}))
    end

    test "anything else is an ordinary message" do
      refute SetupProposal.request?(message(%{text: "/setup now"}))
      refute SetupProposal.request?(message(%{text: "please /setup"}))
      refute SetupProposal.request?(message(%{text: "/SETUP"}))
      refute SetupProposal.request?(message(%{role: "system"}))
      refute SetupProposal.request?(message(%{role: "agent"}))
      refute SetupProposal.request?(%{role: "operator"})
    end

    test "an untrusted source (MCP, a thread agent) cannot ask for one" do
      refute SetupProposal.request?(message(%{source: "mcp"}))
    end
  end
end
