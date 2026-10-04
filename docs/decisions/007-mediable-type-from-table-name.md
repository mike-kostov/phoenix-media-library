# ADR-007: Polymorphic type derived from the Ecto table name

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-27 (v0.2.0)

## Context
The first version appended "s" to the module name, which broke irregular
plurals (`Category` became "categorys").

## Decision
`mediable_type` is the schema's table name (`__schema__(:source)`).
Override with `use PhxMediaLibrary.HasMedia, media_type: "..."` or by
defining `__media_type__/0`. Schemas without Ecto fall back to the
underscored module name.

## Consequences
- Renaming a table changes the type of existing rows; a migration guide is
  still missing (backlog).
