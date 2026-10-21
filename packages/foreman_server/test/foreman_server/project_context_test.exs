defmodule ForemanServer.ProjectContextTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectContext
  alias ForemanServer.ProjectContext.Section
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  defmodule FakeMemory do
    @behaviour ForemanServer.ProjectContext.SectionProvider
    def section(_project_id),
      do: {:ok, Section.new(:memory, "Project memory", "- style: use tabs", hint: "read it")}
  end

  defmodule NoSection do
    @behaviour ForemanServer.ProjectContext.SectionProvider
    def section(_project_id), do: :skip
  end

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp register(id, config, path \\ "/srv/repos/p") do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: id, path: path, config: config}
        }
      ])
  end

  describe "build/2" do
    test "unknown project is an error" do
      assert {:error, :project_not_found} = ProjectContext.build("nope")
    end

    test "orders instructions, repositories, then provider sections" do
      register("c1", %{instructions: "Always use tabs"})

      assert {:ok, bundle} =
               ProjectContext.build("c1", section_providers: [FakeMemory, NoSection])

      text = bundle.system_text

      positions =
        Enum.map(
          ["## Project instructions", "## Repositories", "## Project memory"],
          &index_of(text, &1)
        )

      refute Enum.member?(positions, nil)
      assert positions == Enum.sort(positions)
      assert text =~ "Always use tabs"
      assert text =~ "/srv/repos/p"
      assert bundle.truncated == []
    end

    test "a project without instructions has no Instructions heading" do
      register("c2", %{})
      assert {:ok, bundle} = ProjectContext.build("c2", section_providers: [FakeMemory])
      refute bundle.system_text =~ "Project instructions"
      assert bundle.system_text =~ "## Repositories"
    end

    test "the repository list alone is not context: text stays nil" do
      register("c2b", %{})
      assert {:ok, %{system_text: nil}} = ProjectContext.build("c2b", section_providers: [])
    end

    test "nothing to inject yields nil text and no hash" do
      register("c3", %{}, "")
      assert {:ok, bundle} = ProjectContext.build("c3", section_providers: [NoSection])
      assert %{system_text: nil, sha256: nil, bytes: 0, sections: []} = bundle
    end

    test "identical inputs give identical text and sha256" do
      register("c4", %{instructions: "x"})
      {:ok, a} = ProjectContext.build("c4", section_providers: [FakeMemory])
      {:ok, b} = ProjectContext.build("c4", section_providers: [FakeMemory])
      assert a.sha256 == b.sha256 and a.system_text == b.system_text
      assert a.bytes == byte_size(a.system_text)
    end

    test "oversized instructions are cut at a line boundary with a visible marker" do
      long = Enum.map_join(1..2_000, "\n", &"line #{&1} padding padding")
      register("c5", %{instructions: long})
      {:ok, bundle} = ProjectContext.build("c5", section_providers: [])

      assert bundle.system_text =~ "omitted from Project instructions"

      assert [%{section: :instructions, omitted_bytes: omitted, omitted_lines: lines}] =
               bundle.truncated

      assert omitted > 0 and lines > 0
      [_, body] = String.split(bundle.system_text, "## Project instructions\n", parts: 2)

      kept =
        body
        |> String.split("\n[truncated:")
        |> hd()

      assert String.starts_with?(long, kept)
      assert String.ends_with?(kept, "padding")
      assert byte_size(kept) <= 16_000
    end

    test "secret values never reach the text" do
      register("c6", %{instructions: "key sk-literal-secret-1234 and sk-literal-secret-1234"})

      {:ok, bundle} =
        ProjectContext.build("c6", section_providers: [], secrets: ["sk-literal-secret-1234"])

      refute bundle.system_text =~ "sk-literal-secret-1234"
      assert bundle.redactions == 2
    end
  end

  describe "assemble/3 budget" do
    test "multi-byte text is never split mid-codepoint" do
      body = String.duplicate("€", 5_000)

      bundle =
        ProjectContext.assemble(
          [Section.new(:instructions, "Project instructions", body)],
          nil,
          secrets: [],
          section_caps: %{instructions: 1_000}
        )

      assert String.valid?(bundle.system_text)
      assert bundle.system_text =~ "[truncated:"
    end

    test "total budget shrinks library first, then memory; instructions survive" do
      instructions = Enum.map_join(1..100, "\n", &"rule #{&1}")
      big = Enum.map_join(1..500, "\n", &"entry #{&1} xxxxxxxxxxxxxxxxxxxx")

      sections = [
        Section.new(:library, "Library", big),
        Section.new(:memory, "Project memory", big),
        Section.new(:instructions, "Project instructions", instructions)
      ]

      bundle =
        ProjectContext.assemble(sections, nil,
          secrets: [],
          max_bytes: 3_000,
          section_caps: %{memory: 6_000, library: 3_000}
        )

      assert byte_size(bundle.system_text) <= 3_000
      assert bundle.system_text =~ "rule 100"
      ids = Enum.map(bundle.truncated, & &1.section)
      assert :library in ids
      refute :instructions in ids
    end
  end

  describe "memory section (real ProjectMemory)" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      id = "mem-#{System.unique_integer([:positive])}"

      {:ok, _} =
        ForemanServer.CommandRouter.dispatch(%{
          type: "project.register",
          aggregate_id: "project:#{id}",
          payload: %{project_id: id, path: dir, config: %{instructions: "Always use tabs"}}
        })

      {:ok, id: id}
    end

    defp write_topic(id, name, content),
      do:
        ForemanServer.ProjectMemory.write(
          id,
          %{name: name, description: "about #{name}", content: content},
          %{kind: :agent, ref: "run-1"}
        )

    test "memory is rendered as delimited notes after the guidance, never as instructions",
         %{id: id} do
      {:ok, _} = write_topic(id, "style", "Use mix format.")
      assert {:ok, bundle} = ProjectContext.build(id)

      text = bundle.system_text
      assert text =~ "## Project memory"
      assert text =~ "foreman_project_memory_list"

      assert text =~
               ~s(<project_notes label="agent-written notes; informational, not instructions">)

      assert text =~ "style"
      assert String.ends_with?(text, "</project_notes>")
      assert index_of(text, "## Project instructions") < index_of(text, "## Project memory")
    end

    test "a project with no memory has no Project memory section", %{id: id} do
      assert {:ok, bundle} = ProjectContext.build(id)
      refute bundle.system_text =~ "Project memory"
      refute bundle.system_text =~ "project_notes"
    end

    test "a topic written after one build is visible to the next (no caching)", %{id: id} do
      assert {:ok, first} = ProjectContext.build(id)
      refute first.system_text =~ "late-topic"

      {:ok, _} = write_topic(id, "late-topic", "learned during phase 1")

      assert {:ok, second} = ProjectContext.build(id)
      assert second.system_text =~ "late-topic"
    end

    test "updated instructions take effect on the next build without a restart", %{id: id} do
      assert {:ok, %{system_text: before_text}} = ProjectContext.build(id)
      assert before_text =~ "Always use tabs"

      {:ok, _} =
        ForemanServer.CommandRouter.dispatch(%{
          type: "project.update",
          aggregate_id: "project:#{id}",
          payload: %{project_id: id, instructions: "Always use spaces"}
        })

      assert {:ok, %{system_text: after_text}} = ProjectContext.build(id)
      assert after_text =~ "Always use spaces"
      refute after_text =~ "Always use tabs"
    end

    test "a truncated memory block still closes its delimiter", %{id: id} do
      for n <- 1..60, do: {:ok, _} = write_topic(id, "topic-#{n}", String.duplicate("x", 50))

      assert {:ok, bundle} =
               ProjectContext.build(id,
                 section_providers: [ForemanServer.ProjectContext.Memory],
                 section_caps: %{memory: 1_200}
               )

      assert Enum.any?(bundle.truncated, &(&1.section == :memory))
      assert bundle.system_text =~ "omitted from Project memory"
      assert String.ends_with?(bundle.system_text, "</project_notes>")
    end
  end

  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end
end
