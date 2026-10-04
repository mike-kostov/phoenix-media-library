defmodule Mix.Tasks.PhxMediaLibrary.DoctorTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias Mix.Tasks.PhxMediaLibrary.Doctor
  alias PhxMediaLibrary.{Config, Health, Media, PathGenerator, Pipeline, StorageWrapper}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    restore_env_on_exit(:async_processor)
    restore_env_on_exit(:file_naming)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.AsyncProcessor.Inline
    )

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp restore_env_on_exit(key) do
    previous = Application.fetch_env(:phx_media_library, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, key, value)
        :error -> Application.delete_env(:phx_media_library, key)
      end
    end)
  end

  defp add(png, collection, filename \\ "Summer Dress.png") do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.using_filename(filename)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    media = Repo.reload!(media)
    on_exit(fn -> if m = Repo.get(Media, media.id), do: Media.delete_files(m) end)
    media
  end

  # The doctor also checks orphans; parents here are plain structs.
  defp doctor(args), do: Doctor.run(args ++ ["--skip-orphans"])

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  defp exists?(media, path), do: StorageWrapper.exists?(Config.storage_adapter(media.disk), path)

  test "reports without changing anything", %{png: png} do
    media = add(png, :images)
    {:ok, media} = media |> Ecto.Changeset.change(metadata: %{}) |> Repo.update()

    doctor([])

    assert output() =~ "Missing metadata: 1"
    assert Repo.reload!(media).metadata == %{}
  end

  test "--reextract repairs metadata lost to the EXIF bug", %{png: png} do
    media = add(png, :images)
    {:ok, _} = media |> Ecto.Changeset.change(metadata: %{}) |> Repo.update()

    doctor(["--reextract", "--yes"])

    assert Repo.reload!(media).metadata["width"] == 400
  end

  test "--regenerate creates missing conversions", %{png: png} do
    media = add(png, :images)
    thumb = PathGenerator.relative_path(media, :thumb)
    StorageWrapper.delete(Config.storage_adapter(:local), thumb)
    assert {:missing_conversions, ["thumb"]} in Health.check(media)

    doctor(["--regenerate", "--yes"])

    assert exists?(media, thumb)
    refute Enum.any?(Health.check(Repo.reload!(media)), &match?({:missing_conversions, _}, &1))
  end

  test "--rename moves every file of pre-0.9 media and keeps it working", %{png: png} do
    # Store under :slug, then switch the app to :semantic, as an upgrade would.
    Application.put_env(:phx_media_library, :file_naming, :slug)
    media = add(png, :responsive_webp)
    old_paths = Media.owned_paths(media)
    assert media.file_name == "summer-dress.png"
    assert length(old_paths) > 3

    Application.put_env(:phx_media_library, :file_naming, :semantic)
    assert :needs_rename in Health.check(media)

    doctor(["--rename", "--yes"])

    renamed = Repo.reload!(media)
    # "_" separates the parts, so the collection's own "_" becomes "-".
    assert renamed.file_name == "posts_#{media.mediable_id}_responsive-webp_#{media.uuid}.png"
    assert renamed.custom_properties["webp"] =~ "posts_"

    new_paths = Media.owned_paths(renamed)
    assert Enum.all?(new_paths, &exists?(renamed, &1))
    assert Enum.all?(old_paths -- new_paths, &(not exists?(renamed, &1)))
    assert Health.check(renamed) == []
  end

  test "renaming media from before file naming records its original name" do
    media = create_media(disk: "memory", file_name: "Summer Photo.JPG", mime_type: "image/jpeg")
    storage = Config.storage_adapter(:memory)
    :ok = StorageWrapper.put(storage, PathGenerator.relative_path(media, nil), "jpeg")

    assert {:ok, renamed} = Pipeline.rename(media)
    assert renamed.metadata["original_file_name"] == "Summer Photo.JPG"
    assert Media.alt_text(renamed) == "Summer Photo"
    assert StorageWrapper.exists?(storage, PathGenerator.relative_path(renamed, nil))
    refute StorageWrapper.exists?(storage, PathGenerator.relative_path(media, nil))
    assert {:skip, :already_named} = Pipeline.rename(renamed)

    Media.delete_files(renamed)
  end

  test "--dry-run shows the plan and changes nothing", %{png: png} do
    Application.put_env(:phx_media_library, :file_naming, :slug)
    media = add(png, :images)
    Application.put_env(:phx_media_library, :file_naming, :semantic)

    doctor(["--rename", "--dry-run"])

    assert output() =~ "Repair: Not named by file_naming: 1"
    assert Repo.reload!(media).file_name == media.file_name
  end

  test "answering no to the prompt changes nothing", %{png: png} do
    media = add(png, :images)
    {:ok, _} = media |> Ecto.Changeset.change(metadata: %{}) |> Repo.update()

    send(self(), {:mix_shell_input, :yes?, false})
    doctor(["--reextract"])

    assert Repo.reload!(media).metadata == %{}
  end

  test "--rebuild --only webp regenerates WebP that is present", %{png: png} do
    media = add(png, :webp_photos)
    webp = media.custom_properties["webp"]
    StorageWrapper.put(Config.storage_adapter(:local), webp, "stale")

    doctor(["--rebuild", "--only", "webp", "--yes"])

    {:ok, content} = StorageWrapper.get(Config.storage_adapter(:local), webp)
    refute content == "stale"
  end

  test "--regenerate creates a missing AVIF", %{png: png} do
    media = add(png, :avif_photos)
    avif = media.custom_properties["avif"]
    StorageWrapper.delete(Config.storage_adapter(:local), avif)
    assert :missing_avif in Health.check(media)

    doctor(["--regenerate", "--yes"])

    assert exists?(media, avif)
    refute :missing_avif in Health.check(Repo.reload!(media))
  end

  test "--rebuild --only avif regenerates AVIF that is present", %{png: png} do
    media = add(png, :avif_photos)
    avif = media.custom_properties["avif"]
    StorageWrapper.put(Config.storage_adapter(:local), avif, "stale")

    doctor(["--rebuild", "--only", "avif", "--yes"])

    {:ok, content} = StorageWrapper.get(Config.storage_adapter(:local), avif)
    refute content == "stale"
  end

  test "--rename moves the AVIF", %{png: png} do
    Application.put_env(:phx_media_library, :file_naming, :slug)
    media = add(png, :avif_photos)
    old_avif = media.custom_properties["avif"]
    Application.put_env(:phx_media_library, :file_naming, :semantic)

    doctor(["--rename", "--yes"])

    renamed = Repo.reload!(media)
    assert renamed.custom_properties["avif"] =~ ~r/posts_.*\.avif$/
    assert exists?(renamed, renamed.custom_properties["avif"])
    refute exists?(renamed, old_avif)
    assert Health.check(renamed) == []
  end

  test "--regenerate makes the placeholder of media uploaded before them", %{png: png} do
    media = add(png, :images)
    responsive = Map.update!(media.responsive_images, "original", &Map.delete(&1, "placeholder"))
    {:ok, media} = media |> Ecto.Changeset.change(responsive_images: responsive) |> Repo.update()
    assert :missing_placeholder in Health.check(media)

    doctor(["--regenerate", "--yes"])

    repaired = Repo.reload!(media)
    assert %{"data_uri" => _} = repaired.responsive_images["original"]["placeholder"]
    refute :missing_placeholder in Health.check(repaired)
  end

  test "--id checks and repairs only that media", %{png: png} do
    target = add(png, :images)
    other = add(png, :images)

    for media <- [target, other],
        do:
          StorageWrapper.delete(
            Config.storage_adapter(:local),
            PathGenerator.relative_path(media, :thumb)
          )

    doctor(["--id", target.id, "--regenerate", "--yes"])

    assert output() =~ "Checking 1 media item(s)"
    assert exists?(target, PathGenerator.relative_path(target, :thumb))
    refute exists?(other, PathGenerator.relative_path(other, :thumb))
  end

  test "--id with an unknown or invalid ID says so" do
    unknown = Ecto.UUID.generate()

    assert_raise Mix.Error, ~r/No media with ID #{unknown}/, fn -> doctor(["--id", unknown]) end
    assert_raise Mix.Error, ~r/--id must be a media UUID/, fn -> doctor(["--id", "42"]) end
  end

  test "--strict exits with status 1 when errors are found" do
    create_media(disk: "local")
    assert catch_exit(doctor(["--strict"])) == {:shutdown, 1}
  end
end
