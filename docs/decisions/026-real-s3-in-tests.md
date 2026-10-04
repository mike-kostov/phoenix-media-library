# ADR-026: Real S3 in tests through a reused Ministack container

## Status
Accepted (Mike, 2026-10-04). Amended 2026-10-04 (Mike): the test helper
starts the container with podman or Docker; Testcontainers is dropped.

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

While doing task 5b: Testcontainers 2.4.0 (the latest) requires
`hackney ~> 1.20`, and hackney 1.25.0 (the latest 1.x) has four advisories
(EEF-CVE-2026-47071 HIGH, -47075 and -47076 MEDIUM, -47069 LOW), fixed only
in 4.x. Forcing hackney 4.8 breaks Testcontainers' connection to the Docker
socket (`{:error, :nxdomain}` on `http+unix://`). Keeping it would break
spec S5 (no advisories in the lock).

## Decision
- The test helper starts a named Ministack container
  (`ministackorg/ministack:1.3.42`) with podman or Docker, whichever is
  installed, and reuses it when it is already there. No new dependency.
- S3 tests run against it as part of the normal `mix test`. Without a
  container runtime they are excluded with a notice, like the `:db` tests
  without Postgres.
- They replace `FakeS3Client`.
- Postgres stays a local service, as today.
- Provider rules that an emulator can't check (signature enforcement,
  ACLs) are taken from provider documentation, recorded in
  `docs/ideas/s3-providers.md`.

## Alternatives Considered

### Testcontainers (the original decision)
- Pros: a maintained library manages the container.
- Dropped: its hackney 1.x has unfixed advisories, and hackney 4 doesn't
  work with it.

### Postgres in a container too
- Pros: reproducible, no local install.
- Deferred: reuse didn't work in the spike, so every run would pay about
  3 s.

### A manual container or a mix alias
- Rejected by Mike in favour of tests managing the container.

## Consequences
- The S3 tests need podman or Docker running; without one they are skipped,
  with a notice.
- The first run pulls the Ministack image and starts it (a few seconds);
  later runs find it already running.
- The container keeps running between runs; remove it with
  `podman rm -f phx_media_library_ministack` (or `docker rm -f`).
- Signature and ACL behaviour still needs real accounts to confirm.
