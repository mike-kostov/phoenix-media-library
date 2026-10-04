# ADR-013: SHA-256 checksums computed while streaming

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-27 (v0.2.0; streaming v0.5.0)

## Context
Files on cloud storage can be corrupted or replaced; integrity checks
need a stored fingerprint.

## Decision
Every upload's SHA-256 is computed while the file streams to storage
(one pass, 64 KB chunks) and stored with the record.
`verify_integrity/1` re-reads and compares; `doctor --deep` runs it for
every media.

## Consequences
- The `cache_bust` URL fingerprint reuses the checksum, so files rebuilt
  in place keep their URL (see the storage guide).
