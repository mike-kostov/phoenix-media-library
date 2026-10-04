defmodule PhxMediaLibrary.FileName do
  @moduledoc """
  Everything about filenames: making client-supplied names safe, and
  choosing the name a file is stored under.

  ## Stored names

  The name a file is stored under is chosen by the library, never by the
  uploader. It is ASCII only: lowercase `a-z`, `0-9`, `-` and `_`, plus a
  lowercase extension. This avoids a whole class of bugs (Unicode
  normalization differences between macOS and Linux, case-insensitive
  filesystems, URL encoding of spaces, `#` and `?`) and of tricks
  (right-to-left override characters, look-alike letters, zero-width
  characters). The extension comes from the detected content type, not the
  uploader. The original name is kept, as UTF-8, in
  `media.metadata["original_file_name"]` for display.

  Three strategies, set globally with `config :phx_media_library,
  file_naming: ...` and per collection with `file_naming:`:

    * `:semantic` (default): `{mediable_type}_{mediable_id}_{collection}_{uuid}.{ext}`,
      e.g. `posts_42_images_3f2a9c1e-….jpg`. Readable, sorts by record, and
      carries everything needed to rebuild a lost database row. Exposes
      record IDs in URLs (as the default directory layout already does).
    * `:slug`: the original name as a slug, e.g. `red-summer-dress.jpg`;
      good for SEO. Cyrillic is transliterated (`снимка.jpg` → `snimka.jpg`)
      and accents dropped (`café` → `cafe`); a name with nothing left becomes
      `file.jpg`.
    * `:random`: `aohnmpeggczvupfgbuoh54enae.jpg`; reveals nothing in the
      name. It doesn't protect the file: for that, use a private disk and
      signed URLs.

  Every path generator puts the media's UUID in the path, so names never
  collide.

  ## Client-supplied names

  Upload filenames (`Plug.Upload.filename`, LiveView `client_name`, the
  `Content-Disposition` of a remote download) are chosen by whoever sends the
  file. `safe/1` reduces them to one path segment before they are used
  anywhere, keeping them readable. Only path separators, control characters
  and leading dots are removed, so `"Summer Photo.JPG"` stays as it is.
  """

  @max_bytes 255
  @max_slug_length 100

  @typedoc "How stored filenames are chosen."
  @type strategy :: :semantic | :slug | :random

  @typedoc "What `storage_name/2` needs to know about the upload."
  @type upload :: %{
          required(:original) => String.t(),
          required(:mime_type) => String.t(),
          required(:mediable_type) => String.t(),
          required(:mediable_id) => term(),
          required(:collection_name) => atom() | String.t(),
          required(:uuid) => String.t()
        }

  @doc """
  The name to store an upload under, for the given strategy.

  ## Examples

      iex> upload = %{
      ...>   original: "Summer Dress (1).JPG",
      ...>   mime_type: "image/jpeg",
      ...>   mediable_type: "products",
      ...>   mediable_id: 42,
      ...>   collection_name: :images,
      ...>   uuid: "3f2a9c1e-7b1d-4e0a-9c2f-1a2b3c4d5e6f"
      ...> }
      iex> PhxMediaLibrary.FileName.storage_name(:semantic, upload)
      "products_42_images_3f2a9c1e-7b1d-4e0a-9c2f-1a2b3c4d5e6f.jpg"
      iex> PhxMediaLibrary.FileName.storage_name(:slug, upload)
      "summer-dress-1.jpg"
      iex> PhxMediaLibrary.FileName.storage_name(:slug, %{upload | original: "Лятна рокля.jpg"})
      "lyatna-roklya.jpg"
      iex> PhxMediaLibrary.FileName.storage_name(:slug, %{upload | original: "写真.jpg"})
      "file.jpg"
      iex> PhxMediaLibrary.FileName.storage_name(:slug, %{upload | original: "photo.jpg", mime_type: "image/png"})
      "photo.png"

  """
  @spec storage_name(strategy(), upload()) :: String.t()
  def storage_name(:semantic, upload) do
    [upload.mediable_type, upload.mediable_id, upload.collection_name, upload.uuid]
    |> Enum.map_join("_", &(&1 |> to_string() |> ascii_slug()))
    |> with_extension(upload)
  end

  def storage_name(:slug, upload) do
    upload.original
    |> Path.rootname()
    |> ascii_slug()
    |> String.slice(0, @max_slug_length)
    |> String.trim("-")
    |> case do
      "" -> "file"
      slug -> slug
    end
    |> with_extension(upload)
  end

  def storage_name(:random, upload) do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> with_extension(upload)
  end

  def storage_name(strategy, _upload) do
    raise ArgumentError,
          "unknown file_naming #{inspect(strategy)}; expected :semantic, :slug or :random"
  end

  @doc """
  Whether `file_name` looks like a `:random` name.

  ## Examples

      iex> PhxMediaLibrary.FileName.random_name?("aohnmpeggczvupfgbuoh54enae.jpg")
      true

      iex> PhxMediaLibrary.FileName.random_name?("red-dress.jpg")
      false

  """
  @spec random_name?(String.t()) :: boolean()
  def random_name?(file_name), do: file_name =~ ~r/^[a-z2-7]{26}\.[a-z0-9]+$/

  @doc """
  The extension to store a file with: the uploader's extension when it
  belongs to the detected content type (keeps `jpeg` vs `jpg`), otherwise the
  content type's usual one. For unrecognised content the uploader's
  extension is kept, reduced to `a-z0-9`, or `bin`.

  ## Examples

      iex> PhxMediaLibrary.FileName.extension("photo.JPEG", "image/jpeg")
      "jpeg"

      iex> PhxMediaLibrary.FileName.extension("photo.jpg", "image/png")
      "png"

      iex> PhxMediaLibrary.FileName.extension("model.Sketch!", "application/octet-stream")
      "sketch"

      iex> PhxMediaLibrary.FileName.extension("noext", "application/octet-stream")
      "bin"

  """
  @spec extension(String.t(), String.t()) :: String.t()
  def extension(original, mime_type) do
    given =
      original
      |> Path.extname()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")
      |> String.slice(0, 10)

    known = if mime_type == "application/octet-stream", do: [], else: MIME.extensions(mime_type)

    cond do
      given in known -> given
      known != [] -> hd(known)
      given != "" -> given
      true -> "bin"
    end
  end

  defp with_extension(base, upload),
    do: base <> "." <> extension(upload.original, upload.mime_type)

  # ASCII-only slug: transliterated (see transliterate/1), anything else
  # outside a-z0-9 becomes "-".
  defp ascii_slug(text) do
    text
    |> transliterate()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Cyrillic follows the Bulgarian official system (2009), which also reads
  # naturally for Russian and Ukrainian; letters unique to other alphabets
  # are added. Russian readers may expect "shch" for щ and nothing for ъ.
  @transliteration %{
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "g",
    "д" => "d",
    "е" => "e",
    "ж" => "zh",
    "з" => "z",
    "и" => "i",
    "й" => "y",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "у" => "u",
    "ф" => "f",
    "х" => "h",
    "ц" => "ts",
    "ч" => "ch",
    "ш" => "sh",
    "щ" => "sht",
    "ъ" => "a",
    "ь" => "y",
    "ю" => "yu",
    "я" => "ya",
    # Russian, Belarusian
    "ё" => "yo",
    "ы" => "y",
    "э" => "e",
    "ў" => "u",
    # Ukrainian
    "є" => "ye",
    "і" => "i",
    "ї" => "yi",
    "ґ" => "g",
    # Serbian, Macedonian
    "ђ" => "dj",
    "ј" => "j",
    "љ" => "lj",
    "њ" => "nj",
    "ћ" => "c",
    "џ" => "dz",
    "ѓ" => "gj",
    "ќ" => "kj",
    "ѕ" => "dz",
    # Latin letters that don't decompose into a base letter plus accent
    "ß" => "ss",
    "æ" => "ae",
    "œ" => "oe",
    "ø" => "o",
    "đ" => "d",
    "ł" => "l",
    "þ" => "th",
    "ð" => "d",
    "ı" => "i"
  }

  @doc """
  Lowercase `text` and turn it into ASCII where a reasonable equivalent
  exists: Cyrillic is transliterated, accents are dropped. Characters with
  no equivalent (e.g. Chinese) are left as they are.

  ## Examples

      iex> PhxMediaLibrary.FileName.transliterate("Снимка на Щастливия Ъгъл")
      "snimka na shtastliviya agal"

      iex> PhxMediaLibrary.FileName.transliterate("Crème Brûlée Straße")
      "creme brulee strasse"

  """
  @spec transliterate(String.t()) :: String.t()
  def transliterate(text) do
    text
    |> String.downcase()
    |> String.graphemes()
    |> Enum.map_join(&Map.get(@transliteration, &1, &1))
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  @doc """
  A `Content-Disposition: attachment` header value for downloading a file
  as `name`: an ASCII `filename` for old clients (transliterated, quotes
  and control characters removed) and the exact name as a UTF-8
  `filename*` (RFC 6266).

  ## Examples

      iex> PhxMediaLibrary.FileName.content_disposition("Report #3.pdf")
      ~s(attachment; filename="Report #3.pdf"; filename*=UTF-8''Report%20%233.pdf)

      iex> PhxMediaLibrary.FileName.content_disposition("Рокля.pdf")
      ~s(attachment; filename="Roklya.pdf"; filename*=UTF-8''%D0%A0%D0%BE%D0%BA%D0%BB%D1%8F.pdf)

  """
  @spec content_disposition(String.t()) :: String.t()
  def content_disposition(name) do
    fallback = name |> String.graphemes() |> Enum.map_join(&ascii_grapheme/1)
    encoded = URI.encode(name, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  defp ascii_grapheme(~s(")), do: "'"
  defp ascii_grapheme("\\"), do: "_"
  defp ascii_grapheme(<<char>>) when char < 32 or char == 127, do: ""
  defp ascii_grapheme(<<char>> = ascii) when char < 127, do: ascii

  defp ascii_grapheme(grapheme) do
    latin = transliterate(grapheme)

    latin =
      if String.upcase(grapheme) == grapheme and String.downcase(grapheme) != grapheme,
        do: String.capitalize(latin),
        else: latin

    if String.match?(latin, ~r/^[\x20-\x7e]+$/), do: latin, else: "_"
  end

  @doc """
  Reduce a client-supplied filename to a single, safe path segment.

  Strips any directory part (both `/` and `\\` separators), control
  characters and leading dots, and caps the length at 255 bytes while
  keeping the extension. Returns `"file"` when nothing usable is left.

  ## Examples

      iex> PhxMediaLibrary.FileName.safe("Summer Photo.JPG")
      "Summer Photo.JPG"

      iex> PhxMediaLibrary.FileName.safe("../../priv/static/app.js")
      "app.js"

      iex> PhxMediaLibrary.FileName.safe("C:\\\\Users\\\\me\\\\photo.png")
      "photo.png"

      iex> PhxMediaLibrary.FileName.safe(".htaccess")
      "htaccess"

      iex> PhxMediaLibrary.FileName.safe("..")
      "file"

  """
  @spec safe(String.t() | nil) :: String.t()
  def safe(filename) when is_binary(filename) do
    filename
    |> String.replace("\\", "/")
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.trim()
    |> String.trim_leading(".")
    |> truncate()
    |> case do
      "" -> "file"
      name -> name
    end
  end

  def safe(_), do: "file"

  @doc """
  Turn a filename into a lowercase slug without its extension, used for
  the `name` field of a media record.

  ## Examples

      iex> PhxMediaLibrary.FileName.slug("Summer Photo (1).JPG")
      "summer-photo-1"

  """
  @spec slug(String.t()) :: String.t()
  def slug(filename) do
    filename
    |> Path.rootname()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp truncate(name) when byte_size(name) <= @max_bytes, do: name

  defp truncate(name) do
    ext = Path.extname(name)
    ext = if byte_size(ext) > 16, do: "", else: ext
    root = String.slice(Path.rootname(name, ext), 0, @max_bytes - byte_size(ext))
    shrink(root, @max_bytes - byte_size(ext)) <> ext
  end

  # String.slice counts graphemes; multi-byte characters may still overflow.
  defp shrink(root, max) when byte_size(root) <= max, do: root
  defp shrink(root, max), do: shrink(String.slice(root, 0..-2//1), max)
end
