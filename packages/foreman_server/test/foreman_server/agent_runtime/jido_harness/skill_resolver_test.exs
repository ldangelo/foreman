defmodule ForemanServer.AgentRuntime.JidoHarness.SkillResolverTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.SkillResolver
  alias ForemanServer.Jobsite.ExecutionProfile

  # TRD-021 / PRD AC-007-1. The fixtures mirror what pi 1.5.0 loads (see the
  # SkillResolver moduledoc): the user skills dir `<agent_dir>/skills`, the
  # project's `.pi/skills`, `.agents/skills`, settings `skills` entries and
  # declared packages. Every directory is a per-test temporary one handed to the
  # resolver; nothing reads the real home directory or the repo.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    agent = Path.join(home, ".pi/agent")
    project = Path.join(tmp, "project")
    File.mkdir_p!(agent)
    # `.git` makes the `.agents/skills` ancestor walk stop at the project.
    File.mkdir_p!(Path.join(project, ".git"))

    %{
      home: home,
      agent: agent,
      project: project,
      opts: [home: home, agent_dir: agent, project_root: project]
    }
  end

  defp host, do: ExecutionProfile.host_backend()

  defp resolve(skill, opts, provider \\ :pi),
    do: SkillResolver.resolve(provider, skill, host(), opts)

  # `<dir>/<dirname>/SKILL.md` with pi's frontmatter; `name` defaults to the
  # directory name, `description: nil` writes none.
  defp put_skill!(root, dirname, opts \\ []) do
    name = Keyword.get(opts, :name, dirname)
    description = Keyword.get(opts, :description, "Does a thing")
    dir = Path.join(root, dirname)
    File.mkdir_p!(dir)

    front =
      [name && "name: #{name}", description && "description: #{description}"]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    File.write!(Path.join(dir, "SKILL.md"), "---\n#{front}\n---\n\n# #{dirname}\n")
  end

  defp write_json!(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
  end

  describe "the directories pi loads" do
    test "a skill under <agent_dir>/skills is available", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a skill under ~/.agents/skills is available", ctx do
      put_skill!(Path.join(ctx.home, ".agents/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "the skill's identity is its frontmatter name, not its directory name", ctx do
      skills = Path.join(ctx.agent, "skills")
      put_skill!(skills, "0sf468-fix-issue", name: "fix-issue")
      put_skill!(skills, "create-prd", name: "something-else")

      assert resolve("fix-issue", ctx.opts) == :available
      # The directory is called create-prd, but pi registers `something-else`.
      assert resolve("create-prd", ctx.opts) == :missing
      assert resolve("something-else", ctx.opts) == :available
    end

    test "a directory name is the identity when the frontmatter has no name", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue", name: nil)
      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a SKILL.md without a description is not loaded by pi, so it is missing", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue", description: nil)
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "a skill in no source is missing", ctx do
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "a skill directory without SKILL.md is missing", ctx do
      File.mkdir_p!(Path.join(ctx.agent, "skills/fix-issue"))
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "the project's .pi/skills is project-scoped, so a skill only there is unverifiable",
         ctx do
      # pi loads project resources only for a trusted launch directory, which is
      # decided at run time for a worktree that does not exist yet.
      put_skill!(Path.join(ctx.project, ".pi/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a skill under <project>/.pi/agent/skills is not read by pi, so it is missing", ctx do
      # The directory the Foreman CLI recommends for a project is not one pi
      # scans (`projectBaseDir = <cwd>/.pi`, then `skills`).
      put_skill!(Path.join(ctx.project, ".pi/agent/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "an ancestor .agents/skills is project-scoped: unverifiable", ctx do
      put_skill!(Path.join(ctx.project, ".agents/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a skill only in ~/.foreman/skills is missing: pi does not scan it", ctx do
      put_skill!(Path.join(ctx.home, ".foreman/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "a skill only in another provider's directory is missing for pi", ctx do
      put_skill!(Path.join(ctx.project, ".claude/skills"), "fix-issue")
      put_skill!(Path.join(ctx.project, ".claude/commands/foreman"), "fix-issue")
      put_skill!(Path.join(ctx.home, ".claude/skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :missing
    end

    test "the agent dir is the injected one, not <home>/.pi/agent", ctx do
      other = Path.join(ctx.home, "elsewhere")
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")

      assert resolve("fix-issue", Keyword.put(ctx.opts, :agent_dir, other)) == :missing
      put_skill!(Path.join(other, "skills"), "fix-issue")
      assert resolve("fix-issue", Keyword.put(ctx.opts, :agent_dir, other)) == :available
    end
  end

  describe "settings skills entries" do
    test "a plain entry resolved from the agent dir is searched", ctx do
      put_skill!(Path.join(ctx.home, "my-skills"), "fix-issue")
      write_json!(Path.join(ctx.agent, "settings.json"), %{"skills" => ["../../my-skills"]})
      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a pattern entry could exclude the skill, so a find is unverifiable", ctx do
      put_skill!(Path.join(ctx.home, "my-skills"), "fix-issue")

      write_json!(Path.join(ctx.agent, "settings.json"), %{
        "skills" => ["../../my-skills", "!fix-issue"]
      })

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end
  end

  describe "declared packages" do
    test "a local package with a pi.skills manifest is read", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-local")
      put_skill!(Path.join(pkg, "bundle"), "fix-issue")
      write_json!(Path.join(pkg, "package.json"), %{"pi" => %{"skills" => ["./bundle"]}})
      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a manifest glob is expanded", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-glob")
      put_skill!(Path.join(pkg, "skills/group"), "fix-issue")
      write_json!(Path.join(pkg, "package.json"), %{"pi" => %{"skills" => ["./skills/*"]}})
      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a package without a manifest contributes its skills directory", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-conv")
      put_skill!(Path.join(pkg, "skills"), "fix-issue")
      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "an npm package is read from <agent_dir>/npm/node_modules", ctx do
      pkg = Path.join(ctx.agent, "npm/node_modules/@scope/skills-pkg")
      put_skill!(Path.join(pkg, "skills"), "fix-issue")

      write_json!(Path.join(pkg, "package.json"), %{
        "name" => "@scope/skills-pkg",
        "version" => "1.2.3",
        "pi" => %{"skills" => ["./skills"]}
      })

      for source <- ["npm:@scope/skills-pkg", "npm:@scope/skills-pkg@1.2.3"] do
        write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [source]})
        assert resolve("fix-issue", ctx.opts) == :available, source
      end

      # A different configured version would be reinstalled by pi at launch.
      write_json!(Path.join(ctx.agent, "settings.json"), %{
        "packages" => ["npm:@scope/skills-pkg@^2"]
      })

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a git package is read from <agent_dir>/git/<host>/<user>/<repo>", ctx do
      pkg = Path.join(ctx.agent, "git/github.com/acme/skills-repo")
      put_skill!(Path.join(pkg, "skills"), "fix-issue")

      write_json!(Path.join(ctx.agent, "settings.json"), %{
        "packages" => ["https://github.com/acme/skills-repo.git"]
      })

      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a package that cannot be resolved makes absence unprovable", ctx do
      # The skill is in none of the plain roots; pi would install a missing
      # package at launch and might find it there.
      for source <- [
            "npm:not-installed",
            "https://github.com/acme/not-cloned",
            "git:github.com/acme/other",
            "github:acme/other",
            Path.join(ctx.tmp_dir, "no-such-local-dir")
          ] do
        write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [source]})
        assert resolve("fix-issue", ctx.opts) == :unverifiable, source
      end
    end

    test "a package whose package.json cannot be parsed is unverifiable", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-bad")
      File.mkdir_p!(pkg)
      File.write!(Path.join(pkg, "package.json"), "{not json")
      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a package declared in the project settings is project-scoped", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-proj")
      put_skill!(Path.join(pkg, "skills"), "fix-issue")
      write_json!(Path.join(ctx.project, ".pi/settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a package declared as a filter object could be filtered: unverifiable", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-filtered")
      put_skill!(Path.join(pkg, "skills"), "fix-issue")

      write_json!(Path.join(ctx.agent, "settings.json"), %{
        "packages" => [%{"source" => pkg, "skills" => ["!fix-issue"]}]
      })

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a package that holds other skills proves the asked one absent", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-other")
      put_skill!(Path.join(pkg, "skills"), "create-prd")
      write_json!(Path.join(pkg, "package.json"), %{"pi" => %{"skills" => ["./skills"]}})
      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})

      assert resolve("fix-issue", ctx.opts) == :missing
      assert resolve("create-prd", ctx.opts) == :available
    end
  end

  describe "what makes absence unprovable" do
    test "an invalid settings.json is unverifiable", ctx do
      File.write!(Path.join(ctx.agent, "settings.json"), "{nope")
      assert resolve("fix-issue", ctx.opts) == :unverifiable

      File.write!(Path.join(ctx.agent, "settings.json"), "[1]")
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "an invalid project settings.json is unverifiable", ctx do
      File.mkdir_p!(Path.join(ctx.project, ".pi"))
      File.write!(Path.join(ctx.project, ".pi/settings.json"), "{nope")
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "an invalid settings.json does not hide a skill found in a user root", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")
      File.write!(Path.join(ctx.agent, "settings.json"), "{nope")
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "an extension could add skills at run time, so absence is unprovable", ctx do
      File.mkdir_p!(Path.join(ctx.agent, "extensions"))
      File.write!(Path.join(ctx.agent, "extensions/hook.ts"), "export default () => {}\n")
      assert resolve("fix-issue", ctx.opts) == :unverifiable

      # A find in a user root stays available.
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")
      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "a package that declares extensions makes absence unprovable", ctx do
      pkg = Path.join(ctx.tmp_dir, "pkg-ext")
      File.mkdir_p!(Path.join(pkg, "ext"))

      write_json!(Path.join(pkg, "package.json"), %{
        "pi" => %{"extensions" => ["./ext/index.ts"], "skills" => []}
      })

      write_json!(Path.join(ctx.agent, "settings.json"), %{"packages" => [pkg]})
      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "frontmatter this resolver cannot parse is unverifiable, not missing", ctx do
      dir = Path.join(ctx.agent, "skills/odd")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "SKILL.md"),
        "---\nname: odd\ndescription: Use when: something odd\n---\n"
      )

      assert resolve("fix-issue", ctx.opts) == :unverifiable
    end

    test "a block-scalar description is read", ctx do
      dir = Path.join(ctx.agent, "skills/fix-issue")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "SKILL.md"),
        "---\nname: fix-issue\ndescription: >\n  Fixes an issue.\n  Use it often.\n---\n"
      )

      assert resolve("fix-issue", ctx.opts) == :available
    end

    test "without a project root absence cannot be proven, but a user find stands", ctx do
      opts = Keyword.delete(ctx.opts, :project_root)
      assert resolve("fix-issue", opts) == :unverifiable

      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")
      assert resolve("fix-issue", opts) == :available
    end
  end

  describe "names that could escape a skill directory" do
    test "never resolve, and never reach the filesystem", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "outside")

      for name <- ["../outside", "../../agent/skills/outside", "a/b", "/etc", "..", ".", ""] do
        assert resolve(name, ctx.opts) == :missing, "#{inspect(name)} must not resolve"
      end
    end
  end

  describe "providers and backends that cannot be verified" do
    test "claude is unverifiable even when the skill exists in every directory", ctx do
      for root <- [ctx.project, ctx.home],
          dir <- [".pi/skills", ".claude/skills", ".claude/commands/foreman"] do
        put_skill!(Path.join(root, dir), "fix-issue")
      end

      assert resolve("fix-issue", ctx.opts, :claude) == :unverifiable
      assert resolve("absent", ctx.opts, :claude) == :unverifiable
    end

    test "a non-host backend is unverifiable, never available, even if the host has the skill",
         ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")

      for backend <- [ExecutionProfile.docker_backend(), :something_else] do
        assert SkillResolver.resolve(:pi, "fix-issue", backend, ctx.opts) == :unverifiable
        assert SkillResolver.resolve(:pi, "absent", backend, ctx.opts) == :unverifiable
      end
    end

    test "an unknown provider is unverifiable", ctx do
      assert resolve("fix-issue", ctx.opts, :nope) == :unverifiable
    end
  end
end
