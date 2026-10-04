# ADR-004: Application environment for global defaults, schemas for the rest

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-24 (v0.1.0)

## Context
A library needs a repo, disks and defaults from the host app. Spreading
everything through global config makes per-collection behaviour hard.

## Decision
Global defaults (repo, disks, WebP, responsive widths, file naming,
pixel limit) live in `config :phx_media_library`. Anything that can differ
per collection is also a collection option, and the collection wins.
Per-upload options win over both.

## Consequences
- Settings resolve in the order upload option, collection, global, library
  default. Since ADR-014 that resolution happens only in
  `PhxMediaLibrary.Model`.
