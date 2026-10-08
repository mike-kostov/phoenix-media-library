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

## Amendment (2026-10-04, Mike)
The AVIF compatibility spike (`docs/ideas/avif-compatibility.md`) found
that the AI APIs (Claude, OpenAI, Gemini) and most link previews read WebP
but not AVIF, and an `<img>` has no fallback for a format the reader can't
decode. Conversions are what plain URLs carry (`og:image`, emails, JSON,
your own `<img>` tags), so:
- Conversions are WebP by default, whatever the collection's `webp:` or
  `avif:` say; `format:` on a conversion overrides it, and
  `format: :original` keeps the original's format (0.8's behaviour).
- Conversions are never AVIF unless the conversion asks for it.
- AVIF exists only for the original and its variants, and is only offered
  through `<picture>` sources, with the WebP or original `<img>` as the
  fallback. Components that render AVIF wrap it in
  `<picture style="display: contents">`, so the page's layout sees only
  the `<img>`.
- Same-shape conversions reuse the original's variants only when both are
  in the same format; otherwise they get their own.
- An ordered, per-collection and per-conversion `formats:` list (AVIF and
  WebP side by side, quality per format) is planned for 0.10.0 (backlog).

## Amendment 2 (2026-10-08, spec 02 F1)
The `formats:` list replaces the fixed rules for conversions and, from
0.10.0, variants:
- Each conversion is made in every listed format, in priority order. The
  last format is the safe one: plain URLs and the `<img>` use it, so a
  plain URL is still never AVIF unless the list ends with AVIF.
- The default is `[:webp]`, so 0.9's behaviour is unchanged.
  `avif: true` is short for `[:avif, :webp]`.
- Responsive variants follow the same list (spec 02, task 11). This
  reverses "Variants in both AVIF and WebP" below, but only for apps that
  list both: storing each size twice is then their choice.

The rules below are the original decision; where they conflict, the
amendments win, the later one first.

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
- Rejected: doubles the variant files for the few browsers without AVIF
  (Safari before 16.4, Edge before 121), which still get the full-size
  WebP.

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
