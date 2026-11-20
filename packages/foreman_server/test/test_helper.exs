# The test database is shared across runs and ProjectionStore rebuilds its whole
# read model from the event log at boot. Without a reset every run inherits every
# prior run's events (48k+ observed), which makes read-after-write assertions time
# out on projection catch-up and makes randomly generated ids collide with tasks
# left by earlier runs.
#
# `mix test` boots the app before it requires this file, and the boot is what replays
# the log: ProjectionStore rebuilds the projection from it and the Dispatcher
# re-admits the runs it says are in flight. So the `test` alias in mix.exs empties the
# log BEFORE the app starts (foreman-a4ec2). Emptied from here, the in-memory
# projection, the aggregate actors and the executors the boot started for the previous
# run's tasks would still carry that run: a second local `mix test` would start from
# the last run's leftovers while CI (fresh DB) never does.
#
# Nothing is reset here. A log that is not empty means the alias did not run (the suite
# was started some other way) or another `mix test` shares this database; either way the
# app has replayed state this run did not create, so stop instead of testing on it.
{:ok, replayed} = ForemanServer.EventStore.read_all_streams_forward(0, 1)

if replayed != [] do
  raise "the event store was not empty when the app booted, so ProjectionStore and the " <>
          "Dispatcher replayed a run this suite did not create. `mix test` empties the log " <>
          "before the app starts (the `test` alias in mix.exs): run the suite with `mix test`, " <>
          "and give every concurrent run its own DATABASE_URL (foreman-a4ec2)"
end

# Give this VM a private temp directory. Tests build scratch paths under
# `System.tmp_dir!/0` as "<prefix>-#{System.unique_integer([:positive])}", but that counter
# restarts at 1 in every VM, so two `mix test` runs on one machine (parallel CI jobs, several
# worktrees, a developer's second terminal) hand out the same names in the shared system temp
# dir. One run's `on_exit` cleanup then deletes the other's repo or worktree under it: an agent
# whose cwd vanished exits 1 ("agent_failed ... exit_status 256"), a prompt log disappears
# mid-test, a `git push` finds no repository. `System.tmp_dir!/0` and every child process read
# TMPDIR, so pointing it at a per-VM directory removes the collision for all ~200 sites at once.
#
# The directory is created fresh and never cleared: an OS pid is reused within minutes, so a bare
# `fm-test-<pid>` can already exist as the leftover of an earlier VM, and `File.rm_rf!/1` on a
# leftover that holds a read-only tree (a Library entry) raised "file already exists" here, before
# any test ran. See `ForemanServer.TestSupport.Tmp`.
vm_tmp = ForemanServer.TestSupport.Tmp.claim_vm_dir!(System.tmp_dir!())
System.put_env("TMPDIR", vm_tmp)
ExUnit.after_suite(fn _ -> ForemanServer.TestSupport.Tmp.release_vm_dir(vm_tmp) end)

# `:eventstore` logs every append, notification and subscription push at :debug.
# It is ~20k lines of a CI log, and because the Beads lease stream id embeds the
# absolute DB path (`beads_db_lease:<path>`) it also puts that path into
# `capture_log` output, which SideChannelCaptureTest asserts must never contain it.
Logger.put_application_level(:eventstore, :warning)

ExUnit.configure(
  exclude: [:langfuse, :external_llm, :docker],
  assert_receive_timeout: 1_000
)

# A run with a hand-written id left in the shared ProjectionStore outlives its test and is read by
# whichever later test types the same id (foreman-b8qjy, foreman-fhe9o): fail the suite and name
# the module that left it. The formatter half is registered by the `test` alias in mix.exs.
ForemanServer.TestSupport.ProjectionLeakGuard.install!()

# The kickoff skill preflight (TRD-022) refuses a run whose `command:` names a skill the harness
# cannot find. The suite's workflows invent skill names, and the developer's real ~/.pi must not
# decide whether they pass, so `:skill_home` points the preflight at a private home whose pi agent
# directory holds one loadable skill (pi loads a SKILL.md only with a frontmatter `description`)
# per skill any test source, fixture or stock workflow names. The one file that means some of its
# names to be ABSENT, run_executor_skill_preflight_test.exs, is not scanned, so the default home
# can never create a skill that test expects to be missing; it, and any other test that needs a
# skill absent (or present only somewhere else), overrides `:skill_home` itself.
skill_home = Path.join(vm_tmp, "skill-home")

skill_sources =
  (Path.wildcard("test/**/*.{exs,yaml}") ++ Path.wildcard("priv/defaults/workflows/*.yaml"))
  |> Enum.reject(&String.ends_with?(&1, "run_executor_skill_preflight_test.exs"))

for path <- skill_sources,
    [_, name] <- Regex.scan(~r{/skill:([A-Za-z0-9][A-Za-z0-9._-]*)}, File.read!(path)) do
  dir = Path.join([skill_home, ".pi", "agent", "skills", name])
  File.mkdir_p!(dir)
  File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: test skill\n---\n")
end

Application.put_env(:foreman_server, :skill_home, skill_home)

# The kickoff provider preflight (TRD-022) requires the harness of every `command:` phase to be
# installed, and `Jido.Harness.status(:pi)` decides that by running the `pi` found on PATH. A
# machine (or CI runner) with no pi, or with a different one, must not change what the suite
# does, so the pi adapter is pointed at a stand-in executable of this VM that answers the two
# probes the adapter makes (`--version`, and `--help` which must mention `--mode`). It is the
# REAL adapter probing a fake binary: tests that need pi absent stub `:providers` themselves
# (as run_executor_test.exs and run_executor_skill_preflight_test.exs do).
fake_pi = Path.join(vm_tmp, "fake-pi")
File.write!(fake_pi, "#!/bin/sh\necho 'pi 0.0.0-test'\necho '  --mode <mode>'\n")
File.chmod!(fake_pi, 0o755)

Application.put_env(
  :jido_harness,
  :provider_config,
  Map.put(Map.new(Application.get_env(:jido_harness, :provider_config, %{})), :pi, %{
    cli_path: fake_pi
  })
)

ExUnit.start()
