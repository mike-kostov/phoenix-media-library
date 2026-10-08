defmodule PhxMediaLibrary.BackgroundDerivativesTest do
  # Spec 02, F2: a row without the original's WebP, AVIF and variants (as an
  # import leaves it) gets them from its job, in the job's one final update.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversions, Media, Model, RecordingAsyncProcessor, ResponsiveImages}

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :async_processor)
    Application.put_env(:phx_media_library, :async_processor, RecordingAsyncProcessor)
    RecordingAsyncProcessor.record_to(self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :async_processor, value)
        :error -> Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    jpeg = create_temp_image(format: :jpg, width: 400, height: 300)
    on_exit(fn -> File.rm(jpeg) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(:avif_responsive, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    %{media: TestRepo.reload!(media)}
  end

  defp count_updates(fun) do
    test = self()
    id = "bg-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_media_library, :test_repo, :query],
      fn _, _, meta, _ ->
        if meta.source == "media" and meta.query =~ ~r/^UPDATE/, do: send(test, :update)
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)

    {result,
     Stream.repeatedly(fn -> receive do: (:update -> 1), after: (0 -> nil) end)
     |> Enum.take_while(& &1)
     |> length()}
  end

  test "the job makes the original's missing WebP, AVIF and variants", %{media: media} do
    # Strip what the upload made, as an imported row starts.
    for path <-
          Media.owned_paths(media) -- [PhxMediaLibrary.PathGenerator.relative_path(media, nil)],
        do: File.rm(Path.join("priv/static/uploads", path))

    bare =
      TestRepo.update!(
        Ecto.Changeset.change(media,
          custom_properties: %{},
          responsive_images: %{},
          generated_conversions: %{}
        )
      )

    {result, updates} =
      count_updates(fn ->
        Conversions.process(bare, Model.conversions(bare, :avif_responsive))
      end)

    assert result == :ok
    assert updates == 2

    made = TestRepo.reload!(bare)
    assert is_binary(made.custom_properties["webp"])
    assert is_binary(made.custom_properties["avif"])
    assert ResponsiveImages.formats(made, nil) == ["avif", "webp"]
    assert made.generated_conversions["thumb"] == ["avif", "webp"]
    assert Media.processing_status(made) == :done
    assert Enum.all?(Media.owned_paths(made), &File.exists?(Path.join("priv/static/uploads", &1)))
  end

  test "an uploaded row's job leaves the upload's derivatives alone", %{media: media} do
    webp = media.custom_properties["webp"]
    %{mtime: before} = File.stat!(Path.join("priv/static/uploads", webp))
    Process.sleep(1_100)

    :ok = Conversions.process(media, Model.conversions(media, :avif_responsive))
    assert File.stat!(Path.join("priv/static/uploads", webp)).mtime == before
  end
end
