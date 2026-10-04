# ADR-009: Three tiers of LiveView components

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-03-01 (v0.5.1)

## Context
Some apps want an upload widget in one line; others need full control of
markup and events.

## Decision
Three tiers: `MediaLive` (a LiveComponent, zero boilerplate),
`<.media_upload>` plus `<.media_gallery>` (composable function components),
and `PhxMediaLibrary.LiveUpload` helpers (full control).

## Consequences
- `MediaLive` is a LiveComponent on purpose (see AGENTS.md design rules).
- All tiers must work without the host app's `core_components`.
