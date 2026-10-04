# ADR-026: Real S3 in tests through Testcontainers and Ministack

## Status
Proposed (2026-10-04), accepted with spec 01's update.

## Date
2026-10-04

## Context
S3 code was tested against a hand-written fake HTTP client
(`FakeS3Client`), which only answers what we expect it to. Mike wants fewer
fakes and containers kept between runs. Spike results
(`docs/ideas/test-containers.md`): Testcontainers 2.4 works with podman
when Ryuk runs privileged; LocalStack now requires an auth token and MinIO
images are no longer on Docker Hub; Ministack (MIT, no account) works and
is reused between runs in about 35 ms. A reused Postgres container was
killed at the end of each run (cause unknown). Ministack does not verify
request signatures.

## Decision
- `{:testcontainers, "~> 2.4", only: :test}`.
- S3 tests run against a reused Ministack container, as part of the normal
  `mix test`. A project `.testcontainers.properties` enables reuse and
  privileged Ryuk, so nothing is set per machine.
- They replace `FakeS3Client`.
- Postgres stays a local service, as today.
- Provider rules that an emulator can't check (signature enforcement,
  ACLs) are taken from provider documentation, recorded in
  `docs/ideas/s3-providers.md`.

## Alternatives Considered

### Postgres in a container too
- Pros: reproducible, no local install.
- Deferred: reuse didn't work in the spike, so every run would pay about
  3 s.

### A manual container or a mix alias
- Rejected by Mike in favour of tests managing the container.

## Consequences
- The test suite needs podman or Docker running.
- The first run pulls the Ministack image and pays about 3 s; later runs
  about 35 ms plus Ryuk's start (about 1.3 s).
- Signature and ACL behaviour still needs real accounts to confirm.
