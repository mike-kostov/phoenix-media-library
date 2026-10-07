defmodule PhxMediaLibrary.DoctorTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, Doctor, Media, PathGenerator, StorageWrapper}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp add(png, collection \\ :images) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    media = Repo.reload!(media)
    on_exit(fn -> if m = Repo.get(Media, media.id), do: Media.delete_files(m) end)
    media
  end

  defp drop_thumb(media),
    do:
      StorageWrapper.delete(
        Config.storage_adapter(:local),
        PathGenerator.relative_path(media, :thumb)
      )

  test "check/1 reports counts and examples, in batches", %{png: png} do
    media = for _ <- 1..3, do: add(png)
    Enum.each(media, &drop_thumb/1)

    assert {:ok, report} =
             Doctor.check(batch_size: 1, orphans: false, collection: "images", model: "posts")

    assert report.checked >= 3
    assert report.counts[:missing_conversions] >= 3
    assert [%{id: _, file_name: _} | _] = report.examples[:missing_conversions]
    assert report.errors == 0
  end

  test "check/1 with an ID checks one media item", %{png: png} do
    media = add(png)
    drop_thumb(media)

    assert {:ok, %{checked: 1, counts: %{missing_conversions: 1}}} = Doctor.check(id: media.id)
  end

  test "an invalid or unknown ID is an error, not an exception" do
    assert {:error, {:invalid_id, "42"}} = Doctor.check(id: "42")
    unknown = Ecto.UUID.generate()
    assert {:error, {:not_found, ^unknown}} = Doctor.check(id: unknown)
  end

  test "repair/1 runs the requested repairs and reports them", %{png: png} do
    media = add(png)
    drop_thumb(media)

    assert {:ok, %{done: 1, failed: 0}} =
             Doctor.repair(id: media.id, repairs: [:missing_conversions])

    assert StorageWrapper.exists?(
             Config.storage_adapter(:local),
             PathGenerator.relative_path(Repo.reload!(media), :thumb)
           )
  end

  test "repair/1 rebuilds what was asked", %{png: png} do
    media = add(png, :webp_photos)
    webp = media.custom_properties["webp"]
    StorageWrapper.put(Config.storage_adapter(:local), webp, "stale")

    assert {:ok, %{done: 1}} = Doctor.repair(id: media.id, rebuild: [:webp])
    {:ok, content} = StorageWrapper.get(Config.storage_adapter(:local), webp)
    refute content == "stale"
  end

  test "an unknown rebuild target is an error" do
    assert {:error, {:invalid_rebuild, :thumbnails}} = Doctor.repair(rebuild: [:thumbnails])
  end

  test "each run emits telemetry with the counts", %{png: png} do
    media = add(png)
    ref = :telemetry_test.attach_event_handlers(self(), [[:phx_media_library, :doctor, :check]])

    {:ok, _report} = Doctor.check(id: media.id)

    assert_received {[:phx_media_library, :doctor, :check], ^ref, %{checked: 1, errors: 0}, _}
  end

  test "works without Mix: the module never calls it" do
    source = File.read!("lib/phx_media_library/doctor.ex")
    refute source =~ "Mix."
  end

  describe "stats/1" do
    test "counts and sizes per collection and per disk", %{png: png} do
      media = add(png)

      assert {:ok, %{collections: collections, disks: disks}} = Doctor.stats(type: "posts")

      assert %{count: count} =
               Enum.find(
                 collections,
                 &(&1.collection_name == "images" and &1.mediable_type == "posts")
               )

      assert count >= 1
      assert Enum.any?(disks, &(&1.disk == media.disk and &1.count >= 1))
    end
  end

  describe "purge_deleted/1" do
    setup do
      previous = Application.fetch_env(:phx_media_library, :soft_deletes)
      Application.put_env(:phx_media_library, :soft_deletes, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, :soft_deletes, value)
          :error -> Application.delete_env(:phx_media_library, :soft_deletes)
        end
      end)
    end

    test "a dry run reports, a real run purges in batches", %{png: png} do
      old = add(png)
      long_ago = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.truncate(:second)
      Repo.update!(Ecto.Changeset.change(old, deleted_at: long_ago))

      assert {:ok, %{count: count, examples: [_ | _]}} = Doctor.purge_deleted(dry_run: true)
      assert count >= 1
      assert Repo.get(Media, old.id)

      assert {:ok, %{purged: purged}} = Doctor.purge_deleted(batch_size: 1)
      assert purged >= 1
      refute Repo.get(Media, old.id)
    end
  end

  describe "clean/1" do
    test "finds orphaned files and records on a local disk; force deletes them", %{png: png} do
      media = add(png)

      dir =
        Path.join("priv/static/uploads", Path.dirname(PathGenerator.relative_path(media, nil)))

      stray = Path.join(dir, "stray.txt")
      File.write!(stray, "x")
      orphan = create_media(disk: "local")

      assert {:ok, [%{disk: :local, files: {:ok, files}, records: records}]} =
               Doctor.clean(disk: "local")

      assert Path.relative_to(stray, "priv/static/uploads") in files
      assert Enum.any?(records, &(&1.id == orphan.id))
      assert File.exists?(stray)

      assert {:ok, _} = Doctor.clean(disk: "local", force: true)
      refute File.exists?(stray)
      refute Repo.get(Media, orphan.id)
    end

    test "an unknown disk is an error, not a new atom" do
      assert {:error, {:unknown_disk, "nope"}} = Doctor.clean(disk: "nope")
    end
  end
end
