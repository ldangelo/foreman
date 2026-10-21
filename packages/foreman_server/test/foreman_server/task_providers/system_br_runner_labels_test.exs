defmodule ForemanServer.TaskProviders.SystemBrRunnerLabelsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.SystemBrRunner

  setup do
    original_path = System.get_env("PATH") || ""

    dir =
      Path.join(
        System.tmp_dir!(),
        "system_br_runner_labels_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    script = Path.join(dir, "br")
    File.write!(script, "#!/bin/sh\nfor arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n")
    File.chmod!(script, 0o755)
    System.put_env("PATH", dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp create_argv(extra) do
    payload =
      Map.merge(
        %{
          title: "Gap",
          type: "bug",
          priority: 1,
          description: "d",
          agent_context: "{}"
        },
        extra
      )

    assert {:ok, %{stdout: stdout, exit_code: 0}} =
             SystemBrRunner.cmd({:create, payload}, %{database_path: "/abs/beads.db"}, [])

    String.split(stdout, "\n", trim: true)
  end

  test "absent :labels adds no --labels flag" do
    argv = create_argv(%{})
    refute "--labels" in argv
    assert List.last(argv) == "--json"
  end

  test "empty :labels adds no --labels flag" do
    argv = create_argv(%{labels: []})
    refute "--labels" in argv
    assert List.last(argv) == "--json"
  end

  test "populated :labels becomes one comma-joined --labels value before --json" do
    argv = create_argv(%{labels: ["foreman-exec", "foreman-gap"]})

    assert Enum.slice(argv, -3, 3) == ["--labels", "foreman-exec,foreman-gap", "--json"]
  end

  test "a label containing a comma raises ArgumentError" do
    assert_raise ArgumentError, ~r/:labels.*comma/s, fn ->
      create_argv(%{labels: ["ok", "a,b"]})
    end
  end

  test "an empty-string or non-binary label raises ArgumentError" do
    assert_raise ArgumentError, ~r/:labels/, fn -> create_argv(%{labels: [""]}) end
    assert_raise ArgumentError, ~r/:labels/, fn -> create_argv(%{labels: [:atom]}) end
  end

  test "a non-list :labels raises ArgumentError" do
    assert_raise ArgumentError, ~r/:labels/, fn -> create_argv(%{labels: "foreman-exec"}) end
  end
end
