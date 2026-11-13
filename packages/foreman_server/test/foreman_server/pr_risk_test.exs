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
end
