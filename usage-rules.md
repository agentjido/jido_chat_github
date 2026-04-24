# LLM Usage Rules for Jido Chat GitHub

`jido_chat_github` adapts GitHub Issues and issue comments to `Jido.Chat.Adapter`.

- Treat each GitHub issue as the canonical thread.
- Keep GitHub App/PAT auth in transport options or environment variables.
- Keep webhook verification strict; never accept unsigned live webhooks.
- Live tests must stay opt-in with `RUN_LIVE_GITHUB_TESTS`.
