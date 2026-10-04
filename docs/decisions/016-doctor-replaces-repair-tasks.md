# ADR-016: The doctor replaces the separate repair tasks

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
Four tasks (`regenerate`, `regenerate_webp`, `regenerate_responsive`,
`drop_originals`) each repaired one thing their own way, and `doctor --fix`
permanently deleted healthy media (WebP-only media and media missing one
conversion).

## Decision
- `PhxMediaLibrary.Health` checks one media item and maps each issue to
  one `Pipeline` step.
- `mix phx_media_library.doctor` reports by default. Repairs are opt-in
  flags (`--regenerate`, `--reextract`, `--rename`, `--drop-originals`,
  `--fix`, `--rebuild`), shown as a plan and confirmed before running.
- `--fix` deletes only media with no files left.
- The four tasks are deprecated in 0.9.0 (they still work and print a
  notice) and removed in 0.10.0.

## Alternatives Considered

### Keep the tasks, fix them one by one
- Rejected: four entry points with overlapping options, and no single
  health report.

## Consequences
- One command to learn; the checks are also callable from code (an admin
  page, a scheduled job).
- Removing the tasks in 0.10.0 needs a CHANGELOG entry and a guide update.
