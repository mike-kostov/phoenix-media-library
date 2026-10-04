# Idea: One S3 adapter that behaves per provider

Captured 2026-10-04, from the spec 01 security checkpoint (task 4 review).
Direction chosen: ADR-025 (per-provider behaviour, set per disk).

## Problem

How might one S3 adapter, on the same ExAws dependency, work correctly on
AWS and on the S3-compatible providers apps actually use, without each app
discovering every provider's gaps itself?

Today the adapter only passes the access key, secret and region to ExAws,
so it can only reach AWS (`deps/ex_aws/lib/ex_aws/config/defaults.ex`
supports `scheme`, `host`, `port`; we never pass them), builds public URLs
for `amazonaws.com` only, and sends `acl: "private"` with every upload.

## Provider matrix

Researched 2026-10-04 from each provider's documentation. "Not documented"
means the page doesn't say; it is not a "no". Ministack is the test
emulator, checked by running it (spike, `docs/ideas/test-containers.md`).

| Capability | AWS S3 | Cloudflare R2 | DigitalOcean Spaces | Backblaze B2 | Hetzner | Ministack (tests) |
|---|---|---|---|---|---|---|
| Presigned POST (browser form with policy) | Yes, it is AWS's own API (page not re-checked) | **No** [R2-1] | Not documented [DO-1] | **No** [B2-1] | Not documented [HZ-1] | Yes, size policy enforced (spike) |
| Presigned PUT | Yes (not re-checked) | Yes [R2-1] | Yes, SigV2 and SigV4 [DO-1] | Yes [B2-1] | Not documented [HZ-1] | Yes (spike) |
| Signed Content-Type enforced on PUT | Expected with SigV4 (not re-checked) | Yes, 403 `SignatureDoesNotMatch` [R2-1] | Not documented | Not documented | Not documented | **No**, signatures not verified (spike) |
| ACL header on upload | Only none or `bucket-owner-full-control` on buckets with default settings; others fail with `AccessControlListNotSupported` [AWS-1, AWS-2] | **Not supported** [R2-2] | `private`, `public-read` [DO-1] | Bucket-level `private`/`public-read`; object ACL on upload not documented [B2-1] | `private`, `public-read` on bucket creation; objects not documented [HZ-1] | Accepted (spike) |
| HEAD and ranged GET | Yes (not re-checked) | Yes [R2-2] | Not documented | Not documented | Not documented | Yes (spike) |
| API endpoint | `s3.<region>.amazonaws.com` | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` [R2-2] | `https://<space>.<region>.digitaloceanspaces.com` [DO-1] | Not on the page | Not on the page | `http://localhost:<port>` |

### What the matrix means for us

- **No ACL by default.** Sending none is the only choice every documented
  provider accepts. Our default `acl: "private"` breaks uploads on AWS
  buckets with default settings (per AWS's docs) and is unsupported on R2.
  This is a bug for 0.9.0.
- **Presigned PUT is the common ground.** Every provider that documents
  presigned URLs supports PUT; POST is missing on R2 and B2 and
  undocumented on Spaces and Hetzner.
- **Emulators don't enforce provider rules.** Ministack accepted a PUT with
  a different Content-Type than the signed one. Container tests prove our
  requests and flows; provider rules come from documentation or real
  accounts.

## Direction to discuss

A `provider:` option on an S3 disk selects defaults for that provider; every
default can be overridden on the disk. Same adapter, same ExAws dependency.

```elixir
disks: [
  r2: [
    adapter: PhxMediaLibrary.Storage.S3,
    provider: :r2,
    account_id: "…",
    bucket: "media",
    access_key_id: "…",
    secret_access_key: "…"
  ]
]
```

| Default set by `provider:` | Example values |
|---|---|
| API endpoint (scheme, host, port) | R2: `<account_id>.r2.cloudflarestorage.com` |
| Public URL base | from the endpoint, or `base_url:` |
| Direct upload method | `:post` on AWS, `:put` elsewhere |
| ACL on upload | none (an explicit `acl:` overrides) |
| Addressing | path-style or virtual-host |

`:generic` (endpoint given explicitly) covers MinIO, Ministack and anything
else S3-compatible.

## Key assumptions to validate

- [ ] Uploads without an ACL work on each listed provider (docs say so for
      AWS and R2; check B2, Spaces, Hetzner pages for object uploads).
- [ ] R2 enforces the signed Content-Type on presigned PUT as documented
      (needs a real R2 bucket; R2 has a free tier).
- [ ] Whether signed Content-Length is enforced on presigned PUT by AWS and
      R2; if not, completion's check (task 5) is the only size guarantee.

## Not doing (and why)

- A second dependency (ReqS3) or a separate adapter per provider: ExAws
  already speaks to all of them; the differences are configuration.
- Trusting the emulator for provider rules: shown above to be wrong.

## Open questions

- Which providers get a built-in profile in 0.9.0 (proposal: `:aws`, `:r2`,
  `:generic`; others documented as `:generic` with settings).
- Whether S1's direct upload method becomes per-provider (POST on AWS, PUT
  elsewhere) or PUT everywhere.

## Sources

- [AWS-1] https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html
- [AWS-2] https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-ownership-error-responses.html
- [R2-1] https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- [R2-2] https://developers.cloudflare.com/r2/api/s3/api/
- [DO-1] https://docs.digitalocean.com/products/spaces/reference/s3-compatibility/
- [B2-1] https://www.backblaze.com/docs/cloud-storage-s3-compatible-api
- [HZ-1] https://docs.hetzner.com/storage/object-storage/supported-actions/
