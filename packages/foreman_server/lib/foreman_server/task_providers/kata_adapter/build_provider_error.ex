defmodule ForemanServer.TaskProviders.KataAdapter.BuildProviderError do
  @moduledoc """
  The single `%ProviderError{}` construction site for the Kata provider (AC-007-4).

  `KataAdapter` and `SystemKataRunner` build every error they return through
  `build_provider_error/3`; nothing else under `task_providers/` creates a
  `ProviderError` for Kata (`kata_adapter_test.exs` scans for it).

  ## Code vocabulary

  The closed vocabulary is `BeadsAdapter.CodeMap`'s (AC-007-1, AC-007-2): no
  Kata-specific code is minted, and a code `CodeMap` does not know degrades to
  `BR_ERROR_ENVELOPE`. Only the code and the `retryable?` flag are read from
  `CodeMap`; the message and hint are written by the caller in Kata terms. The one
  override is `CLAIMED_BY_OTHER`, which is never retryable for Kata (AC-013-2) so
  `RunExecutor` classifies it as permanent, where `CodeMap` marks it retryable.

  ## Context

  The context key set is closed (AC-007-3, AC-017-4):

    * `id` - the code that was mapped (never text from kata)
    * `command` - `%{binary: "kata"}`, so an operator can tell which CLI failed
    * `exit_code` - the exit status the runner reported, `nil` when there is none
    * `stderr_byte_count` - the size of kata's stderr; the text is never read
    * `sanitized?` - always `true`
    * `redacted_fields` - always `["assignee", "description"]`, for every code
    * `missing_fields` - the payload fields that were absent; `ProviderError.new/3`
      seeds it (`[]`) on every error

  The owner of an issue, `error.data`, `message` and `hint` from kata's stderr, and
  any presence flag for them never reach an error.

  ## Mapping a runner failure

  `from_runner_error/2` implements the verb-and-exit-code mapping, because the runner
  never reads stderr (AC-007-3): exit 5 from `claim` or `unassign` is
  `CLAIMED_BY_OTHER`, exit 5 from any other verb (`comment`'s idempotency mismatch,
  for one) is `BR_ERROR_ENVELOPE`, 4 is `ISSUE_NOT_FOUND`, 3 is `VALIDATION_FAILED`,
  7 (daemon unavailable) and 8 (wait timeout) are `BR_TIMEOUT_SUBPROCESS`, and every
  other non-zero status - a signal death included - is `BR_ERROR_ENVELOPE`. A failure
  with no exit status (a runner timeout, a missing working directory, a closed port)
  keeps the runner's own code, message and hint.
  """

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ProviderError

  @binary "kata"
  @redacted_fields ["assignee", "description"]
  @context_keys [
    :id,
    :command,
    :exit_code,
    :stderr_byte_count,
    :sanitized?,
    :redacted_fields,
    :missing_fields
  ]

  @typedoc "Exit status reported by the runner; `nil` when the process produced none."
  @type exit_code :: integer() | nil

  @doc "The closed set of keys every Kata `ProviderError.context` carries."
  @spec context_keys() :: [atom(), ...]
  def context_keys, do: @context_keys

  @doc """
  Builds the `ProviderError` for `input`, mapped through `BeadsAdapter.CodeMap`.

  `exit_code` and `stderr_byte_count` describe the failed `kata` process (`nil` and
  `0` for an error the adapter raises itself).
  """
  @spec build_provider_error(ProviderErrorInput.t(), exit_code(), non_neg_integer()) ::
          ProviderError.t()
  def build_provider_error(%ProviderErrorInput{} = input, exit_code, stderr_byte_count)
      when (is_nil(exit_code) or is_integer(exit_code)) and is_integer(stderr_byte_count) and
             stderr_byte_count >= 0 do
    %ProviderError{code: code, retryable?: code_map_retryable?, context: %{id: id}} =
      CodeMap.build_provider_error(input, nil, stderr_byte_count)

    ProviderError.new(code, input.message,
      hint: input.hint,
      retryable?: retryable?(code, code_map_retryable?),
      context: %{
        id: id,
        command: %{binary: @binary},
        exit_code: exit_code,
        stderr_byte_count: stderr_byte_count,
        sanitized?: true,
        redacted_fields: @redacted_fields,
        missing_fields: input.missing_fields
      }
    )
  end

  @doc """
  Maps a failed runner call to the `ProviderError` the adapter returns.

  `argv` is the argument list that was run (its head is the verb) and `runner_error`
  the `ProviderError` the runner returned for it.
  """
  @spec from_runner_error([String.t(), ...], ProviderError.t()) :: ProviderError.t()
  def from_runner_error(
        [verb | _argv],
        %ProviderError{
          context: %{exit_code: exit_code, stderr_byte_count: stderr_byte_count}
        } = runner_error
      )
      when is_binary(verb) do
    {code, message, hint} =
      if is_nil(exit_code),
        do: {runner_error.code, runner_error.message, runner_error.hint},
        else: classify(verb, exit_code)

    code
    |> ProviderErrorInput.from_local(message, hint, runner_error.retryable?)
    |> build_provider_error(exit_code, stderr_byte_count)
  end

  defp classify(verb, 5) when verb in ["claim", "unassign"] do
    {"CLAIMED_BY_OTHER", "Kata issue is owned by another actor.",
     "Release the issue with kata unassign, or choose another one, before retrying."}
  end

  defp classify(_verb, 5) do
    {"BR_ERROR_ENVELOPE", "Kata reported a conflict for this command.",
     "Check the command arguments, such as a reused idempotency key, before retrying."}
  end

  defp classify(_verb, 4) do
    {"ISSUE_NOT_FOUND", "Kata issue was not found.",
     "Verify the issue reference before retrying."}
  end

  defp classify(_verb, 3) do
    {"VALIDATION_FAILED", "Kata rejected the command as invalid.",
     "Check the command arguments against the installed kata version."}
  end

  defp classify(_verb, exit_code) when exit_code in [7, 8] do
    {"BR_TIMEOUT_SUBPROCESS", "Kata daemon was unavailable or the command timed out.",
     "Retry after checking that the Kata daemon is reachable."}
  end

  defp classify(_verb, exit_code) when is_integer(exit_code) do
    {"BR_ERROR_ENVELOPE", "Kata CLI exited with an unmapped non-zero status.",
     "Update the adapter mapping or install a supported kata version."}
  end

  # AC-013-2: a Kata claimed-by-other error is permanent, overriding the CodeMap default.
  defp retryable?("CLAIMED_BY_OTHER", _code_map_retryable?), do: false
  defp retryable?(_code, code_map_retryable?), do: code_map_retryable?
end
