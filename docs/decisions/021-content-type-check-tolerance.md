# ADR-021: Content-type check: compare content with the extension, with tolerance

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
The check compared the detected type with itself and always passed.
Comparing strictly would reject valid files: a `.docx` is detected as
`application/zip`, `audio/wav` as `audio/x-wav`.

## Decision
Content is compared with the type the filename's extension claims, and
these are not mismatches: the same family (`image/*`, `audio/*`,
`video/*`), ZIP content declared as a ZIP-based format, `application/xml`
vs `text/xml`, and an unknown extension. SVG only matches SVG, because it
can carry scripts.

## Alternatives Considered

### Strict equality
- Rejected: false rejections for common files.

## Consequences
- What matters is how the file will be served, and the extension decides
  that. Image bytes named `.html` are still rejected.
- A table test in `mime_detector_test.exs` guards the rules.
