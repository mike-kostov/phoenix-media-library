# Spec 02: Release 0.10.0

Status: draft, 2026-10-05. Waiting for Mike's review.
Source: `docs/backlog.md` (0.10.0 section), `docs/ideas/db-performance.md`,
`docs/ideas/media-indexes.md`, ADR-017, ADR-024 (amended).

## Objective

0.10.0 makes image formats configurable per app and per conversion, makes
sure the library doesn't slow down the apps it is in, removes what 0.9.0
deprecated, and settles the responsive rules. 0.9.0 is on Hex, so the
upgrade notes cover 0.9 to 0.10. It is a minor 0.x release: breaking
changes are allowed, each with a CHANGELOG entry and an upgrade note.

## Assumptions

1. Postgres stays the only supported database in 0.10.0; SQLite is
   assessed by the database spike, and built only if Mike agrees after.
2. The database work starts as a spike (P1); changes it leads to are
   specced here after Mike reviews the numbers.
3. Commands, project structure, code style, testing and boundaries are
   those of spec 01 and `AGENTS.md`.

## Features

**F1. An ordered `formats:` list.** (backlog 0.10.0; ADR-024 amendment)
- `formats:` per collection and per conversion (a conversion's list
  wins), and globally. Default `[:webp]`, as 0.9.0's safe default.
- Priority order. Each conversion and responsive variant is made in every
  listed format, from the original. The last format is the safe one: plain
  URLs (`url/2`, `og:image`, emails) and the `<img>` use it; the earlier
  ones become typed `<picture>` sources, in order.
- Quality per format, as a keyword list that keeps the order:
  `formats: [avif: [quality: 50], webp: [quality: 80]]`; plain atoms mix
  in.
- `:original` means the uploaded file's format (a PNG stays PNG).
- Covers conversions and variants; the original's own copies stay with
  `webp:` and `avif:`. `avif: true` becomes shorthand for
  `formats: [:avif, :webp]`; a conversion's `format: x` for
  `formats: [x]`.
- Delete, clean, rename, the doctor and shared variants (F8 of spec 01)
  handle several formats per size.

**F2. Bulk ingestion.** (Mike, 2026-10-05) A route for importing many
media at once that doesn't write each row six to eight times. Its design
waits for the database spike (P1); this spec gets its details then.

### Changes

**C1. Removed: what 0.9.0 deprecated.**
- `PhxMediaLibrary.presigned_upload_url/3` and the `presigned_upload_url/3`
  storage callback.
- `mix phx_media_library.regenerate`, `regenerate_webp`,
  `regenerate_responsive` and `drop_originals` (use the doctor).

**C2. One responsive rule.** (ADR-017) Today originals get responsive
variants only when their collection sets `responsive:`, while conversions
get them whenever the global `responsive_images` switch is on, which is
the default. 0.10.0 makes conversions follow their collection too: no
`responsive:`, no variants. Apps that relied on the old rule set
`responsive: true` on the collection; the upgrade notes say so.

**C3. Media table indexes.** (`docs/ideas/media-indexes.md`, Mike
2026-10-05) In the installer template: drop the redundant
(mediable_type, mediable_id) index and the checksum index, make
(deleted_at) a partial index, and drop (collection_name) unless P1 shows a
use. Existing apps get an optional migration and an upgrade note. P1 may
add to this.

### Project

**P1. Database spike.** (`docs/ideas/db-performance.md`) Postgres, 100,000
then 1,000,000 media rows:
- writes, dead rows, index writes and WAL per image upload, and their
  effect on concurrent reads;
- latency of what apps do: a page of records with media preloaded,
  `get_media` per record, joins from app tables to media, while uploads
  run;
- the levers ranked by measured effect, and what SQLite support would
  take.
Result: an idea doc with numbers and recommendations, reviewed with Mike.

**P2. Upgrade notes and docs.** `guides/upgrading-to-0.10.md` lists each
change from 0.9 and how to adapt; README and guides match 0.10.0; no
warnings anywhere (as 0.9.0's P5).

## Success criteria

- F1: a collection with `formats: [:avif, :webp]` stores every conversion
  and variant in both formats, `<picture>` offers AVIF then WebP, and every
  plain URL is WebP; a conversion with `formats: [:original]` stays in the
  upload's format.
- C1: the removed functions and tasks are gone, and the upgrade notes say
  what replaces each.
- C2: in a collection without `responsive:`, conversions get no variants.
- C3: new installs get the new indexes; the optional migration runs on a
  0.9 database.
- P1 is reviewed with Mike before F2 is specced.
- `mix precommit` green, `mix docs` without warnings.

## Open questions

1. F2's shape, after P1.
2. Whether P1's results change C3 or F1 (for example, fewer writes per
   upload).
3. SQLite: after P1.
