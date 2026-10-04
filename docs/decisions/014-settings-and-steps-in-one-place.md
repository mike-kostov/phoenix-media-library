# ADR-014: Collection settings and processing steps live in one place

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
Uploads and four maintenance tasks each looked up per-collection settings
their own way, and they had drifted. `regenerate_webp` used the global WebP
settings unless given `--model`, `drop_originals` ignored a collection's
`keep_original`, `regenerate_responsive` used the global widths, and
`regenerate` called `String.to_atom` on collection names.

## Decision
- `PhxMediaLibrary.Model` resolves every per-collection setting (WebP,
  responsive, file naming, pixel limit, conversions) from a model struct, a
  model module or a media record.
- `PhxMediaLibrary.Pipeline` has one function per processing step:
  metadata, WebP, responsive variants, conversions, dropping the original,
  renaming. Steps return `{:ok, media}` (or `:ok`), `{:skip, reason}` or
  `{:error, reason}`.
- Uploads (`MediaAdder`), mix tasks and the doctor call these and nothing
  else.

## Alternatives Considered

### Shared helper functions, task code kept
- Pros: smaller change.
- Rejected: the drift came from each caller assembling settings itself;
  shared helpers would not have stopped that.

## Consequences
- A repair produces what an upload produces.
- A new setting or step is added once, in `Model` or `Pipeline`.
- `MediaAdder` lost its private copies (86 lines).
