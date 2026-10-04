# Idea: AVIF-only conversions, or WebP?

Captured 2026-10-04, a research spike on ADR-024 for 0.9.0. No decision yet.

## Problem

How might conversions use AVIF's smaller files without breaking the places
apps send them that can't read AVIF?

With `avif: true`, ADR-024 saves conversions (`:thumb`, `:preview`) as AVIF
and nothing else. The full-size image keeps a WebP or original fallback in
`<img src>`; conversions have none. Apps put conversions in a bare `<img>`,
in og:image, in emails and in JSON APIs.

One gap is already in our code. `<.responsive_img conversion={:preview}>`
renders a bare `<img>` whose `src` and `srcset` are both AVIF, because
`format_sources/2` in `view_helpers.ex` returns `[]` for conversions. A
browser without AVIF shows a broken image. I found this by reading the code;
I did not test it in a browser.

## Compatibility matrix

Researched 2026-10-04. [T-x] marks a person's published test, not vendor
docs. "Not documented" means the docs don't say; it is not a "no".

| Consumer | AVIF | WebP |
|---|---|---|
| Chrome desktop | 85+ [CIU-1] | 32+ [CIU-2] |
| Edge | 121+ [CIU-1] | 18+ [CIU-2] |
| Firefox | 93+ [CIU-1] | 65+ [CIU-2] |
| Safari macOS | Partial 16.1 to 16.3 (still images, macOS 13+, no noise synthesis); full 16.4+ [CIU-1] | 16.0+; 14 to 15.6 need macOS 11+ [CIU-2] |
| iOS Safari | 16.0+; 16.0 to 16.3 without animation or noise synthesis [CIU-1] | 14.0+ [CIU-2] |
| Chrome Android | Yes (caniuse lists only version 154) [CIU-1] | Yes [CIU-2] |
| Samsung Internet | 14.0+ [CIU-1] | 4+ [CIU-2] |
| Global users with support | 95.36% [CIU-1] | 96.82% [CIU-2] |
| Google Search and Images | Yes, since August 2024 [G-1, G-2] | Yes [G-1] |
| Bing | Not verified | Not verified |
| Facebook | Docs list JPEG, GIF, PNG [FB-1]; works [T-1, T-2] | Works [T-1, T-2] |
| WhatsApp | Docs name no formats [WA-1]; colours broken [T-1], works [T-2] | Works [T-1, T-2] |
| LinkedIn | Docs name no formats [LI-1]; no [T-1, T-2] | Works [T-1, T-2] |
| X | Docs not reachable (HTTP 402); no [T-2] | Works [T-2] |
| Slack | Docs name no formats [SL-1]; no [T-1, T-2] | Works [T-1, T-2] |
| Discord, Telegram | No [T-1] | Works [T-1] |
| iMessage | No [T-2] | Works [T-2] |
| Gmail | Converts to JPEG (tested 2023-01) [CE-1] | Converts to JPEG (tested 2021-02) [CE-2] |
| Apple Mail | macOS 13.3+, iOS 16.4+ [CE-1] | Mail 14+ [CE-2] |
| Outlook Windows 2007 to 2019 | No [CE-1] | No [CE-2] |
| Outlook macOS, iOS | Yes since 2023-04 [CE-1] | Yes [CE-2] |
| Outlook.com | Depends on the browser [CE-1] | Depends on the browser [CE-2] |
| Claude API | No; JPEG, PNG, GIF, WebP [AI-1] | Yes [AI-1] |
| OpenAI API | No; PNG, JPEG, WebP, still GIF [AI-2] | Yes [AI-2] |
| Gemini API | No; PNG, JPEG, WebP, HEIC, HEIF [AI-3] | Yes [AI-3] |
| LLM crawlers | Not documented; OpenAI's crawler page doesn't mention images [AI-4] | Not documented |

### What the matrix means for us

