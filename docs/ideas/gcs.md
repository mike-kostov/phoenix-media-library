# Idea: Google Cloud Storage

Researched 2026-10-08 (plan 02, Task 16).

## Question

Can Google Cloud Storage (GCS) be a `provider: :gcs` preset of the existing
S3 adapter, talking to GCS's XML API with HMAC keys and AWS SigV4 signing?
Or does it need a native adapter on the JSON API, which would bring OAuth
tokens and likely a new optional dependency such as Goth?

## What the adapter uses

From `lib/phx_media_library/storage/s3.ex`, all through ExAws with SigV4
header or query signing:

- `put/3`: PutObject for binaries; for streams, `ExAws.S3.upload`
  (CreateMultipartUpload, UploadPart in 5 MiB parts, CompleteMultipartUpload,
  AbortMultipartUpload on failure). Optional `x-amz-acl` and `Cache-Control`
  headers, none by default.
- `get/2`: GetObject.
- `stat/3`: HeadObject (for `Content-Length`), then a ranged GetObject
  (`Range: bytes=0-N`).
- `exists?/2`: HeadObject.
- `delete/2`: DeleteObject, with 404 treated as success.
- `url/2`: an unsigned public URL (from `:base_url`, or the endpoint with
  path-style or virtual-host addressing), or a presigned GET URL (query
  auth, `X-Amz-*` parameters, service `s3`, expiry capped at one week by
  ExAws) with an optional signed `response-content-disposition` parameter.
- `presigned_upload/3`: a presigned PUT URL that signs `content-type`
  (`direct_upload: :put`), or a POST policy form (`direct_upload: :post`):
  ExAws sends the fields `X-Amz-Algorithm` (`AWS4-HMAC-SHA256`),
  `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Signature` and `Policy`, with
  `content-length-range` and `eq $Content-Type` conditions.
- Region: whatever the disk sets, used in the credential scope.

Not used: ListObjects, CopyObject, bucket operations (outside tests), S3
checksum headers.

## Capability table

"Not confirmed" means the official docs don't say; it is not a "no".

