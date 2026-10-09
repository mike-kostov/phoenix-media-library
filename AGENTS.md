# AGENTS.md: PhxMediaLibrary

This file is the entrypoint for AI agents working in this repository. It
holds the rules that always apply and points to the skill or document for
everything else. Load those only when the task needs them.

## About this project

PhxMediaLibrary attaches files to Ecto schemas, in the spirit of Spatie's
Laravel Media Library: collections, storage backends, conversions,
responsive images, uploads, LiveView components.

It is a Phoenix library, not an application. It owns a polymorphic `media`
table, injects `has_many` associations into the host's schemas, and ships
LiveView components and a Plug. It has no endpoint, router, layouts, auth or
asset bundle. Optional dependencies: `:image` (libvips), `ex_aws_s3`, `oban`,
FFmpeg. Tests run on PostgreSQL and on SQLite (`DB=sqlite`). Releases go to Hex. There is no CI
(ADR-022).

## Five Non-Negotiables (always active)

1. **Surface assumptions before building.** State what you are assuming and ask for correction before writing any code.
2. **Stop and ask when requirements conflict.** Name the specific conflict; do not guess or silently pick one interpretation.
3. **Push back when warranted.** You are not a yes-machine. State the problem clearly, propose an alternative, then respect the final decision.
4. **Prefer the boring, obvious solution.** A staff engineer should see the code and say "of course." Cleverness is expensive.
5. **Touch only what you are asked to touch.** No unsolicited refactors, no "while I'm here" scope creep, no removing things you don't fully understand.

## Workflow

| Phase | What happens | Where it lives |
|---|---|---|
| Define | Turn the ask into a spec with acceptance criteria. Five lines is fine, zero is not. | `docs/specs/` (rough ideas first in `docs/ideas/`) |
| Plan | Break the spec into small, ordered, verifiable tasks. | `docs/plans/` |
| Build | Implement in vertical slices, one commit each. | the code |
| Verify | Prove each slice works (definition of done below). | the tests |
| Review | Check correctness, readability, security, performance. | |
| Ship | Changelog, version, `mix hex.build --unpack`, release. | `CHANGELOG.md` |

- A decision that would be expensive to reverse, or that someone could
  re-argue later, gets an ADR in `docs/decisions/`.
- Agreed work without a spec yet goes in `docs/backlog.md`. Bugs found
  during a release go into that release.
- Versioning: features and changed behaviour go into the minor in progress
  (0.10.0, which keeps growing until Mike releases it); fixes after a
  release go into its patch line (0.10.x). Ask before deciding which.
- Never write a date into a file without checking the real current time
  first.

## Skill route map

Load `using-agent-skills` first if unsure which skill applies; it routes to the others.

| Situation | Load |
|---|---|
| Unsure which skill applies | `.agents/skills/using-agent-skills/SKILL.md` |
| The ask is underspecified | `.agents/skills/interview-me/SKILL.md` |
| A rough concept needs sharpening | `.agents/skills/idea-refine/SKILL.md` |
| New feature or significant change, no spec yet | `.agents/skills/spec-driven-development/SKILL.md` |
| Spec is clear, break it into tasks | `.agents/skills/planning-and-task-breakdown/SKILL.md` |
| Writing or reviewing Elixir, Ecto, HEEx or LiveView code | `.agents/rules/elixir-phoenix.md` |
| Loading the right context at the right time | `.agents/skills/context-engineering/SKILL.md` |
| Code must match a library's official docs | `.agents/skills/source-driven-development/SKILL.md` |
| High stakes or unfamiliar code | `.agents/skills/doubt-driven-development/SKILL.md` |
| Any change touching more than one file | `.agents/skills/incremental-implementation/SKILL.md` |
| Logic, bug fixes, behaviour changes: test first | `.agents/skills/test-driven-development/SKILL.md` |
| Building or changing the shipped LiveView components | `.agents/skills/frontend-ui-engineering/SKILL.md` |
| The default look of shipped components | `.agents/skills/taste-skill/SKILL.md` |
| A public function, behaviour or module boundary | `.agents/skills/api-and-interface-design/SKILL.md` |
| Anything that runs in the browser | `.agents/skills/browser-testing-with-devtools/SKILL.md` |
| Tests fail or behaviour is unexpected | `.agents/skills/debugging-and-error-recovery/SKILL.md` |
| Reviewing a change | `.agents/skills/code-review-and-quality/SKILL.md` |
| Code works but is hard to read | `.agents/skills/code-simplification/SKILL.md` |
| Uploads, remote URLs, filenames, signed URLs, any untrusted data | `.agents/skills/security-and-hardening/SKILL.md` |
| Performance requirements or a suspected regression | `.agents/skills/performance-optimization/SKILL.md` |
| Commits, branches, versions | `.agents/skills/git-workflow-and-versioning/SKILL.md` |
| CI/CD (this project has none, ADR-022) | `.agents/skills/ci-cd-and-automation/SKILL.md` |
| Removing or deprecating something users rely on | `.agents/skills/deprecation-and-migration/SKILL.md` |
| Recording a decision or writing docs | `.agents/skills/documentation-and-adrs/SKILL.md` |
| Preparing a Hex release | `.agents/skills/shipping-and-launch/SKILL.md` |
| Writing any prose (docs, comments, commits, ADRs) | `.agents/skills/unslop/SKILL.md` |

