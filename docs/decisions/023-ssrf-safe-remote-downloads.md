# ADR-023: Remote downloads refuse private networks and stream to disk

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
`add_from_url/3` takes URLs that often come from users. It followed
redirects to any address (cloud metadata at `169.254.169.254` included),
held the body in memory, and decompressed gzip, so a 10 MB response could
expand to gigabytes.

## Decision
`PhxMediaLibrary.Downloader`:
- resolves the host and refuses private, loopback, link-local, CGNAT and
  multicast addresses, re-checking every redirect hop;
- connects to the checked IP, keeping TLS verification on the hostname;
- streams the body to a temporary file without decompressing it;
- stops at `:max_size` (the collection's `max_size` by default) and
  `:total_timeout` (5 minutes).
`allow_private_hosts: true` opts out, for intranets.

## Consequences
- Downloads from internal services need the opt-out.
- Files served with `Content-Encoding: gzip` are stored compressed.
