# Idea: Real services in tests through Testcontainers

Captured 2026-10-04. Direction chosen: ADR-026. Spike on branch
`spike/testcontainers`
(`test/spike/containers_spike_test.exs`, run with `--only spike`).

## Problem

How might the tests use real S3 and Postgres instead of fakes, without
slowing down everyday test runs?

Fakes written so far that hide real behaviour: `FakeS3Client` (pretends to
be S3). Fakes that are fine: `FailingImageProcessor` (forces a failure
libvips won't produce on demand), Req `plug:` stubs for the downloader's
SSRF logic, `FakeEndpoint`.

## Spike results (podman 5.6.2 on macOS)

| Finding | Detail |
|---|---|
| Testcontainers works with podman | Only with Ryuk privileged: `TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED=true` (or `ryuk.container.privileged=true` in `~/.testcontainers.properties`). Without it: `{:error, :ryuk_connection_failed}`. |
| LocalStack can't be used | `localstack/localstack:latest` (2026.9.0) quits without `LOCALSTACK_AUTH_TOKEN`: "License activation failed". Its free community edition is gone. |
| MinIO can't be used | Docker Hub denies `minio/minio` pulls ("requested access to the resource is denied"), pinned tag and `latest`. |
| Ministack works | `ministackorg/ministack:1.3.42`, MIT, no account; Testcontainers ships `MinistackContainer`. Bucket, put, HEAD, ranged GET, ACL header: all work. Presigned POST size policy enforced (204 within, 400 over). |
| Ministack doesn't verify signatures | A presigned PUT signed for `text/plain` accepted `text/html` (ExAws did sign `content-type;host`). Container tests prove flows, not provider rules. |
| Postgres works | `postgres:15-alpine` via `PostgresContainer`. |

Timing, images cached, two runs:

| Step | Time |
|---|---|
| `Testcontainers.start_link` (Ryuk) | 1.3 to 1.7 s |
| Ministack container | 2.6 s |
| Postgres container | 2.9 to 3.1 s |
| Spike total (both) | about 8 s |

### Keeping containers between runs

Reuse needs `with_reuse(true)` on the container and the property
`testcontainers.reuse.enable=true`, which can live in a project file,
`.testcontainers.properties`, next to `ryuk.container.privileged=true`, so
nothing has to be set per machine
(`deps/testcontainers/lib/container/protocols/container_builder_helper.ex`).
Ryuk only removes containers labelled `reuse=false`.

| Run | Ryuk start | Ministack | Postgres | Total |
|---|---|---|---|---|
| 1 (cold) | 1.7 s | 2.9 s | 3.8 s | 8.6 s |
| 2 | 1.4 s | **0.03 s** | 2.6 s | 4.1 s |
| 3 | 1.3 s | **0.04 s** | 2.9 s | 4.4 s |

- Ministack is reused: it stays up between runs and is found in about
  35 ms.
- Postgres is not: each run's container carries the reuse label and the
  same hash, yet is killed (exit 137) when the run ends. Cause unknown;
  possibly a bug in the package's Postgres module. Not investigated further
  (time box).
- Ryuk's 1.3 s remains on every run.

## Direction to discuss

- S3 tests tagged `:s3`, against Ministack through Testcontainers; they
  replace `FakeS3Client`.
- Whether `mix test` starts Postgres in a container too: reproducible and no
  local install, for about 3 s per run (less with reuse). The current suite
  uses a local Postgres.
- Testcontainers is a test-only dependency (`{:testcontainers, "~> 2.4",
  only: :test}`); it brings `hackney` and `tesla` into the test build only.
- Podman users set the Ryuk variable once; the guide for contributors says
  so.

## Also found

- `req` 0.5.17 (our constraint `~> 0.5`) has two HIGH advisories:
  CVE-2026-49755 (decompression bomb, fixed in 0.6.1) and CVE-2026-49756
  (multipart header injection, fixed in 0.6.0). The library's own requests
  are not affected (the downloader passes `raw: true` and `decode_body:
  false`; nothing uses `form_multipart`), but the constraint keeps apps on
  vulnerable versions. Allowing `>= 0.6.1` needs a compatibility check.
