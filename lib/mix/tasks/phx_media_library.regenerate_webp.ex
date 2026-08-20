defmodule Mix.Tasks.PhxMediaLibrary.RegenerateWebp do
  @moduledoc """
  Re-generates WebP derivatives for existing media from their originals.

  Run this after changing WebP `quality` config, or to add WebP to media that
  predate it. Re-derives from each media's **original**, so media stored with
  `keep_original: false` (WebP replaced the source) cannot be regenerated and
  are skipped with a warning.

  ## Usage

      $ mix phx_media_library.regenerate_webp --model MyApp.Catalog.Product
      $ mix phx_media_library.regenerate_webp --collection photos --dry-run

  ## Options

      --model         Only this model type (also needed to read per-collection
                      WebP overrides; without it the global :webp config is used)
      --collection    Only this collection
      --dry-run       Show what would be regenerated
  """

  @shortdoc "Regenerates WebP derivatives from originals"

  use Mix.Task

  import Ecto.Query

  alias PhxMediaLibrary.{Config, PathGenerator, Webp}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, collection: :string, dry_run: :boolean]
      )

    Mix.Task.run("app.start")
    dry_run? = opts[:dry_run] || false
    repo = Config.repo()
    module = opts[:model] && Module.concat([opts[:model]])

    Mix.shell().info("\n#{IO.ANSI.cyan()}PhxMediaLibrary — Regenerate WebP#{IO.ANSI.reset()}")
    if dry_run?, do: Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN#{IO.ANSI.reset()}")

    # image media that have a non-WebP original to convert from
    query =
      from(m in PhxMediaLibrary.Media,
        where: like(m.mime_type, "image/%") and m.mime_type != "image/webp",
        order_by: [asc: m.inserted_at]
      )

    query = if opts[:collection], do: where(query, [m], m.collection_name == ^opts[:collection]), else: query
    query = if opts[:model], do: where(query, [m], m.mediable_type == ^to_mediable_type(module)), else: query

    media = repo.all(query)
    Mix.shell().info("Found #{length(media)} image(s)\n")

    {done, skipped} =
      media
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {m, i}, {d, s} ->
        process(m, i, length(media), module, dry_run?) |> tally({d, s})
      end)

    Mix.shell().info("\n#{IO.ANSI.green()}✓ #{done} regenerated, #{skipped} skipped#{IO.ANSI.reset()}")
  end

  defp process(media, i, total, module, dry_run?) do
    settings = webp_settings(module, media.collection_name)
    local = PathGenerator.full_path(media, nil)

    cond do
      not Keyword.get(settings, :enabled, false) ->
        Mix.shell().info("[#{i}/#{total}] skip (webp off): #{media.file_name}")
        :skip

      is_nil(local) or not File.exists?(local) ->
        Mix.shell().info(
          "[#{i}/#{total}] #{IO.ANSI.yellow()}skip (no local original)#{IO.ANSI.reset()}: #{media.file_name}"
        )

        :skip

      dry_run? ->
        Mix.shell().info("[#{i}/#{total}] would regenerate: #{media.file_name}")
        :skip

      true ->
        storage = Config.storage_adapter(media.disk)
        orig_path = PathGenerator.relative_path(media, nil)
        Webp.generate(media, local, settings, storage, orig_path)
        Mix.shell().info("[#{i}/#{total}] #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{media.file_name}")
        :done
    end
  end

  # Resolve per-collection WebP settings when the model module is known, else
  # fall back to the global :webp config.
  defp webp_settings(nil, _collection), do: Config.resolve_webp(nil)

  defp webp_settings(module, collection) do
    override =
      if function_exported?(module, :get_media_collection, 1) do
        case module.get_media_collection(String.to_atom(collection)) do
          %PhxMediaLibrary.Collection{webp: webp} -> webp
          _ -> nil
        end
      end

    Config.resolve_webp(override)
  end

  defp to_mediable_type(module), do: module.__schema__(:source)

  defp tally(:done, {d, s}), do: {d + 1, s}
  defp tally(_, {d, s}), do: {d, s + 1}
end
