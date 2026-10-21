defmodule ForemanServer.Test.FakeReqLlm do
  @moduledoc """
  Fake LLM at the `req_llm` boundary (no network).

  Replaces the two `ReqLLM.Generation` entrypoints that `jido_ai` calls
  (`stream_text/3` for ReAct, `generate_text/3` for the CoT call) with a scripted
  reply and leaves everything downstream real: `jido_ai`'s ReAct runtime, stream
  consumption, usage merging and `Jido.AI.generate_text/2` all run unmodified.
  The test process receives `{:fake_llm_call, model, messages, opts}` per call.

  Uses `:meck`, so tests using it must be `async: false`. `install/2` registers
  its own cleanup.
  """

  @type reply ::
          {:answer, String.t(), map()}
          | {:answer_without_usage, String.t()}
          | {:error, term()}

  @spec install(pid(), reply()) :: :ok
  def install(test_pid, reply) when is_pid(test_pid) do
    :ok = :meck.new(ReqLLM.Generation, [:passthrough, :no_link])

    # The scripted model id is deliberately not in the LLMDB catalog.
    previous = Application.get_env(:req_llm, :warn_unverified_models)
    Application.put_env(:req_llm, :warn_unverified_models, false)

    :meck.expect(ReqLLM.Generation, :stream_text, fn model, messages, opts ->
      send(test_pid, {:fake_llm_call, model, messages, opts})
      stream_reply(reply)
    end)

    :meck.expect(ReqLLM.Generation, :generate_text, fn model, messages, opts ->
      send(test_pid, {:fake_llm_call, model, messages, opts})
      generate_reply(reply)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      :meck.unload(ReqLLM.Generation)

      if is_nil(previous),
        do: Application.delete_env(:req_llm, :warn_unverified_models),
        else: Application.put_env(:req_llm, :warn_unverified_models, previous)
    end)

    :ok
  end

  defp stream_reply({:error, reason}), do: {:error, reason}
  defp stream_reply({:answer, text, usage}), do: stream_response(text, %{usage: usage})
  defp stream_reply({:answer_without_usage, text}), do: stream_response(text, %{})

  defp stream_response(text, extra_metadata) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        Map.put(extra_metadata, :finish_reason, :stop)
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: [ReqLLM.StreamChunk.text(text)],
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model(),
       context: ReqLLM.Context.new([])
     }}
  end

  defp generate_reply({:error, reason}), do: {:error, reason}
  defp generate_reply({:answer, text, usage}), do: response(text, usage)
  defp generate_reply({:answer_without_usage, text}), do: response(text, nil)

  defp response(text, usage) do
    {:ok,
     %ReqLLM.Response{
       id: "fake-response",
       model: "fake-model",
       context: ReqLLM.Context.new([]),
       message: ReqLLM.Context.assistant(text),
       usage: usage,
       finish_reason: :stop
     }}
  end

  defp model, do: LLMDB.Model.new!(%{id: "fake-model", model: "fake-model", provider: :openai})
end
