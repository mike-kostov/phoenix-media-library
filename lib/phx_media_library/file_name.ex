defmodule PhxMediaLibrary.FileName do
  @moduledoc """
  Makes client-supplied filenames safe to use in storage paths.

  Upload filenames (`Plug.Upload.filename`, LiveView `client_name`, the
  `Content-Disposition` of a remote download) are chosen by whoever sends the
  file. Joined into a storage path unchanged, a name like
  `"../../priv/static/app.js"` would write outside the media's directory.

  `safe/1` keeps the name readable — only path separators, control characters
  and leading dots are removed — so `"Summer Photo.JPG"` stays as it is.
  """

  @max_bytes 255

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
    |> String.downcase()
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
