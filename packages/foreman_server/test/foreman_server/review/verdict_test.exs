defmodule ForemanServer.Review.VerdictTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Review.{Gap, Verdict}

  defp verdict do
    %Verdict{
      verdict: :partially_met,
      summary: "Mostly done.",
      scores: %{correctness: 4, tests: 2, documentation: 3, robustness: 5},
      gaps: [
        %Gap{
          title: "No tests",
          description: "Route is untested.",
          dimension: :tests,
          severity: :major
        }
      ]
    }
  end

  test "to_map is JSON-ready with string keys and string enums" do
    map = Verdict.to_map(verdict())

    assert map == %{
             "verdict" => "partially_met",
             "summary" => "Mostly done.",
             "scores" => %{"correctness" => 4, "tests" => 2, "documentation" => 3, "robustness" => 5},
             "gaps" => [
               %{
                 "title" => "No tests",
                 "description" => "Route is untested.",
                 "dimension" => "tests",
                 "severity" => "major"
               }
             ],
             "error_code" => nil
           }

    assert {:ok, ^map} = map |> Jason.encode!() |> Jason.decode()
  end

  test "to_map carries an error code for an undetermined verdict" do
    v = %Verdict{verdict: :undetermined, summary: "boom", error_code: :evaluator_failed}

    assert %{"verdict" => "undetermined", "error_code" => "evaluator_failed", "gaps" => []} =
             Verdict.to_map(v)
  end

  test "to_markdown names the verdict, summary, scores and gaps" do
    md = Verdict.to_markdown(verdict())

    assert md =~ "# Review verdict: partially_met"
    assert md =~ "Mostly done."
    assert md =~ "- tests: 2/5"
    assert md =~ "- **No tests** (major, tests): Route is untested."
  end

  test "to_markdown omits empty sections but shows the error" do
    md = Verdict.to_markdown(%Verdict{verdict: :undetermined, summary: "boom", error_code: :evaluator_failed})

    assert md =~ "boom"
    assert md =~ "Error: `evaluator_failed`"
    refute md =~ "## Scores"
    refute md =~ "## Gaps"
  end
end
