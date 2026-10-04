# ADR-024: Derivatives in the served format, variants in one format only

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
With WebP on, responsive variants were already WebP only. Two cases still
stored more than needed. Measured on a 1600x1200 JPEG in a collection with
WebP and responsive variants:
- conversions ignored WebP: `:preview` (8,402 bytes) and `:thumb` were
  JPEGs, while the page shows them more than anything else;
- the width-only `:preview` got 160w and 320w variants identical to the
  original's.
AVIF (spec 01, F3) would add a second modern format, and with it the
question of producing every size twice.

## Decision
- Responsive variants are generated only in the best format that is on:
  AVIF, else WebP, else the original's format.
- The full-size image keeps a fallback chain (AVIF, WebP, original) for
  browsers without AVIF.
- Conversions are saved in the served format (AVIF over WebP) unless the
  conversion sets `format:` itself.
- A conversion with the original's aspect ratio gets no variants of its
  own; its `srcset` reuses the original's variants up to its width.

## Alternatives Considered

### Variants in both AVIF and WebP
- Pros: browsers without AVIF still choose a size.
- Rejected: doubles the variant files for about 5% of browsers, which still
  get the full-size WebP.

### Conversions keep the original's format
- Pros: no behaviour change.
- Rejected: the most-viewed images stay the largest.

## Consequences
- Fewer files and smaller pages; a 0.9.0 behaviour change for conversions.
- Existing conversions change format only after
  `doctor --rebuild --only conversions`.
- `srcset` for same-shape conversions is built from the original's
  variants, so the two must stay in the same format (they do, by the first
  rule).
