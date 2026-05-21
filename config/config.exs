import Config

if config_env() == :dev do
  config :git_ops,
    mix_project: Jido.Chat.GitHub.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jido_chat_github",
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
