defmodule PhxMediaLibrary.ComponentsRenderTest do
  # What the shipped components render.
  use PhxMediaLibrary.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Components, ComponentsLive, Media}

  @moduletag :db
  @endpoint PhxMediaLibrary.TestEndpoint

  defp media(attrs),
    do:
      struct(
        Media,
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            uuid: Ecto.UUID.generate(),
            mediable_type: "posts",
            mediable_id: "1",
            collection_name: "images",
            disk: "memory",
            metadata: %{},
            custom_properties: %{},
            responsive_images: %{},
            generated_conversions: %{}
          },
          attrs
        )
      )

  describe "<.media_upload> and <.media_upload_button>" do
    test "render the drop zone, the file input and the button" do
      {:ok, _view, html} =
        live_isolated(build_conn(), ComponentsLive,
          session: %{"opts" => %{"label" => "Drop files"}}
        )

      assert html =~ "phx-drop-target"
      assert html =~ ~s(type="file")
      assert html =~ "Pick a file"
    end

    test "list entries with their size and a cancel button; refusals show their error" do
      {:ok, view, _html} = live_isolated(build_conn(), ComponentsLive)

      input =
        file_input(view, "#form", :files, [
          %{name: "a.txt", content: "aaa", type: "text/plain"},
          %{name: "b.png", content: "png", type: "image/png"}
        ])

      render_upload(input, "a.txt")
      html = render(view)

      assert html =~ "a.txt"
      assert html =~ ~s(phx-click="cancel_upload")
      assert html =~ "b.png"
      assert html =~ ~r/not accepted|isn't accepted|not allowed/i

      [%{"ref" => ref} | _] = input.entries
      view |> element(~s([phx-click="cancel_upload"][phx-value-ref="#{ref}"])) |> render_click()
      refute render(view) =~ "a.txt"
    end

    test "compact and disabled layouts" do
      {:ok, _view, html} =
        live_isolated(build_conn(), ComponentsLive,
          session: %{"opts" => %{"compact" => true, "disabled" => true}}
        )

      assert html =~ "cursor-not-allowed"
      assert html =~ ~s(tabindex="-1")
      refute html =~ "min-h-[180px]"
    end
  end

  describe "<.media_gallery>" do
    test "renders each item with a delete button, in the given columns" do
      items = [
        media(%{file_name: "a.pdf", mime_type: "application/pdf"}),
        media(%{file_name: "b.txt", mime_type: "text/plain"})
      ]

      html =
        render_component(&Components.media_gallery/1,
          id: "g",
          media: Enum.map(items, &{"media-#{&1.id}", &1}),
          columns: 3,
          confirm_message: "Sure?"
        )

      for item <- items do
        assert html =~ ~s(id="media-#{item.id}")
        assert html =~ ~s(aria-label="Delete #{item.file_name}")
      end

      assert html =~ ~s(data-confirm="Sure?")
      assert html =~ "lg:grid-cols-3"
    end

    test "shows the empty slot without items" do
      html =
        render_component(&Components.media_gallery/1,
          id: "g",
          media: [],
          empty: [%{inner_block: fn _, _ -> "Nothing yet" end}]
        )

      assert html =~ "Nothing yet"
    end
  end

  describe "<.media_video>" do
    test "plays the file with its poster and shows its metadata" do
      video =
        media(%{
          file_name: "clip.mp4",
          mime_type: "video/mp4",
          metadata: %{
            "duration" => 75.4,
            "width" => 1280,
            "height" => 720,
            "codec" => "h264",
            "fps" => 29.97
          },
          responsive_images: %{"poster" => %{"url" => "/posters/clip.jpg"}}
        })

      html =
        render_component(&Components.media_video/1, media: video, autoplay: true, muted: true)

      assert html =~ ~s(type="video/mp4")
      assert html =~ ~s(poster="/posters/clip.jpg")
      assert html =~ "1:15"
      assert html =~ "1280×720"
      assert html =~ "h264"
      assert html =~ "autoplay"
    end
  end

  describe "<.blurhash>" do
    test "a canvas carrying the hash, sized as asked" do
      item =
        media(%{
          file_name: "a.jpg",
          mime_type: "image/jpeg",
          responsive_images: %{"blurhash" => "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}
        })

      html = render_component(&Components.blurhash/1, media: item, width: 40, height: 30)

      assert html =~ ~s(data-hash="LEHV6nWB2yk8pyo0adR*.7kCMdnj")
      assert html =~ ~s(width="40")
      assert html =~ "aspect-ratio: 40 / 30"
    end

    test "nothing without a hash" do
      html =
        render_component(&Components.blurhash/1,
          media: media(%{file_name: "a.jpg", mime_type: "image/jpeg"})
        )

      refute html =~ "<canvas"
    end
  end

  _ = &create_test_post/0
end
