defmodule PhxMediaLibraryTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Media, MediaAdder}

  describe "add/2" do
    test "creates a MediaAdder struct for a model and file path" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = PhxMediaLibrary.add(model, "/path/to/file.jpg")

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
    end

    test "creates a MediaAdder struct for a model and Plug.Upload" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      upload = %Plug.Upload{
        path: "/tmp/test.jpg",
        filename: "uploaded.jpg",
        content_type: "image/jpeg"
      }

      adder = PhxMediaLibrary.add(model, upload)

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == upload
    end
  end

  describe "add_from_url/2" do
    test "creates a MediaAdder struct with URL source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = PhxMediaLibrary.add_from_url(model, "https://example.com/image.jpg")

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == {:url, "https://example.com/image.jpg"}
    end
  end

  describe "using_filename/2" do
    test "sets custom filename on MediaAdder" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> PhxMediaLibrary.add("/path/to/file.jpg")
        |> PhxMediaLibrary.using_filename("custom-name.jpg")

      assert adder.custom_filename == "custom-name.jpg"
    end
  end

  describe "with_custom_properties/2" do
    test "sets custom properties on MediaAdder" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      properties = %{"alt" => "My image", "caption" => "A test"}

      adder =
        model
        |> PhxMediaLibrary.add("/path/to/file.jpg")
        |> PhxMediaLibrary.with_custom_properties(properties)

      assert adder.custom_properties == properties
    end
  end

  describe "with_responsive_images/1" do
    test "enables responsive images on MediaAdder" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> PhxMediaLibrary.add("/path/to/file.jpg")
        |> PhxMediaLibrary.with_responsive_images()

      assert adder.generate_responsive == true
    end
  end

  describe "url/2" do
    test "delegates to Media.url/2" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      # Just verify it doesn't raise - actual URL depends on config
      assert is_binary(PhxMediaLibrary.url(media))
    end
  end

  describe "srcset/2" do
    test "returns nil when no responsive images exist" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        responsive_images: %{},
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      assert PhxMediaLibrary.srcset(media) == nil
    end

    test "returns srcset string when responsive images exist" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        responsive_images: %{
          "original" => [
            %{"width" => 320, "path" => "images/test-uuid/responsive/test-320.jpg"},
            %{"width" => 640, "path" => "images/test-uuid/responsive/test-640.jpg"}
          ]
        },
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      srcset = PhxMediaLibrary.srcset(media)
      assert is_binary(srcset)
      assert srcset =~ "320w"
      assert srcset =~ "640w"
    end
  end

  describe "fluent API chaining" do
    test "supports full fluent chain" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> PhxMediaLibrary.add("/path/to/file.jpg")
        |> PhxMediaLibrary.using_filename("my-image.jpg")
        |> PhxMediaLibrary.with_custom_properties(%{"alt" => "Alt text"})
        |> PhxMediaLibrary.with_responsive_images()

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_filename == "my-image.jpg"
      assert adder.custom_properties == %{"alt" => "Alt text"}
      assert adder.generate_responsive == true
    end
  end
end
