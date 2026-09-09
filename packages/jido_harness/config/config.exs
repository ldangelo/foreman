import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

if config_env() == :dev do
  config :git_hooks,
    auto_install: true,
    verbose: true,
    # `git_hooks` defaults an installed hook's working directory to
    # `$(git rev-parse --show-toplevel)`, which is this monorepo's root, not
    # this package. That root has no `mix.exs`, so every installed hook ran
    # `mix git_hooks.run <hook>` from a directory with no mix project and
    # failed unconditionally (`** (Mix) The task "git_hooks.run" could not
    # be found` / "no mix.exs was found in the current directory") — the
    # repo-wide broken `commit-msg` hook this pins down. Pin the project
    # path explicitly to this package so the generated hook `cd`s here.
    project_path: Path.expand("..", __DIR__),
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: Jido.Harness.MixProject,
    changelog_file: "CHANGELOG.md",
    # `mix git_ops.check_message` reads the commit message file at
    # `Path.join(repository_path, ".git/COMMIT_EDITMSG")` (a literal path,
    # not git's own `--git-path` discovery). Since `project_path` above puts
    # the task's cwd at this package rather than the actual git repository
    # root — this package is not its own git repo — that join must be
    # pointed at the real root explicitly, or it reads a path that never
    # exists. `Git.init!/1` elsewhere in git_ops (release, message_hook)
    # tolerates either path equally, since plain git commands discover
    # `.git` upward from any working-tree subdirectory; only this literal
    # join needs the true root.
    repository_path: Path.expand("../../..", __DIR__),
    repository_url: "https://github.com/agentjido/jido_harness",
    manage_mix_version?: true,
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

import_config "#{config_env()}.exs"
