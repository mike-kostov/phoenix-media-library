defmodule PhxMediaLibrary.MediaAdderTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.MediaAdder

  describe "new/2" do
    test "creates a MediaAdder struct with model and source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
    end

    test "initializes with empty custom_properties" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      assert adder.custom_properties == %{}
    end

    test "initializes generate_responsive as false" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      assert adder.generate_responsive == false
    end

    test "initializes custom_filename as nil" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      assert adder.custom_filename == nil
    end

    test "initializes disk as nil" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      assert adder.disk == nil
    end

    test "accepts URL tuple as source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, {:url, "https://example.com/image.jpg"})

      assert adder.source == {:url, "https://example.com/image.jpg"}
    end

    test "accepts URL tuple with options as source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      opts = [headers: [{"Authorization", "Bearer token"}], timeout: 5000]
      adder = MediaAdder.new(model, {:url, "https://example.com/image.jpg", opts})

      assert adder.source == {:url, "https://example.com/image.jpg", opts}
    end

    test "initializes extract_metadata based on global config" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      adder = MediaAdder.new(model, "/path/to/file.jpg")

      # Default is true (from MetadataExtractor.enabled?/0)
      assert adder.extract_metadata == true
    end

    test "accepts Plug.Upload as source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      upload = %Plug.Upload{
        path: "/tmp/test.jpg",
        filename: "uploaded.jpg",
        content_type: "image/jpeg"
      }

      adder = MediaAdder.new(model, upload)

      assert adder.source == upload
    end

    test "accepts map with path and filename as source" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      source = %{path: "/tmp/file.jpg", filename: "my-file.jpg"}

      adder = MediaAdder.new(model, source)

      assert adder.source == source
    end
  end

  describe "using_filename/2" do
    test "sets custom filename" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("custom-name.jpg")

      assert adder.custom_filename == "custom-name.jpg"
    end

    test "overwrites previous filename" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("first.jpg")
        |> MediaAdder.using_filename("second.jpg")

      assert adder.custom_filename == "second.jpg"
    end

    test "preserves other fields" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "test"})
        |> MediaAdder.using_filename("custom.jpg")

      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_properties == %{"alt" => "test"}
    end
  end

  describe "with_custom_properties/2" do
    test "sets custom properties" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}
      properties = %{"alt" => "My image", "caption" => "A test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.with_custom_properties(properties)

      assert adder.custom_properties == properties
    end

    test "merges multiple property calls" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "Alt text"})
        |> MediaAdder.with_custom_properties(%{"caption" => "Caption"})

      assert adder.custom_properties == %{"alt" => "Alt text", "caption" => "Caption"}
    end

    test "later values override earlier ones for same key" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "First"})
        |> MediaAdder.with_custom_properties(%{"alt" => "Second"})

      assert adder.custom_properties == %{"alt" => "Second"}
    end

    test "preserves other fields" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("custom.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "test"})

      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_filename == "custom.jpg"
    end
  end

  describe "with_responsive_images/1" do
    test "enables responsive images" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.with_responsive_images()

      assert adder.generate_responsive == true
    end

    test "preserves other fields" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("custom.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "test"})
        |> MediaAdder.with_responsive_images()

      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_filename == "custom.jpg"
      assert adder.custom_properties == %{"alt" => "test"}
    end
  end

  describe "without_metadata/1" do
    test "disables metadata extraction" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.without_metadata()

      assert adder.extract_metadata == false
    end

    test "preserves other fields" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("custom.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "test"})
        |> MediaAdder.with_responsive_images()
        |> MediaAdder.without_metadata()

      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_filename == "custom.jpg"
      assert adder.custom_properties == %{"alt" => "test"}
      assert adder.generate_responsive == true
      assert adder.extract_metadata == false
    end

    test "can be re-enabled by creating a new adder" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.without_metadata()

      assert adder.extract_metadata == false

      # New adder starts with extraction enabled
      adder2 = MediaAdder.new(model, "/path/to/other.jpg")
      assert adder2.extract_metadata == true
    end
  end

  describe "fluent API chaining" do
    test "supports full fluent chain" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("my-image.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "Alt text"})
        |> MediaAdder.with_custom_properties(%{"caption" => "Caption"})
        |> MediaAdder.with_responsive_images()

      assert %MediaAdder{} = adder
      assert adder.model == model
      assert adder.source == "/path/to/file.jpg"
      assert adder.custom_filename == "my-image.jpg"
      assert adder.custom_properties == %{"alt" => "Alt text", "caption" => "Caption"}
      assert adder.generate_responsive == true
      assert adder.extract_metadata == true
    end

    test "supports full fluent chain with metadata disabled" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("my-image.jpg")
        |> MediaAdder.with_custom_properties(%{"alt" => "Alt text"})
        |> MediaAdder.with_responsive_images()
        |> MediaAdder.without_metadata()

      assert %MediaAdder{} = adder
      assert adder.custom_filename == "my-image.jpg"
      assert adder.custom_properties == %{"alt" => "Alt text"}
      assert adder.generate_responsive == true
      assert adder.extract_metadata == false
    end

    test "order of chained calls doesn't matter" do
      model = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      adder1 =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.using_filename("name.jpg")
        |> MediaAdder.with_responsive_images()
        |> MediaAdder.with_custom_properties(%{"key" => "value"})
        |> MediaAdder.without_metadata()

      adder2 =
        model
        |> MediaAdder.new("/path/to/file.jpg")
        |> MediaAdder.without_metadata()
        |> MediaAdder.with_custom_properties(%{"key" => "value"})
        |> MediaAdder.using_filename("name.jpg")
        |> MediaAdder.with_responsive_images()

      assert adder1.custom_filename == adder2.custom_filename
      assert adder1.custom_properties == adder2.custom_properties
      assert adder1.generate_responsive == adder2.generate_responsive
      assert adder1.extract_metadata == adder2.extract_metadata
    end
  end

  describe "struct" do
    test "has correct struct keys" do
      adder = %MediaAdder{}

      assert Map.has_key?(adder, :model)
      assert Map.has_key?(adder, :source)
      assert Map.has_key?(adder, :custom_filename)
      assert Map.has_key?(adder, :custom_properties)
      assert Map.has_key?(adder, :generate_responsive)
      assert Map.has_key?(adder, :extract_metadata)
      assert Map.has_key?(adder, :disk)
    end

    test "default struct has nil values" do
      adder = %MediaAdder{}

      assert adder.model == nil
      assert adder.source == nil
      assert adder.custom_filename == nil
      assert adder.custom_properties == nil
      assert adder.generate_responsive == nil
      assert adder.extract_metadata == nil
      assert adder.disk == nil
    end
  end
end
