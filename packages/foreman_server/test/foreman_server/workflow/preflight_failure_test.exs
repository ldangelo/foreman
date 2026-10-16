defmodule ForemanServer.Workflow.PreflightFailureTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PreflightFailure

  # TRD-002 / TRD-003 and PRD AC-002-1, AC-007-1. `AGENTS.md` §5.3 requires a
  # distinct code per distinct cause; the class set is closed by `@classes`, so
  # this walks every class rather than the subset the executor happens to be
  # reachable with in a test environment.
  describe "summarize/1" do
    test "every class renders text no other class renders" do
      rendered =
        Enum.map(PreflightFailure.classes(), fn class ->
          failure = %PreflightFailure{
            phase: "code",
            provider: :pi,
            model: "minimax/M2.7",
            class: class
          }

          {class, PreflightFailure.summarize(failure)}
        end)

      texts = Enum.map(rendered, &elem(&1, 1))

      assert length(Enum.uniq(texts)) == length(texts),
             "two classes render identically: #{inspect(rendered)}"

      # The pair this struct exists to separate: "the catalog answered: absent"
      # is a workflow defect, "the catalog could not be asked" is an
      # infrastructure defect. Both previously reached the run record as one
      # reason atom.
      {_not_found, not_found_text} = List.keyfind(rendered, :model_not_found, 0)
      {_unavailable, unavailable_text} = List.keyfind(rendered, :catalog_unavailable, 0)
      assert not_found_text =~ "not present"
      assert unavailable_text =~ "could not answer"
      refute not_found_text =~ "could not answer"
    end

    test "each summary names the phase, provider, and class" do
      for class <- PreflightFailure.classes() do
        text =
          PreflightFailure.summarize(%PreflightFailure{
            phase: "code",
            provider: :pi,
            model: "m",
            class: class
          })

        assert text =~ "code"
        assert text =~ ":pi"
        assert text =~ Atom.to_string(class)
      end
    end

    test "detail rides in the summary when the check carried one" do
      text =
        PreflightFailure.summarize(%PreflightFailure{
          phase: "code",
          provider: :pi,
          model: "minimax/M2.7",
          class: :catalog_unavailable,
          detail: :timeout
        })

      assert text =~ "timeout"
    end

    test "an unclassified value degrades to text naming it rather than raising" do
      assert PreflightFailure.summarize(%PreflightFailure{phase: nil, provider: :pi, class: :wat}) =~
               ":wat"
    end
  end

  test "classes/0 lists the checked order the executor's cond follows" do
    assert PreflightFailure.classes() == [
             :provider_unsupported,
             :provider_not_installed,
             :model_not_found,
             :catalog_unavailable
           ]
  end

  test "the discriminating fields are enforced, so a failure cannot be built without one" do
    # `@enforce_keys` raises ArgumentError (struct construction, not field
    # access), and `class` — the whole discriminator — is among them.
    assert_raise ArgumentError, fn ->
      struct!(PreflightFailure, phase: "code", provider: :pi)
    end
  end
end
