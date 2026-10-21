defmodule ForemanServer.Overview.Tabs.Library do
  @moduledoc """
  Library tab: one row per entry of the project's library (`ForemanServer.Library`),
  sorted by name. Rows are string-keyed and read-only; adding, replacing and
  removing stay on the library API/CLI.

  An unknown project has no library, so its tab is an empty list; any other
  failure (unreadable disk) raises and `Overview.Tabs` reports the tab as
  `provider_failed` rather than as an empty library.
  """

  @behaviour ForemanServer.Overview.TabProvider

  alias ForemanServer.Library
  alias ForemanServer.Library.{Entry, Error}

  @impl true
  def tab, do: :library

  @impl true
  def rows(project_id) do
    case Library.list(project_id) do
      {:ok, entries} -> Enum.map(entries, &row/1)
      {:error, %Error{code: :project_not_found}} -> []
      {:error, %Error{} = error} -> raise "library unreadable: #{error.code}: #{error.message}"
    end
  end

  defp row(%Entry{} = entry) do
    %{
      "entry_id" => entry.entry_id,
      "name" => entry.name,
      "kind" => Atom.to_string(entry.kind),
      "file_count" => entry.file_count,
      "bytes" => entry.bytes,
      "created_at" => entry.created_at
    }
  end
end
