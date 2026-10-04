# ADR-001: Fluent pipeline API for adding media

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-24 (v0.1.0)

## Context
Developers coming from Spatie's Laravel Media Library expect to attach a
file in one readable chain. Elixir's pipe operator gives the same shape
without method chaining on objects.

## Decision
Adding media is a pipeline over a builder struct (`MediaAdder`):

    post
    |> PhxMediaLibrary.add(upload)
    |> PhxMediaLibrary.using_filename("photo.jpg")
    |> PhxMediaLibrary.to_collection(:images)

Each option is a function that returns the updated builder; `to_collection/3`
validates, stores and persists. Bang variants (`to_collection!/3`) raise.

## Consequences
- New per-upload options are new builder functions, not new arities of
  `to_collection/3`.
- Nothing touches storage or the database before `to_collection/3`.
