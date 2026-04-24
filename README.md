# Jido Chat GitHub

`jido_chat_github` adapts GitHub Issues and issue comments to the `Jido.Chat.Adapter` contract.

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
- Events: `Issues`, `Issue comments`

The adapter verifies `X-Hub-Signature-256`, parses `issues` and `issue_comment` events, and treats `owner/repo#issue_number` as the external room id.
