# ADR-006: Declarative schema DSL with nested collections

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-27 (v0.2.0; nested style v0.5.1)

## Context
Returning lists of structs from `media_collections/0` works but reads
like configuration from afar, and conversions had to name their
collections explicitly.

## Decision
Schemas declare collections and conversions with macros. Nesting
`convert` inside `collection ... do` scopes the conversion to that
collection and is the recommended style. The function style
(`def media_collections`) stays supported, and the two can be mixed per
concern.

## Consequences
- Collections and conversions are compile-time data, available through
  `media_collections/0` and `media_conversions/0`.
