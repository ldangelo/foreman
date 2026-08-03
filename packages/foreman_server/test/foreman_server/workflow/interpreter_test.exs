defmodule ForemanServer.Workflow.InterpreterTest do
  use ExUnit.Case, async: false

  @template_names ~w(discover assess plan implement verify release)

  test "load!/1 loads each bundled workflow template" do
    Enum.each(@template_names, fn template_name ->
      path = Application.app_dir(:foreman_server, "priv/defaults/workflows/#{template_name}.yaml")

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["name"] == template_name
      assert is_binary(workflow["description"])
      assert is_list(workflow["phases"])

      assert Enum.any?(workflow["phases"], fn phase ->
               is_map(phase) and is_binary(phase["name"]) and phase["name"] != ""
             end)
    end)
  end

  test "load!/1 raises when phases are missing" do
    path = write_temp_yaml!("name: broken\ndescription: phases missing\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define top-level keys \"name\" and \"phases\"/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  defp write_temp_yaml!(contents) do
    directory =
      Path.join(System.tmp_dir!(), "workflow-interpreter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    path = Path.join(directory, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