- **Browsers are close.** 4.6% of users lack AVIF, 3.2% lack WebP. Inside
  `<picture>` neither number matters, because the `<img>` falls back.
- **Everything else is not close.** No AI API lists AVIF; all three take
  WebP. In the two link-preview tests, Facebook is the only service that
  shows AVIF cleanly; every tested service shows WebP.
- **Email doesn't separate them.** Gmail converts both to JPEG, and classic
  Outlook on Windows shows neither.
- **Conversions are the files apps share.** AVIF-only makes the most-shared
  file the least compatible one. A conversion can set `format:` to opt out
  (ADR-024), but only apps that know about the problem will do that.

## Options

**A. Keep AVIF-only conversions.** One file per conversion. No pipeline
change. The guides must tell apps to set `format: :webp` or `:jpeg` on
conversions used outside the browser. The bare `<img>` stays broken for
4.6% of users, because no fallback file exists.

**B. Conversions in WebP; AVIF only in typed sources.** Conversions take
the WebP format (or the original's when WebP is off). AVIF stays on the
original and its variants. One file per conversion, a little larger than
AVIF (not measured here). Code changes:

- Drop the AVIF branch in `Model.conversion_format/3`.
- A same-shape conversion's `srcset` reuses the original's AVIF variants,
  so the components must put that `srcset` in a `<source type="image/avif">`
  and give the `<img>` only the WebP conversion. Variants of a conversion
  with a different shape need the same treatment.
- Amend ADR-024, and add tests and a changelog line.

**C. Conversions in both formats.** One AVIF and one WebP file per
conversion, the same pattern as the original. Two files per conversion.
This needs sibling generation for conversions, health and doctor checks
for them, `format_sources/2` for conversions, and a way to ask for one
format, because `url(media, :thumb)` returns one URL. It is the most code.

### Recommendation

B. Every non-browser consumer in the matrix reads WebP, and most don't
read AVIF. B also fixes the broken conversion `<img>` with a small change.
C can come later as an opt-in if the bytes saved on conversions turn out
to matter.

## Open questions

- How much smaller is an AVIF conversion than the WebP one at our default
  quality? Measure on the ADR-024 test image before choosing between B and
  C.
- Should B's conversions be JPEG rather than WebP when they're meant for
  og:image? WebP passed every test except Xing's [T-1].

## Sources

All read 2026-10-04.

- [CIU-1] https://caniuse.com/avif (data updated 2026-09-30, raw data at https://github.com/Fyrd/caniuse/blob/main/features-json/avif.json)
- [CIU-2] https://caniuse.com/webp (same data release)
- [G-1] https://developers.google.com/search/docs/appearance/google-images (updated 2026-03-02)
- [G-2] https://developers.google.com/search/blog/2024/08/happy-avifriday (2024-08-30)
- [FB-1] https://developers.facebook.com/docs/sharing/webmasters/ (undated)
- [WA-1] https://developers.facebook.com/documentation/business-messaging/whatsapp/link-previews/ (undated)
- [LI-1] https://www.linkedin.com/help/linkedin/answer/a521928 (undated)
- [SL-1] https://docs.slack.dev/messaging/unfurling-links-in-messages/ (undated)
- [T-1] https://darekkay.com/blog/open-graph-image-formats/ (Darek Kay, updated 2025-11-13)
- [T-2] https://joost.blog/use-avif-webp-share-images/ (Joost de Valk, 2024-12-04)
- [CE-1] https://www.caniemail.com/features/image-avif/ (last tested 2023-01-14)
- [CE-2] https://www.caniemail.com/features/image-webp/ (last tested 2021-02-06)
- [AI-1] https://platform.claude.com/docs/en/build-with-claude/vision
- [AI-2] https://developers.openai.com/api/docs/guides/images-vision
- [AI-3] https://ai.google.dev/gemini-api/docs/image-understanding (updated 2026-09-23)
- [AI-4] https://developers.openai.com/api/docs/bots
