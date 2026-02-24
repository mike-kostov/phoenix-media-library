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

    collection = opts[:collection]
    model = opts[:model]
    dry_run? = opts[:dry_run] || false
    _batch_size = opts[:batch_size] || 50

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Regenerate Responsive Images#{IO.ANSI.reset()}
    =============================================
    """)

    if dry_run? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN#{IO.ANSI.reset()}\n")
    end

    repo = PhxMediaLibrary.Config.repo()

    # Only process images
    query =
      from(m in PhxMediaLibrary.Media,
        where: like(m.mime_type, "image/%"),
        order_by: [asc: m.inserted_at]
      )

    query = if collection, do: where(query, [m], m.collection_name == ^collection), else: query
    query = if model, do: where(query, [m], m.mediable_type == ^model), else: query

    total = repo.aggregate(query, :count)
    Mix.shell().info("Found #{total} image(s) to process\n")

    query
    |> repo.all()
    |> Enum.with_index(1)
    |> Enum.each(fn {media, index} ->
      progress = "[#{index}/#{total}]"

      if dry_run? do
        Mix.shell().info("#{progress} Would regenerate: #{media.file_name}")
      else
        Mix.shell().info("#{progress} Processing: #{media.file_name}")

        case PhxMediaLibrary.ResponsiveImages.generate_all(media) do
          {:ok, responsive_data} ->
            media
            |> Ecto.Changeset.change(responsive_images: responsive_data)
            |> repo.update!()

            Mix.shell().info("  #{IO.ANSI.green()}✓ Done#{IO.ANSI.reset()}")

          {:error, reason} ->
            Mix.shell().error("  #{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        end
      end
    end)

    Mix.shell().info("\n#{IO.ANSI.green()}✓ Complete!#{IO.ANSI.reset()}")
  end
end
