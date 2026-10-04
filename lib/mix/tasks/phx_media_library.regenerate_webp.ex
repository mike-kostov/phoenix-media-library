defmodule Mix.Tasks.PhxMediaLibrary.RegenerateWebp do
  @moduledoc """
  > #### Deprecated {: .warning}
  >
  > Use `mix phx_media_library.doctor --rebuild --only webp`, which
  > shares its code with uploads. This task will be removed in 0.10.0.

  Re-generates WebP derivatives for existing media from their originals.

  Run this after changing WebP `quality` or `max_dimension` config, or to add
  WebP to media that predate it. Follow with `regenerate_responsive` when the
  cap changed, so the `srcset` reflects the new served size. Re-derives from each media's **original**, so media stored with
  `keep_original: false` (WebP replaced the source) cannot be regenerated and
  are skipped with a warning.

  ## Usage

      $ mix phx_media_library.regenerate_webp --model MyApp.Catalog.Product
      $ mix phx_media_library.regenerate_webp --collection photos --dry-run

  ## Options

      --model         Only this model (e.g. MyApp.Catalog.Product)
      --collection    Only this collection
      --dry-run       Show what would be regenerated
  """

  @shortdoc "(Deprecated) Regenerates WebP derivatives from originals"

  use Mix.Task

  import Ecto.Query

  alias PhxMediaLibrary.{Config, Model, Pipeline}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, collection: :string, dry_run: :boolean]
      )

    Mix.Task.run("app.start")

    Mix.shell().info(
      "#{IO.ANSI.yellow()}Deprecated: use `mix phx_media_library.doctor --rebuild --only webp`. " <>
        "This task will be removed in 0.10.0.#{IO.ANSI.reset()}"
    )

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

    query =
      if opts[:collection],
        do: where(query, [m], m.collection_name == ^opts[:collection]),
        else: query

    query =
      if opts[:model],
        do: where(query, [m], m.mediable_type == ^to_mediable_type(module)),
        else: query

    media = repo.all(query)
    Mix.shell().info("Found #{length(media)} image(s)\n")

    {done, skipped} =
      media
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {m, i}, {d, s} ->
        process(m, i, length(media), dry_run?) |> tally({d, s})
      end)

    Mix.shell().info(
      "\n#{IO.ANSI.green()}✓ #{done} regenerated, #{skipped} skipped#{IO.ANSI.reset()}"
    )
  end

  # Settings come from the media's own collection (PhxMediaLibrary.Model), the
  # same as on upload.
  defp process(media, i, total, true = _dry_run?) do
    if Keyword.get(Model.webp_settings(media, media.collection_name), :enabled, false) do
      Mix.shell().info("[#{i}/#{total}] would regenerate: #{media.file_name}")
    else
      Mix.shell().info("[#{i}/#{total}] skip (webp off): #{media.file_name}")
    end

    :skip
  end

  defp process(media, i, total, false = _dry_run?) do
    case Pipeline.webp(media) do
      {:ok, _media} ->
        Mix.shell().info(
          "[#{i}/#{total}] #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{media.file_name}"
        )

        :done

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

  defp to_mediable_type(module), do: module.__schema__(:source)

  defp tally(:done, {d, s}), do: {d + 1, s}
  defp tally(_, {d, s}), do: {d, s + 1}
end
