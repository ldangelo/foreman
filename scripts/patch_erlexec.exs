# Applies Foreman's erlexec patch to the erlexec hex dependency in the calling Mix
# project's deps directory. Loaded from `packages/*/mix.exs` and wired into the `deps.get`,
# `deps.loadpaths` and `deps.compile` aliases, so every path that fetches, resolves or
# builds deps (fresh clone, CI, `mix test`, `mix compile`, `mix deps.compile erlexec`) ends
# up with a patched erlexec. The patch step always runs BEFORE the compile that builds the
# port (it removes the stale build), except after `deps.get`, which only fetches.
#
# Why: erlexec 2.3.4 lets the parent and the child both call setpgid() after fork().
# On macOS, concurrent calls can both fail, so the child exits 1 with "Cannot set
# effective group to 0: Operation not permitted" and the agent process never starts.
# See packages/jido_harness/patches/erlexec/process-group-startup.patch and the
# "erlexec process-group startup patch" section of packages/jido_harness/UPSTREAM_PIN.md.
#
# Idempotent: a patched tree is recognised by BOTH the handshake's error string and the
# tolerance check, so a half-applied or hand-edited file is never taken for patched.
# Loud: if the patch cannot be applied the build stops, so an unpatched erlexec never
# looks healthy.
defmodule ErlexecPatch do
  @markers ["Process group startup parent unavailable", "getpgrp() != gid"]
  @patch Path.expand("../packages/jido_harness/patches/erlexec/process-group-startup.patch", __DIR__)

  def apply(_args \\ []) do
    dep_dir = Path.join(Mix.Project.deps_path(), "erlexec")
    source = Path.join(dep_dir, "c_src/exec_impl.cpp")

    cond do
      # Deps not fetched yet; Mix reports that itself, and `deps.get` re-runs this step.
      not File.regular?(source) -> :ok
      patched?(File.read!(source)) -> :ok
      true -> patch!(dep_dir)
    end
  end

  defp patched?(contents), do: Enum.all?(@markers, &String.contains?(contents, &1))

  defp patch!(dep_dir) do
    unless File.regular?(@patch), do: Mix.raise("erlexec patch missing: #{@patch}")

    unless System.find_executable("patch") do
      Mix.raise("""
      The `patch` executable is required to apply #{Path.relative_to_cwd(@patch)} to erlexec
      (without it erlexec would be built without the process-group startup fix).
      """)
    end

    # Dry-run first: a partially applied patch would leave the markers behind and make
    # the next run believe the tree is patched.
    args = ["-p1", "--forward", "-d", dep_dir, "-i", @patch]

    with {_out, 0} <- System.cmd("patch", ["--dry-run" | args], stderr_to_stdout: true),
         {_out, 0} <- System.cmd("patch", args, stderr_to_stdout: true) do
      invalidate_build(dep_dir)
      Mix.shell().info("* patched erlexec (process-group startup): #{dep_dir}")
    else
      {out, status} ->
        Mix.raise("""
        Could not apply #{Path.relative_to_cwd(@patch)} to #{dep_dir} (patch exit #{status}).
        erlexec would be built WITHOUT the process-group startup fix, which lets spawned
        agent processes fail intermittently on macOS. Re-fetch the dependency
        (rm -rf #{dep_dir} && mix deps.get) or update the patch.

        #{out}
        """)
    end
  end

  # A patched source must not be shadowed by previously compiled objects or ports, in ANY
  # Mix environment: `_build/<env>/lib/erlexec` is per-env, the objects and port are not.
  defp invalidate_build(dep_dir) do
    build_root = Path.dirname(Mix.Project.build_path())

    for path <- Path.wildcard(Path.join([build_root, "*", "lib", "erlexec"])) do
      File.rm_rf!(path)
    end

    for pattern <- ["c_src/*.o", "c_src/*.d", "priv/*/exec-port", "priv/native"],
        path <- Path.wildcard(Path.join(dep_dir, pattern)) do
      File.rm_rf!(path)
    end

    :ok
  end
end
