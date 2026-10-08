defmodule PhxMediaLibrary.PdfThumbnailsTest do
  # Spec 02, F7: a PDF's first page becomes its image.
  use PhxMediaLibrary.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{
    AsyncProcessor,
    Components,
    Conversion,
    Conversions,
    Doctor,
    DocumentRenderer,
    Media,
    PathGenerator
  }

  @moduletag :db

  setup do
    for key <- [:async_processor, :document_renderer] do
      previous = Application.fetch_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Inline)
    pdf = create_temp_pdf()
    on_exit(fn -> File.rm(pdf) end)
    %{pdf: pdf}
  end

  defp add(pdf) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(pdf)
      |> PhxMediaLibrary.to_collection(:documents, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    TestRepo.reload!(media)
  end

  describe "with pdftoppm" do
    @describetag :pdftoppm

    setup do
      Application.put_env(:phx_media_library, :document_renderer, DocumentRenderer.Pdftoppm)
    end

    test "a PDF gets its conversions and a placeholder; the PDF stays the download", %{pdf: pdf} do
      media = add(pdf)

      assert media.mime_type == "application/pdf"
      assert PhxMediaLibrary.url(media) =~ ~r/\.pdf$/
      assert media.generated_conversions["thumb"] == "webp"
      assert PhxMediaLibrary.url(media, :thumb) =~ ~r/_thumb\.webp$/

      {:ok, thumb} = Image.open(PathGenerator.full_path(media, :thumb))
      assert {Image.width(thumb), Image.height(thumb)} == {150, 150}
      {:ok, preview} = Image.open(PathGenerator.full_path(media, :preview))
      assert {Image.width(preview), Image.height(preview)} == {800, 534}

      assert get_in(media.responsive_images, ["original", "placeholder", "data_uri"])
      refute get_in(media.responsive_images, ["original", "widths"])
    end

    test "format: :original gives the page's format, PNG", %{pdf: pdf} do
      media = add(pdf)

      :ok =
        Conversions.process_single(media, Conversion.new(:page, width: 100, format: :original))

      media = TestRepo.reload!(media)
      assert media.generated_conversions["page"] == "png"
      assert <<0x89, "PNG", _::binary>> = File.read!(PathGenerator.full_path(media, :page))
    end

    test "the doctor finds and remakes a missing thumbnail", %{pdf: pdf} do
      media = add(pdf)
      File.rm!(PathGenerator.full_path(media, :thumb))

      assert {:ok, %{counts: %{missing_conversions: 1}}} = Doctor.check(id: media.id)
      assert {:ok, %{done: 1}} = Doctor.repair(id: media.id, repairs: [:missing_conversions])
      assert File.exists?(PathGenerator.full_path(media, :thumb))
    end

    test "the gallery shows the thumbnail", %{pdf: pdf} do
      media = add(pdf)

      html =
        render_component(&Components.media_gallery/1,
          id: "g",
          media: [{"m", media}],
          conversion: :thumb
        )

      assert html =~ ~r/<img[^>]+_thumb\.webp/
    end
  end

  describe "without a renderer" do
    setup do
      Application.put_env(:phx_media_library, :document_renderer, DocumentRenderer.Null)
      :persistent_term.erase({DocumentRenderer, :unavailable_logged})
      :ok
    end

    test "the upload succeeds, without conversions, and it is logged once", %{pdf: pdf} do
      log =
        capture_log(fn ->
          media = add(pdf)
          assert media.generated_conversions == %{}
          add(pdf)
        end)

      assert length(String.split(log, "PDFs are stored without thumbnails")) == 2
    end
  end
end
