defmodule ForemanServer.PrFixRedactionTest do
  @moduledoc """
  The prompt of a PR fix thread is redacted with the run's project's secret VALUES (every stored
  value whatever its name, `ProjectEnvironment.secrets/1`) as well as the name patterns: the
  check output, the review comments and the operator's note all reach the agent. The list is
  read once per plan.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{PrFix, SecretStore}
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.{MeckScope, SecretStoreDir}

  @moduletag :tmp_dir

  # `DB_URL` looks like no secret by name; the store holds it all the same.
  @db_url "postgres://svc:hunter2pw@db.internal:5432/app"
  @seven "abcdefg"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:meck)
    MeckScope.new_once!([SecretStore])
  end

  setup %{tmp_dir: tmp} do
    MeckScope.restore_on_exit!([SecretStore])
    SecretStoreDir.use_tmp_dir!(tmp)
    :ok
  end

  defp plan!(kind, ctx, opts) do
    opts = Keyword.put_new(opts, :fetch_fun, fn _url -> {:ok, ctx.status} end)
    opts = Keyword.put_new(opts, :log_fetcher, fn _url, _check -> {:error, :none} end)
    assert {:ok, plan} = PrFix.plan(kind, ctx.run_id, ctx.pr_url, opts)
    plan
  end

  defp watched!(opts \\ []) do
    ctx = Fix.watched!(opts)
    SecretStoreDir.put!(ctx.project_id, "DB_URL", @db_url)
    SecretStoreDir.put!(ctx.project_id, "SEVEN_CHR", @seven)
    ctx
  end

  test "a stored project value in a failing check's log never reaches the prompt, whatever its name; a value under the floor is not rewritten" do
    ctx = watched!()

    plan =
      plan!("ci", ctx,
        log_fetcher: fn _url, _check ->
          {:ok, "build failed\nconnecting to #{@db_url}\nretry #{@seven}"}
        end
      )

    refute plan.prompt =~ @db_url
    assert plan.prompt =~ "connecting to [REDACTED]"
    assert plan.prompt =~ "retry #{@seven}"
  end

  test "the log is redacted before its tail is cut: a value straddling the cut leaves no part of itself" do
    original = Application.get_env(:foreman_server, :pr_fix)

    on_exit(fn ->
      if original,
        do: Application.put_env(:foreman_server, :pr_fix, original),
        else: Application.delete_env(:foreman_server, :pr_fix)
    end)

    # a window of 30 bytes ends inside the 45-byte value: cut first, its last 30 bytes remain
    Application.put_env(
      :foreman_server,
      :pr_fix,
      Keyword.put(original || [], :log_tail_bytes, 30)
    )

    ctx = watched!()

    plan =
      plan!("ci", ctx,
        log_fetcher: fn _url, _check -> {:ok, String.duplicate("x", 100) <> @db_url} end
      )

    refute plan.prompt =~ "hunter2pw"
    assert plan.prompt =~ "[REDACTED]"
  end

  test "a stored project value in a review comment or in the operator's note never reaches the prompt" do
    comments = [
      %{id: "c1", author: "eve", body: "use #{@db_url} here", url: nil, created_at: nil}
    ]

    ctx =
      watched!(status: Support.status(head_branch: "foreman/run/phase", comments: comments))

    plan = plan!("comments", ctx, note: "the url is #{@db_url}")

    refute plan.prompt =~ @db_url
    assert plan.prompt =~ "use [REDACTED] here"
    assert plan.prompt =~ "the url is [REDACTED]"
  end

  test "the project's list is read once per plan, not once per check or text" do
    checks = for n <- 1..3, do: Support.failing_check("check-#{n}")

    ctx =
      watched!(
        status:
          Support.status(
            checks: checks,
            checks_state: :failing,
            head_branch: "foreman/run/phase"
          )
      )

    plan = plan!("ci", ctx, log_fetcher: fn _url, _check -> {:ok, "log #{@db_url}"} end)

    assert length(Regex.scan(~r/Log excerpt for/, plan.prompt)) == 3
    refute plan.prompt =~ @db_url
    assert :meck.num_calls(SecretStore, :pairs, [ctx.project_id]) == 1
  end

  test "a run whose project environment is refused is planned with the patterns alone, never raising" do
    ctx =
      Fix.watched!(
        settings: %{
          thread_model: "sonnet",
          config: %{env: %{"FOREMAN_RUN_ID" => "sneaky"}}
        }
      )

    {plan, log} =
      with_log(fn ->
        plan!("ci", ctx, log_fetcher: fn _url, _check -> {:ok, "oops password=hunter2"} end)
      end)

    assert plan.prompt =~ "oops password=[REDACTED]"
    refute plan.prompt =~ "hunter2"
    assert log =~ "reserved_project_env_keys"
  end
end
