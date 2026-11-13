defmodule ForemanServer.PrRiskTest do
  # TRD-041: the judgement block parser and the prompt content that asks for it.
  use ExUnit.Case, async: true

  alias ForemanServer.PrRisk

  @start "<!-- FOREMAN_RISK_JUDGEMENT_START -->"
  @end_ "<!-- FOREMAN_RISK_JUDGEMENT_END -->"
  @fstart "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @fend "<!-- FOREMAN_REVIEW_FINDINGS_END -->"

  defp json(overrides \\ %{}) do
    %{
      "schema" => "foreman.risk_judgement/1",
      "level" => "MEDIUM",
      "rationale" => "changes the retry path"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp block(text \\ json()), do: "#{@start}\n#{text}\n#{@end_}\n"

  describe "parse_judgement/1 outcomes" do
    test "one valid block is recorded with its level and rationale" do
      assert %{status: "recorded", level: "MEDIUM", rationale: "changes the retry path"} =
               judged = PrRisk.parse_judgement("# Review\n" <> block())

      assert judged.defect == nil
      assert judged.defect_detail == nil
    end

    test "every level is accepted" do
      for level <- ~w(LOW MEDIUM HIGH) do
        assert %{status: "recorded", level: ^level} =
                 PrRisk.parse_judgement(block(json(%{"level" => level})))
      end
    end

    test "no block is absent, with no level and no rationale: never recorded, never neutral" do
      for contents <- ["", "# Review\nlooks fine\n", @fstart <> "\n{}\n" <> @fend] do
        assert %{status: "absent", level: nil, rationale: nil, defect: nil} =
                 PrRisk.parse_judgement(contents)
      end

      assert PrRisk.absent() == PrRisk.parse_judgement("nothing here")
    end

    test "a judgement block next to the findings block is read independently" do
      contents = "#{@fstart}\nnot even json\n#{@fend}\n" <> block()
      assert %{status: "recorded", level: "MEDIUM"} = PrRisk.parse_judgement(contents)
    end

    test "the rationale may be exactly 1000 characters, not 1001" do
      assert %{status: "recorded"} =
               PrRisk.parse_judgement(block(json(%{"rationale" => String.duplicate("é", 1000)})))

      assert %{status: "malformed", defect: "invalid_field"} =
               PrRisk.parse_judgement(block(json(%{"rationale" => String.duplicate("é", 1001)})))
    end

    for {name, contents, defect} <- [
          {"an unterminated block", "#{@start}\n{\"schema\": 1}\n", "unterminated_block"},
          {"an end marker with no start", "#{@end_}\n", "unterminated_block"},
          {"misordered markers", "#{@end_}\n{}\n#{@start}\n", "unterminated_block"},
          {"invalid JSON", "#{@start}\n{not json\n#{@end_}\n", "invalid_json"},
          {"an empty block", "#{@start}\n#{@end_}\n", "invalid_json"},
          {"a JSON array", "#{@start}\n[1]\n#{@end_}\n", "unknown_schema"},
          {"an unknown schema",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/2\", \"level\": \"LOW\", \"rationale\": \"x\"}\n#{@end_}\n",
           "unknown_schema"},
          {"an unknown level",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"CRITICAL\", \"rationale\": \"x\"}\n#{@end_}\n",
           "invalid_field"},
          {"a lowercase level",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"high\", \"rationale\": \"x\"}\n#{@end_}\n",
           "invalid_field"},
          {"a missing rationale",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"LOW\"}\n#{@end_}\n",
           "invalid_field"},
          {"a blank rationale",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"LOW\", \"rationale\": \"  \"}\n#{@end_}\n",
           "invalid_field"},
          {"an unknown key",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"LOW\", \"rationale\": \"x\", \"extra\": 1}\n#{@end_}\n",
           "invalid_field"},
          {"a repeated key",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"HIGH\", \"level\": \"LOW\", \"rationale\": \"x\"}\n#{@end_}\n",
           "invalid_field"},
          {"a control character in the rationale",
           "#{@start}\n{\"schema\": \"foreman.risk_judgement/1\", \"level\": \"LOW\", \"rationale\": \"a\\u001bb\"}\n#{@end_}\n",
           "invalid_field"}
        ] do
      test "#{name} is malformed with defect #{defect}" do
        assert %{
                 status: "malformed",
                 level: nil,
                 rationale: nil,
                 defect: unquote(defect),
                 defect_detail: detail
               } = PrRisk.parse_judgement(unquote(contents))

        assert detail != ""
      end
    end

    test "a block over 4096 bytes is malformed too_large, not parsed" do
      padded = json(%{"rationale" => String.duplicate("x", 900)}) <> String.duplicate(" ", 4096)

      assert %{status: "malformed", defect: "too_large", level: nil} =
               PrRisk.parse_judgement(block(padded))
    end

    test "a block of exactly 4096 bytes is still parsed" do
      body = json()
      padded = body <> String.duplicate(" ", 4096 - byte_size(body))
      assert byte_size(padded) == 4096
      assert %{status: "recorded"} = PrRisk.parse_judgement(block(padded))
    end
  end

  describe "the one-pair rule" do
    test "two counted blocks (an echoed one at column 0) are malformed multiple_blocks and no level is used" do
      echoed =
        block(json(%{"level" => "LOW"})) <> "\nquoted from the previous phase:\n" <> block()

      assert %{status: "malformed", defect: "multiple_blocks", level: nil, rationale: nil} =
               PrRisk.parse_judgement(echoed)

      # Neither order yields the first or the last level.
      assert %{status: "malformed", level: nil} =
               PrRisk.parse_judgement(block(json(%{"level" => "HIGH"})) <> block())
    end

    test "a block quoted inside a code fence and one real block: the real block is recorded" do
      quoted = "```\n" <> block(json(%{"level" => "LOW"})) <> "```\n"

      assert %{status: "recorded", level: "HIGH"} =
               PrRisk.parse_judgement(quoted <> block(json(%{"level" => "HIGH"})))

      tilde = "~~~~\n" <> block(json(%{"level" => "LOW"})) <> "~~~~\n"

      assert %{status: "recorded", level: "HIGH"} =
               PrRisk.parse_judgement(tilde <> block(json(%{"level" => "HIGH"})))
    end

    test "a block that is only quoted in a fence is absent" do
      assert %{status: "absent"} = PrRisk.parse_judgement("```\n" <> block() <> "```\n")
    end

    test "an indented or `> `-prefixed marker line is not counted" do
      real = block()
      indented = "    #{@start}\n    #{json(%{"level" => "LOW"})}\n    #{@end_}\n"
      quoted = "> #{@start}\n> #{json(%{"level" => "LOW"})}\n> #{@end_}\n"

      assert %{status: "recorded", level: "MEDIUM"} = PrRisk.parse_judgement(indented <> real)
      assert %{status: "recorded", level: "MEDIUM"} = PrRisk.parse_judgement(quoted <> real)
      assert %{status: "absent"} = PrRisk.parse_judgement(indented <> quoted)
    end

    test "a fence that wraps the real block hides it: absent, never read as the level" do
      assert %{status: "absent", level: nil} =
               PrRisk.parse_judgement("```json\n" <> block() <> "```\n")
    end

    defp crlf(text), do: String.replace(text, "\n", "\r\n")

    test "a block with CRLF line ends is recorded" do
      assert %{status: "recorded", level: "MEDIUM", rationale: "changes the retry path"} =
               PrRisk.parse_judgement(crlf("# Review\n" <> block()))
    end

    test "a CRLF-fenced quoted marker and one real block: the real block is recorded" do
      quoted = crlf("```\n" <> block(json(%{"level" => "LOW"})) <> "```\n")

      assert %{status: "recorded", level: "HIGH"} =
               PrRisk.parse_judgement(quoted <> crlf(block(json(%{"level" => "HIGH"}))))

      # a block that is only quoted in a CRLF fence is absent
      assert %{status: "absent"} = PrRisk.parse_judgement(quoted)
    end

    test "the end marker before the start marker is malformed unterminated_block" do
      assert %{status: "malformed", defect: "unterminated_block", level: nil, rationale: nil} =
               PrRisk.parse_judgement("#{@end_}\n#{json()}\n#{@start}\n")
    end
  end

  describe "the review prompts (TRD-041)" do
    @prompts Path.expand("../../priv/defaults/workflows/prompts", __DIR__)

    defp prompt(file),
      do: @prompts |> Path.join(file) |> File.read!() |> String.split() |> Enum.join(" ")

    for file <- ["review-repo-rules.md", "review-coderabbit.md"] do
      test "#{file} asks for the judgement once, after the findings block, outside any fence" do
        text = prompt(unquote(file))

        assert length(String.split(text, "FOREMAN_RISK_JUDGEMENT_START")) == 2,
               "the start marker appears once (the one example)"

        assert length(String.split(text, "FOREMAN_RISK_JUDGEMENT_END")) == 2

        {findings_at, _} = :binary.match(text, "FOREMAN_REVIEW_FINDINGS_END")
        {judgement_at, _} = :binary.match(text, "FOREMAN_RISK_JUDGEMENT_START")
        assert judgement_at > findings_at

        assert text =~ "after the findings block"
        assert text =~ "outside any code"
        assert text =~ "do not wrap the block in one"

        # The one example sits in the prompt's own fence, and says so.
        assert text =~ "this prompt's formatting only"
      end

      test "#{file} says it is the agent's claim and can only raise the level" do
        text = prompt(unquote(file))
        assert text =~ "your own claim"
        assert text =~ "can only raise the level"
        assert text =~ "never lower it"
      end

      test "#{file} tells the reviewer to quote a marker line inside a code fence" do
        text = prompt(unquote(file))
        assert text =~ "quote a judgement marker line, put the quote inside a code fence"
        assert text =~ "second block"
      end
    end

    test "the repository-rules prompt forbids copying the previous judgement; the other has no previous phase" do
      rules = prompt("review-repo-rules.md")
      assert rules =~ "Never copy the previous phase's judgement block"
      assert rules =~ "never copy a previous judgement block"
      refute rules =~ ~r/copy[^.]*judgement block into/i

      coderabbit = prompt("review-coderabbit.md")
      refute coderabbit =~ "previous phase"
      refute coderabbit =~ ~r/copy[^.]*judgement/i
    end
  end

  describe "record/1 (TRD-018)" do
    alias ForemanServer.PrRisk.Rubric

    defp findings_record(overrides \\ %{}) do
      Map.merge(
        %{
          head_sha: "h1",
          status: "recorded",
          findings: [],
          defect: nil,
          defect_detail: nil,
          judgement: %{
            status: "recorded",
            level: "LOW",
            rationale: "free text",
            defect: nil,
            defect_detail: nil
          },
          digest: "fd-1"
        },
        overrides
      )
    end

    defp input(overrides \\ %{}) do
      Map.merge(
        %{
          identity: %{run_id: "r1", project_id: "p1", task_id: "t1", pr_url: "u", repo_id: nil},
          head_sha: "h1",
          files: [%{path: "lib/a.ex", additions: 2, deletions: 1}],
          changed_files: 1,
          additions: 2,
          deletions: 1,
          base_branch: "main",
          recorded_base: "main",
          checks: %{status: :eligible, reasons: []},
          findings: findings_record(),
          policy_version: "pv"
        },
        overrides
      )
    end

    test "the level is the rubric's, the rest is derived, and every nested map is string-keyed JSON" do
      rec = PrRisk.record(input())
      assert rec.level == "LOW" and rec.rubric_version == Rubric.version()
      assert rec.digest =~ ~r/\A[0-9a-f]{16}\z/
      assert rec.findings_digest == "fd-1"
      assert rec.instructions == []
      assert Enum.all?(rec.rationale, &Enum.all?(Map.keys(&1), fn k -> is_binary(k) end))
      assert rec.evidence |> Jason.encode!() |> Jason.decode!() == rec.evidence
      assert rec.rationale |> Jason.encode!() |> Jason.decode!() == rec.rationale
      assert PrRisk.record(input()) == rec
    end

    test "the digest moves with the head, the identity and every content field" do
      base = PrRisk.record(input()).digest

      for other <- [
            input(%{head_sha: "h2"}),
            input(%{
              identity: %{
                run_id: "r2",
                project_id: "p1",
                task_id: "t1",
                pr_url: "u",
                repo_id: nil
              }
            }),
            input(%{
              identity: %{
                run_id: "r1",
                project_id: "p1",
                task_id: "t1",
                pr_url: "u",
                repo_id: "b"
              }
            }),
            input(%{base_branch: "dev"}),
            input(%{additions: 3}),
            input(%{checks: %{status: :ineligible, reasons: [%{code: :failing}]}}),
            input(%{findings: findings_record(%{digest: "fd-2"})}),
            input(%{policy_version: "pv2"})
          ] do
        refute PrRisk.record(other).digest == base
      end
    end

    test "a missing input is HIGH, never filled in" do
      for override <- [
            %{files: nil},
            %{changed_files: nil},
            %{additions: nil},
            %{recorded_base: nil},
            %{findings: nil},
            %{checks: nil}
          ] do
        assert PrRisk.record(input(override)).level == "HIGH", inspect(override)
      end

      none = PrRisk.record(input(%{findings: nil}))
      assert none.findings_digest == nil and none.judgement == nil
      assert none.unresolved_findings == []
      assert none.evidence["findings"] == nil
    end

    test "the judgement is summarised without its text and bound to the findings' head" do
      rec = PrRisk.record(input())

      assert rec.judgement == %{
               "head_sha" => "h1",
               "status" => "recorded",
               "level" => "LOW",
               "defect" => nil
             }

      refute Jason.encode!(rec) =~ "free text"

      other = PrRisk.record(input(%{head_sha: "h2"}))
      assert other.level == "HIGH"
      assert other.unresolved_findings == []
      assert other.judgement["head_sha"] == "h1"
    end

    test "unresolved findings follow the review's rule, are bounded, and cut their text" do
      f = fn sev, disp, desc ->
        %{
          "severity" => sev,
          "path" => "a",
          "line" => 1,
          "description" => desc,
          "disposition" => disp,
          "source" => "s"
        }
      end

      items =
        [
          f.("critical", "open", String.duplicate("x", 500)),
          f.("major", "declined", "d"),
          f.("minor", "declined", "skip"),
          f.("major", "fixed", "skip")
        ] ++ for(n <- 1..30, do: f.("nitpick", "open", "n#{n}"))

      rec = PrRisk.record(input(%{findings: findings_record(%{findings: items})}))
      listed = rec.unresolved_findings
      assert length(listed) == 20

      assert [
               %{"severity" => "critical", "description" => cut},
               %{"severity" => "major", "disposition" => "declined"} | _
             ] = listed

      assert String.length(cut) == 300
      refute Enum.any?(listed, &(&1["description"] == "skip"))

      assert rec.evidence["findings"]["unresolved"] ==
               %{"critical" => 1, "major" => 1, "minor" => 0, "nitpick" => 30}
    end
  end
end
