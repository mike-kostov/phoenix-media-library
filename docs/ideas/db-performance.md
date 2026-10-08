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

## Results so far (first spike run, 2026-10-07)

Scripts and raw output are in `tmp/db-spike/` (not committed).

**Setup.** Postgres 17.10 in Podman (VM: 7 CPUs, 6 GB) on an Apple M4
Pro. Default settings: `shared_buffers` 128 MB, `max_wal_size` 1 GB,
`synchronous_commit` on. The same Postgres instance and VM also run other
projects' containers and this repo's test suite, so nothing here is
isolated. `seed.sql` builds 15 mediable types, 1 to 20 media per parent,
2 to 4 collections: 20% bare rows (documents, 0.5 kB), 52% plain (1.7 kB),
28% heavy (4.7 kB with TOAST), 5% soft-deleted. 100,380 rows (heap 132 MB,
TOAST 37 MB) and 1,005,080 rows (heap 1,316 MB, TOAST 372 MB).

### Writes per upload

Method: `writes_e2e.exs` uploads a 2400x1600 JPEG 10 times per
collection through the library (inline processing, no global responsive
config, like an app), and counts statements (Ecto telemetry), table stats
and WAL records per relation (`pg_walinspect`). Medians.

| Collection | Statements | Updates (HOT) | Index entries | WAL | Row | Wall time |
|---|---|---|---|---|---|---|
| bare (no conversions) | 1 SELECT, 1 INSERT | 0 | 7 | 1.1 kB | 0.5 kB | 9 ms |
| plain (thumb, preview, placeholders) | 4 SELECT, 1 INSERT, 2 UPDATE | 2 (1) | 14 | 4.2 kB | 1.7 kB | 98 ms |
| heavy (WebP, AVIF, responsive) | 4 SELECT, 1 INSERT, 6 UPDATE | 6 (5) | 15 | 7.7 kB | 2.2 kB | 1,292 ms |

The heavy upload writes `custom_properties` twice (WebP, AVIF),
`generated_conversions` once and `responsive_images` three times (3.1 kB
as text, TOASTed). A non-HOT update adds an entry to all 7 indexes. These
WAL figures exclude full-page images; under load a heavy upload cost
9.8 kB at 100k and 23.8 kB at 1M, 59% of it full-page images.

### Read latency

Method: `bench.exs` via `run.sh <label>`. Four readers call the library
(Ecto preload of `has_media` associations, `get_media/2`, joins from a
`posts` table) for 15 s per operation, one operation after another. A
writer replays the SQL of one heavy upload ("heavy6": insert, then 6
updates spread over 1.2 s) open-loop at a fixed rate. Each run resets the
table from a seed copy, rebuilds indexes, runs `VACUUM ANALYZE` and
`CHECKPOINT`, and prewarms the OS cache. One run per row. p95 in ms.

| Rows, load | preload `:images`, 40 posts | preload `:media`, 40 posts | `get_media` | join 40 posts to images | posts page + cover (lateral) | writer statement p95 |
|---|---|---|---|---|---|---|
| 100k idle | 6.3 | 16.5 | 0.80 | 7.1 | 9.1 | |
| 100k, 20/s | 7.7 | 18.4 | 0.91 | 8.6 | 11.5 | 24 |
| 100k, 100/s | 8.1 | 21.9 | 1.04 | 9.5 | 11.5 | 23 |
| 1M idle | 12.0 | 46.1 | 1.17 | 8.7 | 4.4 | |
| 1M, 20/s | 21.0 | 153 | 1.54 | 12.5 | 7.7 | 46 |
| 1M, 100/s | 224 | 437 | 7.1 | 50.4 | 7.6 | 402 |

The lateral join mostly measures the app's `posts` index (the 100k run
had none). At 1M and 100 heavy uploads/s the writer stopped keeping up
(statement p99 2.5 s): the laptop's database was saturated.

### Levers tried at 1M and 100 uploads/s

Same method, one run each. "collapsed1": the insert, then one update with
all derivative data after processing. "insert_only": the row is written
once, complete. "proposed" indexes: drop `(mediable_type, mediable_id)`
and `(collection_name)`, `deleted_at` partial (`docs/ideas/media-indexes.md`).
"minimal": proposed without the checksum index. p95 in ms.

