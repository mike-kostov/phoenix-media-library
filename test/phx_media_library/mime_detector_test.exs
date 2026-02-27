defmodule PhxMediaLibrary.MimeDetectorTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.MimeDetector
  alias PhxMediaLibrary.MimeDetector.Default

  # ---------------------------------------------------------------------------
  # Helper: build minimal binary content with known magic bytes
  # ---------------------------------------------------------------------------

  defp jpeg_content, do: <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF">>
  defp png_content, do: <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
  defp gif87a_content, do: <<"GIF87a", 0x01, 0x00, 0x01, 0x00>>
  defp gif89a_content, do: <<"GIF89a", 0x01, 0x00, 0x01, 0x00>>
  defp webp_content, do: <<"RIFF", 0x00, 0x00, 0x00, 0x00, "WEBP", "VP8 ">>
  defp bmp_content, do: <<"BM", 0x36, 0x00, 0x00, 0x00>>
  defp tiff_le_content, do: <<0x49, 0x49, 0x2A, 0x00, 0x08, 0x00>>
  defp tiff_be_content, do: <<0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x08>>
  defp ico_content, do: <<0x00, 0x00, 0x01, 0x00, 0x01, 0x00>>

  defp svg_xml_content,
    do: ~s(<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="100"></svg>)

  defp svg_bare_content, do: ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)
  defp pdf_content, do: <<"%PDF-1.7", 0x0A>>
  defp rtf_content, do: <<"{\\rtf1\\ansi">>
  defp ms_office_content, do: <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0x00>>
  defp mp3_id3_content, do: <<"ID3", 0x04, 0x00, 0x00>>
  defp mp3_sync_fb_content, do: <<0xFF, 0xFB, 0x90, 0x00>>
  defp mp3_sync_f3_content, do: <<0xFF, 0xF3, 0x90, 0x00>>
  defp mp3_sync_f2_content, do: <<0xFF, 0xF2, 0x90, 0x00>>
  defp ogg_content, do: <<"OggS", 0x00, 0x02>>
  defp flac_content, do: <<"fLaC", 0x00, 0x00>>
  defp wav_content, do: <<"RIFF", 0x00, 0x00, 0x00, 0x00, "WAVE", "fmt ">>
  defp aiff_content, do: <<"FORM", 0x00, 0x00, 0x00, 0x00, "AIFF", "COMM">>
  defp aac_f1_content, do: <<0xFF, 0xF1, 0x50, 0x00>>
  defp aac_f9_content, do: <<0xFF, 0xF9, 0x50, 0x00>>
  defp midi_content, do: <<"MThd", 0x00, 0x00, 0x00, 0x06>>
  defp avi_content, do: <<"RIFF", 0x00, 0x00, 0x00, 0x00, "AVI ", "LIST">>
  defp mkv_content, do: <<0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42>>
  defp flv_content, do: <<"FLV", 0x01, 0x05>>
  defp zip_content, do: <<0x50, 0x4B, 0x03, 0x04, 0x14, 0x00>>
  defp zip_empty_content, do: <<0x50, 0x4B, 0x05, 0x06, 0x00, 0x00>>
  defp gzip_content, do: <<0x1F, 0x8B, 0x08, 0x00>>
  defp bzip2_content, do: <<"BZh9", 0x31, 0x41>>
  defp sevenz_content, do: <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00>>
  defp rar_content, do: <<"Rar!", 0x1A, 0x07, 0x01>>
  defp xz_content, do: <<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00>>
  defp zstd_content, do: <<0x28, 0xB5, 0x2F, 0xFD, 0x00>>
  defp wasm_content, do: <<0x00, "asm", 0x01, 0x00, 0x00, 0x00>>
  defp sqlite_content, do: <<"SQLite format 3", 0x00, 0x01, 0x00>>
  defp elf_content, do: <<0x7F, "ELF", 0x02, 0x01>>
  defp macho_32le_content, do: <<0xCE, 0xFA, 0xED, 0xFE, 0x0C, 0x00>>
  defp macho_32be_content, do: <<0xFE, 0xED, 0xFA, 0xCE, 0x00, 0x00>>
  defp macho_64le_content, do: <<0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00>>
  defp macho_64be_content, do: <<0xFE, 0xED, 0xFA, 0xCF, 0x00, 0x00>>
  defp pe_content, do: <<"MZ", 0x90, 0x00, 0x03, 0x00>>
  defp xml_non_svg_content, do: ~s(<?xml version="1.0"?>\n<root><child/></root>)

  # ftyp-based formats
  defp ftyp_content(brand),
    do: <<0x00, 0x00, 0x00, 0x1C, "ftyp", brand::binary-size(4), 0x00, 0x00>>

  defp avif_content, do: ftyp_content("avif")
  defp avis_content, do: ftyp_content("avis")
  defp heic_content, do: ftyp_content("heic")
  defp heix_content, do: ftyp_content("heix")
  defp heif_content, do: ftyp_content("heif")
  defp mif1_content, do: ftyp_content("mif1")
  defp mp4_isom_content, do: ftyp_content("isom")
  defp mp4_iso2_content, do: ftyp_content("iso2")
  defp mp4_mp41_content, do: ftyp_content("mp41")
  defp mp4_mp42_content, do: ftyp_content("mp42")
  defp m4v_content, do: ftyp_content("M4V ")
  defp m4a_content, do: ftyp_content("M4A ")
  defp m4p_content, do: ftyp_content("M4P ")
  defp qt_content, do: ftyp_content("qt  ")
  defp three_gpp_content, do: ftyp_content("3gp5")
  defp three_gpp2_content, do: ftyp_content("3g2a")
  defp dash_content, do: ftyp_content("dash")
  defp unknown_ftyp_content, do: ftyp_content("zzzz")

  # TAR needs content >= 262 bytes with "ustar" at offset 257
  defp tar_content do
    padding = :binary.copy(<<0x00>>, 257)
    <<padding::binary, "ustar", 0x00, 0x30, 0x30>>
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Image formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — images" do
    test "detects JPEG" do
      assert {:ok, "image/jpeg"} = Default.detect(jpeg_content(), "photo.jpg")
    end

    test "detects PNG" do
      assert {:ok, "image/png"} = Default.detect(png_content(), "image.png")
    end

    test "detects GIF87a" do
      assert {:ok, "image/gif"} = Default.detect(gif87a_content(), "anim.gif")
    end

    test "detects GIF89a" do
      assert {:ok, "image/gif"} = Default.detect(gif89a_content(), "anim.gif")
    end

    test "detects WebP" do
      assert {:ok, "image/webp"} = Default.detect(webp_content(), "photo.webp")
    end

    test "detects BMP" do
      assert {:ok, "image/bmp"} = Default.detect(bmp_content(), "image.bmp")
    end

    test "detects TIFF little-endian" do
      assert {:ok, "image/tiff"} = Default.detect(tiff_le_content(), "photo.tiff")
    end

    test "detects TIFF big-endian" do
      assert {:ok, "image/tiff"} = Default.detect(tiff_be_content(), "photo.tiff")
    end

    test "detects ICO" do
      assert {:ok, "image/x-icon"} = Default.detect(ico_content(), "favicon.ico")
    end

    test "detects SVG via XML prologue" do
      assert {:ok, "image/svg+xml"} = Default.detect(svg_xml_content(), "icon.svg")
    end

    test "detects SVG via bare <svg tag" do
      assert {:ok, "image/svg+xml"} = Default.detect(svg_bare_content(), "icon.svg")
    end

    test "detects XML that is not SVG" do
      assert {:ok, "application/xml"} = Default.detect(xml_non_svg_content(), "data.xml")
    end

    test "detects AVIF" do
      assert {:ok, "image/avif"} = Default.detect(avif_content(), "photo.avif")
    end

    test "detects AVIF sequence" do
      assert {:ok, "image/avif"} = Default.detect(avis_content(), "seq.avif")
    end

    test "detects HEIC" do
      assert {:ok, "image/heic"} = Default.detect(heic_content(), "photo.heic")
    end

    test "detects HEIC (heix brand)" do
      assert {:ok, "image/heic"} = Default.detect(heix_content(), "photo.heic")
    end

    test "detects HEIF" do
      assert {:ok, "image/heif"} = Default.detect(heif_content(), "photo.heif")
    end

    test "detects HEIF (mif1 brand)" do
      assert {:ok, "image/heif"} = Default.detect(mif1_content(), "photo.heif")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Document formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — documents" do
    test "detects PDF" do
      assert {:ok, "application/pdf"} = Default.detect(pdf_content(), "doc.pdf")
    end

    test "detects RTF" do
      assert {:ok, "application/rtf"} = Default.detect(rtf_content(), "doc.rtf")
    end

    test "detects Microsoft Compound Binary (legacy Office)" do
      assert {:ok, "application/msword"} = Default.detect(ms_office_content(), "doc.doc")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Audio formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — audio" do
    test "detects MP3 with ID3v2 header" do
      assert {:ok, "audio/mpeg"} = Default.detect(mp3_id3_content(), "song.mp3")
    end

    test "detects MP3 frame sync 0xFFFB" do
      assert {:ok, "audio/mpeg"} = Default.detect(mp3_sync_fb_content(), "song.mp3")
    end

    test "detects MP3 frame sync 0xFFF3" do
      assert {:ok, "audio/mpeg"} = Default.detect(mp3_sync_f3_content(), "song.mp3")
    end

    test "detects MP3 frame sync 0xFFF2" do
      assert {:ok, "audio/mpeg"} = Default.detect(mp3_sync_f2_content(), "song.mp3")
    end

    test "detects OGG" do
      assert {:ok, "audio/ogg"} = Default.detect(ogg_content(), "audio.ogg")
    end

    test "detects FLAC" do
      assert {:ok, "audio/flac"} = Default.detect(flac_content(), "audio.flac")
    end

    test "detects WAV" do
      assert {:ok, "audio/wav"} = Default.detect(wav_content(), "audio.wav")
    end

    test "detects AIFF" do
      assert {:ok, "audio/aiff"} = Default.detect(aiff_content(), "audio.aiff")
    end

    test "detects AAC ADTS (0xFFF1)" do
      assert {:ok, "audio/aac"} = Default.detect(aac_f1_content(), "audio.aac")
    end

    test "detects AAC ADTS (0xFFF9)" do
      assert {:ok, "audio/aac"} = Default.detect(aac_f9_content(), "audio.aac")
    end

    test "detects MIDI" do
      assert {:ok, "audio/midi"} = Default.detect(midi_content(), "song.mid")
    end

    test "detects M4A (ftyp)" do
      assert {:ok, "audio/mp4"} = Default.detect(m4a_content(), "song.m4a")
    end

    test "detects M4P (ftyp)" do
      assert {:ok, "audio/mp4"} = Default.detect(m4p_content(), "song.m4p")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Video formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — video" do
    test "detects AVI" do
      assert {:ok, "video/x-msvideo"} = Default.detect(avi_content(), "video.avi")
    end

    test "detects Matroska/WebM" do
      assert {:ok, "video/x-matroska"} = Default.detect(mkv_content(), "video.mkv")
    end

    test "detects FLV" do
      assert {:ok, "video/x-flv"} = Default.detect(flv_content(), "video.flv")
    end

    test "detects MP4 (isom)" do
      assert {:ok, "video/mp4"} = Default.detect(mp4_isom_content(), "video.mp4")
    end

    test "detects MP4 (iso2)" do
      assert {:ok, "video/mp4"} = Default.detect(mp4_iso2_content(), "video.mp4")
    end

    test "detects MP4 (mp41)" do
      assert {:ok, "video/mp4"} = Default.detect(mp4_mp41_content(), "video.mp4")
    end

    test "detects MP4 (mp42)" do
      assert {:ok, "video/mp4"} = Default.detect(mp4_mp42_content(), "video.mp4")
    end

    test "detects M4V (ftyp)" do
      assert {:ok, "video/mp4"} = Default.detect(m4v_content(), "video.m4v")
    end

    test "detects QuickTime (ftyp)" do
      assert {:ok, "video/quicktime"} = Default.detect(qt_content(), "video.mov")
    end

    test "detects 3GPP (ftyp)" do
      assert {:ok, "video/3gpp"} = Default.detect(three_gpp_content(), "video.3gp")
    end

    test "detects 3GPP2 (ftyp)" do
      assert {:ok, "video/3gpp2"} = Default.detect(three_gpp2_content(), "video.3g2")
    end

    test "detects DASH (ftyp)" do
      assert {:ok, "video/mp4"} = Default.detect(dash_content(), "video.mp4")
    end

    test "unknown ftyp brand falls back to video/mp4" do
      assert {:ok, "video/mp4"} = Default.detect(unknown_ftyp_content(), "video.mp4")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Archive formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — archives" do
    test "detects ZIP" do
      assert {:ok, "application/zip"} = Default.detect(zip_content(), "archive.zip")
    end

    test "detects empty ZIP" do
      assert {:ok, "application/zip"} = Default.detect(zip_empty_content(), "archive.zip")
    end

    test "detects GZIP" do
      assert {:ok, "application/gzip"} = Default.detect(gzip_content(), "archive.gz")
    end

    test "detects BZIP2" do
      assert {:ok, "application/x-bzip2"} = Default.detect(bzip2_content(), "archive.bz2")
    end

    test "detects 7-Zip" do
      assert {:ok, "application/x-7z-compressed"} = Default.detect(sevenz_content(), "archive.7z")
    end

    test "detects RAR" do
      assert {:ok, "application/vnd.rar"} = Default.detect(rar_content(), "archive.rar")
    end

    test "detects XZ" do
      assert {:ok, "application/x-xz"} = Default.detect(xz_content(), "archive.xz")
    end

    test "detects TAR" do
      assert {:ok, "application/x-tar"} = Default.detect(tar_content(), "archive.tar")
    end

    test "detects Zstandard" do
      assert {:ok, "application/zstd"} = Default.detect(zstd_content(), "archive.zst")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — Other formats
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — other" do
    test "detects WASM" do
      assert {:ok, "application/wasm"} = Default.detect(wasm_content(), "module.wasm")
    end

    test "detects SQLite" do
      assert {:ok, "application/x-sqlite3"} = Default.detect(sqlite_content(), "data.db")
    end

    test "detects ELF" do
      assert {:ok, "application/x-elf"} = Default.detect(elf_content(), "program")
    end

    test "detects Mach-O 32-bit little-endian" do
      assert {:ok, "application/x-mach-binary"} = Default.detect(macho_32le_content(), "binary")
    end

    test "detects Mach-O 32-bit big-endian" do
      assert {:ok, "application/x-mach-binary"} = Default.detect(macho_32be_content(), "binary")
    end

    test "detects Mach-O 64-bit little-endian" do
      assert {:ok, "application/x-mach-binary"} = Default.detect(macho_64le_content(), "binary")
    end

    test "detects Mach-O 64-bit big-endian" do
      assert {:ok, "application/x-mach-binary"} = Default.detect(macho_64be_content(), "binary")
    end

    test "detects PE executable" do
      assert {:ok, "application/x-msdownload"} = Default.detect(pe_content(), "program.exe")
    end
  end

  # ---------------------------------------------------------------------------
  # Default.detect/2 — unrecognized content
  # ---------------------------------------------------------------------------

  describe "Default.detect/2 — unrecognized" do
    test "returns error for plain text" do
      assert {:error, :unrecognized} = Default.detect("Hello, world!", "readme.txt")
    end

    test "returns error for empty content" do
      assert {:error, :unrecognized} = Default.detect("", "empty.bin")
    end

    test "returns error for random bytes" do
      assert {:error, :unrecognized} = Default.detect(<<0xAB, 0xCD, 0xEF, 0x12>>, "random.bin")
    end

    test "returns error for very short content" do
      assert {:error, :unrecognized} = Default.detect(<<0x01>>, "short.bin")
    end
  end

  # ---------------------------------------------------------------------------
  # MimeDetector.detect/2 — public API with configurable detector
  # ---------------------------------------------------------------------------

  describe "MimeDetector.detect/2" do
    test "delegates to the default detector" do
      assert {:ok, "image/png"} = MimeDetector.detect(png_content(), "photo.png")
    end

    test "can be configured to use a custom detector" do
      defmodule TestDetector do
        @behaviour PhxMediaLibrary.MimeDetector

        @impl true
        def detect(_content, _filename), do: {:ok, "custom/type"}
      end

      prev = Application.get_env(:phx_media_library, :mime_detector)
      Application.put_env(:phx_media_library, :mime_detector, TestDetector)

      try do
        assert {:ok, "custom/type"} = MimeDetector.detect(png_content(), "photo.png")
      after
        if prev do
          Application.put_env(:phx_media_library, :mime_detector, prev)
        else
          Application.delete_env(:phx_media_library, :mime_detector)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MimeDetector.verify/3
  # ---------------------------------------------------------------------------

  describe "MimeDetector.verify/3" do
    test "returns :ok when detected type matches declared type" do
      assert :ok = MimeDetector.verify(png_content(), "photo.png", "image/png")
    end

    test "returns :ok when content is unrecognized (trusts declared type)" do
      assert :ok = MimeDetector.verify("plain text", "notes.txt", "text/plain")
    end

    test "returns :ok for case-insensitive MIME comparison" do
      assert :ok = MimeDetector.verify(jpeg_content(), "photo.jpg", "Image/JPEG")
    end

    test "returns :ok when declared type has parameters" do
      # SVG might be declared as "image/svg+xml;charset=utf-8"
      assert :ok =
               MimeDetector.verify(svg_bare_content(), "icon.svg", "image/svg+xml;charset=utf-8")
    end

    test "returns error when content type doesn't match declared type" do
      assert {:error, {:content_type_mismatch, "image/png", "application/pdf"}} =
               MimeDetector.verify(png_content(), "fake.pdf", "application/pdf")
    end

    test "catches executable disguised as image" do
      assert {:error, {:content_type_mismatch, "application/x-msdownload", "image/jpeg"}} =
               MimeDetector.verify(pe_content(), "photo.jpg", "image/jpeg")
    end

    test "catches ELF binary disguised as PDF" do
      assert {:error, {:content_type_mismatch, "application/x-elf", "application/pdf"}} =
               MimeDetector.verify(elf_content(), "document.pdf", "application/pdf")
    end
  end

  # ---------------------------------------------------------------------------
  # MimeDetector.detect_with_fallback/2
  # ---------------------------------------------------------------------------

  describe "MimeDetector.detect_with_fallback/2" do
    test "returns detected type when magic bytes match" do
      assert "image/png" = MimeDetector.detect_with_fallback(png_content(), "photo.png")
    end

    test "returns detected type even when extension differs" do
      assert "image/png" = MimeDetector.detect_with_fallback(png_content(), "fake.txt")
    end

    test "falls back to extension-based detection for unrecognized content" do
      result = MimeDetector.detect_with_fallback("plain text", "data.csv")
      assert result == "text/csv"
    end

    test "falls back to extension for plain text files" do
      result = MimeDetector.detect_with_fallback("hello world", "readme.md")
      # MIME library typically returns text/markdown or application/octet-stream
      assert is_binary(result)
    end

    test "returns a MIME type even for unknown extensions" do
      result = MimeDetector.detect_with_fallback("random data", "unknown.xyz123")
      assert is_binary(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases and real-world scenarios
  # ---------------------------------------------------------------------------

  describe "real-world scenarios" do
    test "correctly detects a minimal valid PNG (from Fixtures.create_minimal_png)" do
      # This is the exact PNG binary used by the test fixtures
      png_data =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
          0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08,
          0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE,
          0xD4, 0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

      assert {:ok, "image/png"} = Default.detect(png_data, "test_image.png")
    end

    test "detect + verify pipeline catches mismatched content" do
      # Someone uploaded a PNG file but named it .pdf
      png_data = png_content()
      detected_mime = MimeDetector.detect_with_fallback(png_data, "report.pdf")
      assert detected_mime == "image/png"

      # Verification catches the mismatch
      assert {:error, {:content_type_mismatch, "image/png", "application/pdf"}} =
               MimeDetector.verify(png_data, "report.pdf", "application/pdf")
    end

    test "detect + verify pipeline passes for matching content" do
      jpeg_data = jpeg_content()
      detected_mime = MimeDetector.detect_with_fallback(jpeg_data, "photo.jpg")
      assert detected_mime == "image/jpeg"

      # Verification passes
      assert :ok = MimeDetector.verify(jpeg_data, "photo.jpg", "image/jpeg")
    end

    test "large TAR content at boundary size (262 bytes)" do
      # Exactly 262 bytes with ustar at offset 257
      content = tar_content()
      assert byte_size(content) >= 262
      assert {:ok, "application/x-tar"} = Default.detect(content, "archive.tar")
    end

    test "content just under 262 bytes without TAR signature falls through" do
      # 261 bytes of zeros — not enough for TAR check, and no other magic
      content = :binary.copy(<<0x00>>, 261)
      assert {:error, :unrecognized} = Default.detect(content, "data.bin")
    end

    test "content >= 262 bytes without ustar at offset 257 falls through correctly" do
      # 300 bytes of zeros — TAR check runs but no ustar, falls to remaining formats
      content = :binary.copy(<<0x00>>, 300)
      assert {:error, :unrecognized} = Default.detect(content, "data.bin")
    end

    test "zstd content that is >= 262 bytes is still detected" do
      # Zstd magic bytes followed by enough padding to exceed 262 bytes
      zstd_prefix = <<0x28, 0xB5, 0x2F, 0xFD>>
      padding = :binary.copy(<<0x00>>, 260)
      content = zstd_prefix <> padding
      assert byte_size(content) >= 262
      assert {:ok, "application/zstd"} = Default.detect(content, "archive.zst")
    end

    test "ELF content that is >= 262 bytes is still detected" do
      elf_prefix = <<0x7F, "ELF">>
      padding = :binary.copy(<<0x00>>, 260)
      content = elf_prefix <> padding
      assert byte_size(content) >= 262
      assert {:ok, "application/x-elf"} = Default.detect(content, "binary")
    end
  end
end
