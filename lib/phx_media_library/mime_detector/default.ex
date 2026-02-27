defmodule PhxMediaLibrary.MimeDetector.Default do
  @moduledoc """
  Default MIME type detector using magic byte signatures.

  Detects common file types by inspecting the first bytes of file content.
  Covers images, documents, audio, video, and archive formats. When content
  doesn't match any known signature, returns `{:error, :unrecognized}` so
  callers can fall back to extension-based detection.

  ## Supported Formats

  ### Images
  JPEG, PNG, GIF, WebP, BMP, TIFF, ICO, AVIF, HEIC/HEIF, SVG

  ### Documents
  PDF, ZIP (and ZIP-based formats: DOCX, XLSX, PPTX), Microsoft Office
  legacy (DOC, XLS, PPT), RTF, XML

  ### Audio
  MP3 (ID3v2), OGG, FLAC, WAV, AIFF, AAC (ADTS), MIDI

  ### Video
  MP4/M4V/M4A (ftyp), AVI, MKV/WebM (Matroska/EBML), FLV, MOV

  ### Archives
  ZIP, GZIP, BZIP2, 7-Zip, RAR, XZ, TAR, Zstandard

  ### Other
  WASM, SQLite, ELF executables, Mach-O executables, PE executables (EXE/DLL)
  """

  @behaviour PhxMediaLibrary.MimeDetector

  @impl true
  @doc """
  Detect MIME type from binary content using magic byte signatures.

  Inspects the first bytes of `content` to identify the file type.
  The `filename` parameter is currently unused but available for future
  heuristics (e.g. differentiating ZIP-based formats by extension).

  Returns `{:ok, mime_type}` or `{:error, :unrecognized}`.
  """
  @spec detect(binary(), String.t()) :: {:ok, String.t()} | {:error, :unrecognized}
  def detect(content, _filename) when is_binary(content) do
    detect_from_magic_bytes(content)
  end

  # ---------------------------------------------------------------------------
  # Images
  # ---------------------------------------------------------------------------

  # JPEG: starts with FF D8 FF
  defp detect_from_magic_bytes(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}

  # PNG: 8-byte signature
  defp detect_from_magic_bytes(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>),
    do: {:ok, "image/png"}

  # GIF: GIF87a or GIF89a
  defp detect_from_magic_bytes(<<"GIF87a", _rest::binary>>), do: {:ok, "image/gif"}
  defp detect_from_magic_bytes(<<"GIF89a", _rest::binary>>), do: {:ok, "image/gif"}

  # WebP: RIFF....WEBP
  defp detect_from_magic_bytes(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: {:ok, "image/webp"}

  # BMP: starts with BM
  defp detect_from_magic_bytes(<<"BM", _rest::binary>>), do: {:ok, "image/bmp"}

  # TIFF: little-endian (II) or big-endian (MM)
  defp detect_from_magic_bytes(<<0x49, 0x49, 0x2A, 0x00, _rest::binary>>),
    do: {:ok, "image/tiff"}

  defp detect_from_magic_bytes(<<0x4D, 0x4D, 0x00, 0x2A, _rest::binary>>),
    do: {:ok, "image/tiff"}

  # ICO: 00 00 01 00
  defp detect_from_magic_bytes(<<0x00, 0x00, 0x01, 0x00, _rest::binary>>),
    do: {:ok, "image/x-icon"}

  # AVIF / HEIC / HEIF: ISO Base Media File Format with ftyp box
  # These all use the ftyp box but with different brand codes
  defp detect_from_magic_bytes(
         <<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>
       ) do
    detect_ftyp_brand(brand)
  end

  # SVG: look for common XML/SVG opening patterns
  defp detect_from_magic_bytes(<<"<?xml", rest::binary>>) do
    # Check if it's an SVG document
    if svg_content?(rest), do: {:ok, "image/svg+xml"}, else: {:ok, "application/xml"}
  end

  defp detect_from_magic_bytes(<<"<svg", _rest::binary>>), do: {:ok, "image/svg+xml"}

  # ---------------------------------------------------------------------------
  # Documents
  # ---------------------------------------------------------------------------

  # PDF: starts with %PDF
  defp detect_from_magic_bytes(<<"%PDF", _rest::binary>>), do: {:ok, "application/pdf"}

  # RTF: starts with {\rtf
  defp detect_from_magic_bytes(<<"{\\rtf", _rest::binary>>), do: {:ok, "application/rtf"}

  # Microsoft Compound Binary (legacy Office: DOC, XLS, PPT)
  defp detect_from_magic_bytes(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _rest::binary>>),
    do: {:ok, "application/msword"}

  # ---------------------------------------------------------------------------
  # Audio
  # ---------------------------------------------------------------------------

  # MP3 with ID3v2 header
  defp detect_from_magic_bytes(<<"ID3", _rest::binary>>), do: {:ok, "audio/mpeg"}

  # MP3 frame sync (MPEG Audio frame header: 0xFF followed by 0xE0+ or 0xF0+)
  defp detect_from_magic_bytes(<<0xFF, 0xFB, _rest::binary>>), do: {:ok, "audio/mpeg"}
  defp detect_from_magic_bytes(<<0xFF, 0xF3, _rest::binary>>), do: {:ok, "audio/mpeg"}
  defp detect_from_magic_bytes(<<0xFF, 0xF2, _rest::binary>>), do: {:ok, "audio/mpeg"}

  # OGG: OggS
  defp detect_from_magic_bytes(<<"OggS", _rest::binary>>), do: {:ok, "audio/ogg"}

  # FLAC: fLaC
  defp detect_from_magic_bytes(<<"fLaC", _rest::binary>>), do: {:ok, "audio/flac"}

  # WAV: RIFF....WAVE
  defp detect_from_magic_bytes(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>),
    do: {:ok, "audio/wav"}

  # AIFF: FORM....AIFF
  defp detect_from_magic_bytes(<<"FORM", _size::binary-size(4), "AIFF", _rest::binary>>),
    do: {:ok, "audio/aiff"}

  # AAC ADTS: starts with 0xFF 0xF1 or 0xFF 0xF9
  defp detect_from_magic_bytes(<<0xFF, 0xF1, _rest::binary>>), do: {:ok, "audio/aac"}
  defp detect_from_magic_bytes(<<0xFF, 0xF9, _rest::binary>>), do: {:ok, "audio/aac"}

  # MIDI: MThd
  defp detect_from_magic_bytes(<<"MThd", _rest::binary>>), do: {:ok, "audio/midi"}

  # ---------------------------------------------------------------------------
  # Video
  # ---------------------------------------------------------------------------

  # AVI: RIFF....AVI
  defp detect_from_magic_bytes(<<"RIFF", _size::binary-size(4), "AVI ", _rest::binary>>),
    do: {:ok, "video/x-msvideo"}

  # Matroska / WebM (EBML header)
  defp detect_from_magic_bytes(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>),
    do: {:ok, "video/x-matroska"}

  # FLV: FLV followed by version byte
  defp detect_from_magic_bytes(<<"FLV", 0x01, _rest::binary>>), do: {:ok, "video/x-flv"}

  # ---------------------------------------------------------------------------
  # Archives
  # ---------------------------------------------------------------------------

  # ZIP: PK\x03\x04 (local file header)
  defp detect_from_magic_bytes(<<0x50, 0x4B, 0x03, 0x04, _rest::binary>>),
    do: {:ok, "application/zip"}

  # ZIP: PK\x05\x06 (empty archive)
  defp detect_from_magic_bytes(<<0x50, 0x4B, 0x05, 0x06, _rest::binary>>),
    do: {:ok, "application/zip"}

  # GZIP: 1F 8B
  defp detect_from_magic_bytes(<<0x1F, 0x8B, _rest::binary>>), do: {:ok, "application/gzip"}

  # BZIP2: BZ followed by version
  defp detect_from_magic_bytes(<<"BZh", _rest::binary>>), do: {:ok, "application/x-bzip2"}

  # 7-Zip: 7z\xBC\xAF\x27\x1C
  defp detect_from_magic_bytes(<<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, _rest::binary>>),
    do: {:ok, "application/x-7z-compressed"}

  # RAR: Rar!\x1A\x07
  defp detect_from_magic_bytes(<<"Rar!", 0x1A, 0x07, _rest::binary>>),
    do: {:ok, "application/vnd.rar"}

  # XZ: FD 37 7A 58 5A 00
  defp detect_from_magic_bytes(<<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, _rest::binary>>),
    do: {:ok, "application/x-xz"}

  # TAR: ustar at offset 257 — we check for shorter content too
  defp detect_from_magic_bytes(content) when byte_size(content) >= 262 do
    case binary_part(content, 257, 5) do
      "ustar" -> {:ok, "application/x-tar"}
      _ -> detect_remaining_formats(content)
    end
  end

  # Zstandard: 28 B5 2F FD
  defp detect_from_magic_bytes(<<0x28, 0xB5, 0x2F, 0xFD, _rest::binary>>),
    do: {:ok, "application/zstd"}

  # ---------------------------------------------------------------------------
  # Other formats
  # ---------------------------------------------------------------------------

  # WASM: \0asm
  defp detect_from_magic_bytes(<<0x00, "asm", _rest::binary>>), do: {:ok, "application/wasm"}

  # SQLite: "SQLite format 3\0"
  defp detect_from_magic_bytes(<<"SQLite format 3", 0x00, _rest::binary>>),
    do: {:ok, "application/x-sqlite3"}

  # ELF (Linux executables/shared libs): 7F 45 4C 46
  defp detect_from_magic_bytes(<<0x7F, "ELF", _rest::binary>>),
    do: {:ok, "application/x-elf"}

  # Mach-O (macOS executables)
  defp detect_from_magic_bytes(<<0xFE, 0xED, 0xFA, 0xCE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_from_magic_bytes(<<0xFE, 0xED, 0xFA, 0xCF, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_from_magic_bytes(<<0xCE, 0xFA, 0xED, 0xFE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_from_magic_bytes(<<0xCF, 0xFA, 0xED, 0xFE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  # PE (Windows EXE/DLL): MZ
  defp detect_from_magic_bytes(<<"MZ", _rest::binary>>),
    do: {:ok, "application/x-msdownload"}

  # No match
  defp detect_from_magic_bytes(_content), do: {:error, :unrecognized}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Called for content >= 262 bytes that didn't match TAR at offset 257
  defp detect_remaining_formats(<<0x28, 0xB5, 0x2F, 0xFD, _rest::binary>>),
    do: {:ok, "application/zstd"}

  defp detect_remaining_formats(<<0x00, "asm", _rest::binary>>),
    do: {:ok, "application/wasm"}

  defp detect_remaining_formats(<<"SQLite format 3", 0x00, _rest::binary>>),
    do: {:ok, "application/x-sqlite3"}

  defp detect_remaining_formats(<<0x7F, "ELF", _rest::binary>>),
    do: {:ok, "application/x-elf"}

  defp detect_remaining_formats(<<0xFE, 0xED, 0xFA, 0xCE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_remaining_formats(<<0xFE, 0xED, 0xFA, 0xCF, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_remaining_formats(<<0xCE, 0xFA, 0xED, 0xFE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_remaining_formats(<<0xCF, 0xFA, 0xED, 0xFE, _rest::binary>>),
    do: {:ok, "application/x-mach-binary"}

  defp detect_remaining_formats(<<"MZ", _rest::binary>>),
    do: {:ok, "application/x-msdownload"}

  defp detect_remaining_formats(_content), do: {:error, :unrecognized}

  # ISO Base Media File Format brand detection (MP4, M4A, HEIC, AVIF, etc.)
  defp detect_ftyp_brand("avif"), do: {:ok, "image/avif"}
  defp detect_ftyp_brand("avis"), do: {:ok, "image/avif"}
  defp detect_ftyp_brand("heic"), do: {:ok, "image/heic"}
  defp detect_ftyp_brand("heix"), do: {:ok, "image/heic"}
  defp detect_ftyp_brand("heif"), do: {:ok, "image/heif"}
  defp detect_ftyp_brand("mif1"), do: {:ok, "image/heif"}
  defp detect_ftyp_brand("isom"), do: {:ok, "video/mp4"}
  defp detect_ftyp_brand("iso2"), do: {:ok, "video/mp4"}
  defp detect_ftyp_brand("mp41"), do: {:ok, "video/mp4"}
  defp detect_ftyp_brand("mp42"), do: {:ok, "video/mp4"}
  defp detect_ftyp_brand("M4V" <> _), do: {:ok, "video/mp4"}
  defp detect_ftyp_brand("M4A" <> _), do: {:ok, "audio/mp4"}
  defp detect_ftyp_brand("M4P" <> _), do: {:ok, "audio/mp4"}
  defp detect_ftyp_brand("qt" <> _), do: {:ok, "video/quicktime"}
  defp detect_ftyp_brand("3gp" <> _), do: {:ok, "video/3gpp"}
  defp detect_ftyp_brand("3g2" <> _), do: {:ok, "video/3gpp2"}
  defp detect_ftyp_brand("dash"), do: {:ok, "video/mp4"}
  # Generic fallback for unknown ftyp brands — likely video/mp4
  defp detect_ftyp_brand(_), do: {:ok, "video/mp4"}

  # Check if XML content contains SVG elements (simple heuristic)
  defp svg_content?(content) when is_binary(content) do
    # Look within the first 1KB for svg indicators
    sample = binary_part(content, 0, min(byte_size(content), 1024))

    String.contains?(sample, "<svg") or
      String.contains?(sample, "xmlns=\"http://www.w3.org/2000/svg\"")
  end
end
