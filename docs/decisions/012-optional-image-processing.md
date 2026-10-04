# ADR-012: Image processing is optional

## Status
Accepted. Recorded on 2026-10-04 from `PRIORITIES.md`.

## Date
2026-02-27 (v0.2.0)

## Context
Many apps only attach PDFs or CSVs. Requiring libvips to store a PDF
blocks them.

## Decision
`:image` is an optional dependency. `ImageProcessor.Null` answers with
clear errors when it is missing, and `Config.image_processor/0` picks
`ImageProcessor.Image` when `:image` is loaded.

## Consequences
- Image features (conversions, WebP, responsive variants, blurhash,
  pixel limit) quietly do nothing without libvips.
