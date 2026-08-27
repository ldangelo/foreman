defmodule ForemanServer.TaskProviders.SystemBrRunnerDbLeafTest do
  @moduledoc """
  `br` rejects a directory passed to `--db` with CONFIG_ERROR
  ("expected a regular file, not a symlink or special file", exit 7).
  Operators register the `.beads` directory, so the runner appends the
  conventional `beads.db` leaf at its single `--db` funnel.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.SystemBrRunner

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "br_db_leaf_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    {:ok, temp_dir: temp_dir}
  end

  test "appends beads.db when the configured database_path is a directory", %{
    temp_dir: temp_dir
  } do
    beads_dir = Path.join(temp_dir, ".beads")
    File.mkdir_p!(beads_dir)
    File.write!(Path.join(beads_dir, "beads.db"), "")

    argv = capture_argv(temp_dir, %{database_path: beads_dir})

    assert Path.join(beads_dir, "beads.db") in argv,
           "expected the beads.db leaf to be appended, got: #{inspect(argv)}"

    refute beads_dir in argv,
           "the bare directory must never reach br: #{inspect(argv)}"
  end

  test "leaves an explicit database file path unchanged", %{temp_dir: temp_dir} do
    db_file = Path.join(temp_dir, "beads.db")
    File.write!(db_file, "")

    argv = capture_argv(temp_dir, %{database_path: db_file})

    assert db_file in argv
    refute Path.join(db_file, "beads.db") in argv
  end

  test "string-keyed config resolves the leaf identically", %{temp_dir: temp_dir} do
    beads_dir = Path.join(temp_dir, ".beads")
    File.mkdir_p!(beads_dir)

    argv = capture_argv(temp_dir, %{"database_path" => beads_dir})

    assert Path.join(beads_dir, "beads.db") in argv
  end

  defp capture_argv(temp_dir, project_config) do
    with_fake_br(temp_dir, ~s(printf '%s\\n' "$@"), fn ->
      assert {:ok, %{stdout: stdout, exit_code: 0}} =
               SystemBrRunner.cmd({:coordination_status, %{}}, project_config)

      String.split(stdout, "\n", trim: true)
    end)
  end

  defp with_fake_br(temp_dir, body, fun) do
    script_path = Path.join(temp_dir, "br")
    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end
end
