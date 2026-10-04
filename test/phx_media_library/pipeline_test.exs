defmodule PhxMediaLibrary.PipelineTest do
  @moduledoc """
  Repairs must resolve settings exactly like uploads. Each test covers a
  place where a mix task or conversions used to read global settings while
  uploads read the collection's.
  """

  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias Mix.Tasks.PhxMediaLibrary.DropOriginals
  alias PhxMediaLibrary.{Config, Conversion, Conversions, Media, PathGenerator, Pipeline}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    previous = Application.get_env(:phx_media_library, :async_processor)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.AsyncProcessor.Inline
    )

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: Application.put_env(:phx_media_library, :async_processor, previous),
        else: Application.delete_env(:phx_media_library, :async_processor)
    end)

    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  # Put the setting back exactly as it was — including "not set".
  defp restore_env_on_exit(key) do
    previous = Application.fetch_env(:phx_media_library, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, key, value)
        :error -> Application.delete_env(:phx_media_library, key)
      end
    end)
  end

  defp add(png, collection) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    on_exit(fn -> Media.delete_files(Repo.reload!(media)) end)
    Repo.reload!(media)
  end

  describe "webp/2" do
    test "uses the collection's settings without being told the model", %{png: png} do
      # :webp_capped has max_dimension: 100; the global :webp config is off.
      media = add(png, :webp_capped)
      media = %{media | custom_properties: %{}}

      assert {:ok, media} = Pipeline.webp(media)
      assert media.custom_properties["webp_width"] == 100
    end

    test "skips collections without WebP", %{png: png} do
      assert {:skip, :disabled} = png |> add(:images) |> Pipeline.webp()
    end
  end

  describe "drop_original/2" do
    test "mix drop_originals honours the collection's keep_original without --model", %{png: png} do
      media = add(png, :webp_only)
      original = PathGenerator.full_path(media, nil)
      refute File.exists?(original)

      # Bring the original back, as if it predates keep_original: false.
      File.cp!(png, original)

      DropOriginals.run([])
      refute File.exists?(original)
    end

    test "keeps originals of collections that keep them", %{png: png} do
      assert {:skip, :keep_original} = png |> add(:webp_photos) |> Pipeline.drop_original()
    end
  end

  describe "responsive/2" do
    test "uses the collection's widths", %{png: png} do
      # :responsive_plain has widths [160, 320]; the global default is wider.
      media = add(png, :responsive_plain)

      assert {:ok, media} = Pipeline.responsive(%{media | responsive_images: %{}})

      # The full-size image (400) is always listed; 160 comes only from the
      # collection (the global widths start at 320).
      widths = Enum.map(media.responsive_images["original"]["variants"], & &1["width"])
      assert Enum.sort(widths) == [160, 320, 400]
    end

    test "conversions keep getting variants by default, with the global widths", %{png: png} do
      # :images doesn't opt in; the global switch (default on) still applies
      # to conversions — the long-standing default.
      media = add(png, :images)
      assert :ok = Conversions.process(media, [Conversion.new(:big, width: 360)])

      widths =
        Repo.reload!(media).responsive_images["big"]["variants"] |> Enum.map(& &1["width"])

      assert Enum.sort(widths) == [320, 360]
    end

    # A crop: same-shape conversions reuse the original's variants (ADR-024).
    test "conversions use the collection's widths when it sets them", %{png: png} do
      media = add(png, :responsive_plain)
      big = Conversion.new(:big, width: 360, height: 100, fit: :crop)
      assert :ok = Conversions.process(media, [big])

      widths =
        Repo.reload!(media).responsive_images["big"]["variants"] |> Enum.map(& &1["width"])

      assert Enum.sort(widths) == [160, 320, 360]
    end

    test "conversions get no variants when the global switch is off", %{png: png} do
      restore_env_on_exit(:responsive_images)
      Application.put_env(:phx_media_library, :responsive_images, enabled: false)

      media = add(png, :images)
      assert :ok = Conversions.process(media, [Conversion.new(:big, width: 360)])

      refute Map.has_key?(Repo.reload!(media).responsive_images, "big")
    end
  end

  describe "with no responsive config (an app's defaults)" do
    # The library's own config/config.exs turns responsive_images on for its
    # tests; apps start without it. Run these with nothing configured.
    setup do
      restore_env_on_exit(:responsive_images)
      Application.delete_env(:phx_media_library, :responsive_images)
    end

    test "with_responsive_images/1 generates variants", %{png: png} do
      {:ok, media} =
        create_test_post()
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.with_responsive_images()
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      on_exit(fn -> Media.delete_files(Repo.reload!(media)) end)
      assert %{"original" => %{"variants" => [_ | _]}} = media.responsive_images
    end

    test "originals of collections that don't opt in get no variants", %{png: png} do
      media = add(png, :images)
      refute get_in(media.responsive_images, ["original", "variants"])
    end

    test "conversions get variants (the global switch defaults to on)", %{png: png} do
      media = add(png, :images)
      assert :ok = Conversions.process(media, [Conversion.new(:big, width: 360)])
      assert Map.has_key?(Repo.reload!(media).responsive_images, "big")
    end

    test "a global enabled: false blocks with_responsive_images/1", %{png: png} do
      Application.put_env(:phx_media_library, :responsive_images, enabled: false)

      {:ok, media} =
        create_test_post()
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.with_responsive_images()
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      on_exit(fn -> Media.delete_files(Repo.reload!(media)) end)
      refute get_in(media.responsive_images, ["original", "variants"])
    end
  end

  describe "metadata/2" do
    test "fills in metadata lost on upload (the EXIF bug)", %{png: png} do
      media = add(png, :images)
      {:ok, media} = media |> Ecto.Changeset.change(metadata: %{}) |> Repo.update()

      assert {:ok, media} = Pipeline.metadata(media)
      assert media.metadata["width"] == 400
    end

    test "works on storage without a local path", %{png: png} do
      media = create_media(disk: "memory", file_name: "photo.png", mime_type: "image/png")
      storage = Config.storage_adapter(:memory)

      :ok =
        PhxMediaLibrary.StorageWrapper.put(
          storage,
          PathGenerator.relative_path(media, nil),
          File.read!(png)
        )

      assert {:ok, media} = Pipeline.metadata(media)
      assert media.metadata["height"] == 300
    end
  end
end
