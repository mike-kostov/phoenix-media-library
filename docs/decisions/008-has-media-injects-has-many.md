# ADR-008: has_media() injects polymorphic has_many associations

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-27 (v0.2.0)

## Context
Ecto developers expect `Repo.preload(post, :media)`, not only query
helpers.

## Decision
`has_media()` inside the schema block injects `has_many :media` scoped by
`mediable_type`; `has_media(:images)` injects a collection-scoped
association. It calls `Ecto.Schema.__has_many__/4` at module compilation
to avoid macro-expansion timing issues.

## Consequences
- The associations don't exclude soft-deleted media or order results.
  Code reading them must do both (`Model.preloaded_media/2` does).
