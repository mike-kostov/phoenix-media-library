# Image placeholders

Captured 2026-10-04 from the 0.9.0 performance review, refined with the
`idea-refine` skill. Target release: 0.9.0.

## Problem Statement

How might we show something that looks like the image in its space before
it loads, on every kind of page, without making the page heavier?

## What exists today

- `responsive_img` sets a tiny blurred copy of the image (32px JPEG, inline
  data URI) as its background, but only for media that has responsive
  variants. Media without `responsive:` gets no placeholder.
- That tiny image keeps the photo's metadata (EXIF, color profile). Measured
  on two sharo-shop product photos it is 5,459 and 1,999 bytes; stripped of
  metadata the same image is about 1,100 bytes. A page of 40 products
  carries 80 to 200 KB of placeholders. This is a bug.
- `<.blurhash>` draws a blurhash with a LiveView hook. Hooks run only after
  the page connects, so it shows nothing on first paint, on controller
  pages, or in emails. Generation (about 10 ms) runs during the upload.

## Recommended Direction

Every image gets a placeholder by default. The default is a 16px WebP with
metadata stripped, set as the image's background: about 150 bytes (140 and
176 bytes on the two photos), so 40 images add about 6 KB. It shows the
image's shape and colors, needs no JavaScript, and works on LiveView pages,
controller pages, and anywhere inline CSS works. Emails that strip inline
backgrounds show no placeholder, which is harmless.

A collection chooses with `placeholder: :blur | :color | false`, and a
global setting gives the default (`:blur`). `:color` is the image's average
color (7 bytes), for pages with very many images or a plain look. `false`
leaves only the space reserved by `width`/`height`.

Placeholders are computed in the background by the async processor (`Task`
by default, Oban when present), not during the upload. Until one is ready,
the image has no placeholder. `mix phx_media_library.doctor --regenerate`
fills them in for existing media.

## Key Assumptions to Validate

- [ ] A 16px image scaled up by the browser looks smoothly blurred, not
      blocky. Check in a browser on a product grid and a hero image before
      building.
- [x] About 150 bytes holds across typical photos, not only the two
      measured. Measured 2026-10-04 on the 235 photos in
      `sharo-shop/tmp/rc-photos`, 16px WebP, default quality, metadata
      stripped: median 122 bytes, 95th percentile 172, max 384; none carry
      EXIF or a color profile.
- [ ] Today's `tiny_placeholder` setting can map onto the new option so
      existing configs keep working.

## MVP Scope

In:
- Placeholder generation as a `Pipeline` step, run by the async processor,
  for every image, original and conversions.
- `placeholder:` collection option and global default; `:blur`, `:color`,
  `false`.
- `responsive_img`, `media_img`, `picture` and the gallery use it.
- The metadata bug fixed for whatever is generated.
- The doctor reports and repairs missing placeholders.
- Documentation: a README section that shows what the library does for page
  speed (placeholders, `width`/`height`, `sizes`, `priority`, caching) with
  a short example; the collections guide documents the option; the
  examples show it on a product grid and a hero image.

Out: everything in Not Doing.

## Not Doing (and Why)

- Dominant color. On product photos with a white background the dominant
  color is white (`#f8f8f8` for both measured photos), so the placeholder is
  invisible. The average color is used for `:color` instead.
- JavaScript blurhash as the default. Blank on first paint and absent
  outside connected LiveView pages. `<.blurhash>` stays as an opt-in.
- A 3x3 CSS color grid. About as small as the WebP (48 to 72 bytes) but
  blockier, and more code.
- Decoding blurhash or ThumbHash on the server. No gain over the WebP.
- Progressive JPEG. Media is served as WebP, which has no progressive mode.

## Open Questions

- Where the placeholder is stored: `responsive_images` (as today, per
  conversion) or a field of its own. Decide in the spec.
- Whether `<.blurhash>` generation also moves to the background.
