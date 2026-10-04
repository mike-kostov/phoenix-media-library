# ADR-003: Async processing behaviour with Task default and Oban option

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-24 (v0.1.0)

## Context
Conversions can take seconds per image. Most apps are fine with a
background task; production apps want retries and persistence.

## Decision
`PhxMediaLibrary.AsyncProcessor` is a behaviour. `AsyncProcessor.Task`
(Task.Supervisor) is the default, `AsyncProcessor.Oban` is optional, and
`AsyncProcessor.Inline` runs synchronously for tests and scripts.

## Consequences
- No Oban dependency for apps that don't need it.
- With the Task processor, pending conversions are lost on a crash;
  `mix phx_media_library.doctor --regenerate` recreates them.
