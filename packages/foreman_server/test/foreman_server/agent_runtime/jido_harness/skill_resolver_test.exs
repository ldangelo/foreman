defmodule ForemanServer.AgentRuntime.JidoHarness.SkillResolverTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.SkillResolver
  alias ForemanServer.Jobsite.ExecutionProfile

  # TRD-021 / PRD AC-007-1. Every directory is a per-test temporary one handed
  # to the resolver; nothing reads the real home directory or the repo.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    project = Path.join(tmp, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(project)
    %{home: home, project: project, opts: [home: home, project_root: project]}
  end

  defp put_skill!(root, relative_dir, skill) do
    dir = Path.join([root, relative_dir, skill])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "# #{skill}\n")
  end

  defp host, do: ExecutionProfile.host_backend()

  describe "pi on the host backend" do
    test "a skill under the project's .pi/agent/skills is available", ctx do
      put_skill!(ctx.project, ".pi/agent/skills", "fix-issue")
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :available
    end

    test "a skill under ~/.pi/agent/skills is available", ctx do
      put_skill!(ctx.home, ".pi/agent/skills", "fix-issue")
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :available
    end

    test "a skill in no directory is missing", ctx do
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :missing
    end

    test "a skill directory without SKILL.md is missing", ctx do
      File.mkdir_p!(Path.join([ctx.project, ".pi/agent/skills", "fix-issue"]))
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :missing
    end

    test "a skill only in ~/.foreman/skills is missing: pi does not scan it", ctx do
      put_skill!(ctx.home, ".foreman/skills", "fix-issue")
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :missing
    end

    test "a skill only in another provider's directory is missing for pi", ctx do
      put_skill!(ctx.project, ".claude/skills", "fix-issue")
      put_skill!(ctx.project, ".claude/commands/foreman", "fix-issue")
      put_skill!(ctx.home, ".claude/skills", "fix-issue")
      assert SkillResolver.resolve(:pi, "fix-issue", host(), ctx.opts) == :missing
    end

    test "without a project root only the home directory is searched", ctx do
      put_skill!(ctx.project, ".pi/agent/skills", "fix-issue")
      assert SkillResolver.resolve(:pi, "fix-issue", host(), home: ctx.home) == :missing
    end

    test "a name can never escape the skill directory", ctx do
      # A real skill exists one level above the skill root; `..` would reach it.
      put_skill!(ctx.project, ".pi/agent", "outside")

      for name <- ["../outside", "../../agent/skills/outside", "a/b", "/etc", "..", ".", ""] do
        assert SkillResolver.resolve(:pi, name, host(), ctx.opts) == :missing,
               "#{inspect(name)} must not resolve"
      end
    end
  end

  describe "providers and backends that cannot be verified" do
    test "claude is unverifiable even when the skill exists in every directory", ctx do
      for root <- [ctx.project, ctx.home],
          dir <- [".pi/agent/skills", ".claude/skills", ".claude/commands/foreman"] do
        put_skill!(root, dir, "fix-issue")
      end

      assert SkillResolver.resolve(:claude, "fix-issue", host(), ctx.opts) == :unverifiable
      assert SkillResolver.resolve(:claude, "absent", host(), ctx.opts) == :unverifiable
    end

    test "a non-host backend is unverifiable, never available, even if the host has the skill",
         ctx do
      put_skill!(ctx.project, ".pi/agent/skills", "fix-issue")

      for backend <- [ExecutionProfile.docker_backend(), :something_else] do
        assert SkillResolver.resolve(:pi, "fix-issue", backend, ctx.opts) == :unverifiable
        assert SkillResolver.resolve(:pi, "absent", backend, ctx.opts) == :unverifiable
      end
    end

    test "an unknown provider is unverifiable", ctx do
      assert SkillResolver.resolve(:nope, "fix-issue", host(), ctx.opts) == :unverifiable
    end
  end
end
