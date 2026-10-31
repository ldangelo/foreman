defmodule ForemanServer.Observability.SecretValueLogFilterTest do
  @moduledoc """
  foreman-25sqf.1.1: stored secret values are redacted from every log event BY VALUE, whatever
  key or text carries them. The filter is a global `:logger` primary filter and its value list
  is global state, so this module is not async and clears the list around every test.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  require Logger

  alias ForemanServer.Observability.SecretValueLogFilter, as: Filter
  alias ForemanServer.Observability.SecretValueLogFilter.Refresher
  alias ForemanServer.{ProjectionStore, SecretStore}
  alias ForemanServer.TestSupport.{ProjectionStoreReset, SecretStoreDir}

  # The application does not run the filter in the test environment (`config/test.exs`: its
  # refresher reads every secret store from a background process, which races tests that count
  # `SecretStore` calls), so each test installs the filter and starts the refresher itself.
  setup %{tmp_dir: tmp} do
    ProjectionStoreReset.reset!()
    SecretStoreDir.use_tmp_dir!(tmp)
    :ok = Filter.install()
    start_supervised!({Refresher, interval_ms: 3_600_000})
    Refresher.refresh_sync()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      Filter.uninstall()
    end)

    {:ok, value: "LOGSECRET-#{System.unique_integer([:positive])}-zzzz"}
  end

  defp register(id) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: "/srv/#{id}"}}
      ])
  end

  defp event(msg), do: %{level: :error, msg: msg, meta: %{time: 1}}

  describe "filter/2 on each message shape" do
    test "a string message holding a value is redacted, nothing else changes", %{value: value} do
      Filter.publish([value])

      assert %{msg: {:string, text}, level: :error, meta: %{time: 1}} =
               Filter.filter(event({:string, ["deploy to ", value, " now"]}), [])

      assert text =~ "[REDACTED]"
      refute text =~ value
      assert text =~ "deploy to "
    end

    test "a format-and-args message is rendered, then redacted", %{value: value} do
      Filter.publish([value])

      assert %{msg: {:string, text}} =
               Filter.filter(event({"target=~s port=~p", [value, 4000]}), [])

      refute text =~ value
      assert text =~ "4000"
    end

    test "a report is rendered, then redacted", %{value: value} do
      Filter.publish([value])

      assert %{msg: {:string, text}} =
               Filter.filter(event({:report, %{deploy: %{nested: [value]}}}), [])

      refute text =~ value
      assert text =~ "deploy"
    end

    test "an event without a value is returned untouched, term for term", %{value: value} do
      Filter.publish([value])
      untouched = event({:string, "nothing secret here"})

      assert Filter.filter(untouched, []) === untouched
    end

    test "with no published values every event passes untouched" do
      untouched = event({:string, "anything at all"})

      assert Filter.filter(untouched, []) === untouched
    end

    test "a message that cannot be rendered is withheld, never passed unchecked", %{value: value} do
      Filter.publish([value])

      # `~d` given a string: `:io_lib.format/2` raises, so the message cannot be checked.
      assert %{msg: {:string, text}} = Filter.filter(event({"count ~d", ["not a number"]}), [])

      assert text =~ "withheld"
    end
  end

  describe "publish/1" do
    test "drops values below the floor: a short value would rewrite ordinary log text" do
      Filter.publish(["1", "short", "1234567"])
      assert Filter.count() == 0

      Filter.publish(["12345678"])
      assert Filter.count() == 1
    end

    test "an empty list switches the filter off", %{value: value} do
      Filter.publish([value])
      assert Filter.count() == 1

      Filter.publish([])
      assert Filter.count() == 0
    end
  end

  describe "through the real logger" do
    test "a published value never reaches a log handler, from any process", %{value: value} do
      Filter.publish([value])

      log =
        capture_log([level: :error], fn ->
          Logger.error("deploy target #{value} failed")
          Task.async(fn -> Logger.error("from another process: #{value}") end) |> Task.await()
        end)

      assert log =~ "[REDACTED]"
      assert log =~ "deploy target"
      assert log =~ "from another process"
      refute log =~ value
    end

    test "before a value is published it is not redacted: the control that the refute can fail",
         %{value: value} do
      log = capture_log([level: :error], fn -> Logger.error("plain #{value}") end)

      assert log =~ value
    end
  end

  describe "Refresher" do
    test "a stored secret is picked up, and stops being redacted once deleted", %{value: value} do
      register("slf-p1")
      {:ok, :stored} = SecretStore.put("slf-p1", "DEPLOY_TARGET", value)
      :ok = Refresher.refresh_sync()

      assert {:ok, [^value]} = Refresher.project_values("slf-p1")

      log = capture_log([level: :error], fn -> Logger.error("leak #{value}") end)
      refute log =~ value

      {:ok, :deleted} = SecretStore.delete("slf-p1", "DEPLOY_TARGET")
      :ok = Refresher.refresh_sync()

      stale = capture_log([level: :error], fn -> Logger.error("after delete #{value}") end)
      assert stale =~ value
    end

    test "every registered project contributes, not just one", %{value: value} do
      other = value <> "-other"
      register("slf-a")
      register("slf-b")
      {:ok, :stored} = SecretStore.put("slf-a", "DEPLOY_TARGET", value)
      {:ok, :stored} = SecretStore.put("slf-b", "DEPLOY_REGION", other)
      :ok = Refresher.refresh_sync()

      log =
        capture_log([level: :error], fn -> Logger.error("both #{value} and #{other}") end)

      refute log =~ value
      refute log =~ other
    end

    test "a secret shorter than the floor is stored but never published", %{value: _} do
      register("slf-short")
      {:ok, :stored} = SecretStore.put("slf-short", "DEPLOY_REGION", "abc123")
      :ok = Refresher.refresh_sync()

      assert Filter.count() == 0

      log = capture_log([level: :error], fn -> Logger.error("code abc123 is fine") end)
      assert log =~ "abc123"
    end

    # The project list is read through `ProjectStore.list/0`, a call into the projection, which a
    # test must not stop. The refresher's `:project_ids` option replaces that read with a function
    # whose outcome the test controls.
    defp start_with_lister(mode_agent) do
      stop_supervised!(Refresher)

      lister = fn ->
        case Agent.get(mode_agent, & &1) do
          {:ids, ids} -> ids
          {:raise, message} -> raise message
          :exit -> exit(:projection_down)
        end
      end

      start_supervised!({Refresher, interval_ms: 3_600_000, project_ids: lister})
      :ok = Refresher.refresh_sync()
    end

    for kind <- [:raise, :exit] do
      test "an unreadable project list (#{kind}) keeps the previous values and warns once",
           %{value: value} do
        register("slf-down")
        {:ok, :stored} = SecretStore.put("slf-down", "DEPLOY_TARGET", value)
        mode = start_supervised!({Agent, fn -> {:ids, ["slf-down"]} end})
        start_with_lister(mode)
        assert Filter.count() == 1

        # A raise message that carries the secret must not reach the log either.
        failure = if unquote(kind) == :raise, do: {:raise, "boom #{value}"}, else: :exit
        Agent.update(mode, fn _ -> failure end)

        log = capture_log([level: :warning], fn -> :ok = Refresher.refresh_sync() end)

        leaked = capture_log([level: :error], fn -> Logger.error("leak #{value}") end)
        refute leaked =~ value
        assert leaked =~ "[REDACTED]"
        assert Filter.count() == 1

        assert log =~ "cannot list projects"
        assert length(String.split(log, "cannot list projects")) == 2
        # The filter is installed, so a leaked value would show as "[REDACTED]", and the raise
        # message ("boom ...") must not be in the warning at all: only the error class is.
        refute log =~ value
        refute log =~ "[REDACTED]"
        refute log =~ "boom"

        repeated =
          capture_log([level: :warning], fn ->
            :ok = Refresher.refresh_sync()
            :ok = Refresher.refresh_sync()
          end)

        refute repeated =~ "cannot list projects"
        assert Filter.count() == 1

        stale = capture_log([level: :error], fn -> Logger.error("still #{value}") end)
        refute stale =~ value

        # Recovery: the list updates again (here the project is gone, so the value stops being
        # redacted), and a later failure is reported afresh.
        Agent.update(mode, fn _ -> {:ids, []} end)
        :ok = Refresher.refresh_sync()
        assert Filter.count() == 0

        again =
          capture_log([level: :error], fn -> Logger.error("after recovery #{value}") end)

        assert again =~ value
      end
    end
  end
end
