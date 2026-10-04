# ADR-019: Collection limits: the newest upload wins, without locks

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
Two uploads racing on a `single_file` collection could each delete the
other: both saw two rows and each deleted "everything except me". The
library supports any Ecto adapter, and portable row locks don't exist.

## Decision
An upload deletes only media older than itself, ordered by position,
insertion time, then ID. The newest item is never deleted. `max_files`
keeps the newest `max` by the same order.

## Alternatives Considered

### Transaction with an advisory or row lock
- Pros: exactly one survivor.
- Rejected: adapter-specific (Postgres advisory locks, MySQL `GET_LOCK`).

## Consequences
- In the rare worst case both items remain until the next upload. The
  collection is never left empty.
