defmodule ForemanServer.Skills.InstallerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Skills.Installer

  @bundled_source_dir Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "..",
                        "priv",
                        "defaults",
                        "skills"
                      ])

  @bundled_skill_dirs @bundled_source_dir
                      |> File.ls!()
                      |> Enum.filter(fn name ->
                        File.dir?(Path.join(@bundled_source_dir, name))
                      end)
                      |> Enum.sort()

  test "install/1 copies bundled skills into ~/.foreman/skills" do
    home_dir = make_temp_dir!("skills-installer-home")

    assert {:ok, installed_paths} = Installer.install(home_dir: home_dir)

    expected_dir = Path.join([home_dir, ".foreman", "skills"])
    assert File.dir?(expected_dir)

    for skill_name <- @bundled_skill_dirs do
      skill_dir = Path.join(expected_dir, skill_name)
      assert File.dir?(skill_dir), "expected skill directory #{skill_dir}"

      skill_md = Path.join(skill_dir, "SKILL.md")
      assert File.regular?(skill_md), "expected SKILL.md at #{skill_md}"
      assert skill_md in installed_paths
    end
  end

  test "install/1 includes the foreman-jobsite-template skill" do
    home_dir = make_temp_dir!("skills-installer-jobsite")

    assert {:ok, installed_paths} = Installer.install(home_dir: home_dir)

    skill_md =
      Path.join([home_dir, ".foreman", "skills", "foreman-jobsite-template", "SKILL.md"])

    assert skill_md in installed_paths
    assert File.regular?(skill_md)

    content = File.read!(skill_md)
    assert content =~ "foreman-jobsite-template"
    assert content =~ "Jobsite.Spec.from_json"
    assert content =~ "on_event"
    assert content =~ "hooks.host"
  end

  test "install/1 with a custom target_dir writes skills there" do
    target_dir = make_temp_dir!("skills-installer-target")

    assert {:ok, installed_paths} = Installer.install(target_dir: target_dir)

    assert Enum.all?(installed_paths, &String.starts_with?(&1, target_dir))
  end

  test "install/1 with a custom source_dir copies only that directory's skills" do
    source_dir = make_temp_dir!("skills-installer-source")
    target_dir = make_temp_dir!("skills-installer-custom-target")

    File.mkdir_p!(Path.join([source_dir, "my-custom-skill", "scripts"]))
    File.write!(Path.join([source_dir, "my-custom-skill", "SKILL.md"]), "# My Skill\n")

    File.write!(Path.join([source_dir, "my-custom-skill", "scripts", "run.exs"]), "# runner\n")

    assert {:ok, installed_paths} =
             Installer.install(source_dir: source_dir, target_dir: target_dir)

    assert length(installed_paths) == 2

    assert Enum.any?(installed_paths, &String.ends_with?(&1, "my-custom-skill/SKILL.md"))

    assert Enum.any?(installed_paths, &String.ends_with?(&1, "my-custom-skill/scripts/run.exs"))
  end

  test "install/1 returns empty list when source has no skill directories" do
    source_dir = make_temp_dir!("skills-installer-empty-source")
    target_dir = make_temp_dir!("skills-installer-empty-target")

    assert {:ok, []} = Installer.install(source_dir: source_dir, target_dir: target_dir)
  end

  test "maybe_install/1 installs when the target directory is absent" do
    home_dir = make_temp_dir!("skills-installer-missing-home")
    File.rm_rf!(home_dir)

    assert {:ok, installed_paths} = Installer.maybe_install(home_dir: home_dir)
    assert Enum.any?(installed_paths, &String.contains?(&1, "foreman-jobsite-template"))

    # The returned paths alone are not proof: a bug that reports paths without
    # writing them would still satisfy the assertions above.
    assert File.regular?(
             Path.join([home_dir, ".foreman", "skills", "foreman-jobsite-template", "SKILL.md"])
           )
  end

  test "maybe_install/1 does not overwrite an existing skill" do
    home_dir = make_temp_dir!("skills-installer-existing-home")
    skill_dir = Path.join([home_dir, ".foreman", "skills", "foreman-jobsite-template"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "# operator edited\n")

    assert {:ok, :noop} = Installer.maybe_install(home_dir: home_dir)
    assert File.read!(Path.join(skill_dir, "SKILL.md")) == "# operator edited\n"
  end

  defp make_temp_dir!(prefix) do
    directory = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end
end