## Definition of done

A change is done when all of these hold. "Seems right" is not one of them.

- A test reproduces the bug or specifies the behaviour, and it fails on the
  old code before it passes on the new code.
- Behaviour that apps see by default is tested without the library's own
  `config/config.exs`, which turns on settings apps don't have.
- `mix precommit` passes. With no CI, it is the only gate. It checks
  formatting rather than fixing it, so run `mix format` first.
- Each commit compiles and passes the tests on its own.
- Every public module and function has `@moduledoc`/`@doc` with an example,
  and every public function has a `@spec`.
- Operations that can fail return `{:ok, _}`/`{:error, _}`; expected
  failures never raise.
- User-visible changes have a `CHANGELOG.md` entry under `[Unreleased]`.
- A user-facing feature appears in the README's feature list and in the
  relevant guide, with a short example.
- Prose went through `unslop`.

## Anti-rationalization

Excuses that came up in this repository, and why they don't hold.

| Excuse | Reality |
|---|---|
| "The existing tests still pass." | They may assert the old behaviour. Eleven tests asserted that `file_name` equals the uploaded name. Read what they check. |
| "My new test passes, so the fix works." | Run it against the old code first. If it passes there too, it proves nothing. |
| "It works in the test config." | The library's dev config enables settings apps don't have. That hid `with_responsive_images/1` doing nothing in apps. |
| "It's only a refactor." | The settings refactor changed a default (responsive variants of conversions) until it was caught. Any behaviour change needs the user's OK and a changelog line. |
| "Swallow the error so the upload never fails." | A swallowed error hid width-only conversions failing for every user. Return the error, or at least log it. |
| "While I'm here, I'll also..." | Non-negotiable 5. Note it in the backlog instead. |

## Library rules (deliberate, do not "fix")

- **`MediaLive` is a LiveComponent on purpose.** A self-contained upload widget is the strong, specific need that justifies one.
- **Never assume the host app's scaffolding.** Components must not depend on `core_components` (`<.icon>`, `<.input>`), `Layouts`, `current_scope`, routes or the host's `app.css`. They carry their own markup, accept `class` overrides, and use colocated hooks only.
- **Settings and processing steps live in one place** (ADR-014). `PhxMediaLibrary.Model` resolves per-collection settings; `PhxMediaLibrary.Pipeline` has one function per step. Never re-implement a setting lookup or a step elsewhere.
- **The library chooses stored filenames** (ADR-015). Never build a path from the uploader's filename; it is kept in `metadata["original_file_name"]`.
- **Components scope client-supplied IDs to their own record** (ADR-018). Who may edit a record is the host app's decision.
- **Dependencies stay optional and minimal** (ADR-010, ADR-012). Optional-dep modules sit inside `if Code.ensure_loaded?`. Never add a required dependency without agreement.
- **Extend through behaviours.** Storage, image, video and async processing, MIME detection, metadata extraction and path generation are behaviours with shipped defaults (ADR-002, ADR-003). A new capability is a new adapter.
- **Settings resolve as upload option, then collection, then global config, then library default** (ADR-004).

## Key files

| File | Purpose |
|---|---|
| `CLAUDE.md` | Claude Code pointer to this file |
| `.agents/skills/` | Workflow skills |
| `.agents/rules/elixir-phoenix.md` | Elixir, Ecto, HEEx and LiveView coding rules |
| `docs/decisions/` | ADRs |
| `docs/specs/`, `docs/plans/`, `docs/ideas/` | Specs, plans, ideas |
| `docs/backlog.md` | Agreed work without a spec, and the parking lot |
| `guides/` | User guides published on HexDocs |
| `CHANGELOG.md` | Release notes |
