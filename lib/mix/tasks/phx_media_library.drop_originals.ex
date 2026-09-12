defmodule Mix.Tasks.PhxMediaLibrary.DropOriginals do
  @moduledoc """
  Deletes the source files of media that already serve a WebP, for collections
  whose resolved WebP settings say `keep_original: false`. Use it after
  switching an existing collection to `keep_original: false`, once
  `regenerate_webp` and `regenerate_responsive` have run (both read the
  original; this task must be last).

  ## Usage

      $ mix phx_media_library.drop_originals --model MyApp.Catalog.Product --dry-run
      $ mix phx_media_library.drop_originals --model MyApp.Catalog.Product

  ## Options

      --model         Only this model (needed to resolve per-collection settings;
                      without it only the global :webp config is consulted)
      --collection    Only this collection
      --dry-run       List what would be deleted
  """

  @shortdoc "Deletes originals of WebP-served media where keep_original is false"

  use Mix.Task

  import Ecto.Query

  alias PhxMediaLibrary.{Config, PathGenerator, Webp}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [model: :string, collection: :string, dry_run: :boolean])

    Mix.Task.run("app.start")
    dry_run? = opts[:dry_run] || false
    repo = Config.repo()
    module = opts[:model] && Module.concat([opts[:model]])

    Mix.shell().info("\n#{IO.ANSI.cyan()}PhxMediaLibrary — Drop originals#{IO.ANSI.reset()}")
    if dry_run?, do: Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN#{IO.ANSI.reset()}")

    query =
      from(m in PhxMediaLibrary.Media,
        where: like(m.mime_type, "image/%") and m.mime_type != "image/webp",
        order_by: [asc: m.inserted_at]
      )

    query =
      if opts[:collection],
        do: where(query, [m], m.collection_name == ^opts[:collection]),
        else: query

    query =
      if module,
        do: where(query, [m], m.mediable_type == ^module.__schema__(:source)),
        else: query

    media = repo.all(query)
    total = length(media)
    Mix.shell().info("Found #{total} image(s)\n")

    {dropped, skipped} =
      media
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {m, i}, {d, s} ->
        case process(m, i, total, module, dry_run?) do
          :dropped -> {d + 1, s}
          :skip -> {d, s + 1}
        end
      end)

    verb = if dry_run?, do: "would drop", else: "dropped"

    Mix.shell().info(
      "\n#{IO.ANSI.green()}✓ #{dropped} #{verb}, #{skipped} skipped#{IO.ANSI.reset()}"
    )
  end

  defp process(media, i, total, module, dry_run?) do
    settings = webp_settings(module, media.collection_name)
    local = PathGenerator.full_path(media, nil)

    cond do
      Keyword.get(settings, :keep_original, true) ->
        Mix.shell().info("[#{i}/#{total}] skip (keep_original): #{media.file_name}")
        :skip

      not match?(%{"webp" => w} when is_binary(w), media.custom_properties) ->
        Mix.shell().info(
          "[#{i}/#{total}] #{IO.ANSI.yellow()}skip (no webp)#{IO.ANSI.reset()}: #{media.file_name}"
        )

        :skip

      is_nil(local) or not File.exists?(local) ->
        Mix.shell().info("[#{i}/#{total}] skip (already gone): #{media.file_name}")
        :skip

      dry_run? ->
        Mix.shell().info("[#{i}/#{total}] would drop: #{media.file_name}")
        :dropped

      true ->
        case Webp.drop_original(media) do
          :ok ->
            Mix.shell().info(
              "[#{i}/#{total}] #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{media.file_name}"
            )

            :dropped

          other ->
            Mix.shell().info(
              "[#{i}/#{total}] #{IO.ANSI.red()}failed#{IO.ANSI.reset()} #{media.file_name}: #{inspect(other)}"
            )

            :skip
        end
    end
  end

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
end
