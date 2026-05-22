# Jido Chat GitHub

[![Hex.pm](https://img.shields.io/hexpm/v/jido_chat_github.svg)](https://hex.pm/packages/jido_chat_github)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_chat_github/)
[![CI](https://github.com/agentjido/jido_chat_github/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_chat_github/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_chat_github.svg)](https://github.com/agentjido/jido_chat_github/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

`jido_chat_github` adapts GitHub Issues and issue comments to the `Jido.Chat.Adapter` contract.

## Installation

```elixir
def deps do
  [
    {:jido_chat_github, "~> 0.1"}
  ]
end
```

## Feature surface

- Repositories map to channel-level rooms as `owner/repo`.
- Issues map to threads as `owner/repo#issue_number`.
- Issue comments map to thread messages.
- `post_channel_message/3` creates an issue.
- `send_message/3`, `post_message/3`, `edit_message/4`, and `delete_message/3` manage issue comments.
- `fetch_channel_messages/2` and `list_threads/2` list repository issues, excluding pull requests.
- `fetch_thread/2`, `open_thread/3`, `fetch_message/3`, and `fetch_messages/2` read issue and comment history.
- `add_reaction/4` and `remove_reaction/4` support GitHub issue and issue-comment reactions.
- Webhooks verify `X-Hub-Signature-256` and parse `issues`, `issue_comment`, and `reaction` events.

GitHub does not accept arbitrary binary uploads through the Issues comments API. Media support is implemented with GitHub Markdown links: remote image URLs render as images, and remote file/audio/video URLs render as links. Local file paths and in-memory uploads should be uploaded elsewhere first, then sent as public or GitHub-accessible URLs.

Replies are represented as quoted Markdown context because GitHub issue comments do not have native nested replies. Pass `reply_to_id`, `reply_to_text`, and optionally `reply_author` when sending a comment.

## Live testing

Create or choose a disposable issue, then set:

```bash
RUN_LIVE_GITHUB_TESTS=true
GITHUB_TOKEN=github_pat_or_app_installation_token
GITHUB_TEST_ISSUE=owner/repo#123
GITHUB_WEBHOOK_SECRET=shared-webhook-secret
```

The token needs `Issues: write` on the target repository. If testing against pull request comments through the shared Issues comments API, also grant `Pull requests: write`.

Run:

```bash
mix test --include live
```

## Webhook setup

Configure a GitHub App webhook, organization webhook, or repository webhook:

- Payload URL: your runtime route for GitHub, for example `/api/webhooks/github`
- Content type: `application/json`
- Secret: `GITHUB_WEBHOOK_SECRET`
- Events: `Issues`, `Issue comments`, `Reactions`

The adapter treats `owner/repo#issue_number` as the external room id for issue-thread events.
