# ADR-005: Binary UUID primary key for media

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-24 (v0.1.0)

## Context
Media rows are created from many places (uploads, direct S3 uploads,
seeds) and sometimes before the row exists the storage path is needed.

## Decision
`media.id` is a binary UUID, and every media also has a `uuid` used in
storage paths, generated before insert. The parent's ID type is
configurable (`mediable_id_type`) because host schemas use integers or
UUIDs.

## Consequences
- The storage path is known before the insert, so a failed insert can
  clean up the stored file.
- IDs from the browser must be cast with `Ecto.UUID.cast/1` before a query
  (see ADR-018).
