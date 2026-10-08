defmodule PhxMediaLibrary.FormatsTest do
  # Spec 02, F1: the ordered `formats:` list and how it resolves.
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.{Collection, Config, Conversion, Model}

  doctest Config, only: [normalize_formats: 1, normalize_formats!: 1]

  defmodule Album do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    schema "albums" do
      has_media()
    end

    media_collections do
      collection(:plain)
      collection(:listed, formats: [avif: [quality: 50], webp: [quality: 80]])
      collection(:avif_on, avif: true)
      collection(:avif_quality, avif: [quality: 40])
      collection(:avif_off, avif: false)
      collection(:avif_and_listed, avif: true, formats: [:jpg])
      collection(:listed_webp_off, formats: [:avif, :webp], webp: false)
    end
  end

  setup do
    previous =
      for key <- [:formats, :avif, :webp],
          do: {key, Application.fetch_env(:phx_media_library, key)}

    Enum.each(previous, fn {key, _} -> Application.delete_env(:phx_media_library, key) end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end
    end)
  end

  defp formats(collection, conversion \\ nil, mime \\ "image/jpeg"),
    do: Model.formats(Album, collection, mime, conversion)

  describe "resolution" do
    test "defaults to WebP" do
      assert formats(:plain) == [webp: []]
    end

    test "a collection's list, with options, in order" do
      assert formats(:listed) == [avif: [quality: 50], webp: [quality: 80]]
    end

    test "a conversion's list wins over the collection's" do
      thumb = Conversion.new(:thumb, width: 100, formats: [:png, :webp])
      assert formats(:listed, thumb) == [png: [], webp: []]
    end

    test "a conversion's format: x is formats: [x]" do
      og = Conversion.new(:og, width: 1200, format: :jpeg)
      assert og.formats == [jpg: []]
      assert formats(:listed, og) == [jpg: []]
    end

    test "a conversion without formats inherits" do
      assert formats(:listed, Conversion.new(:thumb, width: 100)) ==
               [avif: [quality: 50], webp: [quality: 80]]
    end

    test "the global list, under the collection's" do
      Application.put_env(:phx_media_library, :formats, [:avif, :original])
      assert formats(:plain) == [avif: [], original: []]
      assert formats(:listed) == [avif: [quality: 50], webp: [quality: 80]]
    end

    test "avif: true is [:avif, :webp], with its quality" do
      assert formats(:avif_on) == [avif: [], webp: []]
      assert formats(:avif_quality) == [avif: [quality: 40], webp: []]

      Application.put_env(:phx_media_library, :avif, quality: 45)
      assert formats(:plain) == [avif: [quality: 45], webp: []]
    end

    test "a level's formats: wins over its avif:" do
      assert formats(:avif_and_listed) == [jpg: []]

      Application.put_env(:phx_media_library, :avif, true)
      Application.put_env(:phx_media_library, :formats, [:png])
      assert formats(:plain) == [png: []]
    end

    test "a collection's avif: false drops AVIF from the global list" do
      Application.put_env(:phx_media_library, :formats, [:avif, :webp])
      assert formats(:avif_off) == [webp: []]

      Application.put_env(:phx_media_library, :formats, [:avif])
      assert formats(:avif_off) == [webp: []]
    end

    test "files libvips can't convert keep their format, unless a conversion lists one" do
      assert formats(:listed, nil, "image/svg+xml") == [original: []]
      assert formats(:listed, nil, "application/pdf") == [original: []]

      cover = Conversion.new(:cover, width: 300, formats: [:jpg])
      assert formats(:listed, cover, "application/pdf") == [jpg: []]
    end

    test "WebP uploads take the list" do
      assert formats(:listed, nil, "image/webp") == [avif: [quality: 50], webp: [quality: 80]]
    end
  end

  # Mike, 2026-10-08: listing a format turns on the original's copy in it.
  describe "the original's copies" do
    defp copies(collection) do
      {Model.webp_settings(Album, collection)[:enabled],
       Model.avif_settings(Album, collection)[:enabled]}
    end

    test "are off by default, whatever the default [:webp] says" do
      assert copies(:plain) == {false, false}
    end

    test "an explicit formats: list turns on each listed format's copy" do
      assert copies(:listed) == {true, true}
      assert copies(:avif_and_listed) == {false, true}
    end

    test "webp: false at the same level wins" do
      assert copies(:listed_webp_off) == {false, true}
    end

    test "a global list turns them on; an explicit off wins" do
      Application.put_env(:phx_media_library, :formats, [:webp])
      assert copies(:plain) == {true, false}
      assert copies(:avif_off) == {true, false}

      Application.put_env(:phx_media_library, :webp, false)
      assert copies(:plain) == {false, false}
    end
  end

  describe "invalid formats are a configuration error" do
    test "on a collection" do
      assert_raise ArgumentError,
                   ~r/collection :bad: formats: \[:gif\]: unknown format :gif/,
                   fn ->
                     Collection.new(:bad, formats: [:gif])
                   end
    end

    test "on a conversion" do
      assert_raise ArgumentError, ~r/conversion :thumb: .*quality of :webp must be 1..100/, fn ->
        Conversion.new(:thumb, formats: [webp: [quality: 0]])
      end

      assert_raise ArgumentError, ~r/not both/, fn ->
        Conversion.new(:thumb, format: :jpg, formats: [:webp])
      end
    end

    test "globally" do
      Application.put_env(:phx_media_library, :formats, [:webp, :webp])
      assert_raise ArgumentError, ~r/listed twice/, fn -> formats(:plain) end
    end

    test "empty lists and unknown options" do
      assert {:error, _} = Config.normalize_formats([])
      assert {:error, message} = Config.normalize_formats(avif: [speed: 4])
      assert message =~ "[:speed]"
    end
  end
end
