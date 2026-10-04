defmodule PhxMediaLibrary.Plug.StaticHeaders do
  @moduledoc """
  Response headers that make uploaded files safe to serve.

  An SVG can contain JavaScript. Shown through an `<img>` tag the script
  never runs, but opening the file's URL directly would run it on your
  domain. These headers serve SVG files sandboxed, so scripts never run,
  while embedded images and styles still display. Other files get no extra
  headers.

  Use it with the `Plug.Static` that serves your uploads:

      # lib/my_app_web/endpoint.ex
      plug Plug.Static,
        at: "/uploads",
        from: {:my_app, "priv/static/uploads"},
        headers: {PhxMediaLibrary.Plug.StaticHeaders, :headers, []}

  `PhxMediaLibrary.Plug.MediaDownload` applies the same headers itself.
  """

  @svg_headers [
    {"content-security-policy",
     "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"},
    {"x-content-type-options", "nosniff"}
  ]

  @doc """
  Headers for the requested file, for `Plug.Static`'s `:headers` option.

  ## Examples

      iex> PhxMediaLibrary.Plug.StaticHeaders.headers(%{request_path: "/uploads/logo.svg"})
      [
        {"content-security-policy", "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"},
        {"x-content-type-options", "nosniff"}
      ]

      iex> PhxMediaLibrary.Plug.StaticHeaders.headers(%{request_path: "/uploads/photo.jpg"})
      []

  """
  @spec headers(%{required(:request_path) => String.t(), optional(atom()) => any()}) ::
          [{String.t(), String.t()}]
  def headers(%{request_path: path}), do: for_path(path)

  @doc """
  Headers for a file path or name.

  ## Examples

      iex> PhxMediaLibrary.Plug.StaticHeaders.for_path("LOGO.SVG") |> length()
      2

  """
  @spec for_path(String.t()) :: [{String.t(), String.t()}]
  def for_path(path) do
    if path |> Path.extname() |> String.downcase() == ".svg", do: @svg_headers, else: []
  end
end