| Variant | preload `:images` | preload `:media` | `get_media` | join | writer p95 | updates (HOT) | dead rows | WAL per upload |
|---|---|---|---|---|---|---|---|---|
| heavy6 (today) | 224 | 437 | 7.1 | 50.4 | 402 | 70,561 (56%) | 37,492 | 23.8 kB |
| collapsed1 | 67 | 362 | 1.9 | 32.4 | 438 | 10,168 (29%) | 8,545 | 20.9 kB |
| insert_only | 21 | 145 | 1.3 | 11.7 | 327 | 0 | 0 | 17.3 kB |
| heavy6, fillfactor 85 | 970 | 544 | 9.6 | 17.6 | 406 | 65,687 (74%) | 25,286 | 22.4 kB |
| collapsed1, fillfactor 85 | 88 | 617 | 1.9 | 12.7 | 276 | 10,235 (78%) | 4,267 | 18.2 kB |
| heavy6, proposed indexes | 784 | 488 | 8.6 | 26.4 | 948 | 69,244 (58%) | 35,937 | 21.5 kB |
| heavy6, minimal indexes | 26 | 155 | 2.2 | 23.6 | 201 | 58,843 (70%) | 22,707 | 16.9 kB |

At 100k all nine variants landed within 7.4 to 10.1 ms for preload
`:images`: within noise.

These runs are noisy: one run per variant, operations measured one after
another against a growing writer backlog, and a 6 GB VM shared with other
work. Two results contradict the rest (fewer indexes 3.5 times slower,
fillfactor 85 4 times slower); the next section repeats them. The first
100k "minimal" run dropped 424 writer statements; two reruns matched it.

### Autovacuum

Method: `vacuum_watch.sh` runs heavy6 at 100 uploads/s for 12.5 minutes
at 1M while sampling `pg_stat_user_tables` every 15 s.

Dead rows rose from 0 to 150,222 (about 12,000 a minute) and no
autovacuum ran. It wasn't falling behind: by default it starts at 20% of
the table, about 200,000 dead rows here, which this load reaches after
about 17 minutes. Meanwhile rows grew 7% (70,000), the heap 21% (1,316 to
1,597 MB) and the indexes 40% (231 to 324 MB). `get_media` p95 stayed at
1.15 ms, the only operation measured.

### Index sizes at 1M

| Index | Freshly built | After the 12.5-minute run |
|---|---|---|
| checksum | 91.6 MB | 128 MB |
| uuid (unique, text) | 56.6 MB | 87 MB |
| primary key | 37.8 MB | 41 MB |
| (type, id, collection) | 20.8 MB | 32 MB |
| (type, id) | 10.9 MB | 20 MB |
| deleted_at | 7.3 MB | 9.3 MB |
| collection_name | 6.7 MB | 8.0 MB |
| total | 231.6 MB | 324 MB |

The reset builds secondary indexes after loading, so they start packed;
the primary key fills during the load, which is why it grew only 8%.
Checksum and uuid, both random keys, are 64% of all index space.

## Repeated comparisons at 1M and 100 uploads/s (2026-10-08)

Method: `tmp/db-spike/repeat.sh 3`. Six variants, three rounds, the
variants interleaved within each round so drift spreads over all of them.
Each run resets the table, then the writer runs at 100 uploads/s while
four readers measure three operations for 20 s each (the writer runs
about 80 s). The table reports the median of the three p95s, with the
three values in brackets. Raw output: `repeat_1m.txt` and lines labelled
`1M rep` in `results.jsonl`.

| Variant | preload `:images` p95 | preload `:media` p95 | `get_media` p95 | writer statement p95 |
|---|---|---|---|---|
| heavy6 (today) | 41 [160, 41, 34] | 250 [311, 250, 243] | 1.8 | 57 [36, 116, 57] |
| collapsed1 | 30 [30, 28, 72] | 203 [113, 203, 223] | 1.2 | 112 [29, 112, 445] |
| insert_only | 11 [10, 11, 11] | 85 [45, 190, 85] | 1.2 | 23 [23, 358, 23] |
| heavy6, minimal indexes | 36 [34, 36, 62] | 249 [240, 417, 249] | 1.7 | 55 [33, 179, 55] |
| collapsed1, minimal indexes | 63 [17, 71, 63] | 191 [112, 191, 277] | 1.2 | 324 [25, 875, 324] |
| collapsed1, fillfactor 85 | 27 [25, 386, 27] | 260 [219, 260, 285] | 1.1 | 29 [29, 67, 29] |

