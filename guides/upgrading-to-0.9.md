# Upgrading to 0.9

Most apps upgrade by bumping the version and running the doctor once.
This page lists every change you might notice, what to do about it, and
how to keep the old behaviour where that is possible.

```elixir
{:phx_media_library, "~> 0.9"}
```

0.9 needs `req ~> 0.7.4`. Req before 0.6.1 has two security advisories;
if another dependency holds Req back, update it first.

## After upgrading

Run the doctor and read its report. It changes nothing without a flag:

```bash
mix phx_media_library.doctor
```

Then repair what it reports, for example:

```bash
mix phx_media_library.doctor --regenerate   # placeholders, missing derivatives
mix phx_media_library.doctor --rename       # move files to the new naming (URLs change)
```

`--rename` changes the URLs of the files it moves, so pages or caches
holding old URLs will 404. Skip it if that matters to you; old names keep
working.

## Things your code may need to change

### Direct uploads to S3

`presigned_upload_url/3` is deprecated in favour of `presigned_upload/3`,
which returns the method too. On AWS disks the upload is now a form POST,
whose signed policy makes S3 enforce the size limit; a client that still
sends a PUT gets an error from S3.

- New code: use `presigned_upload/3` and the uploader in the
  [storage guide](storage.md#direct-uploads-to-s3), which handles POST and
  PUT.
- To keep a PUT client: set `direct_upload: :put` on the disk. The PUT
  must send the `content-type` that was signed (`:content_type`, or the
  type of the filename).

`complete_external_upload/4` needs only `filename:`. It reads the size
and type from the stored object and ignores `:content_type` and `:size`.

### `consume_media/5`

When some uploads fail it returns `{:error, {:partial, saved, failed}}`
instead of the first error, so the saved media are no longer lost. Code
that matches `{:error, _}` keeps working; code that matched a specific
reason must match the `:partial` tuple, where `failed` holds
`{entry, reason}` pairs. Success is unchanged.

### Maintenance tasks

The old tasks still run and print a notice. They go in 0.10.0.

| Before | Now |
|---|---|
| `mix phx_media_library.regenerate` | `mix phx_media_library.doctor --rebuild --only conversions` |
| `mix phx_media_library.regenerate_webp` | `mix phx_media_library.doctor --rebuild --only webp` |
| `mix phx_media_library.regenerate_responsive` | `mix phx_media_library.doctor --rebuild --only responsive` |
| `mix phx_media_library.drop_originals` | `mix phx_media_library.doctor --drop-originals` |

## Changed defaults

### Stored filenames

New uploads are stored under a name the library chooses, never the
uploader's: `posts_42_images_<uuid>.jpg` by default. The uploaded name is
kept in `metadata["original_file_name"]`, and the library uses it for alt
text and download names.

- Existing media keep their names; `doctor --rename` moves them.
- For readable names, set `file_naming: :slug` globally or per collection
  (`red-summer-dress.jpg`). There is no way to store the uploader's name
  as is; it was unsafe.

### Placeholders

Every image gets a placeholder, a 32px WebP of about 260 bytes, made in
the background after the upload. The image components show it as the
image's background. Before, only `<.responsive_img>` showed one, a JPEG of
2 to 5 KB, for media with responsive variants.

- To keep them off: `config :phx_media_library, placeholder: false` (or
  the old `responsive_images: [tiny_placeholder: false]`).
- With placeholders on, every image upload starts a background job, even
  in collections without conversions. With Oban that is one job per image.
- `doctor --regenerate` makes placeholders for existing media and replaces
  the old JPEG ones.

### Conversions in WebP and AVIF collections

In a collection with `webp:` or `avif:` on, conversions without their own
`format:` are now WebP (or AVIF) files. To keep a JPEG conversion, give it
a format:

```elixir
convert :thumb, width: 150, height: 150, fit: :cover, format: :jpg
```

Existing conversions change after
`mix phx_media_library.doctor --rebuild --only conversions`, which removes
the old files.

A conversion with `format:` is now stored with that format's extension
(`photo_thumb.webp`, not WebP bytes in `photo_thumb.jpg`). Conversions
stored before keep their paths.

### Responsive variants of conversions

A conversion with the original's shape, such as a width-only `:preview`,
gets no variants of its own; its `srcset` uses the original's. Crops keep
theirs. Existing media keeps its variants until rebuilt.

Which conversions get variants at all is unchanged (ADR-017). A later
minor release will make conversions follow their collection's
`responsive:` setting, with a deprecation notice first.

### Image components

- `width` and `height` are set from the stored file, so the browser
  reserves the space. Scaled images need CSS `height: auto` (Tailwind's
  default). Pass `width`/`height` to override.
- Lazy `<.responsive_img>` defaults `sizes` to `"auto, 100vw"` (was
  `"100vw"`). Pass `sizes="100vw"` to keep the old value.
- Images get `decoding="async"`, except with `priority`.
- `<.picture>` offers WebP as a typed `<source>` instead of a `srcset` on
  the `<img>`.

### Cache fingerprint

`cache_bust: true` and `cdn_url/2` add `?vsn=…` (was `?v=…`), which
`Plug.Static` caches for a year. URLs with the old parameter change once.

### Download names

`download: true` URLs name the file after the upload, with an ASCII
fallback and a UTF-8 `filename*`. To keep the stored name, pass it:

```elixir
PhxMediaLibrary.download_url(media, nil, filename: media.file_name)
```

### URLs with special characters

URLs now percent-encode each path segment, so media stored under names
with spaces, `#` or Cyrillic loads. Such URLs look different, and work.

### S3

- Uploads send no ACL unless the disk sets one. AWS buckets with default
  settings reject `acl: "private"`. To keep sending it, set
  `acl: "private"` on the disk.
- `provider: :r2` or `:generic` with `endpoint:` reach other services.
  Disks without `provider:` behave as before (`:aws`).
