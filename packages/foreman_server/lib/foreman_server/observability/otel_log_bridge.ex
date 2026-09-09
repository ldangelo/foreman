defmodule ForemanServer.Observability.OtelLogBridge do
  @moduledoc """
  Single Foreman-owned bridge from Logger events to sanitized OTel log payloads.

  Contract verified against pinned deps:

    * `:opentelemetry_exporter` 1.10.0 exposes generated logs protobuf module
      `:opentelemetry_exporter_logs_service_pb` with OTLP Logs Data Model maps
      (`:resource_logs`, `:scope_logs`, `:log_record`, `:resource`).
    * The 1.10.0 Hex package references `:otel_exporter_logs_otlp`, but the
      module is absent from the installed dep source. Foreman therefore uses the
      generated protobuf encoder plus `:httpc` for logs instead of pretending the
      trace exporter path also exports logs. Tests pin this contract and use the
      capture exporter to avoid network.

  Console logging is preserved because this module installs an additional Erlang
  `:logger` handler only when SigNoz logs are explicitly enabled.
  """

  alias ForemanServer.Observability.Redactor

  @handler_id :foreman_signoz_otel_log_bridge
  @schema_url "https://opentelemetry.io/schemas/1.27.0"

  # RFC 5424 / Elixir Logger's full severity set, ordered least to most
  # severe. Shared by normalize_level/1 (config + install/1 input),
  # level_rank/1 (threshold comparison), and severity_number/1 (OTLP
  # SeverityNumber encoding) so all three stay in lockstep.
  @valid_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @type exporter :: :otel | {:capture, pid()} | (map() -> :ok | {:error, term()})

  @spec install_from_config() :: :ok | {:error, term()} | :disabled
  def install_from_config do
    config = Application.get_env(:foreman_server, :signoz_logs, [])

    if enabled?(config) do
      install(config)
    else
      :disabled
    end
  end

  @spec install(keyword() | map()) :: :ok | {:error, term()}
  def install(config) do
    case level(config) do
      nil ->
        {:error, {:invalid_level, config_value(config, :level, :info)}}

      level ->
        _ = :logger.remove_handler(@handler_id)

        handler_config = %{
          level: level,
          exporter: exporter(config),
          endpoint: endpoint(config),
          headers: headers(config)
        }

        :logger.add_handler(@handler_id, __MODULE__, handler_config)
    end
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall, do: :logger.remove_handler(@handler_id)

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, config) do
    if level_allowed?(level, Map.get(config, :level, :info)) do
      payload = otel_payload(level, msg, meta)

      case export(payload, config) do
        :ok -> :ok
        {:error, reason} -> ForemanServer.Telemetry.signoz_log_export_failure(reason, config)
      end
    end

    :ok
  rescue
    error ->
      ForemanServer.Telemetry.signoz_log_export_failure({:bridge_crash, error}, config)
      :ok
  end

  @spec otel_payload(Logger.level(), term(), map() | keyword()) :: map()
  def otel_payload(level, msg, metadata \\ %{}) do
    attrs =
      metadata
      |> Redactor.redact_metadata()
      |> Map.put(:source, "logger")
      |> maybe_put(
        :module,
        metadata_value(metadata, :mfa, 0) || metadata_value(metadata, :module)
      )
      |> maybe_put(
        :function,
        metadata_value(metadata, :mfa, 1) || metadata_value(metadata, :function)
      )
      |> maybe_put(:line, metadata_value(metadata, :line))

    %{
      resource_logs: [
        %{
          resource: %{
            attributes: [%{key: "service.name", value: string_value("foreman_server")}]
          },
          schema_url: @schema_url,
          scope_logs: [
            %{
              scope: %{name: "ForemanServer.Observability.OtelLogBridge", version: "0.1.0"},
              schema_url: @schema_url,
              log_records: [
                %{
                  time_unix_nano: timestamp(metadata),
                  observed_time_unix_nano: System.system_time(:nanosecond),
                  severity_number: severity_number(level),
                  severity_text: level |> to_string() |> String.upcase(),
                  body: string_value(Redactor.redact_message(msg)),
                  attributes: encode_attributes(attrs)
                }
              ]
            }
          ]
        }
      ]
    }
  end

  @spec export(map(), map()) :: :ok | {:error, term()}
  def export(payload, %{exporter: {:capture, pid}}) when is_pid(pid) do
    send(pid, {:foreman_signoz_log, payload})
    :ok
  end

  def export(payload, %{exporter: fun}) when is_function(fun, 1), do: fun.(payload)

  def export(payload, config) do
    cond do
      Map.get(config, :exporter) != :otel ->
        :ok

      not Code.ensure_loaded?(:opentelemetry_exporter_logs_service_pb) ->
        {:error, :otel_logs_protobuf_unavailable}

      true ->
        export_to_otel(payload, config)
    end
  end

  def enabled?(config), do: config_value(config, :enabled, false) in [true, "true", "1", 1]
  def level(config), do: config_value(config, :level, :info) |> normalize_level()
  def endpoint(config), do: config_value(config, :endpoint, nil)
  def headers(config), do: config_value(config, :headers, [])
  def exporter(config), do: config_value(config, :exporter, :otel)

  defp export_to_otel(payload, config) do
    with endpoint when is_binary(endpoint) and endpoint != "" <- endpoint(config),
         headers <- headers(config),
         :ok <- ensure_https_for_headers(endpoint, headers),
         :ok <- ensure_inets_started(),
         {:ok, body} <- encode_payload(payload) do
      # The blocking network call runs off-process via a bounded, supervised
      # Task.Supervisor pool (CodeRabbit review) rather than a raw
      # Task.start/1: validation and payload encoding above stay synchronous
      # and cheap, so config/precondition errors are still reported to the
      # caller of export/2 immediately. `max_children` on
      # OtelLogExportSupervisor bounds concurrent exports; once the pool is
      # full, start_child/2 returns `{:error, :max_children}` and the record
      # is dropped with an overload telemetry event rather than queuing
      # unbounded work or blocking the logger handler.
      case Task.Supervisor.start_child(
             ForemanServer.Observability.OtelLogExportSupervisor,
             fn ->
               try do
                 case post_logs(endpoint, headers, body) do
                   {:ok, _status} ->
                     :ok

                   {:error, reason} ->
                     ForemanServer.Telemetry.signoz_log_export_failure(reason, config)
                 end
               rescue
                 error ->
                   ForemanServer.Telemetry.signoz_log_export_failure(
                     {:bridge_crash, error},
                     config
                   )
               end
             end
           ) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        {:error, :max_children} ->
          ForemanServer.Telemetry.signoz_log_export_overload(config)

        {:error, reason} ->
          ForemanServer.Telemetry.signoz_log_export_failure(reason, config)
      end

      :ok
    else
      nil -> {:error, :missing_endpoint}
      "" -> {:error, :missing_endpoint}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_export_result, other}}
    end
  end

  # CWE-319: refuse to send configured export headers (credentials) to a
  # plaintext endpoint. Headerless exports (the local-dev default, no
  # collector auth) are unaffected.
  defp ensure_https_for_headers(_endpoint, []), do: :ok

  defp ensure_https_for_headers(endpoint, [_ | _]) do
    if String.starts_with?(endpoint, "https://") do
      :ok
    else
      {:error, {:insecure_endpoint_with_headers, endpoint}}
    end
  end

  defp ensure_inets_started do
    case Application.ensure_all_started(:inets) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:inets_start_failed, reason}}
    end
  end

  defp encode_payload(payload) do
    {:ok,
     apply(:opentelemetry_exporter_logs_service_pb, :encode_msg, [
       %{resource_logs: payload.resource_logs},
       :export_logs_service_request
     ])}
  rescue
    error -> {:error, {:encode_failed, error}}
  end

  defp post_logs(endpoint, headers, body) do
    request = {
      String.to_charlist(endpoint),
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
      end),
      ~c"application/x-protobuf",
      body
    }

    # autoredirect: false — httpc defaults to following 3xx redirects and
    # replaying the original request, including any configured
    # Authorization/credential headers, against the redirect target, which
    # can be a different and/or less-secure origin (CWE-319; see also
    # erlang/otp GHSA-m75x-4vwg-ggjh, which hardened only a fixed list of
    # well-known header names — our operator-supplied header name is
    # arbitrary, so it is not necessarily covered even on a patched OTP).
    # SigNoz/OTel collector log ingest has no legitimate reason to redirect
    # this POST.
    case :httpc.request(:post, request, [timeout: 5_000, autoredirect: false], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, inspect(body)}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp encode_attributes(attrs) do
    Enum.map(attrs, fn {key, value} -> %{key: to_string(key), value: any_value(value)} end)
  end

  defp any_value(value) when is_boolean(value), do: %{bool_value: value}
  defp any_value(value) when is_integer(value), do: %{int_value: value}
  defp any_value(value) when is_float(value), do: %{double_value: value}
  defp any_value(value), do: string_value(value)
  defp string_value(value), do: %{string_value: to_string(value)}

  defp timestamp(%{time: time}) when is_integer(time), do: time * 1_000
  defp timestamp(_), do: System.system_time(:nanosecond)

  defp severity_number(:debug), do: 5
  defp severity_number(:info), do: 9
  defp severity_number(:notice), do: 10
  defp severity_number(:warning), do: 13
  defp severity_number(:error), do: 17
  defp severity_number(:critical), do: 18
  defp severity_number(:alert), do: 19
  defp severity_number(:emergency), do: 21
  defp severity_number(_), do: 9

  defp level_allowed?(level, min), do: level_rank(level) >= level_rank(min)
  defp level_rank(:debug), do: 10
  defp level_rank(:info), do: 20
  defp level_rank(:notice), do: 25
  defp level_rank(:warning), do: 30
  defp level_rank(:error), do: 40
  defp level_rank(:critical), do: 50
  defp level_rank(:alert), do: 60
  defp level_rank(:emergency), do: 70
  defp level_rank(_), do: 20

  defp normalize_level(level) when level in @valid_levels, do: level

  defp normalize_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "notice" -> :notice
      "warning" -> :warning
      "error" -> :error
      "critical" -> :critical
      "alert" -> :alert
      "emergency" -> :emergency
      _ -> nil
    end
  end

  defp normalize_level(_), do: nil

  defp config_value(config, key, default) when is_map(config), do: Map.get(config, key, default)

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(_, _, default), do: default

  defp metadata_value(metadata, key), do: metadata |> metadata_map() |> Map.get(key)

  defp metadata_value(metadata, :mfa, index) do
    case metadata_value(metadata, :mfa) do
      tuple when is_tuple(tuple) and tuple_size(tuple) > index -> elem(tuple, index)
      _ -> nil
    end
  end

  defp metadata_map(metadata) when is_map(metadata), do: metadata
  defp metadata_map(metadata) when is_list(metadata), do: Enum.into(metadata, %{})
  defp metadata_map(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