The p50s did not move: preload `:images` 4.4 to 5.2 ms and `get_media`
0.5 to 0.7 ms in every run but two. The latency differences are all in
the tail, and the tail is noisy: a single run can be ten times its
neighbours.

What varied little between runs (per upload, medians):

| Variant | Updates | HOT | Dead rows | WAL | Heap growth |
|---|---|---|---|---|---|
| heavy6 | 6 | 67% | 2.5 | 25.8 kB | 4.5 kB |
| collapsed1 | 1 | 31% | 0.8 | 22.9 kB | 1.5 kB |
| insert_only | 0 | | 0 | 19.9 kB | 1.1 kB |
| heavy6, minimal indexes | 6 | 66% | 2.6 | 17.9 kB | 4.4 kB |
| collapsed1, minimal indexes | 1 | 30% | 0.8 | 15.1 kB | 1.5 kB |
| collapsed1, fillfactor 85 | 1 | 81% | 0.4 | 20.4 kB | 1.4 kB |

What this shows:

- Writing the row once (insert_only) is the only change with a clear
  read effect: preload `:images` p95 4 times lower than today (11 against
  41 ms) in all three rounds, and preload `:media` 3 times lower.
- One update instead of six cuts dead rows by 3 and heap growth by 3, but
  its read effect (30 against 41 ms) is within the noise.
- The minimal index set cuts WAL per upload by 31% to 34% in every round
  and changes no read latency measurably.
- Fillfactor 85 more than doubles HOT updates (31% to 81%) and halves
  dead rows, but the table starts 15% larger (1,316 to about 1,550 MB) and
  reads did not change.
- The first run's 224 ms for heavy6 did not come back (34 to 160 ms); this
  time the writer kept up. Its two outliers were noise.

Why the tail moves is not isolated. Candidates: commits per upload (7, 2
and 1, each with an fsync), index scans visiting dead row versions, and
page cache pressure in the shared VM. Telling them apart needs a
dedicated database host.

## Bulk insert (for F2)

Method: `tmp/db-spike/bulk_run.sh` runs `bulk.exs`, which copies the 1M
seed rows into a fresh table (`PREFILL=1`), builds the indexes, then adds
100,000 rows with final derivative data (written once, as an import
would) through `Repo.insert_all` on one connection. Rows/s counts only
the `insert_all` calls, which include Ecto's encoding. WAL is the
cluster's LSN difference, so it includes any other database's writes on
the instance (it was idle). One run each.

| Indexes | Batch | Rows/s | WAL per row | Index growth for +10% rows |
|---|---|---|---|---|
| today's 7 | 1,000 | 4,013 | 4.7 kB | +78 MB (224 to 302 MB) |
| minimal 4 | 1,000 | 5,993 | 3.1 kB | +38 MB (108 to 147 MB) |
| today's 7 | 3,000 | 2,978 / 3,269 (two runs) | 4.6 kB | +75 MB |
| minimal 4 | 3,000 | 4,898 / 4,829 | 3.1 kB | +36 MB |
| today's, dropped and rebuilt after | 3,000 | 7,588 insert, 3,723 with the rebuild (13.5 s) | 4.0 kB | ends at 251 MB, not 300 |

- `Repo.insert_all` of media rows cannot take more than 3,449 rows: 19
  columns per row against Postgres's limit of 65,535 parameters per
  statement. 5,000 failed. SQLite's default limit (32,766) allows 1,724.
- Larger batches were not faster: 1,000 rows beat 3,000 in both index
  sets.
- The minimal index set gives 1.5 times the rows/s and a third less WAL.
- Dropping and rebuilding indexes doesn't pay when adding 10% to a big
  table: the rebuild of all 1.1M rows ate the gain. It may pay for an
  import that doubles the table; not measured.
- A bulk row costs 3 to 5 kB of WAL against 20 to 26 kB per upload at
  100/s, because rows written together share pages.
- Runs differ by about 10%; a Phoenix dev server in another container
  used about 23% of a CPU throughout.

## UUIDv7 against random v4 ids

Method: `BATCH=2000 mix run tmp/db-spike/bulk.exs 1000000 <scenarios>`
loads 1M rows into an empty table on one connection; output in
`uuid_results.txt`. The v7 ids are made in Elixir (about 15 lines in
`bulk.exs`, no dependency) for both `id` and `uuid`. "v7" is random
within a millisecond; "v7, monotonic" adds a 12-bit counter within the
millisecond (RFC 9562, method 1). One run each.

