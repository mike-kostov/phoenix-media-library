# Multi-Tenant Media

This guide explains how PhxMediaLibrary works in multi-tenant applications,
and when you need `PathGenerator.Tenant` vs. the built-in natural scoping.

## Overview

Every media record stores `mediable_type` and `mediable_id` columns that
identify which Ecto record owns the file. This gives you **natural per-model
scoping** out of the box: `PhxMediaLibrary.get_media/2` is already filtered
to the owner, and storage paths already encode the owning record's type and ID.

```elixir
# Fully isolated — no extra tenant filtering needed
PhxMediaLibrary.get_media(tenant_a_post, :images)
PhxMediaLibrary.get_media(tenant_b_post, :images)
```

For most SaaS applications this is enough: the `Post` (or `User`,
`Organization`, etc.) belongs to a tenant in your domain model, and the
media follows naturally.

### When to Use PathGenerator.Tenant

If you have a top-level `Tenant` / `Organization` model and want all files —
regardless of which sub-record owns them — namespaced under that tenant *in
storage*, you need an extra layer. Use `PathGenerator.Tenant` and the
`path_context` escape hatch for exactly this case.

## The `PathGenerator.Tenant` Built-In

`PhxMediaLibrary.PathGenerator.Tenant` prepends a `tenant_id` segment to the
standard path structure:

```
{tenant_id}/{mediable_type}/{mediable_id}/{uuid}/{filename}
{tenant_id}/{mediable_type}/{mediable_id}/{uuid}/{base}_{conversion}{ext}
```

Example with `tenant_id: "acme"` on a `posts` model:

```
acme/posts/42/550e8400-.../photo.jpg
acme/posts/42/550e8400-.../photo_thumb.jpg
```

### Configure

```elixir
# config/config.exs
config :phx_media_library,
  path_generator: PhxMediaLibrary.PathGenerator.Tenant
```

### Pass `tenant_id` via `path_context`

Both atom and string keys are supported:

```elixir
# Atom key (recommended for internal calls)
PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{tenant_id: "acme"})

# String key (handy when context is decoded from JSON or controller params)
PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{"tenant_id" => "acme"})
```

Without a `tenant_id` key the generator falls back to `"shared"`, so
existing call sites that omit context keep working:

```elixir
# Falls back to "shared/posts/42/.../photo.jpg"
PhxMediaLibrary.PathGenerator.relative_path(media, :thumb)
```

Integer tenant IDs are coerced to strings automatically:

```elixir
PhxMediaLibrary.PathGenerator.relative_path(media, nil, %{tenant_id: 42})
# => "42/posts/abc/uuid/photo.jpg"
```

### Wire `path_context` into Your Upload Flow

Pass `path_context` through your controller or LiveView when adding media:

```elixir
def handle_event("upload", _params, socket) do
  %{current_tenant: tenant, post: post} = socket.assigns

  result =
    post
    |> PhxMediaLibrary.add(uploaded_file)
    |> PhxMediaLibrary.to_collection(:images, path_context: %{tenant_id: tenant.slug})

  case result do
    {:ok, media} -> {:noreply, stream_insert(socket, :media, media)}
    {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
  end
end
```

## Querying Media by Tenant

### Natural Scoping (most common)

```elixir
# Already scoped to this post's tenant via mediable_id
PhxMediaLibrary.get_media(post, :images)
```

### Cross-Model Queries

When you need all media across every sub-record for a given tenant:

```elixir
import Ecto.Query

post_ids =
  from(p in Post, where: p.tenant_id == ^tenant.id, select: p.id)
  |> Repo.all()
  |> Enum.map(&to_string/1)

from(m in PhxMediaLibrary.Media,
  where: m.mediable_type == "posts" and m.mediable_id in ^post_ids
)
|> Repo.all()
```

Alternatively, if you store `tenant_id` in `custom_properties` at upload time,
you can query directly on that JSON column:

```elixir
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.to_collection(:images,
  custom_properties: %{tenant_id: tenant.slug}
)
```

```elixir
from(m in PhxMediaLibrary.Media,
  where: fragment("?->>'tenant_id' = ?", m.custom_properties, ^tenant.slug)
)
|> Repo.all()
```

## Per-Tenant Storage Backends

For data-residency requirements you may want each tenant's files on a
separate disk (e.g. different S3 buckets or regions). The `:disk` option on
`to_collection/3` lets you route uploads at the call site:

```elixir
# config/config.exs
config :phx_media_library,
  disks: [
    eu_s3: [adapter: PhxMediaLibrary.Storage.S3, bucket: "media-eu", region: "eu-west-1"],
    us_s3: [adapter: PhxMediaLibrary.Storage.S3, bucket: "media-us", region: "us-east-1"]
  ]
```

```elixir
disk = if tenant.region == :eu, do: :eu_s3, else: :us_s3

post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.to_collection(:images, disk: disk)
```

`PhxMediaLibrary.Media` records store which disk they were written to in the
`disk` field, so `PhxMediaLibrary.url(media)` and deletion always use the
correct backend automatically.

## Custom Tenant Path Generators

`PathGenerator.Tenant` covers the standard case. For fully custom path
structures, implement the `PhxMediaLibrary.PathGenerator` behaviour (see its
moduledoc for a complete worked example) and configure:

```elixir
config :phx_media_library,
  path_generator: MyApp.TenantPathGenerator
```

## Rolling Out to Existing Data

Changing the path generator **does not retroactively rename stored files**.
Each `Media` record's storage path is determined at upload time and stored
implicitly via the `uuid` and `mediable_*` columns. Only new uploads use the
new generator.

To migrate existing files to the new path structure:

1. Generate the new path for each media record using the new generator.
2. Copy (or move) the file in storage from the old path to the new path.
3. If you are using a custom storage adapter that tracks paths explicitly,
   update any stored path references in the database.
4. Delete the file at the old path once the new path is verified.

This migration is intentionally left to the application developer because the
correct strategy (copy vs. move, rollback plan, downtime window) depends
entirely on your deployment and storage backend.

> **Tip:** Run the migration in batches to avoid timeouts, and use
> `mix phx_media_library.doctor` afterwards to verify no orphaned records
> remain.