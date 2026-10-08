defmodule PhxMediaLibrary.NonImageConversionsTest do
  # Spec 02, B4: files that aren't images get no conversions job, and a job
  # for one doesn't fail.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversions, Media, Model, RecordingAsyncProcessor}

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

    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)

    {:ok, media} =
      create_test_post() |> PhxMediaLibrary.add(txt) |> PhxMediaLibrary.to_collection(:documents)

    on_exit(fn -> Media.delete_files(media) end)
    %{media: media}
  end

  test "an upload of a text file to a collection with conversions queues none", %{media: media} do
    assert Model.conversions(media, :documents) != []
    refute_received {:process_async, _id, [_ | _]}
  end

  test "a conversions job for a text file succeeds without doing anything", %{media: media} do
    assert :ok = Conversions.process(media, Model.conversions(media, :documents))
    assert TestRepo.reload!(media).generated_conversions == %{}
  end
end
