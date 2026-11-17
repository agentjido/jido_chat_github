# LLM Usage Rules for Jido Chat GitHub

`jido_chat_github` adapts GitHub Issues and issue comments to `Jido.Chat.Adapter`.

- Treat each GitHub issue as the canonical thread.
- Keep GitHub App or PAT auth in `Client.credentials`. Do not put it in Signal
  data or generic transport options.
- Keep webhook verification strict; never accept unsigned live webhooks.
- Keep managed Room, bridge, storage, and provider runtime ownership in Jido
  Chat core.
- Live tests must stay opt-in with `RUN_LIVE_GITHUB_TESTS`.
