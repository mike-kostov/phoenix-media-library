# Idea: the media table under real load

Captured 2026-10-05 (Mike). Follows `docs/ideas/media-indexes.md`, which
measured single queries on 150k rows and found nothing slow, but didn't
answer the real question.

## Problem

How might we make sure the library never slows down the app it is in?
The media table is where many of an app's tables meet, so it sees the
app's reads (pages loading media, preloads, joins) and the library's
writes (uploads and their processing) at the same time.

## First spike (agreed scope)

Postgres only. 100,000 media rows, then 1,000,000.

1. **Writes per upload.** Count the statements and row versions one image
   upload produces, end to end (insert, then the WebP, AVIF, responsive,
   placeholder and conversion updates). Measure dead rows, index writes
   and WAL per upload, and what a burst of uploads does to concurrent
   reads.
2. **Reads under load.** Latency of what apps do with this library: a
   page of records with their media preloaded, `get_media` per record,
   joins from an app table to media, while uploads are running.
3. **What to change.** Rank the levers by measured effect, for example:
   fewer updates per upload (one write after processing), `fillfactor` so
   updates stay on the same page, ordered (v7) UUIDs instead of random
   ones, the size of the JSON columns, the index changes from the first
   spike.
4. **SQLite.** How much would SQLite support take? List what is
   Postgres-specific today (JSON operators, types, queries, migrations).

Bulk import is not the upload path at scale: one row written six to eight
times is fine for daily uploads, but an import should take a different
route. The spike measures the current path; a bulk ingestion route is a
feature of its own, designed with the spike's numbers.

## Questions for later (not needed for the first spike)

- Target scale beyond 1M: Mike mentioned 50M rows in another project.
- How many models point at the media table in a typical app.
- Bulk imports: do they store files, or reference files already in
  storage? Do they need conversions right away, or later in the
  background?
- Which updates happen after insert in real apps: reordering, custom
  properties, regenerating derivatives.
- MySQL: only if SQLite turns out cheap.

## Not doing (yet)

- Partitioning, or splitting derivative data out of the media row:
  only if the spike shows the row is the problem.
