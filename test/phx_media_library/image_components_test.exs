defmodule PhxMediaLibrary.ImageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhxMediaLibrary.{Media, ViewHelpers}

  defp media(attrs) do
    struct(
      %Media{
        id: Ecto.UUID.generate(),
        uuid: Ecto.UUID.generate(),
        collection_name: "images",
        file_name: "dress.jpg",
        mime_type: "image/jpeg",
        disk: "memory",
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate(),
        custom_properties: %{},
        metadata: %{"width" => 1200, "height" => 800},
        generated_conversions: %{},
        responsive_images: %{}
      },
      attrs
    )
  end

  describe "Media.dimensions/2" do
    test "uses the metadata for the original" do
      assert Media.dimensions(media(%{})) == {1200, 800}
    end

    test "uses the capped WebP size when that is what's served" do
      m =
        media(custom_properties: %{"webp" => "x.webp", "webp_width" => 600, "webp_height" => 400})

      assert Media.dimensions(m) == {600, 400}
    end

    test "uses the largest responsive variant for a conversion" do
      m =
        media(
          responsive_images: %{
            "preview" => %{
              "variants" => [
                %{"width" => 320, "height" => 213, "path" => "a"},
                %{"width" => 800, "height" => 533, "path" => "b"}
              ]
            }
          }
        )

      assert Media.dimensions(m, :preview) == {800, 533}
    end

    test "is nil when unknown" do
      assert Media.dimensions(media(metadata: %{})) == nil
      assert Media.dimensions(media(%{}), :thumb) == nil
    end
  end

  describe "width and height attributes" do
    test "media_img, responsive_img and picture output the served size" do
      for component <- [
            &ViewHelpers.media_img/1,
            &ViewHelpers.responsive_img/1,
            &ViewHelpers.picture/1
          ] do
        html = render_component(component, media: media(%{}))
        assert html =~ ~s(width="1200"), inspect(component)
        assert html =~ ~s(height="800"), inspect(component)
      end
    end

    test "explicit values win" do
      html =
        render_component(&ViewHelpers.media_img/1, media: media(%{}), width: 300, height: 200)

      assert html =~ ~s(width="300")
      assert html =~ ~s(height="200")
    end

    test "are left out when unknown" do
      html = render_component(&ViewHelpers.media_img/1, media: media(metadata: %{}))
      refute html =~ "width="
      refute html =~ "height="
    end
  end
end
