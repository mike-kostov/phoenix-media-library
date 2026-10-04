# ADR-022: No CI for this project

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
The library is maintained by one person and has no GitHub Actions or
other CI.

## Decision
No CI (Mike, 2026-10-04). `mix precommit` is the only gate, and it runs
before every commit.

## Consequences
- `mix precommit` must pass on `main` to be a usable gate. It currently
  stops at `credo --strict` (16 findings) and an unformatted file; fixing
  that is in the backlog.
- Each commit is verified locally, including in a clean worktree when a
  change is split into several commits.
