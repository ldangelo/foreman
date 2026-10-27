defmodule ForemanServer.Observability.FileLog do
  @moduledoc """
  Mirrors the server's operational log to a size-rotated file
  (default `~/.foreman/logs/foreman-server.log`).

  This is only the wiring of OTP's built-in `:logger_std_h` file handler: the
  console handler is untouched and no log line is formatted differently.
  Configured by `config :foreman_server, :server_log` (`enabled`, `path`,
  `max_bytes`, `max_files`); disabled under `MIX_ENV=test`.
  """

  @handler_id :foreman_server_log_file

  @type config :: %{
          path: Path.t(),
          max_bytes: pos_integer(),
          max_files: pos_integer()
        }

  @spec install_from_config() :: :ok | :disabled | {:error, term()}
  def install_from_config do
    config = Application.get_env(:foreman_server, :server_log, [])

    if Keyword.get(config, :enabled, false) do
      install(%{
        path: Keyword.fetch!(config, :path),
        max_bytes: Keyword.fetch!(config, :max_bytes),
        max_files: Keyword.fetch!(config, :max_files)
      })
    else
      :disabled
    end
  end

  @spec install(config()) :: :ok | {:error, term()}
  def install(%{path: path, max_bytes: max_bytes, max_files: max_files})
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 and
             is_integer(max_files) and max_files > 0 do
    _ = :logger.remove_handler(@handler_id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      :logger.add_handler(@handler_id, :logger_std_h, %{
        config: %{
          file: String.to_charlist(path),
          max_no_bytes: max_bytes,
          max_no_files: max_files
        },
        formatter:
          Logger.Formatter.new(
            format: "$dateT$time $metadata[$level] $message\n",
            metadata: [:request_id]
          )
      })
    end
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall, do: :logger.remove_handler(@handler_id)
end
