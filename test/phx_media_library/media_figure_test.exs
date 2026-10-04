defmodule PhxMediaLibrary.MediaFigureTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhxMediaLibrary.{Media, ViewHelpers}

  defp media(custom_properties \\ %{}) do
    %Media{
      uuid: "8f2c4d1e-0000-4000-8000-000000000000",
      collection_name: "images",
      file_name: "photo.jpg",
      mime_type: "image/jpeg",
      disk: "memory",
      mediable_type: "posts",
      mediable_id: "42",
      metadata: %{"width" => 1600, "height" => 1200},
      custom_properties: custom_properties,
      generated_conversions: %{"preview" => true},
      responsive_images: %{}
    }
  end

  defp render(assigns), do: render_component(&ViewHelpers.media_figure/1, assigns)

  test "renders a figure with the image and the caption attribute" do
    html = render(media: media(), caption: "A red <dress>")

    assert html =~ "<figure"
    assert html =~ "<img"
    assert html =~ ">A red &lt;dress&gt;</figcaption>"
  end

  test "uses custom_properties[\"caption\"] when no attribute is given" do
    assert render(media: media(%{"caption" => "Summer collection"})) =~
             ">Summer collection</figcaption>"
  end

  test "no caption, no figcaption" do
    html = render(media: media())
    assert html =~ "<figure"
    refute html =~ "figcaption"
  end

  test "image options reach the image" do
    html =
      render(media: media(), conversion: :preview, sizes: "50vw", priority: true, class: "w-full")

    [img] = Regex.run(~r/<img[^>]*>/, html)
    assert img =~ "_preview.jpg"
    assert img =~ ~s(class="w-full")
    assert img =~ ~s(fetchpriority="high")
    assert img =~ ~s(loading="eager")
  end

  test "figure_class and caption_class style the wrapper" do
    html = render(media: media(), caption: "C", figure_class: "my-8", caption_class: "text-sm")

    assert html =~ ~s(<figure class="my-8">)
    assert html =~ ~s(<figcaption class="text-sm">C</figcaption>)
  end
end
