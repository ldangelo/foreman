defmodule ForemanServer.Jobsite.Template.Feature do
  @moduledoc """
  Reads a natural-language prompt for the intents a remote jobsite spec can carry.

  The table below is a deterministic keyword match, not a model call: the same prompt always
  yields the same features. Each row is `{id, pattern, effect}` and a feature is reported for
  every row whose pattern matches, in table order.

  An `effect` is one of:

    * `:iterate` - the prompt asks for a loop: the spec gets an iteration budget and a
      completion signal, and the prompt file tells the agent how to end the run.
    * `:publish` - the prompt asks for the work to be published: `push: true` on the named branch.
    * `{:note, text}` - the prompt asks for something a remote spec cannot express. Nothing is
      added to the spec; the text is reported to the author and written into the script header so
      the request is never silently dropped.

  What is deliberately NOT inferred from free text, because the guess would widen what the
  generated script may do:

    * the sandbox: `host` runs the agent on the server's own machine, so it is chosen only by an
      explicit `sandbox` option (and the server must allow it). A prompt that merely mentions
      "the host header" must not turn isolation off.
    * the provider and the model: Foreman never learns a provider from free text or from a model
      name. They are explicit options (the model may come from the project's `thread_model`).
    * `strategy: "head"`: the agent would edit the server's own checkout in place, with no branch to
      review, merge or push (see the `work-in-place` row).

  Keyword matching has no notion of negation: "do not push" matches `push-to-origin`. Every
  feature that was applied is listed in the generated script's header so the author can veto it,
  and an explicit `push: false` option overrides the inference.
  """

  @enforce_keys [:id, :effect]
  defstruct [:id, :effect]

  @type effect :: :iterate | :publish | {:note, String.t()}
  @type t :: %__MODULE__{id: String.t(), effect: effect()}

  @table [
    {"loop", ~r/\bloop\b|iterate|re-?try|until it|keep (going|trying)|per-?iteration/i, :iterate},
    {"review-and-fix",
     ~r/review.?fix|failing (test|build|suite)|make (the )?(tests?|build|ci) (pass|green)|test.?and.?fix/i,
     :iterate},
    {"push-to-origin", ~r/\bpush\b|publish|to origin|open a pr|create a (pr|pull request)/i,
     :publish},
    {"work-in-place",
     ~r/without a (new )?branch|stay on (the )?current branch|no new branch|in place|:head\b/i,
     {:note,
      "this template always works on a named branch in its own worktree: strategy head would make " <>
        "the agent edit the server's own checkout in place, with no branch to review, merge or " <>
        "push, so it is never chosen from a prompt; write the spec by hand if that is what you want"}},
    {"session-resume",
     ~r/resume (the |a )?session|continue (the |from )?(previous )?conversation/i,
     {:note,
      "resume_session takes a real agent session id, which a prompt cannot supply, so this " <>
        "template starts a fresh session; agent.env values are never persisted, so a resumed " <>
        "jobsite runs without them"}},
    {"fan-out", ~r/parallel|fan.?out|multiple (repos|worktrees|branches)|each of|for every/i,
     {:note,
      "one jobsite per item: loop in a script of your own and merge each completed branch ONE AT A " <>
        "TIME, because a merge changes the server's checkout and concurrent merges race (see " <>
        "`foreman init --template parallel`)"}},
    {"notify", ~r/notify|slack|telegram|message me|ping me|alert me/i,
     {:note,
      "a spec has no notification field: read the returned jobsite's \"status\" after " <>
        "Foreman.Client.run/2 and send the message yourself"}},
    {"cleanup", ~r/clean up|remove the worktree|discard the (branch|worktree)|teardown/i,
     {:note,
      "worktree reclamation is not a remote spec key: merge the branch, then delete it in the " <>
        "repository checkout"}},
    {"artifact-gate",
     ~r/required file|must produce|an? artifact|report file|write a .{0,80} report/i,
     {:note,
      "the remote spec has no required-file gate: name the exact path in the prompt, have the " <>
        "agent commit it, then check the branch after the run"}}
  ]

  @doc """
  The features a prompt asks for, in table order.
  """
  @spec read(String.t()) :: [t()]
  def read(prompt) when is_binary(prompt) do
    for {id, pattern, effect} <- @table, Regex.match?(pattern, prompt) do
      %__MODULE__{id: id, effect: effect}
    end
  end
end
