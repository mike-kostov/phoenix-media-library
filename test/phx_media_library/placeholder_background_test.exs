defmodule PhxMediaLibrary.PlaceholderBackgroundTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, TestNote}
  alias PhxMediaLibrary.Workers.ProcessConversions

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :async_processor)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :async_processor, value)
        :error -> Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    photo = create_photo_with_profile()
    on_exit(fn -> File.rm(photo) end)
    %{photo: photo}
  end

  defp add(photo) do
    {:ok, media} =
      %TestNote{id: Ecto.UUID.generate()}
      |> PhxMediaLibrary.add(photo)
      |> PhxMediaLibrary.to_collection(:photos, disk: :local)

    on_exit(fn -> Media.delete_files(media) end)
    TestRepo.get!(Media, media.id)
  end

  defp placeholder(media), do: get_in(media.responsive_images || %{}, ["original", "placeholder"])

  test "an upload without conversions leaves the placeholder to the background", %{photo: photo} do
    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.RecordingAsyncProcessor
    )

    PhxMediaLibrary.RecordingAsyncProcessor.record_to(self())

    media = add(photo)

    assert_received {:process_async, id, []} when id == media.id
    assert placeholder(media) == nil
  end

  test "with the Inline processor, the upload ends with a placeholder", %{photo: photo} do
    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.AsyncProcessor.Inline
    )

    assert %{"data_uri" => _} = placeholder(add(photo))
  end

  test "the Oban worker makes the placeholder for a job without conversions", %{photo: photo} do
    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.RecordingAsyncProcessor
    )

    PhxMediaLibrary.RecordingAsyncProcessor.record_to(self())
    media = TestRepo.update!(Ecto.Changeset.change(add(photo), responsive_images: %{}))

    assert :ok ==
             Oban.Testing.perform_job(
               ProcessConversions,
               %{"media_id" => media.id, "conversions" => [], "mediable_type" => "notes"},
               []
             )

    assert %{"data_uri" => _} = placeholder(TestRepo.get!(Media, media.id))
  end
end
