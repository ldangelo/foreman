defmodule ForemanServer.ProjectMemory.GuidanceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.ProjectMemory.{Error, Guidance, Store}

  defp write(dir, content),
    do: Store.write(dir, [], %{name: "note", description: "d", content: content})

  test "500 copies of the same line are :content_not_durable (repeated_lines) and nothing is stored",
       %{tmp_dir: dir} do
    content = String.duplicate("the same noisy log line\n", 500)

    assert {:error, %Error{code: :content_not_durable, details: %{reason: :repeated_lines}}} =
             write(dir, content)

    refute File.exists?(Path.join(dir, ".foreman/memory/note.md"))
  end

  test "a pasted .env of secrets is :content_not_durable (mostly_secrets)", %{tmp_dir: dir} do
    env = Enum.map_join(1..20, "\n", &"SVC#{&1}_API_KEY=sk-#{String.duplicate("x", 40)}#{&1}")

    assert {:error, %Error{code: :content_not_durable, details: %{reason: :mostly_secrets}}} =
             write(dir, env)

    refute File.exists?(Path.join(dir, ".foreman/memory/note.md"))
  end

  test "a short note (<200 bytes) with one secret is accepted and redacted (under the 200-byte exemption)",
       %{tmp_dir: dir} do
    content = "Deploy needs API_KEY=abc set"
    assert byte_size(content) < 200
    assert {:ok, entry} = write(dir, content)
    assert entry.redactions == 1
    refute File.read!(Path.join(dir, ".foreman/memory/note.md")) =~ "API_KEY=abc"
  end

  test "a normal 2 KB markdown note with three distinct bullet lists passes", %{tmp_dir: dir} do
    section = fn title ->
      "## #{title}\n" <>
        Enum.map_join(1..8, "\n", &"- #{title} fact number #{&1} that matters to the project") <>
        "\n"
    end

    content = Enum.map_join(["Conventions", "Decisions", "Gotchas"], "\n", section)
    assert byte_size(content) > 800
    assert {:ok, _} = write(dir, content)
  end

  test "guidance fits the E3 budget and names the tools it tells agents to call" do
    text = Guidance.text()
    assert byte_size(text) <= 1200
    assert text =~ "foreman_project_memory_list"
    assert text =~ "foreman_project_memory_forget"
    assert Guidance.tool_description(:write) =~ text
  end
end
