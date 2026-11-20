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
             :catalog_unavailable,
             :skill_not_found
           ]
  end

  test "the discriminating fields are enforced, so a failure cannot be built without one" do
    # `@enforce_keys` raises ArgumentError (struct construction, not field
    # access), and `class` — the whole discriminator — is among them.
    assert_raise ArgumentError, fn ->
      struct!(PreflightFailure, phase: "code", provider: :pi)
    end
  end

  describe ":skill_not_found" do
    test "backend and skill default to nil and the class is part of the closed set" do
      failure = %PreflightFailure{phase: "code", provider: :pi, class: :skill_not_found}

      assert failure.backend == nil
      assert failure.skill == nil
      assert :skill_not_found in PreflightFailure.classes()
    end

    test "its summary names the skill and the backend, and no other class says so" do
      failure = %PreflightFailure{
        phase: "code",
        provider: :pi,
        class: :skill_not_found,
        skill: "fix-issue",
        backend: :host_workflow
      }

      text = PreflightFailure.summarize(failure)

      assert text =~ "skill_not_found"
      assert text =~ ~s("fix-issue")
      assert text =~ ":host_workflow"
      refute text =~ "unclassified"

      for class <- PreflightFailure.classes() -- [:skill_not_found] do
        other =
          PreflightFailure.summarize(%PreflightFailure{
            phase: "code",
            provider: :pi,
            class: class
          })

        refute other =~ "skill"
      end
    end

    test "the skill and backend are optional in the summary" do
      text =
        PreflightFailure.summarize(%PreflightFailure{
          phase: "code",
          provider: :pi,
          class: :skill_not_found
        })

      assert text =~ "skill_not_found"
      refute text =~ "unclassified"
    end
  end
end
