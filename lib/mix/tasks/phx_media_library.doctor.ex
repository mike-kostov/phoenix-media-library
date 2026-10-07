defmodule Mix.Tasks.PhxMediaLibrary.Doctor do
  @moduledoc """
  Checks the health of stored media and repairs what it can.

  Without options it only reports. Repairs are opt-in, show their plan and
  ask before running (`--yes` skips the question). Each repair runs the same
  `PhxMediaLibrary.Pipeline` step an upload runs, so repaired media matches
  newly uploaded media. Works with any storage adapter (on S3 every file
  check is a request, so large libraries take a while).

  ## What it checks

    * **Files.** Media with no files left (error); missing conversions,
      WebP, AVIF, responsive variants or placeholders (repairable).
    * **Metadata.** Images without dimensions, e.g. from the EXIF-date bug
      before 0.8.4 (repairable).
    * **Names.** Files not stored under their collection's `file_naming`,
      e.g. uploaded before 0.9 (repairable).
    * **Originals.** Originals still present where the collection says
      WebP `keep_original: false` (repairable).
    * **Integrity.** Checksum mismatches, with `--deep` (error).
    * **Records.** Media whose parent record no longer exists, and the
      soft-delete backlog.

  The checks find what is missing or outdated, not what was made with
  other settings: after changing a collection's conversion, WebP, AVIF,
  responsive or placeholder settings, run `--rebuild` for it.

  The task is a thin wrapper: the checks and repairs are
  `PhxMediaLibrary.Doctor.check/1` and `repair/1`, which also run without
  Mix (in a release, a scheduled job, an admin page).

  ## Usage

      # Report only
      $ mix phx_media_library.doctor

      # Fill in missing conversions, WebP, AVIF, variants and placeholders
      $ mix phx_media_library.doctor --regenerate

      # Rename pre-0.9 files and fill in lost metadata, for one model
      $ mix phx_media_library.doctor --model products --rename --reextract

      # Rebuild every WebP after changing its quality
      $ mix phx_media_library.doctor --rebuild --only webp

      # Check and repair one media item
      $ mix phx_media_library.doctor --id 8f2c4d1e-… --regenerate

  ## Repairs

      --regenerate      Create missing conversions, WebP, AVIF, responsive
                        variants and placeholders
      --reextract       Extract missing metadata (dimensions, EXIF)
      --rename          Move files to their collection's file_naming
                        (URLs change; old links will 404)
      --drop-originals  Delete originals where keep_original: false
      --fix             Permanently delete media with no files left
      --rebuild         Regenerate derivatives even when present (after
                        changing conversion, WebP, AVIF, responsive or
                        placeholder settings)
        --only          With --rebuild: conversions, webp, avif, responsive
                        and/or placeholders
                        (comma-separated; default all)
        --conversion    With --rebuild: only this conversion (repeatable)

  ## Filters and other options

      --id              Only this media item (skips the orphan and backlog
                        reports, which cover all media)
      --model           Only this model: mediable type ("products") or
                        module (MyApp.Catalog.Product)
      --collection      Only this collection
      --disk            Only this disk
      --deep            Also verify checksums (reads every file)
      --skip-files      Skip the per-media checks
      --skip-orphans    Skip the orphaned-records check
      --dry-run         Show the repair plan without asking or running it
      --yes             Run repairs without asking
      --strict          Exit with status 1 when errors are found
                        (for scheduled jobs and CI)

  """

  @shortdoc "Checks media health and repairs problems"

  use Mix.Task

  alias PhxMediaLibrary.Doctor.CLI

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    shell = Mix.shell()

    case CLI.run(args, %{info: &shell.info/1, yes?: &shell.yes?/1}) do
      {:ok, 0} -> :ok
      {:ok, status} -> exit({:shutdown, status})
      {:error, message} -> Mix.raise(message)
    end
  end
end
