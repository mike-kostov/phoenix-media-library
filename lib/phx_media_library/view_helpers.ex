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

  alias PhxMediaLibrary.Media

  @doc """
  Renders a simple img tag for a media item.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name to use (default: original)
  - `alt` - Alt text (falls back to custom_properties["alt"] or filename)
  - `class` - CSS classes
  - All other attributes are passed through to the img tag

  ## Examples

      <.media_img media={@post.avatar} class="w-20 h-20 rounded-full" />

      <.media_img media={@image} conversion={:thumb} alt="Product thumbnail" />

  """
  attr(:media, Media, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:alt, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def media_img(assigns) do
    alt =
      assigns.alt ||
        get_in(assigns.media.custom_properties, ["alt"]) ||
        assigns.media.file_name

    assigns = assign(assigns, :alt, alt)

    ~H"""
    <img
      src={PhxMediaLibrary.url(@media, @conversion)}
      alt={@alt}
      class={@class}
      {@rest}
    />
    """
  end

  @doc """
  Renders a responsive img tag with srcset.

  Includes progressive loading with a tiny placeholder that's
  replaced when the full image loads.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name to use
  - `sizes` - The sizes attribute for responsive images
  - `alt` - Alt text
  - `class` - CSS classes
  - `loading` - Loading strategy ("lazy" or "eager", default: "lazy")
  - `placeholder` - Show blur placeholder (default: true)

  ## Examples

      <.responsive_img
        media={@hero_image}
        sizes="100vw"
        class="w-full h-auto"
      />

      <.responsive_img
        media={@thumbnail}
        conversion={:preview}
        sizes="(max-width: 768px) 100vw, 33vw"
        loading="eager"
      />

  """
  attr(:media, Media, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:sizes, :string, default: "100vw")
  attr(:alt, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:loading, :string, default: "lazy")
  attr(:placeholder, :boolean, default: true)
  attr(:rest, :global)

  def responsive_img(assigns) do
    alt =
      assigns.alt ||
        get_in(assigns.media.custom_properties, ["alt"]) ||
        assigns.media.file_name

    srcset = PhxMediaLibrary.srcset(assigns.media, assigns.conversion)
    src = PhxMediaLibrary.url(assigns.media, assigns.conversion)
    placeholder = Media.placeholder(assigns.media, assigns.conversion)

    assigns =
      assigns
      |> assign(:alt, alt)
      |> assign(:srcset, srcset)
      |> assign(:src, src)
      |> assign(:placeholder_uri, placeholder)

    ~H"""
    <img
      src={@src}
      srcset={@srcset}
      sizes={@sizes}
      alt={@alt}
      class={@class}
      loading={@loading}
      style={if @placeholder && @placeholder_uri, do: placeholder_style(@placeholder_uri)}
      {@rest}
    />
    """
  end

  @doc """
  Renders a picture element with multiple sources.

  Useful for art direction or serving different formats.

  ## Attributes

  - `media` (required) - The media item to render
  - `conversion` - Conversion name
  - `alt` - Alt text
  - `class` - CSS classes for the img element
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
  attr(:class, :string, default: nil)
  attr(:sources, :list, default: [])
  attr(:rest, :global)

  def picture(assigns) do
    alt =
      assigns.alt ||
        get_in(assigns.media.custom_properties, ["alt"]) ||
        assigns.media.file_name

    assigns = assign(assigns, :alt, alt)

    ~H"""
    <picture>
      <%= for source <- @sources do %>
        <source
          media={source[:media]}
          srcset={PhxMediaLibrary.srcset(@media, source[:conversion])}
        />
      <% end %>
      <img
        src={PhxMediaLibrary.url(@media, @conversion)}
        srcset={PhxMediaLibrary.srcset(@media, @conversion)}
        alt={@alt}
        class={@class}
        {@rest}
      />
    </picture>
    """
  end

  # Private helpers

  defp placeholder_style(data_uri) do
    """
    background-image: url('#{data_uri}');
    background-size: cover;
    background-repeat: no-repeat;
    """
  end
end
