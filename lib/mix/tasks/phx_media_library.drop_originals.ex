defmodule Mix.Tasks.PhxMediaLibrary.DropOriginals do
  @moduledoc """
  > #### Deprecated {: .warning}
  >
  > Use `mix phx_media_library.doctor --drop-originals`, which
  > shares its code with uploads. This task will be removed in 0.10.0.

  Deletes the source files of media that already serve a WebP, for collections
  whose resolved WebP settings say `keep_original: false`. Use it after
  switching an existing collection to `keep_original: false`, once
  `regenerate_webp` and `regenerate_responsive` have run (both read the
  original; this task must be last).

  ## Usage

      $ mix phx_media_library.drop_originals --model MyApp.Catalog.Product --dry-run
      $ mix phx_media_library.drop_originals --model MyApp.Catalog.Product

  ## Options

      --model         Only this model (e.g. MyApp.Catalog.Product)
      --collection    Only this collection
      --dry-run       List what would be deleted
  """

  @shortdoc "(Deprecated) Deletes originals of WebP-served media where keep_original is false"

  use Mix.Task

  import Ecto.Query

  alias PhxMediaLibrary.{Config, Pipeline}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [model: :string, collection: :string, dry_run: :boolean])

    Mix.Task.run("app.start")

    Mix.shell().info(
      "#{IO.ANSI.yellow()}Deprecated: use `mix phx_media_library.doctor --drop-originals`. " <>
        "This task will be removed in 0.10.0.#{IO.ANSI.reset()}"
    )

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
        case process(m, i, total, dry_run?) do
          :dropped -> {d + 1, s}
          :skip -> {d, s + 1}
        end
      end)

    verb = if dry_run?, do: "would drop", else: "dropped"

    Mix.shell().info(
      "\n#{IO.ANSI.green()}✓ #{dropped} #{verb}, #{skipped} skipped#{IO.ANSI.reset()}"
    )
  end

  # Settings come from the media's own collection (PhxMediaLibrary.Model), the
  # same as on upload.
  defp process(media, i, total, dry_run?) do
    case Pipeline.drop_original(media, dry_run: dry_run?) do
      :ok ->
        verb = if dry_run?, do: "would drop", else: "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}"
        Mix.shell().info("[#{i}/#{total}] #{verb} #{media.file_name}")
        :dropped

      {:skip, reason} ->
        Mix.shell().info("[#{i}/#{total}] skip (#{reason}): #{media.file_name}")
        :skip

      {:error, reason} ->
        Mix.shell().info(
          "[#{i}/#{total}] #{IO.ANSI.red()}failed#{IO.ANSI.reset()} #{media.file_name}: #{inspect(reason)}"
        )

        :skip
    end
  end
end
