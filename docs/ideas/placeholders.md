# Idea: Lighter image placeholders

Captured 2026-10-04, from the 0.9.0 performance review.

## Problem

`responsive_img` shows a placeholder until the real image loads. Today it
is a 32px blurred copy of the image, base64-encoded into the HTML:
0.5 to 1 KB per image, so a page of 40 product images carries 20 to 40 KB
of placeholders before any image downloads.

## Options

- Dominant color. One color from the image, set as the background while
  the image loads. About 7 bytes, no JavaScript. Not implemented yet;
  libvips can compute it at upload.
- Blurhash. About 30 characters, drawn as a blur by a small script. Already
  shipped as an optional `<.blurhash>` component.
- Tiny image. What `responsive_img` does today.

## Proposal

Dominant color by default for every image, and the tiny image only for
`priority` images, where a richer placeholder is worth the bytes.

## Status

Waiting for a decision before the 0.9.0 spec.
