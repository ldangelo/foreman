defmodule ForemanServer.Skills.InstallerTest do
  # `async: false`: two of these tests call `Workflow.Catalog.init/1`, which boots the whole
  # workflow catalog against a temp root. The other `Catalog` suites in this project are also
  # `async: false` for the same reason.
  use ExUnit.Case, async: false

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

    # Prove the recursive copy (File.cp_r) installs nested assets, not just SKILL.md.
    nested_rel = Path.join(["scripts", "validate_spec.py"])

    installed_nested =
      Path.join([home_dir, ".foreman", "skills", "foreman-jobsite-template"])
      |> Path.join(nested_rel)

    source_nested =
      Installer.bundled_skills_source()
      |> Path.join("foreman-jobsite-template")
      |> Path.join(nested_rel)

    assert File.regular?(installed_nested),
           "expected nested asset #{nested_rel} to be installed recursively"

    assert File.read!(installed_nested) == File.read!(source_nested),
           "nested asset content must match source bytes"
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

  # The pre-fix gate asked "is anything in the destination?" rather than "is
  # everything the bundle ships there?", so once an operator had any skill
  # installed, a skill added to the bundle in a later release never reached them.
  # With one bundled skill today this cannot fail against `priv/defaults/skills`
  # (`@bundled_skill_dirs` == ["foreman-jobsite-template"]), so the source is
  # faked to two skills.
  test "maybe_install/1 installs a skill added to the bundle when another is present" do
    source_dir = make_temp_dir!("skills-installer-two-source")
    home_dir = make_temp_dir!("skills-installer-two-home")

    for name <- ["alpha-skill", "beta-skill"] do
      File.mkdir_p!(Path.join(source_dir, name))
      File.write!(Path.join([source_dir, name, "SKILL.md"]), "# #{name}\n")
    end

    dest_skills = Path.join([home_dir, ".foreman", "skills"])
    installed_dir = Path.join(dest_skills, "alpha-skill")
    File.mkdir_p!(installed_dir)
    File.write!(Path.join(installed_dir, "SKILL.md"), "# operator edited\n")

    assert {:ok, installed_paths} =
             Installer.maybe_install(source_dir: source_dir, home_dir: home_dir)

    assert Enum.any?(installed_paths, &String.ends_with?(&1, "beta-skill/SKILL.md")),
           "the new skill must install even though alpha-skill was already present"

    assert File.dir?(Path.join(dest_skills, "beta-skill"))

    # The installing pass must not clobber the operator's edits to the skill
    # that already existed.
    assert File.read!(Path.join(installed_dir, "SKILL.md")) == "# operator edited\n"
  end

  test "maybe_install/1 is a no-op when every bundled skill is present" do
    source_dir = make_temp_dir!("skills-installer-all-source")
    home_dir = make_temp_dir!("skills-installer-all-home")
    dest_skills = Path.join([home_dir, ".foreman", "skills"])

    for name <- ["alpha-skill", "beta-skill"] do
      File.mkdir_p!(Path.join(source_dir, name))
      File.write!(Path.join([source_dir, name, "SKILL.md"]), "# #{name}\n")
      File.mkdir_p!(Path.join(dest_skills, name))
      File.write!(Path.join([dest_skills, name, "SKILL.md"]), "# operator edited\n")
    end

    assert {:ok, :noop} = Installer.maybe_install(source_dir: source_dir, home_dir: home_dir)

    assert File.read!(Path.join([dest_skills, "alpha-skill", "SKILL.md"])) ==
             "# operator edited\n"

    assert File.read!(Path.join([dest_skills, "beta-skill", "SKILL.md"])) ==
             "# operator edited\n"
  end

  # Guards the restrict step, which is easy to drop while touching either function: without
  # it `maybe_install/1` reaches `install/1` with no `:install_skills` and force-copies the
  # whole bundle, overwriting the operator's edits (`File.cp_r/2` overwrites destination
  # files — verified, not assumed).
  test "install/1 with :install_skills copies only the named skills" do
    source_dir = make_temp_dir!("skills-restrict-source")
    target_dir = make_temp_dir!("skills-restrict-target")

    for name <- ["alpha-skill", "beta-skill"] do
      File.mkdir_p!(Path.join(source_dir, name))
      File.write!(Path.join([source_dir, name, "SKILL.md"]), "# #{name}\n")
      File.mkdir_p!(Path.join(target_dir, name))
      File.write!(Path.join([target_dir, name, "SKILL.md"]), "# operator edited\n")
    end

    assert {:ok, installed_paths} =
             Installer.install(
               source_dir: source_dir,
               target_dir: target_dir,
               install_skills: ["beta-skill"]
             )

    assert Enum.any?(installed_paths, &String.ends_with?(&1, "beta-skill/SKILL.md"))
    refute Enum.any?(installed_paths, &String.ends_with?(&1, "alpha-skill/SKILL.md"))

    assert File.read!(Path.join([target_dir, "alpha-skill", "SKILL.md"])) ==
             "# operator edited\n"

    assert File.read!(Path.join([target_dir, "beta-skill", "SKILL.md"])) == "# beta-skill\n"
  end

  # An empty allowlist must mean "nothing", never "everything": `Keyword.get/2` cannot tell
  # an absent option from `[]`, so a caller that passes an empty list must not get a full
  # reinstall of skills the operator has edited.
  test "install/1 with an empty :install_skills copies nothing" do
    source_dir = make_temp_dir!("skills-restrict-empty-source")
    target_dir = make_temp_dir!("skills-restrict-empty-target")

    File.mkdir_p!(Path.join(source_dir, "alpha-skill"))
    File.write!(Path.join([source_dir, "alpha-skill", "SKILL.md"]), "# alpha-skill\n")

    assert {:ok, []} =
             Installer.install(source_dir: source_dir, target_dir: target_dir, install_skills: [])

    refute File.dir?(Path.join(target_dir, "alpha-skill"))
  end

  # The boot hook used to discard the result with `_ =`, so a skill install that failed was
  # indistinguishable from one that never needed to run.
  #
  # `Catalog.init/1` is called directly rather than via `start_supervised!/2`. Booting a second
  # `Catalog` process installs every bundled workflow and schedules a poll timer; in this shared
  # `async: false` file that starves the other GenServers, and a boot can then land after the
  # test that started it has exited — which is what made the mailbox-based version flake under a
  # full-suite run. Same producer (`init/1`), same consumer (telemetry), no scheduler pressure.
  #
  # The counts are read from a per-invocation `:counters` ref written by a handler that runs
  # inline in the emitting process, so they are settled the moment `init/1` returns. Events are
  # also forwarded to the test process so `refute_receive` remains meaningful in both directions.
  defp boot_catalog(skills_opts) do
    counts = :counters.new(2, [])
    handler_base = "skills-hook-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    test_pid = self()

    attach = fn suffix, event, index, key ->
      :ok =
        :telemetry.attach(
          handler_base <> suffix,
          event,
          fn _event, measurements, metadata, _config ->
            :counters.add(counts, index, 1)
            send(test_pid, {key, if(key == :skills_installed, do: measurements, else: metadata)})
          end,
          nil
        )
    end

    attach.("-installed", [:foreman_server, :skills, :installed], 1, :skills_installed)
    attach.("-error", [:foreman_server, :skills, :install, :error], 2, :skills_install_error)

    on_exit(fn ->
      :telemetry.detach(handler_base <> "-installed")
      :telemetry.detach(handler_base <> "-error")
    end)

    root = make_temp_dir!("skills-catalog-hook-workflows")
    File.mkdir_p!(Path.join(root, "prompts"))

    # `AssetCatalog.new/1`, not a bare `%AssetCatalog{}`: `prompts_dir` defaults to `nil` and
    # `load_prompts/1` then crashes in `File.ls/1` before `init/1` returns.
    {:ok, _state} =
      ForemanServer.Workflow.Catalog.init(
        [catalog: ForemanServer.Workflow.AssetCatalog.new(root)] ++ skills_opts
      )

    %{installed: :counters.get(counts, 1), errors: :counters.get(counts, 2)}
  end

  test "Catalog boot hook reports a successful skills install" do
    skills_dir = make_temp_dir!("skills-catalog-hook-target")

    assert %{installed: installed, errors: 0} = boot_catalog(skills_target_dir: skills_dir)
    assert installed > 0
    assert File.regular?(Path.join([skills_dir, "foreman-jobsite-template", "SKILL.md"]))

    # `count` is the number of FILES the installer copied, so it is larger than the one
    # `installed` event the counter records; the file on disk is the real assertion.
    assert_receive {:skills_installed, %{count: copied}}
    assert copied > 0
    refute_receive {:skills_install_error, _}
  end

  # A destination that cannot hold skills must be reported, not swallowed — the `_ =` this
  # replaced discarded exactly that case.
  test "Catalog boot hook reports a failed skills install" do
    blocked = Path.join(make_temp_dir!("skills-catalog-hook-blocked"), "not-a-dir")
    File.write!(blocked, "a regular file cannot hold skills")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{installed: 0, errors: errors} = boot_catalog(skills_target_dir: blocked)
        assert errors > 0
      end)

    # Loud in both channels: telemetry, which reaches only a process that attached a handler,
    # and `Logger`, which is what an operator actually sees.
    assert log =~ "Skills boot-install failed"
    assert log =~ blocked
    assert_receive {:skills_install_error, %{reason: reason}}
    assert reason != nil
    refute_receive {:skills_installed, _}
  end

  # `skills_home_dir:` must reach the installer as `:home_dir`, which is what
  # `Installer.target_dir/1` resolves against `System.user_home!()`. The `skills_`-prefix
  # mapping table in `Catalog.init/1` is otherwise unasserted — deleting that one pair would
  # leave the whole skills hook writing into the operator's real home — so this pins it.
  test "Catalog boot hook defaults the skills target to the user home" do
    home_dir = make_temp_dir!("skills-catalog-hook-default-home")

    assert %{installed: installed, errors: 0} = boot_catalog(skills_home_dir: home_dir)
    assert installed > 0

    assert File.regular?(
             Path.join([home_dir, ".foreman", "skills", "foreman-jobsite-template", "SKILL.md"])
           )
  end

  # `Installer.maybe_install/1` no longer calls `File.ls/1` on the destination at all — it asks
  # `skill_installed?/2` per bundled name — so an absent destination reaches `install/1` only
  # because `restrict(names, nil)` returns every name. Returning `[]` for `nil` instead (i.e.
  # swapping the order of the two `restrict/2` clauses) would make every boot a silent no-op.
  test "maybe_install/1 with no :install_skills installs every bundled skill" do
    source_dir = make_temp_dir!("skills-restrict-absent-option-source")
    home_dir = make_temp_dir!("skills-restrict-absent-option-home")

    for name <- ["alpha-skill", "beta-skill"] do
      File.mkdir_p!(Path.join(source_dir, name))
      File.write!(Path.join([source_dir, name, "SKILL.md"]), "# #{name}\n")
    end

    assert {:ok, installed_paths} =
             Installer.maybe_install(source_dir: source_dir, home_dir: home_dir)

    assert Enum.any?(installed_paths, &String.ends_with?(&1, "alpha-skill/SKILL.md"))
    assert Enum.any?(installed_paths, &String.ends_with?(&1, "beta-skill/SKILL.md"))
  end

  # `target_dir/1` must treat a PRESENT `nil` exactly as an absent key. The `skills_*` option
  # translation in `Catalog.init/1` names keys the caller may not have set, and
  # `Keyword.get/3`'s default fires only on ABSENCE, so a forwarded `home_dir: nil` has to
  # resolve to the fallback rather than raise in `Path.join/1` and crash catalog boot.
  # `Keyword.get/2` + `||` is the discriminator: swap it for the 3-arity default form and the
  # nil cases below raise instead of matching.
  test "Installer.target_dir/1 treats a present nil option as absent" do
    user_home_skills = Path.join([System.user_home!(), ".foreman", "skills"])

    assert Installer.target_dir([]) == user_home_skills
    assert Installer.target_dir(home_dir: nil) == user_home_skills
    assert Installer.target_dir(home_dir: nil, target_dir: nil) == user_home_skills
    assert Installer.target_dir(target_dir: nil) == user_home_skills

    # A real value still wins over both nils, and `:target_dir` wins over `:home_dir`.
    assert Installer.target_dir(home_dir: "/h", target_dir: "/t") == "/t"
    assert Installer.target_dir(home_dir: "/h") == "/h/.foreman/skills"
  end

  # CodeRabbit #3: an ABSENT source directory is an error, not an empty bundle. `File.ls/1`
  # distinguishes the two causes -- `{:ok, []}` for an existing-but-empty directory,
  # `{:error, :enoent}` for one that is not there -- so folding them together (§5.3) is what let
  # a broken bundle source install ZERO skills while reporting a successful no-op. An empty
  # directory still means "nothing to copy": that is a configuration, not a defect, and it is the
  # ordinary state once the bundle is already installed.
  test "maybe_install/1 errors on an absent source but noops on an empty one" do
    missing_source = Path.join(make_temp_dir!("skills-source-missing"), "nope")
    dest_home = make_temp_dir!("skills-source-missing-home")

    assert {:error, {:source_dir_missing, ^missing_source}} =
             Installer.maybe_install(source_dir: missing_source, home_dir: dest_home)

    empty_source = make_temp_dir!("skills-source-empty")

    assert {:ok, :noop} = Installer.maybe_install(source_dir: empty_source, home_dir: dest_home)

    # Absent and unreadable are also distinct from each other (§5.3), and absent is distinct from
    # the `:bundled_skills_missing` the auto-detected path reports -- see
    # `test "the auto-detected bundle reports a missing subtree as a bundle problem"` below.
    file_as_dir = Path.join(make_temp_dir!("skills-source-blocked"), "not-a-dir")
    File.write!(file_as_dir, "a regular file is not a directory")

    assert {:error, {:list_skills_failed, ^file_as_dir, :enotdir}} =
             Installer.maybe_install(source_dir: file_as_dir, home_dir: dest_home)
  end

  # The auto-detected bundle is the case CodeRabbit's finding was actually about: a release that
  # ships `priv/` without `priv/defaults/skills` used to install nothing and say nothing. It gets
  # its own error code because the cause is a packaging defect, not a bad operator argument.
  # Reached by pointing `ForemanServer.Skills.Digest`'s sibling resolver at a tree that is not
  # there, which is what `bundled_skills_source/0` does in a release.
  test "the auto-detected bundle reports a missing subtree as a bundle problem" do
    dest_home = make_temp_dir!("skills-bundle-missing-home")
    gone = Path.join(make_temp_dir!("skills-bundle-missing"), "priv/defaults/skills")
    refute File.exists?(gone)

    # No `:source_dir` key, so the resolver decides the path -- and `:bundled_skills_dir` is the
    # one override that lets the release scenario (priv/ shipped WITHOUT the skills subtree) be
    # exercised here instead of only inside a real release build.
    assert {:error, {:bundled_skills_missing, ^gone}} =
             Installer.maybe_install(home_dir: dest_home, bundled_skills_dir: gone)

    # A bundle directory that EXISTS but holds no skills is the other fact: nothing to install,
    # not a failure. This is the distinction the finding asked for.
    present = make_temp_dir!("skills-bundle-present")

    assert {:ok, :noop} =
             Installer.maybe_install(home_dir: dest_home, bundled_skills_dir: present)
  end

  # `ForemanServer.Skills.Digest.digest/2` is the function BOTH `@bundled_skills_fingerprint`
  # and `__mix_recompile__?/0` are computed from (installer.ex:90 and :132), so exercising it
  # here exercises the shipped fingerprint rather than a copy of its logic. It digests SKILL.md
  # CONTENT, not the directory listing: a names-only digest assigns the same value to two trees
  # that differ only in file body, which is why `__mix_recompile__?/0` answering `false` after a
  # bundle edit let a stale `@bundled_skill_dirs` ship in a release. Replacing the body
  # expression with `name` must make this fail -- that is the proof it discriminates.
  test "the skills digest fingerprints skill content, not just skill names" do
    base = make_temp_dir!("skills-fingerprint")

    build = fn label, name, body ->
      dir = Path.join(base, label)
      skill = Path.join(dir, name)
      File.mkdir_p!(skill)

      if body do
        File.write!(Path.join(skill, "SKILL.md"), body)
      else
        File.write!(Path.join(skill, "NOTES.md"), "a skill directory with no SKILL.md")
      end

      dir
    end

    over = fn dir ->
      dir
      |> File.ls!()
      |> Enum.sort()
      |> then(&ForemanServer.Skills.Digest.digest(&1, dir))
    end

    pristine = build.("pristine", "alpha-skill", "---\nname: alpha\n---\noriginal body\n")
    edited = build.("edited", "alpha-skill", "---\nname: alpha\n---\nchanged body\n")
    stripped = build.("stripped", "alpha-skill", nil)
    untouched_copy = build.("identical", "alpha-skill", "---\nname: alpha\n---\noriginal body\n")

    # Same skill NAMES, different content -> different digest. This is the regression: a
    # names-only digest makes this equality hold and the bundle edit never recompiles.
    assert over.(pristine) != over.(edited)

    # A SKILL.md that vanished is a change too, not a silent no-op.
    assert over.(pristine) != over.(stripped)

    # The digest is a pure function of the tree, so a byte-identical tree is stable. Without
    # this the two inequalities above could be satisfied by anything that varies per call.
    assert over.(pristine) == over.(untouched_copy)
    assert is_binary(over.(pristine))
  end

  defp make_temp_dir!(prefix) do
    directory = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end
end
