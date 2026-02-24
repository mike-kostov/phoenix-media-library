defmodule PhxMediaLibrary.CollectionTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Collection

  describe "new/2" do
    test "creates a collection with default values" do
      collection = Collection.new(:images)

      assert collection.name == :images
      assert collection.disk == nil
      assert collection.accepts == nil
      assert collection.single_file == false
      assert collection.max_files == nil
      assert collection.fallback_url == nil
      assert collection.fallback_path == nil
    end

    test "creates a collection with custom disk" do
      collection = Collection.new(:uploads, disk: :s3)

      assert collection.name == :uploads
      assert collection.disk == :s3
    end

    test "creates a collection with accepted mime types" do
      accepts = ~w(image/jpeg image/png image/gif)
      collection = Collection.new(:images, accepts: accepts)

      assert collection.accepts == accepts
    end

    test "creates a single file collection" do
      collection = Collection.new(:avatar, single_file: true)

      assert collection.name == :avatar
      assert collection.single_file == true
    end

    test "creates a collection with max files limit" do
      collection = Collection.new(:gallery, max_files: 10)

      assert collection.name == :gallery
      assert collection.max_files == 10
    end

    test "creates a collection with fallback URL" do
      collection =
        Collection.new(:avatar,
          fallback_url: "/images/default-avatar.png",
          fallback_path: "priv/static/images/default-avatar.png"
        )

      assert collection.fallback_url == "/images/default-avatar.png"
      assert collection.fallback_path == "priv/static/images/default-avatar.png"
    end

    test "creates a collection with all options" do
      collection =
        Collection.new(:documents,
          disk: :s3,
          accepts: ~w(application/pdf),
          single_file: false,
          max_files: 5,
          fallback_url: "/default.pdf"
        )

      assert collection.name == :documents
      assert collection.disk == :s3
      assert collection.accepts == ~w(application/pdf)
      assert collection.single_file == false
      assert collection.max_files == 5
      assert collection.fallback_url == "/default.pdf"
    end
  end

  describe "struct" do
    test "has correct struct keys" do
      collection = %Collection{}

      assert Map.has_key?(collection, :name)
      assert Map.has_key?(collection, :disk)
      assert Map.has_key?(collection, :accepts)
      assert Map.has_key?(collection, :single_file)
      assert Map.has_key?(collection, :max_files)
      assert Map.has_key?(collection, :fallback_url)
      assert Map.has_key?(collection, :fallback_path)
    end
  end
end
