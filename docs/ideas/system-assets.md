# Idea: the app's own images through the library

Captured 2026-10-09 (Mike), during an app's upgrade to 0.10. For 0.11.

## Problem

An app's own images (logo, hero images, page photos in `priv/static`) are
served as they are: no placeholders, BlurHash, WebP, AVIF or responsive
sizes, unlike uploaded media. Apps write their own tasks to make WebP
copies.

## Direction (discussed, not agreed in detail)

- **One owner for the app's files:** `mediable_type: "assets"` with a fixed
  id; each key is a one-file collection, `collection_name: "brand/logo"`.
  The (type, id, collection) index finds a key.
- **Settings per namespace,** declared like a schema's:
  `use PhxMediaLibrary.Assets` with `media_collections`.
- **Requested by key:** `asset("home/hero")` for the components,
  `asset_url("brand/logo", :thumb)`; cached in memory, a fallback and a log
  line for a missing key.
- **A repeatable sync, not a migration per image:** files under
  `priv/assets/<namespace>/<key>.<ext>`; new files added, changed ones (by
  checksum) replaced, unchanged skipped, removed ones reported, never
  deleted. `mix phx_media_library.assets.sync`, and `bin/media_assets sync`
  in releases, run on deploy next to migrations.
- **Later:** assets an editor changes in an admin page, on the same rows.

## Risks

- The doctor and `clean` must know the assets owner: today "assets" has no
  table, so its rows would read as orphans and `doctor --fix` would delete
  them. A test that `--fix` leaves assets alone.
- Adding assets only inserts rows; uploads are untouched.

## Open questions

1. File-based sync first, admin-managed later (proposed)?
2. Key format: `brand/logo` or `brand.logo`; extensions in keys or not.
3. Where the sync runs in releases: a generated command (proposed) or at
   boot.
