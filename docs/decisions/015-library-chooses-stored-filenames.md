# ADR-015: The library chooses stored filenames

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
Stored paths used the uploader's filename. That allowed path traversal
(`../../app.js`) and produced URLs that broke on spaces, `#` or `?`.
Unicode names behave differently across filesystems (macOS normalizes `é`
differently from Linux; macOS and Windows ignore case) and allow tricks
such as right-to-left override characters.

## Decision
- New uploads are stored under a name the library chooses, ASCII only
  (`a-z0-9-_` plus a lowercase extension). The extension comes from the
  detected content, not the uploader.
- Three strategies, set globally (`file_naming:`) and per collection:
  `:semantic` (default), `{type}_{id}_{collection}_{uuid}.{ext}`, enough to
  rebuild a lost record by hand; `:slug`, the original name as a slug, for
  SEO, with Cyrillic transliterated (Bulgarian official system, 2009) and
  accents dropped; `:random`, which reveals nothing in the name but does not
  protect the file.
- The uploaded name is kept in `metadata["original_file_name"]` for display.
- Existing media keep their names; `doctor --rename` moves them.

## Alternatives Considered

### Sanitized client names
- Pros: readable, no URL change for users.
- Rejected: still Unicode and case problems, and no recovery value.

### UUID-only names
- Pros: simplest, nothing leaks.
- Kept as the `:random` strategy rather than the default: a file found
  outside the database says nothing about where it belongs.

## Consequences
- New uploads' URLs look different; this is a minor-version change
  (0.9.0).
- Nothing may fall back to the stored name for display. Alt text comes from
  `Media.alt_text/1`.
- `:semantic` names show record IDs in URLs, as the default directory
  layout already did.
