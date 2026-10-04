defmodule Mix.Tasks.PhxMediaLibrary.RegenerateResponsive do
  @moduledoc """
  Regenerates responsive images for existing media.

  This task is useful when:
  - You've changed responsive image configuration
  - You've added responsive images to existing media that didn't have them
  - Responsive images were corrupted or deleted

  ## Usage

      # Regenerate for all media
      $ mix phx_media_library.regenerate_responsive

      # Regenerate for specific collection
      $ mix phx_media_library.regenerate_responsive --collection images

      # Dry run
      $ mix phx_media_library.regenerate_responsive --dry-run

  ## Options

      --collection    Only regenerate for this collection
      --model         Only regenerate for this model type
      --dry-run       Show what would be regenerated
      --batch-size    Number to process at once (default: 50)

  """

  @shortdoc "Regenerates responsive images"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          collection: :string,
          model: :string,
          dry_run: :boolean,
          batch_size: :integer
        ]
      )

    Mix.Task.run("app.start")


    dry_run? = opts[:dry_run] || false

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Regenerate Responsive Images#{IO.ANSI.reset()}
    =============================================
    """)

    if dry_run? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN#{IO.ANSI.reset()}\n")
    end

    repo = PhxMediaLibrary.Config.repo()
    query = build_responsive_query(opts[:collection], opts[:model])
    total = repo.aggregate(query, :count)
    Mix.shell().info("Found #{total} image(s) to process\n")

    query
    |> repo.all()
    |> Enum.with_index(1)
    |> Enum.each(&process_item(&1, total, dry_run?, repo))

    Mix.shell().info("\n#{IO.ANSI.green()}✓ Complete!#{IO.ANSI.reset()}")
  end

  defp build_responsive_query(collection, model) do
    query =
      from(m in PhxMediaLibrary.Media,
        where: like(m.mime_type, "image/%"),
        order_by: [asc: m.inserted_at]
      )

    query = if collection, do: where(query, [m], m.collection_name == ^collection), else: query
    if model, do: where(query, [m], m.mediable_type == ^model), else: query
  end

  defp process_item({media, index}, total, true = _dry_run?, _repo) do
    Mix.shell().info("[#{index}/#{total}] Would regenerate: #{media.file_name}")
  end

  # Widths and the opt-in come from the media's own collection
  # (PhxMediaLibrary.Model), the same as on upload. Variants are regenerated
  # for the original and every generated conversion.
  defp process_item({media, index}, total, false = _dry_run?, _repo) do
    of = [nil | Map.keys(media.generated_conversions || %{})]

    case PhxMediaLibrary.Pipeline.responsive(media, of: of) do
      {:ok, _media} ->
        Mix.shell().info(
          "[#{index}/#{total}] #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{media.file_name}"
        )

      {:skip, reason} ->
        Mix.shell().info("[#{index}/#{total}] skip (#{reason}): #{media.file_name}")

      {:error, reason} ->
        Mix.shell().error(
          "[#{index}/#{total}] #{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()} #{media.file_name}"
        )
    end
  end
end
