# Idea: Rename the library

Captured 2026-10-04, from the "Pending" decisions in `PRIORITIES.md`.

## Problem

The `Phx` prefix suggests a Phoenix-only library. When the name was first
questioned, the core was Ecto-only. That has changed: the library now
ships LiveView components and a Plug, and is tied to Ecto associations, so
the prefix fits better than it did.

## Options

`PhxMediaLibrary` (keep), `PhxMedia`, `ExMedia`, `Mediator`.

## Status

Parked. A rename costs every user a dependency and module rename, so it
only makes sense together with a 1.0 release, if at all.
