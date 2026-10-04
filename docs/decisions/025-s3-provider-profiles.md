# ADR-025: S3 behaviour per provider, set per disk

## Status
Proposed (2026-10-04), accepted with spec 01's update.

## Date
2026-10-04

## Context
The S3 adapter only reached AWS: it passed the access key, secret and
region to ExAws (which supports any `scheme`, `host` and `port`), built
public URLs for `amazonaws.com`, and sent `acl: "private"` on every upload.
Providers differ in ways that break that (sources in
`docs/ideas/s3-providers.md`):
- ACL headers fail on AWS buckets with default settings and are
  unsupported on R2;
- presigned POST (spec 01, S1) is missing on R2 and B2 and undocumented on
  Spaces and Hetzner; presigned PUT is supported by every provider that
  documents presigned URLs.
Mike's direction: one adapter on the same ExAws dependency, adapting per
provider, because future providers are unknown.

## Decision
- A disk's `provider:` selects a preset: `:aws`, `:r2`, `:generic`. Presets
  are data (default values), not separate code paths.
- Every behaviour can be set explicitly on the disk and overrides the
  preset, so an unknown provider works as `:generic` plus settings:
  - `endpoint:` (scheme, host, port; `:r2` builds it from `account_id:`),
  - addressing (virtual-host or path-style),
  - public URL base (from the endpoint, or `base_url:`),
  - `direct_upload: :post | :put` (`:aws` defaults to `:post`, others to
    `:put`),
  - `acl:` (no ACL header unless set).
- Direct uploads get `PhxMediaLibrary.presigned_upload/3`, returning a map
  with the method, URL, form fields (POST) or headers (PUT) and the key,
  so one client uploader handles both methods. `presigned_upload_url/3`
  stays as a deprecated wrapper and is removed in 0.10.0.
- With PUT, the signature covers the Content-Type, the server refuses to
  sign above the size limit, and completion's check (spec 01, task 5) is
  the size guarantee. Signed Content-Length is not relied on until a
  provider documents enforcing it.

## Alternatives Considered

### PUT everywhere
- Pros: one method, one uploader.
- Rejected: gives up AWS's server-side size enforcement for a simpler
  default; per-disk choice keeps both.

### A separate adapter or library per provider
- Rejected: ExAws already speaks to all of them; the differences are
  configuration.

## Consequences
- The adapter works with R2, Spaces, B2, Hetzner, self-hosted servers and
  the test emulator.
- Uploads stop sending an ACL by default, which fixes uploads on AWS
  buckets with default settings.
- A new preset is a small data change; behaviour that differs in a new way
  becomes a new disk option.
