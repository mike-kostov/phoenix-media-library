defmodule PhxMediaLibrary.PathGeneratorTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Media, PathGenerator}

  describe "for_new_media/1" do
    test "generates path from attributes" do
      attrs = %{
        mediable_type: "posts",
        mediable_id: "123e4567-e89b-12d3-a456-426614174000",
        uuid: "abc-123",
        file_name: "test-image.jpg"
      }

      path = PathGenerator.for_new_media(attrs)

      assert path == "posts/123e4567-e89b-12d3-a456-426614174000/abc-123/test-image.jpg"
    end

    test "handles different mediable types" do
      attrs = %{
        mediable_type: "users",
        mediable_id: "user-456",
        uuid: "file-uuid",
        file_name: "avatar.png"
      }

      path = PathGenerator.for_new_media(attrs)

      assert path == "users/user-456/file-uuid/avatar.png"
    end

    test "preserves file extension" do
      attrs = %{
        mediable_type: "products",
        mediable_id: "prod-1",
        uuid: "uuid-1",
        file_name: "document.pdf"
      }

      path = PathGenerator.for_new_media(attrs)

      assert String.ends_with?(path, ".pdf")
    end
  end

  describe "relative_path/2" do
    test "generates path for original file (no conversion)" do
      media = %Media{
        uuid: "media-uuid-123",
        mediable_type: "posts",
        mediable_id: "post-id-456",
        file_name: "photo.jpg"
      }

      path = PathGenerator.relative_path(media)

      assert path == "posts/post-id-456/media-uuid-123/photo.jpg"
    end

    test "generates path for original file with nil conversion" do
      media = %Media{
        uuid: "media-uuid-123",
        mediable_type: "posts",
        mediable_id: "post-id-456",
        file_name: "photo.jpg"
      }

      path = PathGenerator.relative_path(media, nil)

      assert path == "posts/post-id-456/media-uuid-123/photo.jpg"
    end

    test "generates path for conversion as atom" do
      media = %Media{
        uuid: "media-uuid-123",
        mediable_type: "posts",
        mediable_id: "post-id-456",
        file_name: "photo.jpg"
      }

      path = PathGenerator.relative_path(media, :thumb)

      assert path == "posts/post-id-456/media-uuid-123/photo_thumb.jpg"
    end

    test "generates path for conversion as string" do
      media = %Media{
        uuid: "media-uuid-123",
        mediable_type: "posts",
        mediable_id: "post-id-456",
        file_name: "photo.jpg"
      }

      path = PathGenerator.relative_path(media, "preview")

      assert path == "posts/post-id-456/media-uuid-123/photo_preview.jpg"
    end

    test "preserves file extension in conversion path" do
      media = %Media{
        uuid: "uuid",
        mediable_type: "docs",
        mediable_id: "doc-1",
        file_name: "image.png"
      }

      path = PathGenerator.relative_path(media, :small)

      assert String.ends_with?(path, "_small.png")
    end

    test "handles files with multiple dots in name" do
      media = %Media{
        uuid: "uuid",
        mediable_type: "posts",
        mediable_id: "1",
        file_name: "my.photo.file.jpg"
      }

      path = PathGenerator.relative_path(media, :thumb)

      # Should append _thumb before the extension
      assert path == "posts/1/uuid/my.photo.file_thumb.jpg"
    end

    test "handles different file extensions" do
      for ext <- ~w(.jpg .png .gif .webp .pdf .docx) do
        media = %Media{
          uuid: "uuid",
          mediable_type: "files",
          mediable_id: "1",
          file_name: "document#{ext}"
        }

        original_path = PathGenerator.relative_path(media)
        assert String.ends_with?(original_path, ext)

        conversion_path = PathGenerator.relative_path(media, :converted)
        assert String.ends_with?(conversion_path, "_converted#{ext}")
      end
    end
  end

  describe "path structure" do
    test "uses mediable_type as first directory" do
      media = %Media{
        uuid: "uuid",
        mediable_type: "articles",
        mediable_id: "123",
        file_name: "test.jpg"
      }

      path = PathGenerator.relative_path(media)

      assert String.starts_with?(path, "articles/")
    end

    test "uses mediable_id as second directory" do
      media = %Media{
        uuid: "uuid",
        mediable_type: "posts",
        mediable_id: "custom-id-here",
        file_name: "test.jpg"
      }

      path = PathGenerator.relative_path(media)
      parts = String.split(path, "/")

      assert Enum.at(parts, 1) == "custom-id-here"
    end

    test "uses uuid as third directory" do
      media = %Media{
        uuid: "unique-file-uuid",
        mediable_type: "posts",
        mediable_id: "1",
        file_name: "test.jpg"
      }

      path = PathGenerator.relative_path(media)
      parts = String.split(path, "/")

      assert Enum.at(parts, 2) == "unique-file-uuid"
    end

    test "filename is last part of path" do
      media = %Media{
        uuid: "uuid",
        mediable_type: "posts",
        mediable_id: "1",
        file_name: "my-file.jpg"
      }

      path = PathGenerator.relative_path(media)

      assert String.ends_with?(path, "/my-file.jpg")
    end
  end
end
