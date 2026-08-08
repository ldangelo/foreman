defmodule ForemanServer.TestSupport.TestApplication do
  @moduledoc false

  @spec reset_application_child!(module()) :: pid()
  def reset_application_child!(child_module) do
    original_state = :sys.get_state(child_module)

    ExUnit.Callbacks.on_exit({child_module, make_ref()}, fn ->
      :sys.replace_state(child_module, fn _state -> original_state end)
    end)

    :ok = GenServer.call(child_module, :reload_config)
    :persistent_term.put({child_module, child_module, :boot_count}, 1)
    Process.whereis(child_module)
  end
end