| Ids | Indexes | Rows/s | Primary key | uuid index | WAL |
|---|---|---|---|---|---|
| v4 | primary key only | 9,132 | 38.0 MB | | 1,523 MB |
| v7 | primary key only | 10,561 | 40.3 MB | | 1,486 MB |
| v7, monotonic | primary key only | 9,017 | 30.1 MB | | 1,483 MB |
| v4 | today's 7 | 4,876 | 38.2 MB | 73.0 MB | 2,601 MB |
| v7 | today's 7 | 6,213 | 40.1 MB | 74.6 MB | 2,419 MB |
| v7, monotonic | today's 7 | 6,122 | 30.1 MB | 56.3 MB | 2,399 MB |

- With all indexes, v7 ids loaded 26% faster and wrote 7% less WAL. With
  the primary key alone the difference is within noise: at 1M the key
  fits in memory.
- Only monotonic v7 makes indexes smaller (primary key -21%, uuid -23%).
  Plain v7 ids are random within a millisecond, so pages still split in
  the middle.
- Every run slows as the table grows (v4 from 6,266 to about 4,100
  rows/s), because the checksum index (118 MB) stays random.
- Postgres 18 has `uuidv7()`, but the library can't rely on it.

## JSON column size

Method: `tmp/db-spike/jsonb.sh 1M` (output in `jsonb_1m.txt`) builds two
copies of the 1M seed and swaps each in as `media` for an idle
`bench.exs` run. "compact" stores responsive variants as a list of
widths, with paths derived from the media row as the library already
does for conversions. "lean" empties `responsive_images`, `metadata` and
`custom_properties`: not an option, a lower bound for what the JSON
costs. All three tables went through `VACUUM FULL`, so they are equally
packed. One run each, idle, p95 in ms.

| Table | Heap | TOAST | Heavy row's `responsive_images` | preload `:images` | preload `:media` | `get_media` | join |
|---|---|---|---|---|---|---|---|
| as seeded | 1,316 MB | 372 MB | 3,077 B | 6.6 | 20.6 | 0.88 | 6.2 |
| compact | 1,325 MB | 280 MB | 787 B | 5.4 | 16.9 | 0.79 | 5.3 |
| lean | 394 MB | 0 | | 1.9 | 4.5 | 0.66 | 2.2 |

Server time for the preload `:media` query (40 random posts, median of
50, including detoasting and turning rows into text): 38.5 ms as seeded,
19.1 compact, 5.6 lean. `EXPLAIN ANALYZE` alone shows 30.7 against 29.2
ms because it doesn't detoast.

- The JSON is most of the read cost: without it a 40-post preload is 3.5
  to 4.5 times faster (rows 1.3 kB against 0.4 kB).
- Compact responsive data cuts the heavy value by 74%, TOAST by 25% and
  preload p95 by 18%.
- The same table measured 46 ms for preload `:media` in the first run and
  20.6 ms here: compare rows within one table, not across sessions.

## SQLite assessment (no implementation)

Method: grep of `lib/`, `priv/repo/migrations/`, `test/support/` and
`mix.exs` for raw SQL, fragments, JSON operators, locks, upserts and
types; checked against the `ecto_sqlite3` 0.24 source. Nothing was run on
SQLite.

`lib/` has no `fragment/1`, no raw SQL, no JSON operators, no
`on_conflict`, no `lock` and no `Repo.stream`. Every query is plain
Ecto. What would behave differently:

