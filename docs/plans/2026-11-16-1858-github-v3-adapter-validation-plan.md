---
title: GitHub adapter current Jido Chat V3 validation
type: implementation-plan
date: 2026-11-16
last_reviewed: 2026-11-16
artifact_contract: kata-plan/v1
artifact_readiness: complete
domain: software
execution: code
product_contract_source: approved-goal
---

# GitHub Adapter Current Jido Chat V3 Validation

## Goal Capsule

- Objective: Make the GitHub `release/v3` migration work with the current
  local Jido Chat V3 source and leave no retired messaging dependency,
  ownership reference, or obsolete core API.
- Means: Select the local Jido Chat path, update the explicit client contract,
  keep provider credentials separate from transport options, correct stale
  documentation, run all offline gates, and complete an Elixir design review.
- Authority: Local GitHub adapter and Jido Chat checks and local GitHub adapter
  edits. No live GitHub request, credential use, commit, push, release, or
  remote update.
- Stop conditions: Stop before provider I/O, a provider branch in core, a
  second process tree, or a compatibility API.
- Next executor: Elixir package engineer.

## Starting Evidence

- `release/v3` starts clean at `9c890e6` and matches `origin/release/v3`.
- The branch already uses current channel, capability, invocation,
  normalization, typed Signal, and Adapter Test Kit boundaries.
- It still selects an older fixed Jido Chat Git source and calls the removed
  client option helper.
- The REST transport reads the token from a mixed option list. The current
  client contract keeps credentials and adapter config separate.
- The README and validation report describe an older candidate, old source
  commits, removed binding APIs, old capability claims, and a separate
  Messaging runtime owner.
- `origin/main` has one later `git_ops` lock update. This unit will retain its
  result without creating a cherry-pick commit.

## Product Contract

- **R1:** Every local environment selects `path: "../jido_chat"`.
- **R2:** Credentials, config, and transport stay explicit. The token does not
  enter request or result Signals or a general transport option list.
- **R3:** The adapter remains stateless. Verified GitHub webhook input
  normalizes directly, and Jido Chat core owns managed Room and provider
  runtime.
- **R4:** All declared native operations use current typed request and result
  Signals. Unsupported operations stop before REST I/O.
- **R5:** GitHub issue-comment identity, pagination, provider errors, and
  normalization stay deterministic and covered without network access.
- **R6:** Documentation states the current V3 API, actual capability set,
  local dependency boundary, and Jido Chat runtime ownership.
- **R7:** Normal tests make no live GitHub request. Live tests remain tagged
  and excluded.
- **R8:** Tests, contracts, coverage, quality, docs, production compile,
  unused dependencies, compile graph, dependency tree, source scan, diff
  check, and design review pass.

## Implementation Units

1. Replace the fixed Jido Chat Git dependency with the sibling local path,
   remove its stale lock entry, and retain the later `git_ops` lock result.
2. Replace the removed client helper with explicit credentials, config, and
   transport arguments. Add direct tests for credential separation.
3. Replace obsolete binding, capability, runtime-owner, release, and source
   documentation with current local V3 guidance.
4. Run all offline gates and an Elixir design review, fix supported findings,
   and repeat affected checks.

## Verification Contract

Run from `/Users/mhostetler/Source/Jido/jido_chat/jido_chat_github`.

- The normal suite excludes `:live` and makes no provider request.
- Contract, coverage, quality, docs, production compile, unused dependency,
  xref cycle and stats, dependency tree, and diff checks pass.
- The dependency tree resolves Jido Chat from `../jido_chat`.
- Repository search finds no retired package name, removed client helper, old
  V2 constraint, old Jido Chat Git source, or obsolete source commit.
- No accepted Elixir design-review finding remains.

## Risks and Mitigations

- Risk: a token enters generic transport options. Mitigation: pass the token
  in a distinct transport argument and test the exact option list.
- Risk: old README capability claims hide feature loss. Mitigation: generate
  the documented list from the adapter's current declared contract during
  review and keep unsupported operations explicit.
- Risk: live tests make GitHub changes. Mitigation: preserve the `:live` tag
  and use only the recording transport in normal tests.

## Definition of Done

- R1 through R8 have current evidence.
- GitHub uses the same local Jido Chat V3 tree as Telegram and Discord.
- No live provider check or remote change occurred.

## Execution Result

Completed in the local working tree on 2026-11-16. The branch and HEAD remain
`release/v3` at `9c890e6`; no commit was created.

- Selected `../jido_chat` in every environment and removed the stale remote
  Jido Chat lock entry.
- Retained the later `git_ops` 2.12.4 lock result from `origin/main` without a
  cherry-pick commit.
- Replaced the removed client option helper with explicit credentials, config,
  and transport fields.
- Passed the token to the transport as a distinct private argument. Generic
  transport options contain adapter config but no token or credentials key.
- Added missing-token, operation, normalization, default Req transport, and
  provider-error tests.
- Replaced old binding, capability, source-pin, and runtime-owner documentation
  with the current Jido Chat V3 contract.
- Kept the live test excluded. No GitHub credential or provider endpoint was
  used.

## Design Review Result

The Elixir design review found and fixed four issues.

1. The transport behavior and Req client kept nine REST functions that no V3
   capability used. The dead callbacks, implementations, and test stubs were
   removed.
2. Operation and normalization list builders used repeated list append. They
   now prepend and reverse once, while preserving provider order.
3. The default Req transport had no offline tests. A recording Req adapter now
   verifies paths, methods, authentication, JSON, pagination, success,
   provider errors, and transport errors without network access.
4. The package had no explicit contract or coverage gate, and coverage output
   appeared as an untracked directory. The Adapter Test Kit has a dedicated
   contract alias, quality enforces built-in coverage, and `/cover/` is ignored.

No accepted finding remains.

## Verification Result

- Full offline suite: 15 passed; one live test excluded.
- Adapter Test Kit contract gate: 10 passed.
- Coverage: 96.13%.
- `mix quality`: passed, including warnings-as-errors compile, strict Credo,
  tests, and coverage.
- Documentation: HTML and Markdown generated without a package warning.
- Production compile with warnings as errors: passed. Dependency compiler
  warnings remain outside this package.
- Unused dependencies: none.
- Compile graph: six files, no compile edges, zero cycles.
- Dependency tree: Jido Chat resolves from `../jido_chat` and consolidated Jido
  resolves at `ec96da60`.
- Retired-package, removed-helper, old binding API, old source-commit, old Hex
  constraint, and old Git-source scan: no matches.
- `git diff --check`: passed.
