# ADR-027: No deprecation cycle before 1.0

## Status
Accepted (Mike, 2026-10-08)

## Date
2026-10-08

## Context
0.9.0 deprecated the old regenerate tasks and `presigned_upload_url/3`
before 0.10.0 removed them. In 0.10.0, `move_to/2` needed a clearer name
next to the new `move_media/4`, which raised the question of keeping a
deprecated alias.

## Decision
Until 1.0, the library renames and removes public functions in the next
minor release without a deprecated alias or warning (Mike, 2026-10-08).
Semantic versioning allows breaking changes in 0.x minors.

## Consequences
- Each breaking change is listed under "Breaking changes" in
  `CHANGELOG.md`, with what to call instead, and in the upgrade guide of
  its release.
- From 1.0 on, the deprecation skill applies: deprecate first, remove in
  the next major.
