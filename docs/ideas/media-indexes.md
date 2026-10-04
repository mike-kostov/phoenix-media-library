# Idea: Fewer, smaller indexes on the media table

Captured 2026-10-04, from a performance spike. Scripts are in
`tmp/index-spike/` (not committed).

## Problem

The installer gives every app six indexes on `media` besides the primary
key. Which of them do the library's queries use, and is one missing?
Changing indexes is cheap now and costs a migration in every app later.

## Setup

- Postgres 17.10 in Podman (7 CPUs, 6 GB) on an Apple M4 Pro. Default
  settings, `work_mem` 4 MB. Every read was a cache hit.
- The table comes from the installer's migration, run through Ecto, with
  the default `binary_id` `mediable_id`, plus a copy with `:string`.
- 150,497 rows: 15 mediable types with 950 parents each, 1 to 20 media per
  parent across 2 to 4 collections, `order_column` per collection, 7,532
  soft-deleted (5%), `inserted_at` spread over a year. The heap is 56 MB.
- The SQL comes from `Ecto.Adapters.SQL.to_sql` and the repo log for
  preloads. Times are the median of 7 `EXPLAIN (ANALYZE, BUFFERS)` runs.

## Baseline

"Type, id, coll" is the `(mediable_type, mediable_id, collection_name)` index.

| Query | Rows | Plan | Index | ms |
|---|---|---|---|---|
| `get_media(post, :gallery)`, `move_to` | 10 | index scan, sort | type, id, coll | 0.023 |
| same, soft deletes on | 10 | index scan, filter, sort | type, id, coll | 0.025 |
| `get_media(post)`, all collections | 19 | index scan, sort | type, id, coll | 0.021 |
| `Model.next_order` | 1 | index scan, max | type, id, coll | 0.018 |
| preload `:images`, 40 parents | 152 | index scan | type, id, coll | 0.075 |
| preload `:media`, 40 parents | 456 | bitmap scan, sort | type, id | 0.32 |
| `purge_trashed(post, before:)` | 1 | index scan, filter | type, id, coll | 0.012 |
| doctor `--model posts --collection images` | 3,370 | bitmap scan, sort | type, id, coll | 1.6 |
| doctor, no filters | 150,497 | parallel seq scan, sort spills 53 MB | none | 86 |
| `stats --collection avatar` | 11,952 read | bitmap scan, hash aggregate | collection | 6.3 |
| `purge_deleted`, list 50 | 50 | index scan | deleted_at | 0.040 |
| `purge_deleted`, delete | 5,950 | bitmap scan | deleted_at | 6.2 |
| `Health`, distinct types | 15 | parallel index-only scan | type, id | 10 |
| `Health`, parent IDs of one type | 950 | index-only scan | type, id | 0.79 |
| lookup by checksum (no library code does this) | 1 | index scan | checksum | 0.014 |

Index sizes: checksum 17.9 MB, unique uuid 10.9, primary key 5.9, type, id,
coll 5.4, type, id 2.8, deleted_at 1.1, collection 1.0. That is 45 MB of
index on a 56 MB heap.

Every per-record query reads 4 or 5 buffers. That stays small as the table
grows, because B-tree depth grows with the log of the row count. What grows
linearly is the doctor without filters, the distinct types scan, `stats`
and the trash purge. All are mix tasks, and no index removes that work.

## Experiments

Each ran in a rolled-back transaction after `VACUUM ANALYZE`.

**Drop (type, id).** Its queries moved to type, id, coll at the same speed:
preload `:media` 0.32 to 0.36 ms, parent IDs 0.79 to 0.86 ms, distinct
types 10.4 to 11.6 ms. The 3-column index starts with the same columns, so
the 2-column one is redundant. Dropping it saves 2.8 MB.

**Add `order_column`.** With `(…, collection_name, order_column)` the sort
became an incremental sort, since the query also orders by `inserted_at`.
Adding `inserted_at` as a fifth column removed the sort. The time stayed
at 0.021 ms. The sort only ever sees one record's collection, 10 rows
here, and that number does not grow with the table. The 5-column index is
9.7 MB against 5.4 MB, and indexing `order_column` stops Postgres from
updating rows in place (HOT) when `move_to` and `reorder` change it.

**Is (collection_name) used?** Only by `stats --collection` without
`--model` (without the index, a parallel seq scan, 6.3 to 11.8 ms). The
regenerate tasks given only `--collection` have the same shape; not
measured. The doctor and per-record queries also filter by type and use
type, id, coll.

**Partial index on live rows**, type, id, coll `WHERE deleted_at IS NULL`.
The planner uses it only with soft deletes on, which is off by default.
0.025 to 0.019 ms, within noise, for 3.1 MB more. With 5% of rows in the
trash it skips one row in twenty.

**Partial index on trashed rows**, `(deleted_at) WHERE deleted_at IS NOT
NULL`, replacing `(deleted_at)`. The planner picks it for Ecto's
`NOT (deleted_at IS NULL)`. Same plans and times (list 0.039 ms, delete
5.2 ms) at 0.16 MB instead of 1.13 MB. The full index holds a NULL entry
for every live row, which with soft deletes off means every row. Some
index is needed: without one, list 50 takes 11.9 ms and the delete 19 ms.

**`:string` mediable_id.** Same plans and times; type, id, coll is 7.0 MB
instead of 5.4.

**Writes.** Inserting 150k rows took about 5 s with either set, so I
don't claim a write speedup.

**Unique (type, id).** Creating it fails with `Key (mediable_type,
mediable_id)=(products, …) is duplicated`. A record has many media, so
this index would be wrong.

## Recommendation

- Keep type, id, coll. It serves every per-record query and both preloads.
- Drop (type, id). Redundant, same plans and times without it.
- Replace (deleted_at) with the partial `WHERE deleted_at IS NOT NULL`
  index. Same plans, 86% smaller.
- Drop (collection_name), low priority. Its only user is a mix task that
  gets 5 ms slower at 150k rows. It is also cheap to keep.
- Don't add an `order_column` index or a live-rows partial index. Neither
  made anything faster.
- Keep the primary key and unique uuid.

Together: 45.0 MB of index becomes 40.2 MB, and an insert writes 5 index
entries instead of 7. The checksum index is the bigger question, see below.

## What a change costs apps

New apps get it from the installer template. No query names an index, so
no library code changes.

Existing apps need their own migration. `mix
phx_media_library.gen.migration tune_media_indexes` creates an empty one,
and the upgrade guide would give the body:

```elixir
def change do
  drop index(:media, [:mediable_type, :mediable_id])
  drop index(:media, [:collection_name])
  drop index(:media, [:deleted_at])
  create index(:media, [:deleted_at], where: "deleted_at IS NOT NULL", name: :media_trashed_index)
end
```

On large tables apps should build the index with `concurrently: true`,
`@disable_ddl_transaction true` and `@disable_migration_lock true`. Index
names follow the table name. Skipping the migration breaks nothing, so
this fits a minor release with a changelog line and an upgrade note.

## Open questions

- The checksum index is the largest, 17.9 MB or 40% of all index space,
  and no library query reads it. Apps may use it to find duplicate uploads.
  Drop it and document how to add it, or keep it?
- Next minor (installer output changes) or wait for a release that needs
  a migration anyway?
