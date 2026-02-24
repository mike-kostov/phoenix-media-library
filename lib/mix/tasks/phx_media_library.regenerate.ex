defmodule Mix.Tasks.PhxMediaLibrary.Regenerate do
  @moduledoc """
  Regenerates media conversions.

  This task is useful when you've changed conversion definitions
  and need to regenerate all derived images.

  ## Usage

      # Regenerate all conversions for all media
      $ mix phx_media_library.regenerate

      # Regenerate specific conversion
      $ mix phx_media_library.regenerate --conversion thumb

      # Regenerate for specific collection
      $ mix phx_media_library.regenerate --collection images

      # Regenerate for specific model type
      $ mix phx_media_library.regenerate --model posts

      # Dry run (show what would be regenerated)
      $ mix phx_media_library.regenerate --dry-run

  ## Options

      --conversion    Only regenerate this conversion (can be repeated)
      --collection    Only regenerate for this collection
      --model         Only regenerate for this model type (e.g., "posts")
      --dry-run       Show what would be regenerated without doing it
      --batch-size    Number of items to process at once (default: 100)

  """

  @shortdoc "Regenerates media conversions"

  use Mix.Task

  import Ecto.Query

  @default_batch_size 100

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          conversion: [:string, :keep],
          collection: :string,
          model: :string,
          dry_run: :boolean,
          batch_size: :integer
        ]
      )

    # Start the application
    Mix.Task.run("app.start")

    conversions = Keyword.get_values(opts, :conversion)
    collection = opts[:collection]
    model = opts[:model]
    dry_run? = opts[:dry_run] || false
    batch_size = opts[:batch_size] || @default_batch_size

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Regenerate#{IO.ANSI.reset()}
    ==========================
    """)

    if dry_run? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}\n")
    end

    repo = PhxMediaLibrary.Config.repo()
    query = build_query(collection, model)

    total = repo.aggregate(query, :count)
    Mix.shell().info("Found #{total} media items to process\n")

    if total == 0 do
      Mix.shell().info("#{IO.ANSI.green()}Nothing to regenerate.#{IO.ANSI.reset()}")
    else
      process_media(repo, query, conversions, dry_run?, batch_size, total)
    end
  end

  defp build_query(collection, model) do
    query = from(m in PhxMediaLibrary.Media, order_by: [asc: m.inserted_at])

    query =
      if collection do
        where(query, [m], m.collection_name == ^collection)
      else
        query
      end

    if model do
      where(query, [m], m.mediable_type == ^model)
    else
      query
    end
  end

  defp process_media(repo, query, conversions, dry_run?, batch_size, total) do
    processor = PhxMediaLibrary.Config.image_processor()

    query
    |> repo.stream(max_rows: batch_size)
    |> repo.transaction(fn stream ->
      stream
      |> Stream.with_index(1)
      |> Enum.each(fn {media, index} ->
        process_single(media, conversions, dry_run?, processor, index, total)
      end)
    end)

    Mix.shell().info("\n#{IO.ANSI.green()}✓ Regeneration complete!#{IO.ANSI.reset()}")
  end

  defp process_single(media, filter_conversions, dry_run?, _processor, index, total) do
    progress = "#{String.pad_leading("#{index}", String.length("#{total}"))} / #{total}"

    # Get conversions for this media item
    conversions = get_conversions_for_media(media)

    # Filter if specific conversions requested
    conversions =
      if filter_conversions != [] do
        Enum.filter(conversions, &(to_string(&1.name) in filter_conversions))
      else
        conversions
      end

    if conversions == [] do
      Mix.shell().info("[#{progress}] #{media.file_name} - no conversions to process")
    else
      conversion_names = Enum.map(conversions, &to_string(&1.name)) |> Enum.join(", ")

      if dry_run? do
        Mix.shell().info(
          "[#{progress}] #{media.file_name} - would regenerate: #{conversion_names}"
        )
      else
        Mix.shell().info("[#{progress}] #{media.file_name} - regenerating: #{conversion_names}")

        case PhxMediaLibrary.Conversions.process(media, conversions) do
          :ok ->
            :ok

          {:error, reason} ->
            Mix.shell().error("  #{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        end
      end
    end
  end

  defp get_conversions_for_media(media) do
    # Try to get the model module and its conversions
    # This is a simplified version - in practice you'd need to
    # look up the actual model module from mediable_type
    media.mediable_type
    |> get_model_module()
    |> get_conversions_from_module(media.collection_name)
  end

  defp get_conversions_from_module(nil, _collection_name), do: []

  defp get_conversions_from_module(module, collection_name) when is_atom(module) do
    if function_exported?(module, :get_media_conversions, 1) do
      module.get_media_conversions(String.to_atom(collection_name))
    else
      []
    end
  end

  @spec get_model_module(String.t()) :: module() | nil
  defp get_model_module(_mediable_type) do
    # This would need to be implemented based on your app's conventions
    # For now, return nil to indicate we can't determine the module
    nil
  end
end
