# Jido Chat GitHub

[![Hex.pm](https://img.shields.io/hexpm/v/jido_chat_github.svg)](https://hex.pm/packages/jido_chat_github)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_chat_github/)
[![CI](https://github.com/agentjido/jido_chat_github/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_chat_github/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_chat_github.svg)](https://github.com/agentjido/jido_chat_github/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

`jido_chat_github` adapts GitHub issue comments to the current Jido Chat V3
Signal and adapter contracts.

## Local V3 status

The `release/v3` branch uses the sibling `../jido_chat` working tree for local
integration. It is not a published Hex dependency. Publication must select the
released Jido Chat V3 Hex package and repeat all package checks.

## Client and operations

Create an immutable client. Store the token in `credentials`. Store adapter
settings, such as a test API base URL, in `config`.

```elixir
client = Jido.Chat.Client.new!(Jido.Chat.GitHub.Adapter,
  id: "support-github",
  credentials: %{token: System.fetch_env!("GITHUB_TOKEN")}
)

{:ok, result} =
  Jido.Chat.send_text(client, "agentjido/jido_chat#123", "Hello from Jido")

comment_id = result.data["result"]["id"]
```

A GitHub Room ID has the form `owner/repository#issue_number`.

The current native operations are:

- `send_message`
- `edit_message`
- `delete_message`
- `fetch_message`
- `fetch_messages`
- `get_user`

All other core operations are explicitly unsupported. Unsupported operations
stop before provider I/O.

## Inbound delivery

Verify the GitHub webhook signature before normalization. Pass one complete,
verified webhook payload to the client.

```elixir
{:ok, delivery} = Jido.Chat.normalize(client, verified_webhook_payload)
signals = delivery.signals
```

The adapter normalizes created and edited issue comments. The host decides how
to send the resulting Signals to its Jido Chat plugin or Runtime. Jido Chat
core owns managed Rooms, provider declarations, bridges, storage, and the
application Signal Bus. This package starts no managed process tree.

## Private data boundary

The adapter passes the token to the transport as a distinct private argument.
It does not add the token to generic transport options or Signal data. The
default Req transport also accepts private adapter config, such as `base_url`,
through the client config list.

## Checks

Run `mix test` and `mix quality`. Live tests stay tagged `:live` and excluded
by default. They run only when `RUN_LIVE_GITHUB_TESTS` and the required GitHub
environment values are set.

See `docs/v3-upgrade-validation.md` for current local evidence.
