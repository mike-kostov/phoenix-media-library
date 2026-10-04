# ADR-017: Responsive variants of conversions keep the old default until a minor release

## Status
Accepted (Mike, 2026-10-04)

## Date
2026-10-04

## Context
Originals get responsive variants only when the collection opts in
(`responsive:`). Conversions got them whenever the global
`responsive_images` switch was on, and it defaults to on. The two rules
disagree. Making conversions follow the collection would stop variants
being generated for apps that never set `responsive:`.

## Decision
Keep the old behaviour in 0.9.0: conversions get variants when the global
switch is on. The one change is that a collection which sets
`responsive: [widths: ...]` now has its widths used for conversions too.
Unify the two rules in a later minor release, with a deprecation note
before it.

## Alternatives Considered

### Make conversions follow the collection now
- Pros: one rule.
- Rejected for now: it changes visible behaviour (no srcset for new
  conversions) in apps that relied on the default.

## Consequences
- `Model.conversion_responsive?/2` holds the conversions rule, next to
  `Model.responsive?/3` for originals.
- `with_responsive_images/1` works without global config (it silently did
  nothing in apps; the library's own dev config hid it).
