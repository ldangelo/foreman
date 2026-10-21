You are resolving merge conflicts on an open GitHub pull request. You are checked out on the
pull request's head branch `{{head_branch}}` in a working copy that is up to date with
`origin/{{head_branch}}`. The pull request targets `{{base_branch}}`, which has moved on.

Pull request: {{pr_url}}

{{data_instruction}}

{{data_block}}

What to do:

1. Run `git fetch origin {{base_branch}}`, then merge `origin/{{base_branch}}` into this
   branch (`git merge origin/{{base_branch}}`). Do not rebase and do not force-push.
2. Resolve every conflict so that BOTH sides' intent is preserved; when unsure, prefer the
   behaviour of the base branch and re-apply this pull request's change on top of it.
3. Run the project's checks until they pass.
4. Complete the merge commit and `git push origin {{head_branch}}`. Push exactly this branch.
5. If the conflicts cannot be resolved safely, run `git merge --abort`, make NO changes and
   explain in your final message.

{{operator_note}}