| Where | What | On SQLite |
|---|---|---|
| `priv/repo/migrations/20240101000000_create_media_table.exs:5,20` and `lib/mix/tasks/phx_media_library.install.ex:119,138` | `:binary_id` primary key and `mediable_id` | stored as TEXT by default; works |
| `20240101000000_create_media_table.exs:13-15`, `20240101000003_add_metadata_to_media.exs:6`, `install.ex:127-129,133` | `:map` columns with `default: %{}` | TEXT holding JSON; `ecto_sqlite3` writes map defaults |
| `lib/phx_media_library/media.ex:62-69,75` | `:map` and `:utc_datetime` fields | JSON text and ISO 8601 text; the `deleted_at` comparisons still sort right |
| `lib/phx_media_library/media.ex:86` | `unique_constraint(:uuid)` | the adapter maps SQLite's message to `media_uuid_index` by naming convention |
| `lib/phx_media_library/doctor.ex:490` | keyset batches on `id > ^id` | text order of lowercase UUIDs equals byte order; works |
| `lib/phx_media_library.ex:823,1083` | reorder in a transaction | works; takes the database-wide write lock |
| `lib/phx_media_library/model.ex:398-407` | `max(order_column) + 1` before insert | same race as on Postgres; no change |
| upload path (6 updates per heavy upload, see above) | 7 write transactions per upload | SQLite has one writer; concurrent uploads queue on `busy_timeout` (2,000 ms by default) and fail past it |
| `Repo.insert_all` (F2) | parameters per statement | 32,766, so at most 1,724 media rows per call (Postgres: 3,449) |
| `test/support/test_repo.ex:6`, `test/support/data_case.ex:30` | tests use the Postgres adapter and sandbox | a second adapter needs its own repo config and a second test run |
| `mix.exs:63` | `postgrex` is dev and test only | the library already has no required driver |

