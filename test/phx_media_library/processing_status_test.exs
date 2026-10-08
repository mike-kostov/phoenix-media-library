defmodule PhxMediaLibrary.ProcessingStatusTest do
  # Spec 02, F6: Media.processing_status/1 from three timestamps.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias Ecto.Migration.Runner
  alias Mix.Tasks.PhxMediaLibrary.Gen

  alias PhxMediaLibrary.{
    Conversions,
    Media,
    Model,
    RecordingAsyncProcessor,
    RefusingImageProcessor
  }

  @moduletag :db

  setup do
    for key <- [:async_processor, :image_processor] do
      previous = Application.fetch_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    Application.put_env(:phx_media_library, :async_processor, RecordingAsyncProcessor)
    RecordingAsyncProcessor.record_to(self())

    jpeg = create_temp_image(format: :jpg, width: 400, height: 300)
    on_exit(fn -> File.rm(jpeg) end)
    %{jpeg: jpeg}
  end

  defp add(source, collection) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(source)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    TestRepo.reload!(media)
  end

  test "queued, then done after its job", %{jpeg: jpeg} do
    media = add(jpeg, :images)
    assert Media.processing_status(media) == :queued

    assert :ok = Conversions.process(media, Model.conversions(media, :images))
    media = TestRepo.reload!(media)

    assert Media.processing_status(media) == :done
    assert media.processing_started_at
    assert media.processing_finished_at
  end

  test "processing while the job runs" do
    media = %Media{processing_started_at: ~U[2026-10-08 10:00:00Z]}
    assert Media.processing_status(media) == :processing
  end

  test "failed, with the error; a retry starts it again", %{jpeg: jpeg} do
    media = add(jpeg, :images)
    Application.put_env(:phx_media_library, :image_processor, RefusingImageProcessor)

    assert {:error, _} = Conversions.process(media, Model.conversions(media, :images))
    failed = TestRepo.reload!(media)
    assert Media.processing_status(failed) == :failed
    assert failed.processing_error =~ "refused"

    Application.delete_env(:phx_media_library, :image_processor)
    assert :ok = Conversions.process(failed, Model.conversions(failed, :images))
    retried = TestRepo.reload!(failed)
    assert Media.processing_status(retried) == :done
    assert retried.processing_error == nil
  end

  test "an upload with no background work is done at once" do
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)

    media = add(txt, :documents)
    assert Media.processing_status(media) == :done
    refute_received {:process_async, _, _}
  end

  describe "the upgrade migration" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "marks existing rows done without rewriting the table; new rows start empty" do
      TestRepo.query!("CREATE TABLE media_upgrade_probe (id serial PRIMARY KEY, name text)")
      TestRepo.query!("INSERT INTO media_upgrade_probe (name) VALUES ('from 0.9')")

      file_node = fn ->
        TestRepo.query!("SELECT pg_relation_filenode('media_upgrade_probe')").rows
      end

      before = file_node.()

      source =
        "media_upgrade_probe"
        |> Gen.Migration.processing_status_template()
        |> String.replace("PhxMediaLibrary.Repo.Migrations", "UpgradeProbe")

      [{module, _}] = Code.compile_string(source)

      Runner.run(TestRepo, TestRepo.config(), 1, module, :forward, :up, :up, log: false)

      TestRepo.query!("INSERT INTO media_upgrade_probe (name) VALUES ('from 0.10')")

      %{rows: rows} =
        TestRepo.query!(
          "SELECT name, processing_finished_at IS NOT NULL FROM media_upgrade_probe ORDER BY id"
        )

      assert rows == [["from 0.9", true], ["from 0.10", false]]
      assert file_node.() == before
    end
  end
end
