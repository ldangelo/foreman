defmodule ForemanServer.Workflow.WorktreeSpecTest do
  # The `worktree:` block is WORKFLOW-level. These tests moved here from
  # `PhaseSpecTest` with the block itself: a run has exactly one worktree, so
  # there is nothing for a phase to declare about it.
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.WorktreeSpec

  describe "normalize/1" do
    # `nil` means "the workflow declared no block", which is distinct from
    # `%{}`: every default applies, including `enabled: true`. It must not
    # collapse to `%{enabled: false}`.
    test "an absent block normalizes to nil, not a disabled worktree" do
      assert WorktreeSpec.normalize(nil) == nil
    end

    test "a non-map declaration normalizes to nil rather than raising" do
      assert WorktreeSpec.normalize("yes") == nil
      assert WorktreeSpec.normalize(42) == nil
    end

    test "a string-keyed (replayed) block normalizes to atom keys" do
      spec =
        WorktreeSpec.normalize(%{
          "enabled" => true,
          "base" => "abc123",
          "branch" => "foreman/{run_id}",
          "path" => "workspace",
          "cleanup" => "never"
        })

      assert spec == %{
               enabled: true,
               base: "abc123",
               branch: "foreman/{run_id}",
               path: "workspace",
               cleanup: "never"
             }
    end

    test "an already atom-keyed block is preserved" do
      spec = WorktreeSpec.normalize(%{enabled: false, cleanup: "always"})

      assert spec == %{enabled: false, cleanup: "always"}
    end

    # The one value that actually disables a worktree. `Enum.find_value/2`
    # treats a present `false` as "keep looking", which silently turned this
    # into `nil` — i.e. into "declared nothing", which enables it.
    test "a present false survives normalization" do
      assert WorktreeSpec.normalize(%{"enabled" => false}) == %{enabled: false}
      assert WorktreeSpec.normalize(%{enabled: false}) == %{enabled: false}
    end

    # AGENTS.md 5.4b: an absent key must be absent, not `nil`. A `nil` reaches
    # `Map.get(spec, :cleanup)` indistinguishably from "declared nothing", and
    # poisons any caller written as `value || fallback`.
    test "absent keys are dropped rather than set to nil" do
      spec = WorktreeSpec.normalize(%{"enabled" => true})

      assert spec == %{enabled: true}
      refute Map.has_key?(spec, :cleanup)
      refute Map.has_key?(spec, :branch)
      refute Map.has_key?(spec, :base)
      refute Map.has_key?(spec, :path)
    end

    test "unrecognized keys are dropped rather than minting atoms" do
      spec = WorktreeSpec.normalize(%{"enabled" => true, "totallyNovelKeyNeverSeen" => "v"})

      assert spec == %{enabled: true}
      refute Enum.any?(Map.keys(spec), &(Atom.to_string(&1) =~ "totallyNovel"))
    end

    # `clean_worktree` is NOT a manifest key. It is the `VcsAdapter` operation
    # name for removing a worktree; an in-flight change normalized it as a
    # manifest key no module read, while `worktree_cleanup/1` stopped reading
    # the `cleanup:` the bundled manifests actually declare.
    test "clean_worktree is not a manifest key" do
      assert WorktreeSpec.normalize(%{"enabled" => true, "clean_worktree" => true}) ==
               %{enabled: true}
    end
  end
end