Effort: the library code likely needs no change. The work is running the
suite against both adapters (`ecto_sqlite3` as a test-only dependency, an
env var to pick), fixing what that turns up, and a guide section (WAL
mode, `busy_timeout`, Oban's Lite engine). About 2 to 4 days. Without CI
(ADR-022), `mix precommit` runs the suite twice or SQLite becomes a
manual release check. Fewer writes per upload matter more here: each one
takes the only write lock.

## Recommendations

Ranked by measured effect against cost. Effects are at 1M rows on this
laptop.

| # | Change | Measured effect | Cost in the library | Cost for apps | Spec 02 |
|---|---|---|---|---|---|
| 1 | Minimal index set: drop `(mediable_type, mediable_id)`, `(collection_name)` and `(checksum)`; `deleted_at` partial | WAL per upload -31% to -34%; bulk rows/s x1.5 and WAL -34%; index space 232 to 116 MB; no read slower in any run | installer template, an optional migration, upgrade note | run the migration (drop and create `CONCURRENTLY` on big tables) | C3, as proposed; P1 found no read that needs the dropped indexes |
| 2 | Write the row fewer times on upload: WebP, AVIF and responsive results go into the insert; the background work ends with one update | one update instead of six: dead rows 2.5 to 0.8 and heap growth 4.5 to 1.5 kB per upload; written once: preload `:images` p95 41 to 11 ms, preload `:media` 250 to 85 ms, no dead rows | `MediaAdder` and `Conversions` collect changes and write once per phase; `Pipeline` steps gain a "return the changes" mode so repairs still write per step (ADR-014 stays) | none; no migration | "fewer writes per upload" (open question 4); makes F6 cheap; matters more for SQLite |
| 3 | F6 timestamps ride on that write: `processing_finished_at` (or the error) in the same update as the derivative data; `processing_started_at` is the one extra update | an extra update costs up to 0.8 dead rows, 0.4 kB of heap and 3 kB of WAL per upload (insert-only against one update) | part of F6 | the optional F6 migration | F6: per media job, not per conversion, so it stays at one extra write |
| 4 | F2 writes rows once with `insert_all`, in batches of 1,000 | 4,000 to 6,000 rows/s on one connection, 3 to 5 kB WAL per row against 20 to 26 kB per upload | new path; batches must stay under 3,449 rows (Postgres) or 1,724 (SQLite); conversions later in the background with one update per row | none | F2; don't drop and rebuild indexes for imports smaller than the table |
| 5 | Monotonic UUIDv7 for `id` and `uuid` | bulk load +26% rows/s with today's indexes; primary key -21%, uuid index -23% | an Ecto type or autogenerate function of about 15 lines, a counter per millisecond; no dependency | none; existing v4 rows stay | none yet; a backlog item |
| 6 | Compact `responsive_images`: widths, with paths derived like conversions | preload p95 -18%, TOAST -25%, heavy row's value -74% | new stored format, readers for both formats, a doctor rewrite for old rows; touches components and URL building | a doctor run to convert | none yet; a backlog item after F1's formats change |
| 7 | Document autovacuum settings for busy media tables | not measured; observed 150,000 dead rows and no autovacuum in 12.5 minutes, because the default waits for 20% of the table | a guide paragraph (per-table `autovacuum_vacuum_scale_factor`) | optional `ALTER TABLE` | none; a guide change |

Not recommended now:

- **Fillfactor 85.** More HOT updates (31% to 81%) and half the dead rows,
  but the table starts 15% larger and no read got faster. Recommendation
  2 removes most of the updates it would help.
- **Partitioning, or moving derivative data out of the row.** The JSON is
  most of a preload's cost, but every page that shows media needs it, so
  moving it out only adds a join.
- **SQLite now.** Little library code changes; the cost is a second test
  setup. Better after recommendation 2.

## Rerun with the 0.10 changes, 100k (2026-10-08)

Method: `tmp/db-spike/rerun_100k.md` (scripts `run_rerun.sh`,
`import_bench.exs`, `bench.exs --mode current --indexes lean`). The
library as of plan 02 Task 19: derivative data in the insert, the job's
start and final update (C4, F6), lean indexes (C3), UUIDv7 (C5), compact
responsive data (C6). Postgres 18.6 in this repo's own container; the
first spike ran on 17.10 elsewhere, and 18 turns data checksums on by
default, which roughly doubles WAL for the same writes. So the old setup
was rerun on 18 in the same session as the baseline. Two runs per side;
cells show both. p95 varies up to twofold between identical runs.

| 100k | First spike (17) | Before, on 18 | After |
|---|---|---|---|
| Heavy upload: statements | 4 SELECT, 1 INSERT, 6 UPDATE | | 2 SELECT, 1 INSERT, 2 UPDATE |
| Heavy upload: index entries, WAL, commits | 15, 7.7 kB, 7 | | 3, 3.8 kB, 3 |
| Plain, bare upload WAL | 4.2, 1.1 kB | | 3.4, 0.8 kB |
| Idle p95, preload `:images` / `:media` | 6.3 / 16.5 ms | 8.8–11.7 / 18.3–32.3 | 3.1–5.1 / 8.2–9.4 |
| 100/s p95, preload `:images` / `:media` | 8.1 / 21.9 ms | 12.9–14.9 / 38.5–38.9 | 4.4–9.6 / 15.3–20.3 |
| 100/s p95, `get_media` / join | 1.04 / 9.5 ms | 1.8–2.0 / 16.8–18.0 | 1.5–1.6 / 10.8–12.7 |
| 100/s writer statement p95 | 23 ms | 51–56 | 26–51 |
| 100/s per upload: WAL, dead rows | 9.8 kB, 2.1 | 11.6 kB, 1.8 | 4.6 kB, 0.9 |
| 100/s index growth | 12.3 MB | 11 MB | 1.5 MB |
| 20/s HOT updates, dead rows per upload | 75%, 2.0 | 80%, 1.4 | 36–58%, 1.4 |

- Writes did what the spike predicted: a third of the statements and a
  fifth of the index entries per heavy upload, WAL per upload down 60% at
  100/s, dead rows halved, index growth down from 11 to 1.5 MB.
- Reads: preload `:media` p95 about halved. The idle runs show it comes
  from the rows: compact `responsive_images` keeps the heavy row out of
  TOAST. That row is 1,992 bytes against the 2,032-byte threshold, so a
  big EXIF block or long names could push it back (not measured).
- HOT updates fell at 20/s: the insert now carries most of the row, and
  the final update rewrites about 2 kB of it, which often no longer fits
  on its page. Fillfactor may be worth retesting (backlog).
- `import_media/2`: 836 rows/s for 10,000 small JPEGs on local disk,
  against 9,390 for raw `insert_all`. The inserts are 7% of the time;
  checking and storing files is 82%. 15% went to a position lookup per
  file that the batch then replaced; fixed after this run.
- Not run: the jobs' updates after an import, imports from URLs or S3,
  real photos with EXIF, 1M rows.

## Not measured

- Anything on a dedicated database host; every latency here shares a
  laptop VM with other work.
- Tables larger than memory, or the 50M rows mentioned for another
  project. v4 ids and the checksum index should hurt more there.
- The upload path through the library at rate: the bench replays its SQL.
- UUIDv7 on single-row uploads; compact JSON under write load.
- The effect of autovacuum tuning, and reads with soft deletes on.
- MySQL.

The spike database `phx_media_library_test_dbspike` was dropped after
these runs. To rerun: `mix ecto.create` and `mix ecto.migrate` with the
env vars from `run.sh`, then `seed.sql` with `-v ppt=6350` (about 3
minutes for 1M rows).
