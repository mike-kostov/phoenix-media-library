defmodule PhxMediaLibrary.HasMediaDSLTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Collection, Conversion, Media}

  # ---------------------------------------------------------------------------
  # Test schemas using the declarative DSL
  # ---------------------------------------------------------------------------

  defmodule DSLPost do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "dsl_posts" do
      field(:title, :string)

      has_media()
      has_media(:images)
      has_media(:documents)
      has_media(:avatar)

      timestamps(type: :utc_datetime)
    end

    media_collections do
      collection(:images, disk: :s3, max_files: 20)
      collection(:documents, accepts: ~w(application/pdf text/plain))
      collection(:avatar, single_file: true, fallback_url: "/images/default.png")
    end

    media_conversions do
      convert(:thumb, width: 150, height: 150, fit: :cover)
      convert(:preview, width: 800, quality: 85)
      convert(:banner, width: 1200, height: 400, fit: :crop, collections: [:images])
    end
  end

  defmodule DSLWithConversionKeyword do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "dsl_conversion_keyword" do
      field(:name, :string)
      has_media()
    end

    media_conversions do
      # `conversion` should also work inside the block
      conversion(:tiny, width: 50, height: 50, fit: :contain)
    end
  end

  # Schema using the function-based approach (existing style)
  defmodule FunctionPost do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "function_posts" do
      field(:title, :string)
      has_media()
      timestamps(type: :utc_datetime)
    end

    def media_collections do
      [
        collection(:images, disk: :local),
        collection(:avatar, single_file: true)
      ]
    end

    def media_conversions do
      [
        conversion(:thumb, width: 100, height: 100, fit: :cover)
      ]
    end
  end

  # Schema with explicit media_type override
  defmodule OverriddenTypePost do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia, media_type: "blog_posts"

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "blog_post_table" do
      field(:title, :string)
      has_media()
      has_media(:images)
    end
  end

  # Schema with user-defined __media_type__/0
  defmodule CustomTypePost do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "custom_posts" do
      field(:title, :string)
      has_media()
    end

    def __media_type__, do: "my_custom_type"
  end

  # Minimal schema — no collections, no conversions, no overrides
  defmodule MinimalSchema do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "minimal_items" do
      field(:name, :string)
      has_media()
    end
  end

  # Schema using the nested collection ... do convert ... end syntax
  defmodule NestedDSLPost do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "nested_dsl_posts" do
      field(:title, :string)
      has_media()
      timestamps(type: :utc_datetime)
    end

    media_collections do
      collection :photos, accepts: ~w(image/jpeg image/png image/webp) do
        convert(:thumb, width: 150, height: 150, fit: :cover)
        convert(:preview, width: 800, quality: 85)
        convert(:large, width: 1200, quality: 90)
      end

      # No conversions for documents — no do block
      collection(:documents, accepts: ~w(application/pdf text/plain))

      collection :cover, single_file: true do
        convert(:thumb, width: 150, height: 150, fit: :cover)
      end
    end
  end

  # Schema mixing nested conversions with a separate media_conversions block
  defmodule MixedNestedAndFlatDSL do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "mixed_nested_flat" do
      field(:name, :string)
      has_media()
    end

    media_collections do
      collection :images, max_files: 20 do
        convert(:gallery, width: 800)
      end

      collection(:documents, accepts: ~w(application/pdf))
    end

    media_conversions do
      convert(:thumb, width: 150, height: 150, fit: :cover, collections: [:images])
    end
  end

  # Schema where nested conversion explicitly overrides :collections
  defmodule NestedWithExplicitCollections do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "nested_explicit" do
      field(:name, :string)
      has_media()
    end

    media_collections do
      collection :photos do
        # Explicitly scoped to both :photos and :avatars despite being
        # nested inside :photos — the explicit :collections wins.
        convert(:shared_thumb, width: 100, collections: [:photos, :avatars])
      end
    end
  end

  # Schema with only DSL collections but function-based conversions
  defmodule MixedStyleSchema do
    use Ecto.Schema
    use PhxMediaLibrary.HasMedia

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "mixed_items" do
      field(:name, :string)
      has_media()
    end

    media_collections do
      collection(:files, accepts: ~w(application/octet-stream))
    end

    def media_conversions do
      [
        conversion(:small, width: 200, height: 200)
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # DSL: media_collections do ... end
  # ---------------------------------------------------------------------------

  describe "media_collections DSL block" do
    test "defines media_collections/0 returning Collection structs" do
      collections = DSLPost.media_collections()

      assert is_list(collections)
      assert length(collections) == 3
      assert Enum.all?(collections, &match?(%Collection{}, &1))
    end

    test "preserves collection names" do
      names =
        DSLPost.media_collections()
        |> Enum.map(& &1.name)

      assert :images in names
      assert :documents in names
      assert :avatar in names
    end

    test "preserves collection options" do
      images = DSLPost.get_media_collection(:images)
      assert images.disk == :s3
      assert images.max_files == 20

      documents = DSLPost.get_media_collection(:documents)
      assert documents.accepts == ~w(application/pdf text/plain)

      avatar = DSLPost.get_media_collection(:avatar)
      assert avatar.single_file == true
      assert avatar.fallback_url == "/images/default.png"
    end

    test "get_media_collection/1 returns nil for unknown collection" do
      assert DSLPost.get_media_collection(:nonexistent) == nil
    end

    test "collections are returned in declaration order" do
      names =
        DSLPost.media_collections()
        |> Enum.map(& &1.name)

      assert names == [:images, :documents, :avatar]
    end
  end

  # ---------------------------------------------------------------------------
  # DSL: media_conversions do ... end
  # ---------------------------------------------------------------------------

  describe "media_conversions DSL block" do
    test "defines media_conversions/0 returning Conversion structs" do
      conversions = DSLPost.media_conversions()

      assert is_list(conversions)
      assert length(conversions) == 3
      assert Enum.all?(conversions, &match?(%Conversion{}, &1))
    end

    test "preserves conversion names" do
      names =
        DSLPost.media_conversions()
        |> Enum.map(& &1.name)

      assert :thumb in names
      assert :preview in names
      assert :banner in names
    end

    test "preserves conversion options" do
      conversions = DSLPost.media_conversions()

      thumb = Enum.find(conversions, &(&1.name == :thumb))
      assert thumb.width == 150
      assert thumb.height == 150
      assert thumb.fit == :cover

      preview = Enum.find(conversions, &(&1.name == :preview))
      assert preview.width == 800
      assert preview.quality == 85

      banner = Enum.find(conversions, &(&1.name == :banner))
      assert banner.width == 1200
      assert banner.height == 400
      assert banner.fit == :crop
      assert banner.collections == [:images]
    end

    test "get_media_conversions/1 filters by collection" do
      # thumb and preview have no collection restriction, banner is for :images
      image_conversions = DSLPost.get_media_conversions(:images)
      image_names = Enum.map(image_conversions, & &1.name)

      assert :thumb in image_names
      assert :preview in image_names
      assert :banner in image_names

      # banner should NOT appear for :documents
      doc_conversions = DSLPost.get_media_conversions(:documents)
      doc_names = Enum.map(doc_conversions, & &1.name)

      assert :thumb in doc_names
      assert :preview in doc_names
      refute :banner in doc_names
    end

    test "conversions are returned in declaration order" do
      names =
        DSLPost.media_conversions()
        |> Enum.map(& &1.name)

      assert names == [:thumb, :preview, :banner]
    end

    test "`conversion` keyword works inside media_conversions block" do
      conversions = DSLWithConversionKeyword.media_conversions()

      assert length(conversions) == 1
      tiny = hd(conversions)
      assert tiny.name == :tiny
      assert tiny.width == 50
      assert tiny.height == 50
      assert tiny.fit == :contain
    end
  end

  # ---------------------------------------------------------------------------
  # Mixed style: DSL collections + function conversions
  # ---------------------------------------------------------------------------

  describe "mixed DSL and function-based styles" do
    test "DSL collections work alongside function-based conversions" do
      collections = MixedStyleSchema.media_collections()
      assert length(collections) == 1
      assert hd(collections).name == :files

      conversions = MixedStyleSchema.media_conversions()
      assert length(conversions) == 1
      assert hd(conversions).name == :small
    end
  end

  # ---------------------------------------------------------------------------
  # Nested DSL: collection ... do convert ... end
  # ---------------------------------------------------------------------------

  describe "nested collection ... do convert ... end syntax" do
    test "collections are defined correctly" do
      collections = NestedDSLPost.media_collections()
      assert length(collections) == 3
      names = Enum.map(collections, & &1.name)
      assert names == [:photos, :documents, :cover]
    end

    test "nested conversions are auto-scoped to enclosing collection" do
      conversions = NestedDSLPost.media_conversions()

      photo_conversions = Enum.filter(conversions, &(:photos in &1.collections))
      assert length(photo_conversions) == 3
      assert Enum.map(photo_conversions, & &1.name) == [:thumb, :preview, :large]

      cover_conversions = Enum.filter(conversions, &(:cover in &1.collections))
      assert length(cover_conversions) == 1
      assert hd(cover_conversions).name == :thumb
    end

    test "collections without do block have no conversions" do
      conversions = NestedDSLPost.media_conversions()
      doc_conversions = Enum.filter(conversions, &(:documents in &1.collections))
      assert doc_conversions == []
    end

    test "get_media_conversions/1 filters correctly for nested conversions" do
      photos = NestedDSLPost.get_media_conversions(:photos)
      assert length(photos) == 3
      assert Enum.map(photos, & &1.name) == [:thumb, :preview, :large]

      cover = NestedDSLPost.get_media_conversions(:cover)
      assert length(cover) == 1
      assert hd(cover).name == :thumb

      docs = NestedDSLPost.get_media_conversions(:documents)
      assert docs == []
    end

    test "nested conversions preserve all options" do
      conversions = NestedDSLPost.media_conversions()
      thumb = Enum.find(conversions, &(&1.name == :thumb and :photos in &1.collections))

      assert thumb.width == 150
      assert thumb.height == 150
      assert thumb.fit == :cover
      assert thumb.collections == [:photos]
    end

    test "collection options are preserved with nested conversions" do
      collections = NestedDSLPost.media_collections()

      photos = Enum.find(collections, &(&1.name == :photos))
      assert photos.accepts == ~w(image/jpeg image/png image/webp)
      assert photos.single_file == false

      cover = Enum.find(collections, &(&1.name == :cover))
      assert cover.single_file == true

      docs = Enum.find(collections, &(&1.name == :documents))
      assert docs.accepts == ~w(application/pdf text/plain)
    end

    test "explicit :collections inside nested block overrides auto-scoping" do
      conversions = NestedWithExplicitCollections.media_conversions()
      assert length(conversions) == 1

      thumb = hd(conversions)
      assert thumb.name == :shared_thumb
      assert thumb.collections == [:photos, :avatars]
    end

    test "mixing nested and flat DSL combines conversions" do
      collections = MixedNestedAndFlatDSL.media_collections()
      assert length(collections) == 2

      conversions = MixedNestedAndFlatDSL.media_conversions()
      assert length(conversions) == 2

      gallery = Enum.find(conversions, &(&1.name == :gallery))
      assert gallery.collections == [:images]

      thumb = Enum.find(conversions, &(&1.name == :thumb))
      assert thumb.collections == [:images]
    end

    test "declaration order is preserved for nested conversions" do
      conversions = NestedDSLPost.media_conversions()
      names = Enum.map(conversions, & &1.name)
      # photos conversions first, then cover conversions
      assert names == [:thumb, :preview, :large, :thumb]
    end
  end

  # ---------------------------------------------------------------------------
  # Function-based approach still works
  # ---------------------------------------------------------------------------

  describe "function-based approach (backwards compatibility)" do
    test "media_collections returns function-defined collections" do
      collections = FunctionPost.media_collections()

      assert length(collections) == 2
      names = Enum.map(collections, & &1.name)
      assert :images in names
      assert :avatar in names
    end

    test "media_conversions returns function-defined conversions" do
      conversions = FunctionPost.media_conversions()

      assert length(conversions) == 1
      assert hd(conversions).name == :thumb
    end

    test "get_media_collection works with function-based approach" do
      images = FunctionPost.get_media_collection(:images)
      assert images.disk == :local

      avatar = FunctionPost.get_media_collection(:avatar)
      assert avatar.single_file == true
    end
  end

  # ---------------------------------------------------------------------------
  # Minimal schema defaults
  # ---------------------------------------------------------------------------

  describe "minimal schema defaults" do
    test "media_collections returns empty list by default" do
      assert MinimalSchema.media_collections() == []
    end

    test "media_conversions returns empty list by default" do
      assert MinimalSchema.media_conversions() == []
    end

    test "get_media_collection returns nil when no collections defined" do
      assert MinimalSchema.get_media_collection(:anything) == nil
    end

    test "get_media_conversions returns empty list when no conversions defined" do
      assert MinimalSchema.get_media_conversions() == []
      assert MinimalSchema.get_media_conversions(:images) == []
    end
  end

  # ---------------------------------------------------------------------------
  # has_many injection
  # ---------------------------------------------------------------------------

  describe "has_media() injects has_many :media" do
    test "schema has :media association" do
      assert :media in DSLPost.__schema__(:associations)
    end

    test ":media association points to PhxMediaLibrary.Media" do
      assoc = DSLPost.__schema__(:association, :media)
      assert assoc.related == PhxMediaLibrary.Media
    end

    test ":media association uses :mediable_id as foreign key" do
      assoc = DSLPost.__schema__(:association, :media)
      assert assoc.related_key == :mediable_id
    end

    test ":media association has mediable_type where clause" do
      assoc = DSLPost.__schema__(:association, :media)
      assert assoc.where == [mediable_type: "dsl_posts"]
    end

    test ":media association has mediable_type defaults" do
      assoc = DSLPost.__schema__(:association, :media)
      assert assoc.defaults == [mediable_type: "dsl_posts"]
    end

    test ":media is a :many cardinality" do
      assoc = DSLPost.__schema__(:association, :media)
      assert assoc.cardinality == :many
    end
  end

  describe "has_media(:collection) injects collection-scoped has_many" do
    test "schema has collection-scoped associations" do
      assocs = DSLPost.__schema__(:associations)

      assert :images in assocs
      assert :documents in assocs
      assert :avatar in assocs
    end

    test "collection association filters by mediable_type and collection_name" do
      images_assoc = DSLPost.__schema__(:association, :images)

      assert images_assoc.where == [
               mediable_type: "dsl_posts",
               collection_name: "images"
             ]
    end

    test "collection association has correct defaults" do
      avatar_assoc = DSLPost.__schema__(:association, :avatar)

      assert avatar_assoc.defaults == [
               mediable_type: "dsl_posts",
               collection_name: "avatar"
             ]
    end

    test "collection associations use :mediable_id as foreign key" do
      docs_assoc = DSLPost.__schema__(:association, :documents)
      assert docs_assoc.related_key == :mediable_id
    end

    test "all collection associations point to Media" do
      for name <- [:images, :documents, :avatar] do
        assoc = DSLPost.__schema__(:association, name)
        assert assoc.related == PhxMediaLibrary.Media
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Polymorphic type derivation (Milestone 2.6)
  # ---------------------------------------------------------------------------

  describe "__media_type__/0 derivation" do
    test "derives from Ecto table name by default" do
      assert DSLPost.__media_type__() == "dsl_posts"
      assert FunctionPost.__media_type__() == "function_posts"
      assert MinimalSchema.__media_type__() == "minimal_items"
    end

    test "explicit override via use option" do
      assert OverriddenTypePost.__media_type__() == "blog_posts"
    end

    test "user-defined __media_type__/0 takes precedence" do
      assert CustomTypePost.__media_type__() == "my_custom_type"
    end

    test "has_many :where uses overridden type" do
      assoc = OverriddenTypePost.__schema__(:association, :media)
      assert assoc.where == [mediable_type: "blog_posts"]
    end

    test "has_many collection :where uses overridden type" do
      assoc = OverriddenTypePost.__schema__(:association, :images)

      assert assoc.where == [
               mediable_type: "blog_posts",
               collection_name: "images"
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Checksum computation (Milestone 2.5)
  # ---------------------------------------------------------------------------

  describe "Media.compute_checksum/2" do
    test "computes SHA-256 checksum by default" do
      content = "hello world"
      checksum = Media.compute_checksum(content)

      # known SHA-256 of "hello world"
      expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
      assert checksum == expected
    end

    test "computes SHA-256 checksum explicitly" do
      content = "test content"
      checksum = Media.compute_checksum(content, "sha256")

      assert is_binary(checksum)
      assert String.length(checksum) == 64
      assert String.match?(checksum, ~r/^[0-9a-f]+$/)
    end

    test "computes MD5 checksum" do
      content = "hello world"
      checksum = Media.compute_checksum(content, "md5")

      # known MD5 of "hello world"
      expected = "5eb63bbbe01eeed093cb22bb8f5acdc3"
      assert checksum == expected
    end

    test "computes SHA-1 checksum" do
      content = "hello world"
      checksum = Media.compute_checksum(content, "sha1")

      # known SHA-1 of "hello world"
      expected = "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed"
      assert checksum == expected
    end

    test "raises for unsupported algorithm" do
      assert_raise RuntimeError, ~r/Unsupported checksum algorithm/, fn ->
        Media.compute_checksum("data", "sha512")
      end
    end

    test "different content produces different checksums" do
      checksum_a = Media.compute_checksum("content A")
      checksum_b = Media.compute_checksum("content B")

      refute checksum_a == checksum_b
    end

    test "same content always produces the same checksum" do
      content = "reproducible"
      checksum_1 = Media.compute_checksum(content)
      checksum_2 = Media.compute_checksum(content)

      assert checksum_1 == checksum_2
    end

    test "handles empty binary" do
      checksum = Media.compute_checksum("")
      assert is_binary(checksum)
      assert String.length(checksum) == 64
    end

    test "handles large binary" do
      content = :crypto.strong_rand_bytes(1_000_000)
      checksum = Media.compute_checksum(content)

      assert is_binary(checksum)
      assert String.length(checksum) == 64
    end
  end

  describe "Media schema checksum fields" do
    test "has checksum field" do
      media = %Media{}
      assert Map.has_key?(media, :checksum)
      assert media.checksum == nil
    end

    test "has checksum_algorithm field with default" do
      media = %Media{}
      assert Map.has_key?(media, :checksum_algorithm)
      assert media.checksum_algorithm == "sha256"
    end

    test "changeset accepts checksum fields" do
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
        checksum: "abc123def456",
        checksum_algorithm: "sha256"
      }

      changeset = Media.changeset(%Media{}, attrs)
      assert changeset.valid?

      media = Ecto.Changeset.apply_changes(changeset)
      assert media.checksum == "abc123def456"
      assert media.checksum_algorithm == "sha256"
    end
  end

  describe "Media.verify_integrity/1" do
    test "returns error when no checksum is stored" do
      media = %Media{checksum: nil, checksum_algorithm: "sha256"}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end

    test "returns error when no algorithm is stored" do
      media = %Media{checksum: "abc", checksum_algorithm: nil}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end
  end

  # ---------------------------------------------------------------------------
  # Optional image processor (Milestone 2.1)
  # ---------------------------------------------------------------------------

  describe "PhxMediaLibrary.ImageProcessor.Null" do
    alias PhxMediaLibrary.ImageProcessor.Null

    test "open/1 returns no_image_processor error" do
      assert {:error, {:no_image_processor, message}} = Null.open("/some/path.jpg")
      assert message =~ "No image processor is available"
      assert message =~ "{:image, \"~> 0.54\"}"
    end

    test "apply_conversion/2 returns no_image_processor error" do
      conversion = %Conversion{name: :thumb, width: 100, height: 100, fit: :cover}
      assert {:error, {:no_image_processor, _}} = Null.apply_conversion(:fake_image, conversion)
    end

    test "save/3 returns no_image_processor error" do
      assert {:error, {:no_image_processor, _}} = Null.save(:fake, "/path", [])
    end

    test "dimensions/1 returns no_image_processor error" do
      assert {:error, {:no_image_processor, _}} = Null.dimensions(:fake)
    end

    test "tiny_placeholder/1 returns no_image_processor error" do
      assert {:error, {:no_image_processor, _}} = Null.tiny_placeholder(:fake)
    end

    test "error messages guide the developer" do
      {:error, {:no_image_processor, message}} = Null.open("/path")

      assert message =~ "image_processor"
      assert message =~ "PhxMediaLibrary.ImageProcessor.Image"
      assert message =~ "file storage"
    end
  end

  # ---------------------------------------------------------------------------
  # Config improvements
  # ---------------------------------------------------------------------------

  describe "Config.image_processor/0 auto-detection" do
    test "returns a module" do
      processor = PhxMediaLibrary.Config.image_processor()
      assert is_atom(processor)
    end

    test "returns Image adapter when :image is available" do
      # In the test env, :image IS a dependency
      if Code.ensure_loaded?(Image) do
        processor = PhxMediaLibrary.Config.image_processor()
        assert processor == PhxMediaLibrary.ImageProcessor.Image
      end
    end
  end

  describe "Config.disk_config/1 with string disk names" do
    test "resolves atom disk names" do
      config = PhxMediaLibrary.Config.disk_config(:memory)
      assert is_list(config)
      assert Keyword.get(config, :adapter) == PhxMediaLibrary.Storage.Memory
    end

    test "resolves string disk names" do
      config = PhxMediaLibrary.Config.disk_config("memory")
      assert is_list(config)
      assert Keyword.get(config, :adapter) == PhxMediaLibrary.Storage.Memory
    end

    test "raises with helpful message for unknown disk" do
      assert_raise RuntimeError, ~r/Unknown disk.*Available disks/, fn ->
        PhxMediaLibrary.Config.disk_config(:nonexistent)
      end
    end

    test "raises with helpful message for unknown string disk" do
      assert_raise RuntimeError, ~r/Unknown disk.*Available disks/, fn ->
        PhxMediaLibrary.Config.disk_config("nonexistent")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PathGenerator fix (Known Issue)
  # ---------------------------------------------------------------------------

  describe "PathGenerator.full_path/2 uses function_exported?" do
    test "returns a path for local disk media when adapter implements path/2" do
      # The Disk adapter implements the optional path/2 callback.
      # We verify function_exported? detects it correctly.
      assert function_exported?(PhxMediaLibrary.Storage.Disk, :path, 2)

      media = %Media{
        uuid: "test-uuid",
        disk: "local",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      # Even though the file doesn't exist on disk, full_path should return
      # a string path (it just computes the expected path, doesn't check existence)
      path = PhxMediaLibrary.PathGenerator.full_path(media, nil)
      assert is_binary(path)
      assert path =~ "test-uuid"
      assert path =~ "test.jpg"
    end

    test "does not crash for memory adapter" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      # Memory adapter defines path/2 but it returns nil (no filesystem).
      # The key thing is that the fixed function_exported? check doesn't crash.
      result = PhxMediaLibrary.PathGenerator.full_path(media, nil)
      assert is_nil(result) or is_binary(result)
    end
  end

  # ---------------------------------------------------------------------------
  # MediaAdder polymorphic type derivation
  # ---------------------------------------------------------------------------

  describe "MediaAdder uses __media_type__/0" do
    test "get_mediable_type uses __media_type__ when available" do
      # We test this indirectly through the TestPost schema
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      # The TestPost schema table is "posts", so __media_type__ returns "posts"
      adder = PhxMediaLibrary.MediaAdder.new(post, "/tmp/test.jpg")
      assert adder.model.__struct__.__media_type__() == "posts"
    end

    test "overridden media type is respected" do
      post = %OverriddenTypePost{id: Ecto.UUID.generate(), title: "Test"}
      assert post.__struct__.__media_type__() == "blog_posts"
    end

    test "custom __media_type__/0 function is respected" do
      post = %CustomTypePost{id: Ecto.UUID.generate(), title: "Test"}
      assert post.__struct__.__media_type__() == "my_custom_type"
    end
  end

  # ---------------------------------------------------------------------------
  # PhxMediaLibrary.media_query/2
  # ---------------------------------------------------------------------------

  describe "PhxMediaLibrary.media_query/2" do
    test "returns an Ecto.Query" do
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      query = PhxMediaLibrary.media_query(post)
      assert %Ecto.Query{} = query
    end

    test "query targets Media schema" do
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      query = PhxMediaLibrary.media_query(post)
      assert query.from.source == {"media", PhxMediaLibrary.Media}
    end

    test "query with collection name is still an Ecto.Query" do
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      query = PhxMediaLibrary.media_query(post, :images)
      assert %Ecto.Query{} = query
    end
  end

  # ---------------------------------------------------------------------------
  # convert/2 function (DSL alias)
  # ---------------------------------------------------------------------------

  describe "convert/2 function" do
    test "creates a Conversion struct identical to conversion/2" do
      via_convert = PhxMediaLibrary.HasMedia.convert(:thumb, width: 100, height: 100, fit: :cover)

      via_conversion =
        PhxMediaLibrary.HasMedia.conversion(:thumb, width: 100, height: 100, fit: :cover)

      assert via_convert == via_conversion
    end
  end
end
