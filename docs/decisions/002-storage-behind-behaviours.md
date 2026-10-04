# ADR-002: Storage behind a behaviour

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-24 (v0.1.0)

## Context
Apps store files on local disk, S3 and other services, and tests want
storage without a filesystem.

## Decision
`PhxMediaLibrary.Storage` is a behaviour. The library ships `Disk`, `S3`
and `Memory` adapters, configured per disk. `StorageWrapper` passes each
disk's config and emits Telemetry. Optional callbacks: `path/2` (a local
path, when the adapter has one) and `presigned_upload_url/3`.

## Consequences
- A new backend is a new adapter; the rest of the library doesn't change.
- Code that needs a local file must not assume `path/2` exists. Since
  ADR-014 it goes through `PhxMediaLibrary.LocalSource`, which fetches a
  temporary copy when there is no local path.
