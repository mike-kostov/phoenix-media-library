defmodule PhxMediaLibrary.PlaceholderComponentsTest do
  use PhxMediaLibrary.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, ViewHelpers}

  @blur %{"data_uri" => "data:image/webp;base64,UklGRg==", "width" => 16, "height" => 12}

  defp media(responsive) do
    %Media{
      uuid: "8f2c4d1e-0000-4000-8000-000000000000",
      collection_name: "images",
      file_name: "photo.jpg",
      mime_type: "image/jpeg",
      disk: "memory",
      mediable_type: "posts",
      mediable_id: "42",
      metadata: %{"width" => 1600, "height" => 1200},
      custom_properties: %{},
      generated_conversions: %{"thumb" => true},
      responsive_images: responsive
    }
  end

  defp blur, do: media(%{"original" => %{"placeholder" => @blur}})
  defp color, do: media(%{"original" => %{"placeholder" => %{"color" => "#a1b2c3"}}})
  defp none, do: media(%{})

  for component <- [:media_img, :responsive_img, :picture] do
    describe "<.#{component}>" do
      test "renders the blur placeholder" do
        html = render_component(&apply(ViewHelpers, unquote(component), [&1]), media: blur())
        assert html =~ "background-image: url(&#39;data:image/webp;base64,UklGRg==&#39;)"
      end

      test "renders the color placeholder" do
        html = render_component(&apply(ViewHelpers, unquote(component), [&1]), media: color())
        assert html =~ "background-color: #a1b2c3"
      end

      test "renders none without one" do
        html = render_component(&apply(ViewHelpers, unquote(component), [&1]), media: none())
        refute html =~ "background"
      end
    end
  end

  test "a conversion without its own placeholder uses the original's" do
    assert ViewHelpers.placeholder_style(color(), :thumb) =~ "#a1b2c3"
  end

  test "the gallery card renders the placeholder" do
    html =
      render_component(&PhxMediaLibrary.Components.media_gallery/1,
        id: "gallery",
        media: [{"media-1", color()}]
      )

    assert html =~ "background-color: #a1b2c3"
  end

  describe "tiny_placeholder: false, the setting before 0.9" do
    @describetag :db

    test "turns placeholders off" do
      previous = Application.get_env(:phx_media_library, :responsive_images)
      on_exit(fn -> Application.put_env(:phx_media_library, :responsive_images, previous) end)
      Application.put_env(:phx_media_library, :responsive_images, tiny_placeholder: false)

      png = create_temp_image(width: 40, height: 30)
      on_exit(fn -> File.rm(png) end)

      {:ok, media} =
        create_test_post() |> PhxMediaLibrary.add(png) |> PhxMediaLibrary.to_collection(:images)

      media = TestRepo.get!(Media, media.id)
      on_exit(fn -> Media.delete_files(media) end)
      refute get_in(media.responsive_images, ["original", "placeholder"])
    end
  end
end
