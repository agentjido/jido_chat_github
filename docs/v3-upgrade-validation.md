# Jido Chat V3 validation: GitHub

Date: 2026-11-16 (America/Chicago).

## Scope

The GitHub `release/v3` branch is validated against the current sibling
`../jido_chat` working tree. The core uses consolidated Jido V3. This is local
integration evidence. It is not Hex publication or live provider evidence.

The adapter keeps these V3 boundaries:

- one stateless `Jido.Chat.Adapter` for GitHub REST operations;
- strict native or unsupported capability values;
- typed core request, result, and inbound Signals;
- direct normalization of verified webhook input;
- provider credentials in `Client.credentials`;
- adapter settings in `Client.config`;
- provider transport in `Client.transport`;
- managed Room and provider runtime in Jido Chat core.

## Current migration changes

- Replaced the fixed remote Jido Chat source with `path: "../jido_chat"` for
  every local environment.
- Removed the stale Jido Chat lock entry and selected the consolidated Jido V3
  commit required by the local core.
- Retained the later `git_ops` lock update from `origin/main` without a
  cherry-pick commit.
- Replaced the removed credential-merging client helper with explicit
  credentials, config, and transport access.
- Moved the token to a distinct transport argument. Generic transport options
  contain adapter config but no token or credentials key.
- Added direct missing-token and credential-separation tests.
- Replaced stale binding, capability, source-pin, and separate-runtime-owner
  documentation with the current Jido Chat V3 contract.

## Offline evidence

Normal tests use a fixed transport and fixtures. They make no GitHub request.
Live tests keep the `:live` tag and remain excluded by default.

The current result is 15 offline tests passed and one live test excluded. The
Adapter Test Kit contract gate passes 10 tests. Built-in coverage is 96.13%.
Quality, HTML and Markdown documentation, production compile, unused
dependency, compile-graph, dependency-tree, retired-reference, diff, and
design-review checks pass. The compile graph has six files, no compile edges,
and no cycles. Production compilation reports dependency compiler warnings
only.

## Dependency boundary

```text
jido_chat_github
└── jido_chat (path: ../jido_chat)
    └── jido (consolidated V3 source selected by Jido Chat)
```

The adapter lock contains no Jido Chat remote source. Package publication must
later replace the local path with the released Jido Chat V3 Hex constraint and
repeat the same gates.

## Live evidence

No live or paid provider call ran. GitHub credentials, permissions, remote
REST delivery, webhook verification, and external service behavior are not
verified by this local unit.
