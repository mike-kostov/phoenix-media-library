defmodule PhxMediaLibrary.ViewHelpers do
  @moduledoc """
  Helper functions for rendering media in Phoenix templates.

  ## Usage in Phoenix

  Add to your `my_app_web.ex`:

      def html_helpers do
        quote do
          # ... existing imports
          import PhxMediaLibrary.ViewHelpers
        end
      end

  Then in your templates:

      <.media_img media={@media} class="rounded-lg" />

      <.responsive_img media={@media} sizes="(max-width: 768px) 100vw, 50vw" />

  """

  use Phoenix.Component

  alias PhxMediaLibrary.{Media, UrlGenerator}

  @doc """
  Renders a simple img tag for a media item.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name to use (default: original)
  - `alt` - Alt text (falls back to `PhxMediaLibrary.Media.alt_text/1`)
  - `width`, `height` - default to the served file's size
  - `loading` - `"lazy"` or `"eager"` (default: not set, i.e. eager)
  - `priority` - the page's main image: loads immediately and first
  - `class` - CSS classes
  - `placeholder` - Show the stored placeholder while loading (default: true)
  - All other attributes are passed through to the img tag

  ## Examples

      <.media_img media={@post.avatar} class="w-20 h-20 rounded-full" />

      <.media_img media={@image} conversion={:thumb} alt="Product thumbnail" loading="lazy" />

  """
  attr(:media, Media, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:alt, :string, default: nil)
  attr(:width, :integer, default: nil, doc: "defaults to the served file's width")
  attr(:height, :integer, default: nil, doc: "defaults to the served file's height")
  attr(:loading, :string, default: nil, doc: ~s("lazy" or "eager"; unset means eager))
  attr(:priority, :boolean, default: false, doc: "the page's main image: load first")
  attr(:class, :string, default: nil)
  attr(:placeholder, :boolean, default: true)
  attr(:rest, :global)

  def media_img(assigns) do
    assigns = assigns |> with_image_defaults() |> with_loading()

    ~H"""
    <img
      src={PhxMediaLibrary.url(@media, @conversion)}
      alt={@alt}
      width={@width}
      height={@height}
      loading={@loading}
      fetchpriority={@fetchpriority}
      decoding={@decoding}
      class={@class}
      style={@placeholder && placeholder_style(@media, @conversion)}
      {@rest}
    />
    """
  end

  @doc """
  Renders a responsive img tag with srcset.

  Includes progressive loading with a tiny placeholder that's
  replaced when the full image loads.

  When the media has an AVIF (`avif:` on), its variants are AVIF only, so
  it renders a `<picture>` with an AVIF source holding the `srcset`, then
  WebP, and the `<img>` for browsers without AVIF.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name to use
  - `sizes` - How wide the image is shown. Defaults to `"auto, 100vw"` for
    lazy images (browsers that support `auto` measure the real slot, others
    assume full width) and `"100vw"` otherwise. Set it for layouts you know,
    e.g. `"(max-width: 768px) 50vw, 25vw"` for a 4-column grid.
  - `alt` - Alt text
  - `width`, `height` - default to the served file's size
  - `loading` - `"lazy"` (default) or `"eager"`
  - `priority` - the page's main image (hero): loads immediately and first
  - `class` - CSS classes
  - `placeholder` - Show blur placeholder (default: true)

  ## Examples

      <.responsive_img media={@hero_image} priority class="w-full h-auto" />

      <.responsive_img
        media={@product.image}
        conversion={:preview}
        sizes="(max-width: 768px) 50vw, 25vw"
      />

  """
  attr(:media, Media, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:sizes, :string, default: nil)
  attr(:alt, :string, default: nil)
  attr(:width, :integer, default: nil, doc: "defaults to the served file's width")
  attr(:height, :integer, default: nil, doc: "defaults to the served file's height")
  attr(:class, :string, default: nil)
  attr(:loading, :string, default: "lazy")
  attr(:priority, :boolean, default: false, doc: "the page's main image: load first")
  attr(:placeholder, :boolean, default: true)
  attr(:rest, :global)

  def responsive_img(assigns) do
    assigns = assigns |> with_image_defaults() |> with_loading() |> with_sizes()
    %{media: media, conversion: conversion} = assigns

    # Variants are AVIF-only when the media has an AVIF (ADR-024): offer them
    # through <picture>, so browsers without AVIF still get the <img>.
    sources = if avif?(media, conversion), do: format_sources(media, conversion), else: []

    assigns =
      assigns
      |> assign(:sources, sources)
      |> assign(:srcset, if(sources == [], do: PhxMediaLibrary.srcset(media, conversion)))
      |> assign(:src, PhxMediaLibrary.url(media, conversion))
      |> assign(:placeholder_style, placeholder_style(media, conversion))

    ~H"""
    <%= if @sources == [] do %>
      {responsive_img_tag(assigns)}
    <% else %>
      <picture>
        <source :for={source <- @sources} type={source.type} srcset={source.srcset} sizes={@sizes} />
        {responsive_img_tag(assigns)}
      </picture>
    <% end %>
    """
  end

  defp responsive_img_tag(assigns) do
    ~H"""
    <img
      src={@src}
      srcset={@srcset}
      sizes={@srcset && @sizes}
      alt={@alt}
      width={@width}
      height={@height}
      class={@class}
      loading={@loading}
      fetchpriority={@fetchpriority}
      decoding={@decoding}
      style={@placeholder && @placeholder_style}
      {@rest}
    />
    """
  end

  @doc """
  Renders a picture element with multiple sources.

  For the original, it offers the media's modern formats as typed sources,
  best first: AVIF (with the responsive `srcset`), then WebP, then the
  `<img>`. `sources` adds art-direction sources before them.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name
  - `alt` - Alt text
  - `width`, `height` - default to the served file's size
  - `sizes` - as for `responsive_img/1`; applied to every source
  - `loading`, `priority` - as for `media_img/1`
  - `class` - CSS classes for the img element
  - `placeholder` - Show the stored placeholder while loading (default: true)
  - `sources` - List of source configurations

  ## Examples

      <.picture
        media={@image}
        sources={[
          %{media: "(max-width: 768px)", conversion: :mobile},
          %{media: "(min-width: 769px)", conversion: :desktop}
        ]}
      />

  """
  attr(:media, Media, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:alt, :string, default: nil)
  attr(:width, :integer, default: nil, doc: "defaults to the served file's width")
  attr(:height, :integer, default: nil, doc: "defaults to the served file's height")
  attr(:sizes, :string, default: nil)
  attr(:loading, :string, default: nil, doc: ~s("lazy" or "eager"; unset means eager))
  attr(:priority, :boolean, default: false, doc: "the page's main image: load first")
  attr(:class, :string, default: nil)
  attr(:placeholder, :boolean, default: true)
  attr(:sources, :list, default: [])
  attr(:rest, :global)

  def picture(assigns) do
    assigns = assigns |> with_image_defaults() |> with_loading() |> with_sizes()
    format_sources = format_sources(assigns.media, assigns.conversion)

    assigns =
      assigns
      |> assign(:format_sources, format_sources)
      |> assign(
        :srcset,
        if(format_sources == [], do: PhxMediaLibrary.srcset(assigns.media, assigns.conversion))
      )

    ~H"""
    <picture>
      <%= for source <- @sources do %>
        <source
          media={source[:media]}
          srcset={PhxMediaLibrary.srcset(@media, source[:conversion])}
          sizes={@sizes}
        />
      <% end %>
      <source :for={source <- @format_sources} type={source.type} srcset={source.srcset} sizes={@sizes} />
      <img
        src={PhxMediaLibrary.url(@media, @conversion)}
        srcset={@srcset}
        sizes={@srcset && @sizes}
        alt={@alt}
        width={@width}
        height={@height}
        loading={@loading}
        fetchpriority={@fetchpriority}
        decoding={@decoding}
        class={@class}
        style={@placeholder && placeholder_style(@media, @conversion)}
        {@rest}
      />
    </picture>
    """
  end

  # Private helpers

  defp avif?(%Media{custom_properties: %{"avif" => avif}}, nil) when is_binary(avif), do: true
  defp avif?(_media, _conversion), do: false

  # Typed <source>s for the original's modern formats, best first (ADR-024).
  # The srcset is in the best format; a second format offers its full-size
  # file. Conversions have no siblings: they are already in the served
  # format.
  defp format_sources(%Media{} = media, nil) do
    props = media.custom_properties || %{}
    srcset = PhxMediaLibrary.srcset(media, nil)

    [{"image/avif", props["avif"]}, {"image/webp", props["webp"]}]
    |> Enum.filter(fn {_type, path} -> is_binary(path) end)
    |> Enum.with_index()
    |> Enum.map(fn {{type, path}, index} ->
      full_size = UrlGenerator.url_for_path(media, path)
      %{type: type, srcset: if(index == 0, do: srcset || full_size, else: full_size)}
    end)
  end

  defp format_sources(_media, _conversion), do: []

  # A priority image loads immediately and first; everything else decodes
  # off the main thread.
  defp with_loading(assigns) do
    if assigns.priority do
      assigns
      |> assign(:loading, "eager")
      |> assign(:fetchpriority, "high")
      |> assign(:decoding, nil)
    else
      assigns |> assign(:fetchpriority, nil) |> assign(:decoding, "async")
    end
  end

  # sizes="auto" lets the browser measure the slot, but only for lazy images.
  defp with_sizes(assigns) do
    default = if assigns.loading == "lazy", do: "auto, 100vw", else: "100vw"
    assign(assigns, :sizes, assigns.sizes || default)
  end

  # Alt text and intrinsic size, unless given. width/height let the browser
  # reserve the image's space before it loads (no layout shift).
  defp with_image_defaults(assigns) do
    dimensions = Media.dimensions(assigns.media, assigns.conversion)

    assigns
    |> assign(:alt, assigns.alt || Media.alt_text(assigns.media))
    |> assign(:width, assigns.width || (dimensions && elem(dimensions, 0)))
    |> assign(:height, assigns.height || (dimensions && elem(dimensions, 1)))
  end

  @doc """
  The inline CSS that shows the image's stored placeholder while it loads:
  the blurred tiny image or the average color (see the `placeholder:`
  collection option), or `nil` when it has none. A conversion without its
  own uses the original's. The components set it; use it for your own
  `<img>` tags.

  ## Examples

      <img src={PhxMediaLibrary.url(@media)} style={placeholder_style(@media, nil)} />

  """
  @spec placeholder_style(Media.t(), atom() | nil) :: String.t() | nil
  def placeholder_style(%Media{responsive_images: responsive}, conversion) do
    responsive = responsive || %{}

    placeholder =
      (conversion && get_in(responsive, [to_string(conversion), "placeholder"])) ||
        get_in(responsive, ["original", "placeholder"])

    case placeholder do
      %{"data_uri" => data_uri} when is_binary(data_uri) ->
        "background-image: url('#{data_uri}'); background-size: cover; background-repeat: no-repeat;"

      %{"color" => color} when is_binary(color) ->
        "background-color: #{color};"

      _ ->
        nil
    end
  end
end
