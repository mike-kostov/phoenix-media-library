defmodule PhxMediaLibrary.WriteCountTest do
  # Spec 02, C4: an upload writes its row once, and its background job once
  # more (docs/ideas/db-performance.md).
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, PathGenerator}

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :async_processor)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.AsyncProcessor.Inline
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :async_processor, value)
        :error -> Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    jpeg = create_temp_image(format: :jpg, width: 1600, height: 1200)
    on_exit(fn -> File.rm(jpeg) end)
    %{jpeg: jpeg}
  end

  defp count_writes(fun) do
    test = self()
    id = "write-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_media_library, :test_repo, :query],
      fn _event, _m, meta, _ ->
        if meta.source == "media" and meta.query =~ ~r/^(INSERT|UPDATE)/,
          do: send(test, {:write, meta.query |> String.split(" ") |> hd()})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, collect([])}
  end

  defp collect(acc) do
    receive do
      {:write, kind} -> collect([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the heaviest upload writes its row twice: on upload and after its job", %{jpeg: jpeg} do
    # WebP + AVIF + responsive + conversions (:thumb, :preview) + placeholders.
    {{:ok, media}, writes} =
      count_writes(fn ->
        create_test_post()
        |> PhxMediaLibrary.add(jpeg)
        |> PhxMediaLibrary.to_collection(:avif_responsive, disk: :local)
      end)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    assert writes == ["INSERT", "UPDATE"]

    # Nothing lost: the record knows every derivative.
    media = TestRepo.get!(Media, media.id)
    assert media.custom_properties["webp"]
    assert media.custom_properties["avif"]
    assert get_in(media.responsive_images, ["original", "variants"])
    assert get_in(media.responsive_images, ["original", "placeholder"])
    assert media.generated_conversions["thumb"] == ["avif", "webp"]
    assert File.exists?(PathGenerator.full_path(media, :thumb))
  end

  test "a refused insert leaves no files behind", %{jpeg: jpeg} do
    post = create_test_post()
    root = Application.get_env(:phx_media_library, :disks)[:local][:root]
    files = fn -> root |> Path.join("**/*.*") |> Path.wildcard() |> MapSet.new() end
    before = files.()

    previous = Application.get_env(:phx_media_library, :repo)
    Application.put_env(:phx_media_library, :repo, PhxMediaLibrary.RefusingRepo)
    on_exit(fn -> Application.put_env(:phx_media_library, :repo, previous) end)

    assert {:error, :refused} =
             post
             |> PhxMediaLibrary.add(jpeg)
             |> PhxMediaLibrary.to_collection(:avif_responsive, disk: :local)

    # Not the original, nor its WebP, AVIF or responsive variants.
    assert MapSet.difference(files.(), before) == MapSet.new()
  end

  test "an upload without derivatives writes once", %{jpeg: _jpeg} do
    txt = create_temp_file("plain notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)

    {{:ok, media}, writes} =
      count_writes(fn ->
        create_test_post()
        |> PhxMediaLibrary.add(txt)
        |> PhxMediaLibrary.to_collection(:documents)
      end)

    on_exit(fn -> Media.delete_files(media) end)
    assert writes == ["INSERT"]
  end
end
