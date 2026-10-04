# ADR-011: ModelRegistry for finding a model from its mediable type

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-03-01 (v0.5.1; loading on miss 2026-10-04)

## Context
Oban jobs, mix tasks and repairs start from a media row and need the
model module to read its collection settings. The lookup lived inside the
Oban worker.

## Decision
`PhxMediaLibrary.ModelRegistry` is always compiled. It checks an explicit
`model_registry` config, then scans loaded modules, caching hits in
`:persistent_term`. Since 2026-10-04 it loads all application modules and
scans once more on a miss, because mix tasks run with lazily loaded
modules.

## Consequences
- Production apps can set `model_registry` to skip scanning.
