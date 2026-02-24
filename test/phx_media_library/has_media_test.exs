defmodule PhxMediaLibrary.HasMediaTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Collection, Conversion}

  describe "using HasMedia" do
    test "TestPost has media_collections/0 function" do
      assert function_exported?(PhxMediaLibrary.TestPost, :media_collections, 0)
    end

    test "TestPost has media_conversions/0 function" do
      assert function_exported?(PhxMediaLibrary.TestPost, :media_conversions, 0)
    end

    test "TestPost has get_media_collection/1 function" do
      assert function_exported?(PhxMediaLibrary.TestPost, :get_media_collection, 1)
    end

    test "TestPost has get_media_conversions/0 function" do
      assert function_exported?(PhxMediaLibrary.TestPost, :get_media_conversions, 0)
    end

    test "TestPost has get_media_conversions/1 function" do
      assert function_exported?(PhxMediaLibrary.TestPost, :get_media_conversions, 1)
    end
  end

  describe "media_collections/0" do
    test "returns list of Collection structs" do
      collections = PhxMediaLibrary.TestPost.media_collections()

      assert is_list(collections)
      assert Enum.all?(collections, &match?(%Collection{}, &1))
    end

    test "returns configured collections" do
      collections = PhxMediaLibrary.TestPost.media_collections()
      collection_names = Enum.map(collections, & &1.name)

      assert :images in collection_names
      assert :documents in collection_names
      assert :avatar in collection_names
      assert :gallery in collection_names
    end
  end

  describe "media_conversions/0" do
    test "returns list of Conversion structs" do
      conversions = PhxMediaLibrary.TestPost.media_conversions()

      assert is_list(conversions)
      assert Enum.all?(conversions, &match?(%Conversion{}, &1))
    end

    test "returns configured conversions" do
      conversions = PhxMediaLibrary.TestPost.media_conversions()
      conversion_names = Enum.map(conversions, & &1.name)

      assert :thumb in conversion_names
      assert :preview in conversion_names
      assert :banner in conversion_names
    end
  end

  describe "get_media_collection/1" do
    test "returns collection by name" do
      collection = PhxMediaLibrary.TestPost.get_media_collection(:images)

      assert %Collection{name: :images} = collection
    end

    test "returns nil for unknown collection" do
      collection = PhxMediaLibrary.TestPost.get_media_collection(:unknown)

      assert collection == nil
    end

    test "returns collection with configured options" do
      collection = PhxMediaLibrary.TestPost.get_media_collection(:documents)

      assert collection.name == :documents
      assert collection.accepts == ~w(application/pdf text/plain)
    end

    test "returns single_file collection" do
      collection = PhxMediaLibrary.TestPost.get_media_collection(:avatar)

      assert collection.name == :avatar
      assert collection.single_file == true
    end

    test "returns collection with max_files" do
      collection = PhxMediaLibrary.TestPost.get_media_collection(:gallery)

      assert collection.name == :gallery
      assert collection.max_files == 5
    end
  end

  describe "get_media_conversions/1" do
    test "returns all conversions when no collection specified" do
      conversions = PhxMediaLibrary.TestPost.get_media_conversions()

      assert length(conversions) == 3
    end

    test "returns all conversions when collection is nil" do
      conversions = PhxMediaLibrary.TestPost.get_media_conversions(nil)

      assert length(conversions) == 3
    end

    test "filters conversions by collection" do
      conversions = PhxMediaLibrary.TestPost.get_media_conversions(:images)
      conversion_names = Enum.map(conversions, & &1.name)

      # thumb and preview have no collection restriction, banner is for :images
      assert :thumb in conversion_names
      assert :preview in conversion_names
      assert :banner in conversion_names
    end

    test "excludes conversions not for the collection" do
      # Banner is only for :images collection
      conversions = PhxMediaLibrary.TestPost.get_media_conversions(:documents)
      conversion_names = Enum.map(conversions, & &1.name)

      assert :thumb in conversion_names
      assert :preview in conversion_names
      refute :banner in conversion_names
    end
  end

  describe "collection/2 helper" do
    test "creates a Collection struct" do
      collection = PhxMediaLibrary.HasMedia.collection(:test)

      assert %Collection{name: :test} = collection
    end

    test "accepts options" do
      collection =
        PhxMediaLibrary.HasMedia.collection(:test,
          disk: :s3,
          accepts: ~w(image/png),
          single_file: true,
          max_files: 10
        )

      assert collection.name == :test
      assert collection.disk == :s3
      assert collection.accepts == ~w(image/png)
      assert collection.single_file == true
      assert collection.max_files == 10
    end
  end

  describe "conversion/2 helper" do
    test "creates a Conversion struct" do
      conversion = PhxMediaLibrary.HasMedia.conversion(:thumb, width: 100)

      assert %Conversion{name: :thumb} = conversion
      assert conversion.width == 100
    end

    test "accepts all conversion options" do
      conversion =
        PhxMediaLibrary.HasMedia.conversion(:full,
          width: 1920,
          height: 1080,
          fit: :cover,
          quality: 85,
          format: :webp,
          collections: [:images],
          queued: false
        )

      assert conversion.name == :full
      assert conversion.width == 1920
      assert conversion.height == 1080
      assert conversion.fit == :cover
      assert conversion.quality == 85
      assert conversion.format == :webp
      assert conversion.collections == [:images]
      assert conversion.queued == false
    end
  end

  describe "default implementations" do
    defmodule MinimalSchema do
      use Ecto.Schema
      use PhxMediaLibrary.HasMedia

      @primary_key {:id, :binary_id, autogenerate: true}
      schema "minimal" do
        field(:name, :string)
        has_media()
      end

      # Not overriding media_collections/0 or media_conversions/0
    end

    test "media_collections returns empty list by default" do
      assert MinimalSchema.media_collections() == []
    end

    test "media_conversions returns empty list by default" do
      assert MinimalSchema.media_conversions() == []
    end

    test "get_media_collection returns nil when no collections defined" do
      assert MinimalSchema.get_media_collection(:images) == nil
    end

    test "get_media_conversions returns empty list when no conversions defined" do
      assert MinimalSchema.get_media_conversions() == []
      assert MinimalSchema.get_media_conversions(:images) == []
    end
  end

  describe "overriding defaults" do
    defmodule CustomSchema do
      use Ecto.Schema
      use PhxMediaLibrary.HasMedia

      @primary_key {:id, :binary_id, autogenerate: true}
      schema "custom" do
        field(:title, :string)
        has_media()
      end

      def media_collections do
        [
          collection(:attachments, disk: :local)
        ]
      end

      def media_conversions do
        [
          conversion(:small, width: 200, height: 200)
        ]
      end
    end

    test "can override media_collections" do
      collections = CustomSchema.media_collections()

      assert length(collections) == 1
      assert hd(collections).name == :attachments
    end

    test "can override media_conversions" do
      conversions = CustomSchema.media_conversions()

      assert length(conversions) == 1
      assert hd(conversions).name == :small
    end
  end
end
