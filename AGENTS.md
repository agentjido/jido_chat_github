# AGENTS.md - Jido Chat GitHub

This package implements GitHub Issues support for `Jido.Chat`.

- Core adapter: `Jido.Chat.GitHub.Adapter`
- Default transport: `Jido.Chat.GitHub.Transport.ReqClient`
- Live tests are tagged `:live` and require explicit environment variables.
- Use injectable transports for unit tests.

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
