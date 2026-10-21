You are fixing a failing CI run on an open GitHub pull request. You are checked out on the
pull request's head branch `{{head_branch}}` (base branch `{{base_branch}}`) in a working
copy that is up to date with `origin/{{head_branch}}`.

Pull request: {{pr_url}}

{{data_instruction}}

{{data_block}}

What to do:

1. Reproduce the failure locally with the project's own test / lint commands, using the
   failing check names and the log excerpt above as your starting point.
2. Fix the cause in the code (not the check): do not weaken, skip or delete tests, linters
   or workflows to make CI pass.
3. Run the relevant checks until they pass.
4. Commit with a clear message and `git push origin {{head_branch}}`. Push exactly this
   branch. Never force-push, never rewrite history, never push to another branch.
5. If the failure is not something you can fix from here (an outage, a missing secret, a flaky
   external service), make NO changes and say so plainly in your final message.

{{operator_note}}
