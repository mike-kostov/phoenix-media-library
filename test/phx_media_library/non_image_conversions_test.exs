defmodule PhxMediaLibrary.NonImageConversionsTest do
  # Spec 02, B4: files that aren't images get no conversions job, and a job
  # for one doesn't fail.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversions, Doctor, Media, Model, RecordingAsyncProcessor}

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

  # Spec 02, B5.
  describe "without an image library" do
    setup do
      previous = Application.fetch_env(:phx_media_library, :image_processor)

      Application.put_env(
        :phx_media_library,
        :image_processor,
        PhxMediaLibrary.ImageProcessor.Null
      )

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, :image_processor, value)
          :error -> Application.delete_env(:phx_media_library, :image_processor)
        end
      end)

      png = create_temp_image(format: :png, width: 40, height: 30)
      on_exit(fn -> File.rm(png) end)
      %{png: png}
    end

    test "an image upload says once that image features need :image", %{png: png} do
      :persistent_term.erase({PhxMediaLibrary.ImageProcessor, :unavailable_logged})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2 do
            {:ok, image} =
              create_test_post()
              |> PhxMediaLibrary.add(png)
              |> PhxMediaLibrary.to_collection(:images)

            Media.delete_files(image)
          end
        end)

      assert length(String.split(log, "images are stored as uploaded")) == 2
      assert log =~ ":image"
    end

    test "the doctor's report says it too", %{png: png} do
      {:ok, image} =
        create_test_post() |> PhxMediaLibrary.add(png) |> PhxMediaLibrary.to_collection(:images)

      on_exit(fn -> Media.delete_files(image) end)

      test = self()
      io = %{info: &send(test, {:line, &1}), yes?: fn _ -> false end}
      Doctor.CLI.run(["--id", image.id], io)

      lines =
        Stream.repeatedly(fn -> receive do: ({:line, l} -> l), after: (0 -> nil) end)
        |> Enum.take_while(& &1)

      assert Enum.any?(lines, &(&1 =~ "No image library"))
    end

    # Spec 02, B12: dimensions can't be read without an image library.
    test "the doctor doesn't report images without dimensions as missing metadata", %{png: png} do
      {:ok, image} =
        create_test_post() |> PhxMediaLibrary.add(png) |> PhxMediaLibrary.to_collection(:images)

      on_exit(fn -> Media.delete_files(image) end)

      # As an app without :image stores it: no dimensions.
      image =
        TestRepo.update!(
          Ecto.Changeset.change(image, metadata: %{"type" => "image", "format" => "png"})
        )

      refute :missing_metadata in PhxMediaLibrary.Health.check(image)
    end

    test "an image upload queues no conversions, and a job does nothing", %{png: png} do
      {:ok, image} =
        create_test_post() |> PhxMediaLibrary.add(png) |> PhxMediaLibrary.to_collection(:images)

      on_exit(fn -> Media.delete_files(image) end)

      refute_received {:process_async, _id, [_ | _]}
      assert Media.processing_status(TestRepo.reload!(image)) == :done
      assert :ok = Conversions.process(image, Model.conversions(image, :images))
    end
  end

  test "a conversions job for a text file succeeds without doing anything", %{media: media} do
    assert :ok = Conversions.process(media, Model.conversions(media, :documents))
    assert TestRepo.reload!(media).generated_conversions == %{}
  end
end
