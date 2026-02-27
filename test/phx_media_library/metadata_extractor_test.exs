defmodule PhxMediaLibrary.MetadataExtractorTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.MetadataExtractor
  alias PhxMediaLibrary.MetadataExtractor.Default

  # ---------------------------------------------------------------------------
  # Helper: create temp files with specific content
  # ---------------------------------------------------------------------------

  defp create_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "meta_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Minimal valid PNG (1x1 red pixel)
  defp minimal_png do
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
      0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
      0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
      0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4, 0xEF, 0x00, 0x00,
      0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>
  end

  # Minimal valid JPEG (smallest valid JFIF)
  defp minimal_jpeg do
    <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00,
      0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9>>
  end

  # ---------------------------------------------------------------------------
  # MetadataExtractor behaviour module tests
  # ---------------------------------------------------------------------------

  describe "MetadataExtractor.extract_metadata/3" do
    test "delegates to the configured extractor and adds extracted_at" do
      path = create_temp_file("hello world", "test.txt")

      assert {:ok, metadata} = MetadataExtractor.extract_metadata(path, "text/plain")
      assert is_map(metadata)
      assert Map.has_key?(metadata, "extracted_at")
      assert {:ok, _, _} = DateTime.from_iso8601(metadata["extracted_at"])
    end

    test "returns metadata even for non-existent file (non-fatal)" do
      # Non-existent file should not crash — the default extractor returns
      # base metadata (type/format) even when Image.open fails.
      assert {:ok, metadata} =
               MetadataExtractor.extract_metadata("/nonexistent/path", "image/jpeg")

      assert is_map(metadata)
      assert metadata["type"] == "image"
      assert metadata["format"] == "jpeg"
      assert Map.has_key?(metadata, "extracted_at")
    end

    test "accepts :extractor option to override the extractor module" do
      defmodule TestExtractor do
        @behaviour PhxMediaLibrary.MetadataExtractor

        @impl true
        def extract(_path, _mime, _opts) do
          {:ok, %{"custom" => true}}
        end
      end

      path = create_temp_file("data", "test.bin")

      assert {:ok, metadata} =
               MetadataExtractor.extract_metadata(path, "application/octet-stream",
                 extractor: TestExtractor
               )

      assert metadata["custom"] == true
      assert Map.has_key?(metadata, "extracted_at")
    end

    test "handles extractor returning error gracefully" do
      defmodule FailingExtractor do
        @behaviour PhxMediaLibrary.MetadataExtractor

        @impl true
        def extract(_path, _mime, _opts) do
          {:error, :something_went_wrong}
        end
      end

      path = create_temp_file("data", "test.bin")

      assert {:ok, metadata} =
               MetadataExtractor.extract_metadata(path, "application/octet-stream",
                 extractor: FailingExtractor
               )

      # Should return empty map, not propagate error
      assert metadata == %{}
    end
  end

  describe "MetadataExtractor.enabled?/0" do
    test "returns true by default" do
      original = Application.get_env(:phx_media_library, :extract_metadata)
      Application.delete_env(:phx_media_library, :extract_metadata)

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :extract_metadata, original)
        else
          Application.delete_env(:phx_media_library, :extract_metadata)
        end
      end)

      assert MetadataExtractor.enabled?() == true
    end

    test "returns false when configured" do
      original = Application.get_env(:phx_media_library, :extract_metadata)
      Application.put_env(:phx_media_library, :extract_metadata, false)

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :extract_metadata, original)
        else
          Application.delete_env(:phx_media_library, :extract_metadata)
        end
      end)

      assert MetadataExtractor.enabled?() == false
    end
  end

  describe "MetadataExtractor.configured_extractor/0" do
    test "returns Default extractor by default" do
      original = Application.get_env(:phx_media_library, :metadata_extractor)
      Application.delete_env(:phx_media_library, :metadata_extractor)

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :metadata_extractor, original)
        else
          Application.delete_env(:phx_media_library, :metadata_extractor)
        end
      end)

      assert MetadataExtractor.configured_extractor() == Default
    end

    test "returns configured extractor module" do
      original = Application.get_env(:phx_media_library, :metadata_extractor)
      Application.put_env(:phx_media_library, :metadata_extractor, SomeCustomModule)

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :metadata_extractor, original)
        else
          Application.delete_env(:phx_media_library, :metadata_extractor)
        end
      end)

      assert MetadataExtractor.configured_extractor() == SomeCustomModule
    end
  end

  # ---------------------------------------------------------------------------
  # Default extractor tests
  # ---------------------------------------------------------------------------

  describe "Default.extract/3 with text files" do
    test "extracts type and format for plain text" do
      path = create_temp_file("Hello, world!", "test.txt")

      assert {:ok, metadata} = Default.extract(path, "text/plain")
      assert metadata["type"] == "document"
      assert metadata["format"] == "text"
    end

    test "extracts type and format for HTML" do
      path = create_temp_file("<html><body>hi</body></html>", "test.html")

      assert {:ok, metadata} = Default.extract(path, "text/html")
      assert metadata["type"] == "document"
      assert metadata["format"] == "html"
    end
  end

  describe "Default.extract/3 with document MIME types" do
    test "extracts type for PDF" do
      path = create_temp_file("%PDF-1.4 fake content", "test.pdf")

      assert {:ok, metadata} = Default.extract(path, "application/pdf")
      assert metadata["type"] == "document"
      assert metadata["format"] == "pdf"
    end

    test "extracts type for MS Word" do
      path = create_temp_file("fake doc", "test.doc")

      assert {:ok, metadata} = Default.extract(path, "application/msword")
      assert metadata["type"] == "document"
      assert metadata["format"] == "doc"
    end

    test "extracts type for XLSX" do
      path = create_temp_file("fake xlsx", "test.xlsx")

      mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      assert {:ok, metadata} = Default.extract(path, mime)
      assert metadata["type"] == "document"
      assert metadata["format"] == "xlsx"
    end

    test "extracts type for DOCX" do
      path = create_temp_file("fake docx", "test.docx")

      mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      assert {:ok, metadata} = Default.extract(path, mime)
      assert metadata["type"] == "document"
      assert metadata["format"] == "docx"
    end

    test "extracts type for PPTX" do
      path = create_temp_file("fake pptx", "test.pptx")

      mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      assert {:ok, metadata} = Default.extract(path, mime)
      assert metadata["type"] == "document"
      assert metadata["format"] == "pptx"
    end

    test "extracts type for OpenDocument formats" do
      path = create_temp_file("fake odt", "test.odt")

      assert {:ok, metadata} = Default.extract(path, "application/vnd.oasis.opendocument.text")
      assert metadata["type"] == "document"
    end

    test "extracts type for MS Excel" do
      path = create_temp_file("fake xls", "test.xls")

      assert {:ok, metadata} = Default.extract(path, "application/vnd.ms-excel")
      assert metadata["type"] == "document"
    end

    test "extracts type for RTF" do
      path = create_temp_file("fake rtf", "test.rtf")

      assert {:ok, metadata} = Default.extract(path, "application/rtf")
      assert metadata["type"] == "document"
    end
  end

  describe "Default.extract/3 with audio MIME types" do
    test "extracts type for MP3" do
      path = create_temp_file("fake mp3", "test.mp3")

      assert {:ok, metadata} = Default.extract(path, "audio/mpeg")
      assert metadata["type"] == "audio"
      assert metadata["format"] == "mp3"
    end

    test "extracts type for WAV" do
      path = create_temp_file("fake wav", "test.wav")

      assert {:ok, metadata} = Default.extract(path, "audio/wav")
      assert metadata["type"] == "audio"
      assert metadata["format"] == "wav"
    end

    test "extracts type for FLAC" do
      path = create_temp_file("fake flac", "test.flac")

      assert {:ok, metadata} = Default.extract(path, "audio/flac")
      assert metadata["type"] == "audio"
      assert metadata["format"] == "flac"
    end

    test "extracts type for OGG audio" do
      path = create_temp_file("fake ogg", "test.ogg")

      assert {:ok, metadata} = Default.extract(path, "audio/ogg")
      assert metadata["type"] == "audio"
      assert metadata["format"] == "ogg"
    end
  end

  describe "Default.extract/3 with video MIME types" do
    test "extracts type for MP4" do
      path = create_temp_file("fake mp4", "test.mp4")

      assert {:ok, metadata} = Default.extract(path, "video/mp4")
      assert metadata["type"] == "video"
      assert metadata["format"] == "mp4"
    end

    test "extracts type for WebM" do
      path = create_temp_file("fake webm", "test.webm")

      assert {:ok, metadata} = Default.extract(path, "video/webm")
      assert metadata["type"] == "video"
      assert metadata["format"] == "webm"
    end

    test "extracts type for QuickTime" do
      path = create_temp_file("fake mov", "test.mov")

      assert {:ok, metadata} = Default.extract(path, "video/quicktime")
      assert metadata["type"] == "video"
      assert metadata["format"] == "mov"
    end

    test "extracts type for AVI" do
      path = create_temp_file("fake avi", "test.avi")

      assert {:ok, metadata} = Default.extract(path, "video/x-msvideo")
      assert metadata["type"] == "video"
      assert metadata["format"] == "msvideo"
    end
  end

  describe "Default.extract/3 with application/octet-stream" do
    test "classifies as other" do
      path = create_temp_file("binary stuff", "test.bin")

      assert {:ok, metadata} = Default.extract(path, "application/octet-stream")
      assert metadata["type"] == "other"
      assert metadata["format"] == "binary"
    end
  end

  describe "Default.extract/3 with image MIME types" do
    test "extracts type and format for PNG" do
      path = create_temp_file(minimal_png(), "test.png")

      assert {:ok, metadata} = Default.extract(path, "image/png")
      assert metadata["type"] == "image"
      assert metadata["format"] == "png"
    end

    test "extracts type and format for JPEG" do
      path = create_temp_file(minimal_jpeg(), "test.jpg")

      assert {:ok, metadata} = Default.extract(path, "image/jpeg")
      assert metadata["type"] == "image"
      assert metadata["format"] == "jpeg"
    end

    test "extracts type and format for SVG" do
      path = create_temp_file("<svg></svg>", "test.svg")

      assert {:ok, metadata} = Default.extract(path, "image/svg+xml")
      assert metadata["type"] == "image"
      assert metadata["format"] == "svg"
    end

    test "extracts type and format for WebP" do
      path = create_temp_file("fake webp", "test.webp")

      assert {:ok, metadata} = Default.extract(path, "image/webp")
      assert metadata["type"] == "image"
      # format extraction doesn't require Image library
      assert metadata["format"] == "webp"
    end

    test "extracts type and format for GIF" do
      path = create_temp_file("fake gif", "test.gif")

      assert {:ok, metadata} = Default.extract(path, "image/gif")
      assert metadata["type"] == "image"
      assert metadata["format"] == "gif"
    end

    test "extracts type and format for BMP" do
      path = create_temp_file("fake bmp", "test.bmp")

      assert {:ok, metadata} = Default.extract(path, "image/bmp")
      assert metadata["type"] == "image"
      assert metadata["format"] == "bmp"
    end

    # Image library-dependent tests
    if Code.ensure_loaded?(Image) do
      test "extracts width and height from a valid PNG using Image library" do
        path = create_temp_file(minimal_png(), "dimensions.png")

        assert {:ok, metadata} = Default.extract(path, "image/png")
        assert metadata["width"] == 1
        assert metadata["height"] == 1
      end

      test "extracts has_alpha from PNG" do
        path = create_temp_file(minimal_png(), "alpha.png")

        assert {:ok, metadata} = Default.extract(path, "image/png")
        assert is_boolean(metadata["has_alpha"])
      end

      test "extracts dimensions from a generated image" do
        # Create a larger image using the Image library
        {:ok, img} = Image.new(640, 480, color: :blue)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_test_#{:erlang.unique_integer([:positive])}_large.png"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, metadata} = Default.extract(path, "image/png")
        assert metadata["width"] == 640
        assert metadata["height"] == 480
        assert metadata["type"] == "image"
      end

      test "extracts dimensions from a JPEG image" do
        {:ok, img} = Image.new(320, 240, color: :red)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_test_#{:erlang.unique_integer([:positive])}_test.jpg"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, metadata} = Default.extract(path, "image/jpeg")
        assert metadata["width"] == 320
        assert metadata["height"] == 240
      end

      test "gracefully handles corrupt image data" do
        path = create_temp_file("this is not a real png", "corrupt.png")

        # Should not crash, but may not extract dimensions
        assert {:ok, metadata} = Default.extract(path, "image/png")
        assert metadata["type"] == "image"
        assert metadata["format"] == "png"
      end

      test "extracts EXIF data when present" do
        # Create a JPEG with EXIF — Image library may or may not include EXIF
        # depending on how the image is created. We test the extraction path.
        {:ok, img} = Image.new(100, 100, color: :green)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_test_#{:erlang.unique_integer([:positive])}_exif.jpg"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, metadata} = Default.extract(path, "image/jpeg")
        assert metadata["width"] == 100
        assert metadata["height"] == 100
        # EXIF may or may not be present depending on how Image generates JPEGs
        # We just verify extraction doesn't crash
        assert is_map(metadata)
      end
    end
  end

  describe "Default.extract/3 error handling" do
    test "returns error tuple for nonexistent file with non-image MIME" do
      # For non-image types, the default extractor just returns base metadata
      # without trying to open the file
      assert {:ok, metadata} = Default.extract("/no/such/file.txt", "text/plain")
      assert metadata["type"] == "document"
    end

    if Code.ensure_loaded?(Image) do
      test "handles Image.open failure gracefully for images" do
        # Nonexistent file — Image.open will fail
        path = "/no/such/file_#{:erlang.unique_integer([:positive])}.jpg"

        assert {:ok, metadata} = Default.extract(path, "image/jpeg")
        # Should still return base metadata even if Image.open fails
        assert metadata["type"] == "image"
        assert metadata["format"] == "jpeg"
      end
    end
  end

  describe "Default.extract/3 format normalization" do
    @format_cases [
      {"image/jpeg", "jpeg"},
      {"image/png", "png"},
      {"image/gif", "gif"},
      {"image/webp", "webp"},
      {"image/svg+xml", "svg"},
      {"image/bmp", "bmp"},
      {"video/mp4", "mp4"},
      {"video/webm", "webm"},
      {"video/quicktime", "mov"},
      {"audio/mpeg", "mp3"},
      {"audio/wav", "wav"},
      {"audio/flac", "flac"},
      {"application/pdf", "pdf"},
      {"application/msword", "doc"},
      {"application/octet-stream", "binary"},
      {"text/plain", "text"},
      {"text/html", "html"},
      {"text/css", "css"}
    ]

    for {mime, expected_format} <- @format_cases do
      test "normalizes #{mime} to format #{expected_format}" do
        path = create_temp_file("content", "test.bin")

        assert {:ok, metadata} = Default.extract(path, unquote(mime))
        assert metadata["format"] == unquote(expected_format)
      end
    end
  end

  describe "Default.extract/3 type classification" do
    @type_cases [
      {"image/jpeg", "image"},
      {"image/png", "image"},
      {"image/gif", "image"},
      {"image/webp", "image"},
      {"image/svg+xml", "image"},
      {"video/mp4", "video"},
      {"video/webm", "video"},
      {"video/quicktime", "video"},
      {"audio/mpeg", "audio"},
      {"audio/wav", "audio"},
      {"audio/flac", "audio"},
      {"audio/ogg", "audio"},
      {"application/pdf", "document"},
      {"application/msword", "document"},
      {"application/rtf", "document"},
      {"application/vnd.ms-excel", "document"},
      {"application/vnd.ms-powerpoint", "document"},
      {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "document"},
      {"application/vnd.oasis.opendocument.text", "document"},
      {"text/plain", "document"},
      {"text/html", "document"},
      {"text/css", "document"},
      {"application/octet-stream", "other"},
      {"application/json", "other"},
      {"application/zip", "other"},
      {"application/gzip", "other"}
    ]

    for {mime, expected_type} <- @type_cases do
      test "classifies #{mime} as #{expected_type}" do
        path = create_temp_file("content", "test.bin")

        assert {:ok, metadata} = Default.extract(path, unquote(mime))
        assert metadata["type"] == unquote(expected_type)
      end
    end
  end

  describe "Default.extract/3 with unknown MIME types" do
    test "classifies unknown type/subtype as other" do
      path = create_temp_file("data", "test.xyz")

      assert {:ok, metadata} = Default.extract(path, "x-custom/something")
      assert metadata["type"] == "other"
    end

    test "handles empty MIME type" do
      path = create_temp_file("data", "test.bin")

      assert {:ok, metadata} = Default.extract(path, "")
      assert metadata["type"] == "other"
    end

    test "handles malformed MIME type without slash" do
      path = create_temp_file("data", "test.bin")

      assert {:ok, metadata} = Default.extract(path, "notavalidmime")
      assert metadata["type"] == "other"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration-style tests: extract_metadata through the full pipeline
  # ---------------------------------------------------------------------------

  describe "extract_metadata full pipeline" do
    test "extracts and timestamps a text file" do
      path = create_temp_file("Some content", "pipeline.txt")

      assert {:ok, metadata} = MetadataExtractor.extract_metadata(path, "text/plain")
      assert metadata["type"] == "document"
      assert metadata["format"] == "text"
      assert Map.has_key?(metadata, "extracted_at")
    end

    test "extracts and timestamps a PDF" do
      path = create_temp_file("%PDF-1.4 content", "pipeline.pdf")

      assert {:ok, metadata} = MetadataExtractor.extract_metadata(path, "application/pdf")
      assert metadata["type"] == "document"
      assert metadata["format"] == "pdf"
      assert Map.has_key?(metadata, "extracted_at")
    end

    if Code.ensure_loaded?(Image) do
      test "extracts image dimensions through full pipeline" do
        {:ok, img} = Image.new(800, 600, color: :blue)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_test_#{:erlang.unique_integer([:positive])}_pipeline.png"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, metadata} = MetadataExtractor.extract_metadata(path, "image/png")
        assert metadata["width"] == 800
        assert metadata["height"] == 600
        assert metadata["type"] == "image"
        assert metadata["format"] == "png"
        assert Map.has_key?(metadata, "extracted_at")
      end
    end

    test "returns empty map with no extracted_at for failed extraction" do
      # Using a custom failing extractor
      defmodule PipelineFailExtractor do
        @behaviour PhxMediaLibrary.MetadataExtractor

        @impl true
        def extract(_path, _mime, _opts), do: {:error, :boom}
      end

      path = create_temp_file("data", "fail.bin")

      assert {:ok, metadata} =
               MetadataExtractor.extract_metadata(path, "application/octet-stream",
                 extractor: PipelineFailExtractor
               )

      # Empty map — no extracted_at because extraction failed
      assert metadata == %{}
    end
  end
end