| Feature | GCS XML API with HMAC | Notes | Source |
|---|---|---|---|
| Endpoint | `https://storage.googleapis.com` | Same host for every bucket and location | [GCS-1], [GCS-12] |
| SigV4 header auth (`AWS4-HMAC-SHA256`) | Yes | Credential scope service is `s3` and the key prefix `AWS4` when using `x-amz-*`; access ID starts with `GOOG` | [GCS-1], [GCS-2] |
| `x-amz-*` headers | Yes, when an `x-goog-*` equivalent exists | `x-amz-content-sha256` accepted in place of `x-goog-content-sha256` | [GCS-1], [GCS-3] |
| Region in the signature | Any value; `auto` in Google's boto3 example | Google recommends the bucket's location, but accepts any value | [GCS-1], [GCS-2] |
| PutObject | Yes | | [GCS-1] |
| Multipart upload (create, part, complete, abort) | Yes, "compatible with Amazon S3 multipart uploads" | Minimum part 5 MiB except the last (from Google's sample), same as ours. Initiate must send `Content-Length: 0`; ExAws does (checked locally). Preconditions unsupported, no MD5 on the result; we use neither | [GCS-6], [GCS-7], [GCS-8] |
| GetObject and ranged GET | Yes | `Range` header documented | [GCS-9] |
| HeadObject with `Content-Length` | Yes | 404 for a missing object | [GCS-10] |
| DeleteObject | Yes | 404 `NoSuchKey` for a missing object, which the adapter treats as success | [GCS-11] |
| Presigned GET (query auth) | Yes, with `X-Amz-*` parameters | "Cloud Storage also accepts these query string parameters if they are consistently prefixed with `X-Amz-` instead of `X-Goog-`" | [GCS-3] |
| Signed URL expiry | 7 days maximum (604800 s) | Same limit ExAws applies | [GCS-4], [GCS-17] |
| `response-content-disposition` on signed GET | Yes | Documented query parameter | [GCS-9] |
| Presigned PUT | Yes (signed URLs with `X-Amz-*`) | Payload is `UNSIGNED-PAYLOAD`, as ExAws sends | [GCS-3], [GCS-4] |
| Signed `Content-Type` enforced on PUT | Not confirmed | Signed headers must match in general; no page states the Content-Type case | [GCS-3] |
| POST policy form with `AWS4-HMAC-SHA256` and `X-Amz-*` fields | Not confirmed, likely no | The form page lists only `x-goog-algorithm` with `GOOG4-HMAC-SHA256` or `GOOG4-RSA-SHA256`, `x-goog-credential`, `x-goog-date`, `x-goog-signature` and `policy`. No mention of `x-amz-*` fields. ExAws emits only the AWS names | [GCS-5] |
| POST policy conditions | `content-length-range`, exact match, `starts-with` | A `bucket` condition is required; ExAws adds it | [GCS-2], [GCS-5] |
| ACL header on upload | Accepted on fine-grained buckets; fails with `400 Bad Request` on uniform bucket-level access | Some organizations enforce uniform access by policy. Sending no ACL, our default, works on both | [GCS-1], [GCS-13], [GCS-14] |
| Path-style addressing | Yes | `https://storage.googleapis.com/BUCKET/OBJECT` | [GCS-12] |
| Virtual-host addressing | Yes | `https://BUCKET.storage.googleapis.com/OBJECT`; not for domain-named buckets | [GCS-12] |
| Public URL | `https://storage.googleapis.com/BUCKET/OBJECT` | Needs `allUsers` with Storage Object Viewer on the bucket; impossible under public access prevention | [GCS-12], [GCS-15] |
| `Cache-Control` | Yes | Public objects without one are served with a 3600 s default | [GCS-9] |
| HMAC key availability | Service or user account, 10 keys per service account | XML API only; blocked where `restrictAuthTypes` restricts HMAC | [GCS-1], [GCS-16] |

## Emulator findings

No emulator found covers the XML API paths the adapter uses (PUT and
multipart) with S3-style requests. None of them verify signatures.

- **fake-gcs-server** (`fsouza/fake-gcs-server`, latest tag v1.56.1). Runs
  with podman or Docker like Ministack (`-scheme http`, port 4443). Its
  README says signed URL query parameters are not validated [FGS-1]. XML
  API PUT support is an open pull request (#1164, picked up as #2092), not
  released [FGS-2]. Local spike on 2026-10-08 with our adapter: GET, HEAD,
  ranged GET, DELETE (404 as success) and a signed GET with
  `response-content-disposition` worked; PutObject, the multipart
  initiate and presigned PUT failed with `400 invalid uploadType`. A
  POST form with `X-Amz-*` fields returned 204 only because the emulator
  ignores the fields, so it proves nothing about GCS.
- **storage-testbench** (`googleapis/storage-testbench`). Google's tool for
  testing its client libraries; "not an officially supported Google
  product", with "limited support for the XML API" [STB-1]. Its source
  routes XML GET and PUT only: no DELETE, no multipart, no forms.
- **gcp-storage-emulator** (`oittaa/gcp-storage-emulator`). A Docker image
  exists; it describes itself as supporting "a limited subset of the API",
  aimed at Google's Python client (JSON API). XML API support not
  documented [GSE-1].

As with Ministack, an emulator could only prove our requests and flows,
never GCS's rules. Here even the flows aren't covered.

## Recommendation

**A `:gcs` preset of the S3 adapter.** Every operation the adapter uses by
default is documented on the XML API with HMAC keys and `AWS4-HMAC-SHA256`,
including multipart uploads, `X-Amz-*` signed URLs and
`response-content-disposition`. The differences are configuration, which is
what ADR-025 presets are for. No new dependency.

Preset defaults:

| Option | Value | Why |
|---|---|---|
| `:endpoint` | `https://storage.googleapis.com` | [GCS-1] |
| `:region` | `"auto"` | Any value is accepted; `auto` matches Google's example [GCS-1], [GCS-2] |
| `:addressing` | `:path` | Works for every bucket name, and matches the documented public URL [GCS-12] |
| `:direct_upload` | `:put` | POST forms are documented only with `x-goog-*` fields, which ExAws doesn't produce [GCS-5] |
| `:acl` | none | Uniform bucket-level access rejects ACL headers [GCS-13] |

Public URLs follow from the endpoint with path addressing, so no
`:base_url` is required (unlike `:r2`); the bucket must grant `allUsers`
read. Users bring an HMAC access ID and secret as `access_key_id` and
`secret_access_key`.

A native JSON API adapter would bring OAuth tokens (HMAC keys don't work on
the JSON API [GCS-16]), so Goth or similar [GOTH], plus a second request
and signing path. It only pays off for apps whose organization blocks HMAC
keys (`restrictAuthTypes`). Park it in the backlog until someone asks; it
would need its own ADR and Mike's agreement on the dependency.

### How to test

- Unit tests without a container: the `:gcs` preset's options, public URL
  shape, and that no ACL is sent.
- Ministack already covers the ExAws request flows on the `:generic` path;
  a `:gcs` disk sends the same requests to a different host.
- A trial on a real bucket, the only way to confirm GCS's rules. The Free
  Tier covers 5 GB-months in `us-east1`, `us-west1` or `us-central1`, but
  needs a billing account [GCS-18]. Check: PutObject, a streamed multipart
  upload over 5 MiB, HEAD plus ranged GET, DELETE of a missing key, signed
  GET with `download: true`, presigned PUT with a wrong Content-Type
  (expect 403), and a `direct_upload: :post` form (expected to fail).

### Open risks

- POST forms: if GCS rejects ExAws's `X-Amz-*` form fields, `:gcs` disks
  can't use `direct_upload: :post`, so uploads lose server-side size
  enforcement and rely on completion's check (ADR-025).
- Signed Content-Type enforcement on presigned PUT is not confirmed.
- ExAws's exact requests (header casing, signed headers, the
  `CompleteMultipartUpload` body) are untested against real GCS. Other
  clients have hit `SignatureDoesNotMatch` there from extra signed
  headers; ExAws signs only `host`, `content-length`, `x-amz-content-sha256`
  and `x-amz-date` (checked locally).
- Organization policies (`restrictAuthTypes`, uniform bucket-level access,
  public access prevention) can block HMAC keys, ACLs or public URLs. The
  guide should name them.
- HMAC secrets are long-lived; the guide should point to service account
  keys [GCS-16].

## Sources

- [GCS-1] https://docs.cloud.google.com/storage/docs/aws-simple-migration
- [GCS-2] https://docs.cloud.google.com/storage/docs/authentication/signatures
- [GCS-3] https://docs.cloud.google.com/storage/docs/authentication/canonical-requests
- [GCS-4] https://docs.cloud.google.com/storage/docs/access-control/signed-urls
- [GCS-5] https://docs.cloud.google.com/storage/docs/xml-api/post-object-forms
- [GCS-6] https://docs.cloud.google.com/storage/docs/multipart-uploads
- [GCS-7] https://docs.cloud.google.com/storage/docs/xml-api/post-object-multipart
- [GCS-8] https://docs.cloud.google.com/storage/docs/xml-api/delete-multipart
- [GCS-9] https://docs.cloud.google.com/storage/docs/xml-api/reference-headers
- [GCS-10] https://docs.cloud.google.com/storage/docs/xml-api/head-object
- [GCS-11] https://docs.cloud.google.com/storage/docs/xml-api/delete-object
- [GCS-12] https://docs.cloud.google.com/storage/docs/request-endpoints
- [GCS-13] https://docs.cloud.google.com/storage/docs/uniform-bucket-level-access
- [GCS-14] https://docs.cloud.google.com/storage/docs/org-policy-constraints
- [GCS-15] https://docs.cloud.google.com/storage/docs/access-control/making-data-public
- [GCS-16] https://docs.cloud.google.com/storage/docs/authentication/hmackeys
- [GCS-17] https://docs.cloud.google.com/storage/docs/access-control/signing-urls-manually
- [GCS-18] https://docs.cloud.google.com/free/docs/free-cloud-features
- [FGS-1] https://github.com/fsouza/fake-gcs-server (README)
- [FGS-2] https://github.com/fsouza/fake-gcs-server/pull/1164 and https://github.com/fsouza/fake-gcs-server/pull/2092
- [STB-1] https://github.com/googleapis/storage-testbench (README and `testbench/rest_server.py`)
- [GSE-1] https://github.com/oittaa/gcp-storage-emulator
- [GOTH] https://hex.pm/packages/goth
- Signed headers issue with another S3 client: https://github.com/aws/aws-sdk-go-v2/issues/1816

All pages read 2026-10-08.
