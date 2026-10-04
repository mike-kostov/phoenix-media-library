# ADR-010: Compile guards for optional dependencies

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-03-01 (v0.5.1)

## Context
Apps without S3 or Oban saw about 15 compile warnings from modules that
referenced missing dependencies.

## Decision
Every module that needs an optional dependency is wrapped in
`if Code.ensure_loaded?(Dep)`: `ImageProcessor.Image`,
`AsyncProcessor.Oban`, `Storage.S3`.

## Consequences
- New optional integrations follow the same pattern.
- A missing dependency shows up as a clear "module not available" error,
  not a compile warning.
