defmodule ForemanServerWeb.OperatorRunDashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "operator-run-dashboard-live-token"
  @xss_name "<script>x</script>.md"
  @trd "docs/TRD/TRD-x.md"

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_path = System.get_env("PATH")
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    root = Path.join(System.tmp_dir!(), "run-dash-live-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    shim = Path.join(root, "shim")
    log = Path.join(root, "git.log")
    File.mkdir_p!(repo)
    File.mkdir_p!(shim)
    File.write!(log, "")

    base = init_repo(repo)

    for {path, body} <- [
          {@trd, "# TRD\nadded trd line\n"},
          {@xss_name, "evil <script>alert(1)</script> body\n"},
          {"big.md", String.duplicate("0123456789abcdef\n", 3_000)}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), body)
    end

    commit_all(repo, "change")

    # Counting fake git: logs every invocation, then runs the real git. A file named slow.txt makes
    # its diff outlast the bounded read.
    real_git = System.find_executable("git")
    File.write!(Path.join(repo, "slow.txt"), "slow\n")
    commit_all(repo, "slow")

    File.write!(Path.join(shim, "git"), """
    #!/bin/sh
    echo "$@" >> "#{log}"
    case "$*" in *..HEAD*slow.txt*) sleep 4;; esac
    exec "#{real_git}" "$@"
    """)

    File.chmod!(Path.join(shim, "git"), 0o755)
    System.put_env("PATH", shim <> ":" <> previous_path)

    seed_run("run-a", repo, base)
    seed_run("run-b", nil, nil)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      ProjectionStoreReset.reset!()
      File.rm_rf!(root)

      if previous_token,
        do: Application.put_env(:foreman_server, :api_bearer_token, previous_token),
        else: Application.delete_env(:foreman_server, :api_bearer_token)
    end)

    {:ok, log: log, repo: repo, shim: shim}
  end

  defp url(params), do: "/dashboard/runs?" <> URI.encode_query(params)

  defp git_calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  describe "deep link (TRD-013)" do
    test "tab=changes&file opens the Changes tab with the added file's diff", %{log: log} do
      {:ok, view, html} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))

      assert html =~ "Diff of #{@trd}"
      assert html =~ "added trd line"
      assert has_element?(view, "#change-preview pre", "added trd line")
      assert has_element?(view, "#change-preview", "not the file itself")

      # The dead render ran no git. The connected mount lists the changes once and reads the diff
      # once (which re-lists to verify the file is changed); handle_params added nothing.
      calls = git_calls(log)
      assert Enum.count(calls, &String.contains?(&1, "--name-status")) == 2
      assert Enum.count(calls, &String.contains?(&1, "..HEAD -- " <> @trd)) == 1
    end

    test "run_id alone shows that run's detail (AC-004-3)" do
      {:ok, view, html} = live(build_conn(), url(run_id: "run-b", token: @token))
      assert html =~ "Run run-b"
      assert has_element?(view, "h3", "Summary")
    end

    test "an unknown tab renders Summary and runs no git", %{log: log} do
      {:ok, _view, html} = live(build_conn(), url(run_id: "run-a", tab: "bogus", token: @token))
      assert html =~ "<h3>Summary</h3>"
      refute html =~ "Code changes and PR evidence"
      assert git_calls(log) == []
    end

    test "a path-traversal file is refused without reaching git", %{log: log} do
      {:ok, view, _} =
        live(
          build_conn(),
          url(run_id: "run-a", tab: "changes", file: "../../etc/passwd", token: @token)
        )

      assert render(view) =~ "not a safe path"
      refute Enum.any?(git_calls(log), &String.contains?(&1, "etc/passwd"))
    end

    test "a file that is not among the changed files is unavailable" do
      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: "README.md", token: @token))

      assert has_element?(view, "#change-preview", "not among the run's changed files")
    end

    test "the dead render runs no git", %{log: log} do
      conn = get(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))
      assert html_response(conn, 200) =~ "Run run-a"
      assert git_calls(log) == []
    end

    test "switching run clears the file" do
      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))

      assert has_element?(view, "#change-preview")
      render_click(view, "select-run", %{"run-id" => "run-b"})
      refute has_element?(view, "#change-preview")
      assert render(view) =~ "Run run-b"
    end

    test "reloading the same URL reproduces the state" do
      path = url(run_id: "run-a", tab: "changes", file: @trd, token: @token)
      {:ok, _, first} = live(build_conn(), path)
      {:ok, _, second} = live(build_conn(), path)
      assert first =~ "added trd line" and second =~ "added trd line"
      assert first =~ "Diff of #{@trd}" and second =~ "Diff of #{@trd}"
    end

    test "the periodic tick does not re-read the preview", %{log: log} do
      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))

      before = Enum.count(git_calls(log), &String.contains?(&1, "..HEAD -- " <> @trd))
      assert before == 1

      send(view.pid, :refresh)
      assert render(view) =~ "added trd line"

      assert Enum.count(git_calls(log), &String.contains?(&1, "..HEAD -- " <> @trd)) == before
    end
  end

  describe "per-file diff view (TRD-014)" do
    test "file names and diff bodies are escaped" do
      {:ok, view, html} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @xss_name, token: @token))

      refute html =~ "<script>x</script>"
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "Diff of &lt;script&gt;x&lt;/script&gt;.md"
      refute has_element?(view, "script")
    end

    test "a diff over the limit shows the truncation notice with byte counts" do
      {:ok, _view, html} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: "big.md", token: @token))

      assert [_, shown, total] = Regex.run(~r/Diff truncated: showing (\d+) of (\d+) bytes/, html)
      assert String.to_integer(shown) <= 24_000
      assert String.to_integer(total) > 48_000
    end

    test "git missing renders the unavailable message beside the list state", %{shim: shim} do
      File.rm!(Path.join(shim, "git"))
      System.put_env("PATH", shim)

      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))

      html = render(view)
      assert html =~ "Change evidence unavailable"
      assert html =~ "Diff unavailable"
    end

    test "a git failure between the list and the diff renders its own message" do
      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: @trd, token: @token))

      # `preview_bounded/3` only returns :git_unavailable when git disappears between its own
      # reads, so the typed result is injected into the live process.
      :sys.replace_state(view.pid, fn state ->
        update_in(
          state.socket,
          &Phoenix.Component.assign(&1, :file_preview, {:error, :git_unavailable})
        )
      end)

      send(view.pid, :ignored)
      assert render(view) =~ "git is not available on the server"
    end

    test "a diff that outlasts the bound renders the timeout message" do
      {:ok, view, _} =
        live(build_conn(), url(run_id: "run-a", tab: "changes", file: "slow.txt", token: @token))

      assert render(view) =~ "timed out"
    end

    test "no token in the URL means no token in any link" do
      conn = put_req_header_token(build_conn())

      {:ok, view, _} = live(conn, "/dashboard/runs?run_id=run-a&tab=changes")
      html = render(view)
      assert html =~ ~s(href="/dashboard/runs?run_id=run-a&amp;tab=changes&amp;file=)
      refute html =~ "token="
    end

    test "clicking a file patches to the file= URL and shows its diff" do
      {:ok, view, _} = live(build_conn(), url(run_id: "run-a", tab: "changes", token: @token))
      refute has_element?(view, "#change-preview")

      view |> element("a", @trd) |> render_click()

      assert_patch(view, url(run_id: "run-a", tab: "changes", file: @trd, token: @token))
      assert has_element?(view, "#change-preview pre", "added trd line")
    end
  end

  defp put_req_header_token(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  defp init_repo(repo) do
    {_, 0} = System.cmd("/usr/bin/env", ["git", "init", "-q"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "base\n")
    commit_all(repo, "base")
    {sha, 0} = System.cmd("/usr/bin/env", ["git", "rev-parse", "HEAD"], cd: repo)
    String.trim(sha)
  end

  defp commit_all(repo, message) do
    {_, 0} = System.cmd("/usr/bin/env", ["git", "add", "-A"], cd: repo)

    {_, 0} =
      System.cmd(
        "/usr/bin/env",
        [
          "git",
          "-c",
          "user.name=Test",
          "-c",
          "user.email=t@example.com",
          "commit",
          "-q",
          "-m",
          message
        ],
        cd: repo
      )
  end

  defp seed_run(run_id, worktree, base) do
    events =
      [
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, project_id: "project-1", workflow_name: "plan"}
        },
        %{
          event_type: "PhaseStarted",
          payload: %{
            phase_id: "#{run_id}-phase-1",
            run_id: run_id,
            index: 1,
            name: "implement",
            attempt: 1,
            artifact_template: "artifact.md"
          }
        }
      ] ++
        if worktree do
          [
            %{
              event_type: "WorktreeCreated",
              payload: %{
                operation_id: "wt-#{run_id}",
                project_id: "project-1",
                run_id: run_id,
                phase_id: "#{run_id}-phase-1",
                worktree_path: worktree,
                base_ref: base,
                branch: "foreman/#{run_id}"
              }
            }
          ]
        else
          []
        end

    assert :ok = ProjectionStore.apply_events(events)
  end
end
