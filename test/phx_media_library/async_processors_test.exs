defmodule PhxMediaLibrary.AsyncProcessorsTest do
  # The Task processor (the default) and the Oban processor, end to end.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{AsyncProcessor, Media, Model}
  alias PhxMediaLibrary.Workers.ProcessConversions

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :async_processor)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :async_processor, value)
        :error -> Application.delete_env(:phx_media_library, :async_processor)
      end

      for media <- TestRepo.all(Media), do: Media.delete_files(media)
    end)

    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp upload(png) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    media
  end

  defp await_done(media, attempts \\ 100) do
    media = TestRepo.reload!(media)

    cond do
      Media.processing_status(media) in [:done, :failed] ->
        media

      attempts == 0 ->
        flunk("still #{Media.processing_status(media)}")

      true ->
        Process.sleep(50)
        await_done(media, attempts - 1)
    end
  end

  describe "Task (the default)" do
    setup do
      Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Task)
    end

    test "an upload returns at once; its conversions are made in the background", %{png: png} do
      media = upload(png)
      assert Media.processing_status(media) in [:queued, :processing, :done]

      done = await_done(media)
      assert Media.processing_status(done) == :done
      assert done.generated_conversions["thumb"]
      assert File.exists?(PhxMediaLibrary.PathGenerator.full_path(done, :thumb))
    end

    test "process_sync/2 runs them in the caller", %{png: png} do
      Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Inline)
      media = upload(png)
      assert :ok = AsyncProcessor.Task.process_sync(media, Model.conversions(media, :images))
    end
  end

  describe "Oban" do
    setup do
      start_supervised!({Oban, repo: TestRepo, testing: :manual})
      Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Oban)
      :ok
    end

    test "an upload inserts one job carrying the conversions' names", %{png: png} do
      media = upload(png)

      assert [job] =
               TestRepo.all(from(j in Oban.Job, where: j.worker == ^inspect(ProcessConversions)))

      assert job.queue == "media"
      assert job.args["media_id"] == media.id
      assert job.args["mediable_type"] == "posts"
      assert Enum.sort(job.args["conversions"]) == ["banner", "preview", "thumb"]

      # The worker then does the work.
      assert :ok = Oban.Testing.perform_job(ProcessConversions, job.args, [])
      assert Media.processing_status(TestRepo.reload!(media)) == :done
    end

    test "process_sync/2 runs the conversions without the queue", %{png: png} do
      Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Inline)
      media = upload(png)
      assert :ok = AsyncProcessor.Oban.process_sync(media, Model.conversions(media, :images))
    end
  end
end
