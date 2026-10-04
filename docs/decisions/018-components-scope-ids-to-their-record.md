# ADR-018: Components scope client-supplied IDs to their own record

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
`MediaLive`'s delete event deleted any media ID the browser sent. A user
allowed to edit one record could delete media attached to another by
changing the ID. The media table has no owner or uploader column.

## Decision
- A component only acts on media of the record and collection it was given
  (`Media.get_for_model/3`); other IDs are "not found". Malformed IDs are
  "not found" too.
- `LiveUpload.delete_media_by_id/2` takes `:model` and `:collection` for the
  same check.
- Whether a user may edit a record is the host app's decision. The library
  adds no user or owner concept.

## Alternatives Considered

### Add an owner or uploader ID column
- Rejected: users and permissions belong to the app; apps that want it can
  store it in `custom_properties`.

## Consequences
- Without `:model`, `delete_media_by_id/2` accepts any ID and the caller
  must check permission; the docs say so.
