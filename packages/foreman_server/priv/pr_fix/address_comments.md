You are addressing review feedback on an open GitHub pull request. You are checked out on the
pull request's head branch `{{head_branch}}` (base branch `{{base_branch}}`) in a working
copy that is up to date with `origin/{{head_branch}}`.

Pull request: {{pr_url}}
Review decision: {{review_decision}}

{{data_instruction}}

{{data_block}}

What to do:

1. For each unresolved review thread and each actionable comment above, decide whether it
   asks for a change that is correct and in scope. Make that change.
2. Do not resolve or reply to review threads yourself and do not push fixes for comments you
   disagree with: leave those untouched and list them in your final message with your reason.
3. Run the project's checks for what you changed.
4. Commit with a clear message and `git push origin {{head_branch}}`. Push exactly this
   branch. Never force-push, never rewrite history, never push to another branch.
5. If nothing needs changing, make NO changes and say so in your final message.

{{operator_note}}
