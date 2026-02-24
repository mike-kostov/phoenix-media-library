defmodule PhxMediaLibrary.MediaTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Media

  describe "changeset/2" do
    test "valid attributes create a valid changeset" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "images",
        name: "test-image",
        file_name: "test-image.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 1024,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?
    end

    test "requires all mandatory fields" do
      changeset = Media.changeset(%Media{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.uuid
      # collection_name has a default value so it won't be in errors
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.file_name
      assert "can't be blank" in errors.mime_type
      assert "can't be blank" in errors.disk
      assert "can't be blank" in errors.size
      assert "can't be blank" in errors.mediable_type
      assert "can't be blank" in errors.mediable_id
    end

    test "sets default values" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "default",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 100,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?

      media = Ecto.Changeset.apply_changes(changeset)
      assert media.custom_properties == %{}
      assert media.generated_conversions == %{}
      assert media.responsive_images == %{}
    end

    test "accepts optional fields" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 100,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate(),
        custom_properties: %{"alt" => "Test image"},
        order_column: 5
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?

      media = Ecto.Changeset.apply_changes(changeset)
      assert media.custom_properties == %{"alt" => "Test image"}
      assert media.order_column == 5
    end

    test "accepts generated_conversions map" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 100,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate(),
        generated_conversions: %{"thumb" => true, "preview" => true}
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?

      media = Ecto.Changeset.apply_changes(changeset)
      assert media.generated_conversions == %{"thumb" => true, "preview" => true}
    end

    test "accepts responsive_images map" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 100,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate(),
        responsive_images: %{
          "original" => [
            %{"width" => 320, "path" => "images/uuid/responsive/test-320.jpg"}
          ]
        }
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?

      media = Ecto.Changeset.apply_changes(changeset)
      assert Map.has_key?(media.responsive_images, "original")
    end
  end

  describe "has_conversion?/2" do
    test "returns true when conversion exists" do
      media = %Media{generated_conversions: %{"thumb" => true, "preview" => true}}

      assert Media.has_conversion?(media, :thumb)
      assert Media.has_conversion?(media, "thumb")
      assert Media.has_conversion?(media, :preview)
    end

    test "returns false when conversion does not exist" do
      media = %Media{generated_conversions: %{"thumb" => true}}

      refute Media.has_conversion?(media, :preview)
      refute Media.has_conversion?(media, :banner)
    end

    test "returns false when generated_conversions is empty" do
      media = %Media{generated_conversions: %{}}

      refute Media.has_conversion?(media, :thumb)
    end

    test "returns false when conversion value is false" do
      media = %Media{generated_conversions: %{"thumb" => false}}

      refute Media.has_conversion?(media, :thumb)
    end
  end

  describe "url/2" do
    test "generates URL for media" do
      media = %Media{
        uuid: "test-uuid-123",
        disk: "memory",
        collection_name: "images",
        name: "test-image",
        file_name: "test-image.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      url = Media.url(media)
      assert is_binary(url)
      assert url =~ "test-uuid-123"
    end

    test "generates URL for conversion" do
      media = %Media{
        uuid: "test-uuid-123",
        disk: "memory",
        collection_name: "images",
        name: "test-image",
        file_name: "test-image.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        generated_conversions: %{"thumb" => true},
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      url = Media.url(media, :thumb)
      assert is_binary(url)
      assert url =~ "thumb"
    end
  end

  describe "srcset/2" do
    test "returns nil when no responsive images exist" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        responsive_images: %{},
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      assert Media.srcset(media) == nil
    end

    test "returns nil when conversion has no responsive images" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        responsive_images: %{
          "original" => [%{"width" => 320, "path" => "path/320.jpg"}]
        },
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      assert Media.srcset(media, :thumb) == nil
    end

    test "returns srcset string for original" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        responsive_images: %{
          "original" => [
            %{"width" => 320, "path" => "images/uuid/responsive/test-320.jpg"},
            %{"width" => 640, "path" => "images/uuid/responsive/test-640.jpg"}
          ]
        },
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      srcset = Media.srcset(media)
      assert is_binary(srcset)
      assert srcset =~ "320w"
      assert srcset =~ "640w"
    end

    test "returns srcset string for conversion" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        responsive_images: %{
          "thumb" => [
            %{"width" => 150, "path" => "images/uuid/responsive/thumb-150.jpg"},
            %{"width" => 300, "path" => "images/uuid/responsive/thumb-300.jpg"}
          ]
        },
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      srcset = Media.srcset(media, :thumb)
      assert is_binary(srcset)
      assert srcset =~ "150w"
      assert srcset =~ "300w"
    end
  end

  describe "struct" do
    test "has correct struct keys" do
      media = %Media{}

      assert Map.has_key?(media, :id)
      assert Map.has_key?(media, :uuid)
      assert Map.has_key?(media, :collection_name)
      assert Map.has_key?(media, :name)
      assert Map.has_key?(media, :file_name)
      assert Map.has_key?(media, :mime_type)
      assert Map.has_key?(media, :disk)
      assert Map.has_key?(media, :size)
      assert Map.has_key?(media, :custom_properties)
      assert Map.has_key?(media, :generated_conversions)
      assert Map.has_key?(media, :responsive_images)
      assert Map.has_key?(media, :order_column)
      assert Map.has_key?(media, :mediable_type)
      assert Map.has_key?(media, :mediable_id)
    end

    test "has default values" do
      media = %Media{}

      assert media.collection_name == "default"
      assert media.custom_properties == %{}
      assert media.generated_conversions == %{}
      assert media.responsive_images == %{}
    end
  end

  # Helper to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
