# ADR-020: Images over 100 megapixels are rejected before decoding

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
A small PNG can declare 40000 × 40000 pixels. Decoding it takes gigabytes
of memory and seconds of CPU (3.2 s for a 1.2 MB, 400-megapixel file in
our measurement).

## Decision
Uploads read only the image header and reject images above the limit
with `{:error, {:image_too_large, pixels, max}}`. The default is 100
megapixels (`config :phx_media_library, max_image_pixels:`), a collection
can set `max_pixels:`, and `:infinity` disables the check.

## Consequences
- The check costs about 34 ms and no extra memory.
- 200-megapixel phone photos are rejected unless the limit is raised.
