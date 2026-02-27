defmodule PhxMediaLibrary.IntegrationTest do
  @moduledoc """
  Integration tests that exercise the full media lifecycle against a real
  Postgres database. These tests verify:

  - Adding media via file paths (the full `add → store → retrieve → delete` flow)
  - Collection validation (MIME types, single file, max files)
  - The `MediaAdder` pipeline end-to-end
  - Storage adapters with real files
  - Checksum computation and integrity verification
  - Polymorphic type derivation and `has_many` preloading
  - Query helpers (`media_query/2`, `get_media/2`, `get_first_media/2`)
  - Error paths (missing files, invalid types, storage failures)
  - The declarative DSL collections and conversions roundtrip
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.{Fixtures, Media, PathGenerator, Storage, TestRepo}

  # Suppress noisy async conversion errors in test output.
  # The async processor fires for every upload but fails on non-image
  # files (expected). We use a no-op processor for these tests.
  setup do
    original_processor = Application.get_env(:phx_media_library, :async_processor)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.IntegrationTest.NoOpProcessor
    )

    on_exit(fn ->
      if original_processor do
        Application.put_env(:phx_media_library, :async_processor, original_processor)
      else
        Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # No-op async processor to avoid background task noise in tests
  # ---------------------------------------------------------------------------

  defmodule NoOpProcessor do
    @moduledoc false
    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(_media, _conversions), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: create a real post in the database
  # ---------------------------------------------------------------------------

  defp create_post!(attrs \\ %{}) do
    defaults = %{title: "Integration Test Post", body: "Hello world"}
    merged = Map.merge(defaults, Map.new(attrs))

    {id, _} = merged |> Map.pop(:id)

    %PhxMediaLibrary.TestPost{id: id || Ecto.UUID.generate()}
    |> Ecto.Changeset.change(Map.take(merged, [:title, :body]))
    |> TestRepo.insert!()
  end

  defp create_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_integ_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)

    on_exit(fn -> File.rm(path) end)

    path
  end

  defp setup_disk_storage(_context) do
    dir = Path.join(System.tmp_dir!(), "phx_media_integ_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_disks = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      memory: [
        adapter: PhxMediaLibrary.Storage.Memory,
        base_url: "/test-uploads"
      ],
      local: [
        adapter: PhxMediaLibrary.Storage.Disk,
        root: dir,
        base_url: "/uploads"
      ]
    )

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(dir)
    end)

    %{storage_dir: dir}
  end

  # ---------------------------------------------------------------------------
  # Full lifecycle: add → store → retrieve → delete
  # ---------------------------------------------------------------------------

  describe "full media lifecycle" do
    setup :setup_disk_storage

    test "add file → persist in DB → retrieve → delete", %{storage_dir: dir} do
      post = create_post!()
      content = "file content here"
      path = create_temp_file(content, "document.txt")

      # 1. Add media (use using_filename so we get a predictable stored name)
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("document.txt")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      # 2. Verify DB record
      assert %Media{} = media
      assert media.id != nil
      assert media.uuid != nil
      assert media.collection_name == "documents"
      assert media.file_name == "document.txt"
      assert media.mime_type == "text/plain"
      assert media.disk == "local"
      assert media.size == byte_size(content)
      assert media.mediable_type == "posts"
      assert media.mediable_id == post.id
      assert media.order_column == 1

      # 3. Verify the file was stored on disk
      stored_path = Path.join(dir, "posts/#{post.id}/#{media.uuid}/document.txt")
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == content

      # 4. Verify checksum was computed and stored
      assert media.checksum != nil
      assert media.checksum_algorithm == "sha256"
      expected_checksum = Media.compute_checksum(content, "sha256")
      assert media.checksum == expected_checksum

      # 5. Retrieve via query helpers
      assert [fetched] = PhxMediaLibrary.get_media(post, :documents)
      assert fetched.id == media.id

      assert fetched_first = PhxMediaLibrary.get_first_media(post, :documents)
      assert fetched_first.id == media.id

      # 6. Verify URL generation
      url = PhxMediaLibrary.url(media)
      assert is_binary(url)
      assert url =~ media.uuid

      # 7. Verify path generation (local disk)
      full_path = PhxMediaLibrary.path(media)
      assert full_path == stored_path

      # 8. Delete
      assert :ok = PhxMediaLibrary.delete(media)

      # Verify DB record removed
      assert TestRepo.get(Media, media.id) == nil

      # Verify file removed from disk
      refute File.exists?(stored_path)
    end

    test "add file with custom filename", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("custom name content", "original.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("renamed.txt")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "renamed.txt"
      assert media.name == "renamed"
    end

    test "add file with custom properties", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("properties test", "props.txt")

      custom = %{"alt" => "A description", "author" => "Test User"}

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("props.txt")
               |> PhxMediaLibrary.with_custom_properties(custom)
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.custom_properties == custom

      # Reload from DB to ensure it was persisted
      reloaded = TestRepo.get!(Media, media.id)
      assert reloaded.custom_properties == custom
    end

    test "to_collection! raises on error" do
      post = create_post!()

      assert_raise PhxMediaLibrary.Error, ~r/Failed to add media/, fn ->
        post
        |> PhxMediaLibrary.add("/nonexistent/file.txt")
        |> PhxMediaLibrary.to_collection!(:documents)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Memory storage (default in test config)
  # ---------------------------------------------------------------------------

  describe "memory storage lifecycle" do
    test "add and retrieve via memory storage" do
      post = create_post!()
      content = "memory storage test"
      path = create_temp_file(content, "memo.txt")

      # Memory is the default disk in test config
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("memo.txt")
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.disk == "memory"

      # Verify stored in memory adapter
      relative_path = PathGenerator.relative_path(media, nil)
      assert {:ok, ^content} = Storage.Memory.get(relative_path, [])

      # Clean up
      PhxMediaLibrary.delete(media)
    end
  end

  # ---------------------------------------------------------------------------
  # Collection validation
  # ---------------------------------------------------------------------------

  describe "collection MIME type validation" do
    test "accepts files matching collection MIME types" do
      post = create_post!()
      path = create_temp_file("valid pdf-ish content", "report.pdf")

      # :documents collection accepts application/pdf and text/plain
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("report.pdf")
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.collection_name == "documents"
    end

    test "rejects files that don't match collection MIME types" do
      post = create_post!()
      # Create a .exe file — MIME will resolve to application/x-msdownload
      path = create_temp_file("not a pdf", "malicious.exe")

      assert {:error, {:invalid_mime_type, _mime, _accepted}} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("malicious.exe")
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "allows any file when collection has no MIME restrictions" do
      post = create_post!()
      path = create_temp_file("anything goes", "random.xyz")

      # :images collection has no accepts restriction
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("random.xyz")
               |> PhxMediaLibrary.to_collection(:images)

      assert media.collection_name == "images"
    end

    test "allows files for collections that are not configured" do
      post = create_post!()
      path = create_temp_file("unconfigured collection", "stuff.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("stuff.txt")
               |> PhxMediaLibrary.to_collection(:unconfigured)

      assert media.collection_name == "unconfigured"
    end
  end

  describe "single file collection" do
    test "replaces previous file when single_file is true" do
      post = create_post!()

      # Add first avatar
      path1 = create_temp_file("avatar 1", "avatar1.jpg")

      assert {:ok, media1} =
               post
               |> PhxMediaLibrary.add(path1)
               |> PhxMediaLibrary.using_filename("avatar1.jpg")
               |> PhxMediaLibrary.to_collection(:avatar)

      # Add second avatar — should replace the first
      path2 = create_temp_file("avatar 2", "avatar2.jpg")

      assert {:ok, media2} =
               post
               |> PhxMediaLibrary.add(path2)
               |> PhxMediaLibrary.using_filename("avatar2.jpg")
               |> PhxMediaLibrary.to_collection(:avatar)

      # Only the second avatar should remain
      avatars = PhxMediaLibrary.get_media(post, :avatar)
      assert length(avatars) == 1
      assert hd(avatars).id == media2.id

      # First one should be deleted from DB
      assert TestRepo.get(Media, media1.id) == nil
    end
  end

  describe "max files collection" do
    test "enforces max_files limit" do
      post = create_post!()

      # :gallery has max_files: 5
      media_ids =
        for i <- 1..6 do
          path = create_temp_file("gallery image #{i}", "gallery_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("gallery_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:gallery)

          media.id
        end

      gallery = PhxMediaLibrary.get_media(post, :gallery)

      # Should have at most 5 items
      assert length(gallery) <= 5

      # The most recently added items should be present
      latest_id = List.last(media_ids)
      gallery_ids = Enum.map(gallery, & &1.id)
      assert latest_id in gallery_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Ordering
  # ---------------------------------------------------------------------------

  describe "media ordering" do
    test "assigns incrementing order_column values" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("file #{i}", "file_#{i}.txt")

        {:ok, media} =
          post
          |> PhxMediaLibrary.add(path)
          |> PhxMediaLibrary.using_filename("file_#{i}.txt")
          |> PhxMediaLibrary.to_collection(:images)

        assert media.order_column == i
      end
    end

    test "get_media returns items ordered by order_column" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("ordered file #{i}", "ordered_#{i}.txt")

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("ordered_#{i}.txt")
        |> PhxMediaLibrary.to_collection(:images)
      end

      items = PhxMediaLibrary.get_media(post, :images)
      orders = Enum.map(items, & &1.order_column)

      assert orders == Enum.sort(orders)
    end
  end

  # ---------------------------------------------------------------------------
  # Checksum and integrity
  # ---------------------------------------------------------------------------

  describe "checksum computation and integrity verification" do
    setup :setup_disk_storage

    test "checksum is stored and matches file content", %{storage_dir: _dir} do
      post = create_post!()
      content = "integrity test content - #{:erlang.unique_integer()}"
      path = create_temp_file(content, "integrity.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("integrity.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      # Reload from DB
      media = TestRepo.get!(Media, media.id)

      assert media.checksum == Media.compute_checksum(content, "sha256")
      assert media.checksum_algorithm == "sha256"
    end

    test "verify_integrity returns :ok for untampered files", %{storage_dir: _dir} do
      post = create_post!()
      content = "verify me"
      path = create_temp_file(content, "verify.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("verify.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert :ok = Media.verify_integrity(media)
    end

    test "verify_integrity detects tampering", %{storage_dir: dir} do
      post = create_post!()
      path = create_temp_file("original content", "tamper.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("tamper.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      # Tamper with the stored file directly on disk
      stored_path = Path.join(dir, "posts/#{post.id}/#{media.uuid}/tamper.txt")
      assert File.exists?(stored_path), "stored file must exist before tampering"
      File.write!(stored_path, "tampered content!!!")

      # Reload the media from DB to make sure we have the stored checksum
      media = TestRepo.get!(Media, media.id)

      assert {:error, :checksum_mismatch} = Media.verify_integrity(media)
    end

    test "verify_integrity returns error when no checksum stored" do
      media = %Media{checksum: nil, checksum_algorithm: "sha256"}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end

    test "different files produce different checksums" do
      post = create_post!()

      path1 = create_temp_file("content A", "file_a.txt")
      path2 = create_temp_file("content B", "file_b.txt")

      {:ok, media1} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("file_a.txt")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, media2} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("file_b.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert media1.checksum != media2.checksum
    end
  end

  # ---------------------------------------------------------------------------
  # Polymorphic type derivation
  # ---------------------------------------------------------------------------

  describe "polymorphic mediable_type" do
    test "derives mediable_type from Ecto table name" do
      post = create_post!()
      path = create_temp_file("type test", "type.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("type.txt")
        |> PhxMediaLibrary.to_collection(:images)

      # TestPost schema uses `schema "posts"` so mediable_type should be "posts"
      assert media.mediable_type == "posts"
    end

    test "__media_type__/0 is defined on TestPost" do
      assert PhxMediaLibrary.TestPost.__media_type__() == "posts"
    end

    test "media is scoped by mediable_type and mediable_id" do
      post1 = create_post!(%{title: "Post 1"})
      post2 = create_post!(%{title: "Post 2"})

      path1 = create_temp_file("post 1 file", "p1.txt")
      path2 = create_temp_file("post 2 file", "p2.txt")

      {:ok, media1} =
        post1
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("p1.txt")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, media2} =
        post2
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("p2.txt")
        |> PhxMediaLibrary.to_collection(:images)

      # Each post should only see its own media
      assert [m1] = PhxMediaLibrary.get_media(post1, :images)
      assert m1.id == media1.id

      assert [m2] = PhxMediaLibrary.get_media(post2, :images)
      assert m2.id == media2.id
    end
  end

  # ---------------------------------------------------------------------------
  # has_many preloading
  # ---------------------------------------------------------------------------

  describe "has_many :media preloading" do
    test "Repo.preload(post, :media) loads all media" do
      post = create_post!()

      path1 = create_temp_file("media 1", "file1.txt")
      path2 = create_temp_file("media 2", "file2.txt")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("file1.txt")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("file2.txt")
        |> PhxMediaLibrary.to_collection(:documents)

      post = TestRepo.preload(post, :media)

      assert length(post.media) == 2
      assert Enum.all?(post.media, &(&1.mediable_id == post.id))
    end

    test "Repo.preload(post, :images) loads only images collection" do
      post = create_post!()

      path1 = create_temp_file("an image", "photo.jpg")
      path2 = create_temp_file("a document", "readme.txt")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("photo.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("readme.txt")
        |> PhxMediaLibrary.to_collection(:documents)

      post = TestRepo.preload(post, :images)

      assert length(post.images) == 1
      assert hd(post.images).collection_name == "images"
    end

    test "preloading multiple collection-scoped associations" do
      post = create_post!()

      path1 = create_temp_file("img content", "img.jpg")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("img.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      path2 = create_temp_file("doc content", "doc.pdf")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("doc.pdf")
        |> PhxMediaLibrary.to_collection(:documents)

      path3 = create_temp_file("avatar content", "avatar.png")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path3)
        |> PhxMediaLibrary.using_filename("avatar.png")
        |> PhxMediaLibrary.to_collection(:avatar)

      post = TestRepo.preload(post, [:media, :images, :documents, :avatar])

      assert length(post.media) == 3
      assert length(post.images) == 1
      assert length(post.documents) == 1
      assert length(post.avatar) == 1
    end

    test "preloading returns empty list when no media exists" do
      post = create_post!()
      post = TestRepo.preload(post, [:media, :images])

      assert post.media == []
      assert post.images == []
    end

    test "media from one post does not leak into another via preload" do
      post1 = create_post!(%{title: "Post A"})
      post2 = create_post!(%{title: "Post B"})

      path = create_temp_file("only for post1", "exclusive.txt")

      {:ok, _} =
        post1
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("exclusive.txt")
        |> PhxMediaLibrary.to_collection(:images)

      post1 = TestRepo.preload(post1, :media)
      post2 = TestRepo.preload(post2, :media)

      assert length(post1.media) == 1
      assert post2.media == []
    end
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  describe "media_query/2" do
    test "returns composable Ecto.Query for all media" do
      post = create_post!()

      path = create_temp_file("query test", "query.txt")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("query.txt")
        |> PhxMediaLibrary.to_collection(:images)

      query = PhxMediaLibrary.media_query(post)
      assert %Ecto.Query{} = query

      results = TestRepo.all(query)
      assert length(results) == 1
    end

    test "filters by collection name when provided" do
      post = create_post!()

      for {collection, filename} <- [{:images, "img.jpg"}, {:documents, "doc.pdf"}] do
        path = create_temp_file("#{collection} content", filename)

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename(filename)
        |> PhxMediaLibrary.to_collection(collection)
      end

      images_query = PhxMediaLibrary.media_query(post, :images)
      assert length(TestRepo.all(images_query)) == 1

      all_query = PhxMediaLibrary.media_query(post)
      assert length(TestRepo.all(all_query)) == 2
    end

    test "query is composable with additional where clauses" do
      post = create_post!()

      path1 = create_temp_file("jpeg content", "photo.jpg")
      path2 = create_temp_file("png content", "icon.png")

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("photo.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, _} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("icon.png")
        |> PhxMediaLibrary.to_collection(:images)

      # Filter further by mime_type
      query =
        post
        |> PhxMediaLibrary.media_query(:images)
        |> where([m], m.mime_type == "image/png")

      results = TestRepo.all(query)
      assert length(results) == 1
      assert hd(results).mime_type == "image/png"
    end
  end

  describe "get_media/2 and get_first_media/2" do
    test "get_media returns all media for a collection" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("item #{i}", "item_#{i}.txt")

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("item_#{i}.txt")
        |> PhxMediaLibrary.to_collection(:images)
      end

      media = PhxMediaLibrary.get_media(post, :images)
      assert length(media) == 3
    end

    test "get_media returns all media when no collection specified" do
      post = create_post!()

      path1 = create_temp_file("img", "img.jpg")
      path2 = create_temp_file("doc", "doc.pdf")

      post
      |> PhxMediaLibrary.add(path1)
      |> PhxMediaLibrary.using_filename("img.jpg")
      |> PhxMediaLibrary.to_collection(:images)

      post
      |> PhxMediaLibrary.add(path2)
      |> PhxMediaLibrary.using_filename("doc.pdf")
      |> PhxMediaLibrary.to_collection(:documents)

      all_media = PhxMediaLibrary.get_media(post)
      assert length(all_media) == 2
    end

    test "get_first_media returns first item by order" do
      post = create_post!()

      path1 = create_temp_file("first", "first.txt")
      path2 = create_temp_file("second", "second.txt")

      {:ok, first_media} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("first.txt")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, _second_media} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("second.txt")
        |> PhxMediaLibrary.to_collection(:images)

      result = PhxMediaLibrary.get_first_media(post, :images)
      assert result.id == first_media.id
    end

    test "get_first_media returns nil when collection is empty" do
      post = create_post!()
      assert PhxMediaLibrary.get_first_media(post, :images) == nil
    end
  end

  describe "get_first_media_url/3" do
    test "returns URL for first media in collection" do
      post = create_post!()
      path = create_temp_file("url test", "url_test.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("url_test.txt")
        |> PhxMediaLibrary.to_collection(:images)

      url = PhxMediaLibrary.get_first_media_url(post, :images)
      assert is_binary(url)
      assert url =~ "url_test"
    end

    test "returns fallback when collection is empty" do
      post = create_post!()
      fallback = "/images/placeholder.png"

      url = PhxMediaLibrary.get_first_media_url(post, :images, fallback: fallback)
      assert url == fallback
    end

    test "returns nil when no fallback and collection is empty" do
      post = create_post!()
      assert PhxMediaLibrary.get_first_media_url(post, :images) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Clear operations
  # ---------------------------------------------------------------------------

  describe "clear_collection/2" do
    test "removes all media from a specific collection" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("image #{i}", "img_#{i}.jpg")

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
        |> PhxMediaLibrary.to_collection(:images)
      end

      path_doc = create_temp_file("a document", "doc.pdf")

      {:ok, doc_media} =
        post
        |> PhxMediaLibrary.add(path_doc)
        |> PhxMediaLibrary.using_filename("doc.pdf")
        |> PhxMediaLibrary.to_collection(:documents)

      # Clear only images
      assert {:ok, 3} = PhxMediaLibrary.clear_collection(post, :images)

      assert PhxMediaLibrary.get_media(post, :images) == []
      # Documents should remain
      assert [remaining] = PhxMediaLibrary.get_media(post, :documents)
      assert remaining.id == doc_media.id
    end
  end

  describe "clear_media/1" do
    test "removes all media from a model" do
      post = create_post!()

      for {collection, filename} <- [{:images, "img.jpg"}, {:documents, "doc.pdf"}] do
        path = create_temp_file("content", filename)

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename(filename)
        |> PhxMediaLibrary.to_collection(collection)
      end

      assert {:ok, 2} = PhxMediaLibrary.clear_media(post)

      assert PhxMediaLibrary.get_media(post) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns error for nonexistent file" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add("/nonexistent/path/to/file.txt")
        |> PhxMediaLibrary.using_filename("file.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, _reason} = result
    end

    test "returns error for empty path" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add("")
        |> PhxMediaLibrary.using_filename("empty.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, _reason} = result
    end

    test "returns error for invalid source type" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add(12_345)
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, :invalid_source} = result
    end
  end

  # ---------------------------------------------------------------------------
  # DSL schema integration with real DB
  # ---------------------------------------------------------------------------

  describe "DSL-configured schema integration" do
    # The DSLPost defined in has_media_dsl_test.exs uses the DSL.
    # We verify that media_collections/0 and media_conversions/0 return
    # the correct structs when used with the TestPost (which uses function style).

    test "TestPost collections are queryable after DB insert" do
      post = create_post!()

      collections = post.__struct__.media_collections()
      collection_names = Enum.map(collections, & &1.name)

      assert :images in collection_names
      assert :documents in collection_names
      assert :avatar in collection_names
      assert :gallery in collection_names
    end

    test "TestPost conversions are queryable" do
      post = create_post!()

      conversions = post.__struct__.media_conversions()
      conversion_names = Enum.map(conversions, & &1.name)

      assert :thumb in conversion_names
      assert :preview in conversion_names
      assert :banner in conversion_names
    end

    test "get_media_collection returns correct config" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:documents)

      assert config.name == :documents
      assert config.accepts == ~w(application/pdf text/plain)
    end

    test "get_media_conversions filters by collection" do
      images_conversions = PhxMediaLibrary.TestPost.get_media_conversions(:images)
      docs_conversions = PhxMediaLibrary.TestPost.get_media_conversions(:documents)

      image_names = Enum.map(images_conversions, & &1.name)
      doc_names = Enum.map(docs_conversions, & &1.name)

      # :banner is scoped to :images
      assert :banner in image_names
      refute :banner in doc_names

      # :thumb and :preview apply to all collections
      assert :thumb in image_names
      assert :thumb in doc_names
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple collections on same model
  # ---------------------------------------------------------------------------

  describe "multiple collections on same model" do
    test "media items are correctly scoped to their collections" do
      post = create_post!()

      path_img = create_temp_file("image data", "photo.jpg")
      path_doc = create_temp_file("document data", "report.pdf")
      path_avatar = create_temp_file("avatar data", "me.png")

      {:ok, img} =
        post
        |> PhxMediaLibrary.add(path_img)
        |> PhxMediaLibrary.using_filename("photo.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, doc} =
        post
        |> PhxMediaLibrary.add(path_doc)
        |> PhxMediaLibrary.using_filename("report.pdf")
        |> PhxMediaLibrary.to_collection(:documents)

      {:ok, avatar} =
        post
        |> PhxMediaLibrary.add(path_avatar)
        |> PhxMediaLibrary.using_filename("me.png")
        |> PhxMediaLibrary.to_collection(:avatar)

      images = PhxMediaLibrary.get_media(post, :images)
      documents = PhxMediaLibrary.get_media(post, :documents)
      avatars = PhxMediaLibrary.get_media(post, :avatar)
      all = PhxMediaLibrary.get_media(post)

      assert length(images) == 1
      assert hd(images).id == img.id

      assert length(documents) == 1
      assert hd(documents).id == doc.id

      assert length(avatars) == 1
      assert hd(avatars).id == avatar.id

      assert length(all) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Real disk storage round-trip
  # ---------------------------------------------------------------------------

  describe "disk storage adapter integration" do
    setup :setup_disk_storage

    test "stores and retrieves file content via local disk", %{storage_dir: dir} do
      post = create_post!()
      content = "disk round-trip content #{:erlang.unique_integer()}"
      path = create_temp_file(content, "disk_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("disk_test.txt")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      # Verify the file exists on disk
      stored_path = PhxMediaLibrary.path(media)
      assert stored_path != nil
      assert String.starts_with?(stored_path, dir)
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == content
    end

    test "delete removes file from disk", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("delete me", "delete_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("delete_test.txt")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      stored_path = PhxMediaLibrary.path(media)
      assert File.exists?(stored_path)

      PhxMediaLibrary.delete(media)

      refute File.exists?(stored_path)
    end

    test "handles binary content correctly", %{storage_dir: _dir} do
      post = create_post!()

      # Create a file with binary content (not valid UTF-8)
      binary_content = :crypto.strong_rand_bytes(256)
      path = create_temp_file(binary_content, "binary.bin")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("binary.bin")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      stored_path = PhxMediaLibrary.path(media)
      assert File.read!(stored_path) == binary_content
      assert media.size == byte_size(binary_content)
    end
  end

  # ---------------------------------------------------------------------------
  # Media changeset and DB constraints
  # ---------------------------------------------------------------------------

  describe "Media changeset with real DB" do
    test "rejects records with missing required fields" do
      changeset = Media.changeset(%Media{}, %{})
      assert {:error, changeset} = TestRepo.insert(changeset)
      refute changeset.valid?
    end

    test "enforces unique UUID constraint" do
      uuid = Ecto.UUID.generate()

      attrs = %{
        uuid: uuid,
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        mime_type: "image/jpeg",
        disk: "memory",
        size: 100,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate()
      }

      assert {:ok, _} = %Media{} |> Media.changeset(attrs) |> TestRepo.insert()

      assert {:error, changeset} =
               %Media{}
               |> Media.changeset(%{attrs | mediable_id: Ecto.UUID.generate()})
               |> TestRepo.insert()

      assert {"has already been taken", _} = changeset.errors[:uuid]
    end

    test "stores and retrieves JSON fields correctly" do
      attrs = %{
        uuid: Ecto.UUID.generate(),
        collection_name: "test",
        name: "json-test",
        file_name: "json-test.txt",
        mime_type: "text/plain",
        disk: "memory",
        size: 42,
        mediable_type: "posts",
        mediable_id: Ecto.UUID.generate(),
        custom_properties: %{"key" => "value", "nested" => %{"a" => 1}},
        generated_conversions: %{"thumb" => true, "preview" => false},
        responsive_images: %{
          "original" => %{
            "variants" => [%{"width" => 320, "height" => 240, "path" => "test/320.jpg"}]
          }
        }
      }

      {:ok, media} = %Media{} |> Media.changeset(attrs) |> TestRepo.insert()

      reloaded = TestRepo.get!(Media, media.id)
      assert reloaded.custom_properties == %{"key" => "value", "nested" => %{"a" => 1}}
      assert reloaded.generated_conversions == %{"thumb" => true, "preview" => false}
      assert get_in(reloaded.responsive_images, ["original", "variants"]) |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures helper integration
  # ---------------------------------------------------------------------------

  describe "Fixtures.create_media/1 with real DB" do
    test "inserts a media record with defaults" do
      media = Fixtures.create_media()

      assert %Media{} = media
      assert media.id != nil
      assert media.collection_name == "default"
      assert media.disk == "memory"

      reloaded = TestRepo.get!(Media, media.id)
      assert reloaded.uuid == media.uuid
    end

    test "inserts a media record with custom attributes" do
      post = create_post!()

      media =
        Fixtures.create_media(%{
          collection_name: "images",
          name: "custom-media",
          file_name: "custom.png",
          mime_type: "image/png",
          mediable_type: "posts",
          mediable_id: post.id,
          checksum: "abc123",
          checksum_algorithm: "sha256"
        })

      assert media.collection_name == "images"
      assert media.mime_type == "image/png"
      assert media.mediable_id == post.id
      assert media.checksum == "abc123"
    end
  end

  # ---------------------------------------------------------------------------
  # DataCase helper
  # ---------------------------------------------------------------------------

  describe "DataCase.errors_on/1" do
    test "extracts errors from invalid changeset" do
      changeset = Media.changeset(%Media{}, %{})
      errors = errors_on(changeset)

      assert "can't be blank" in errors[:uuid]
      assert "can't be blank" in errors[:name]
      assert "can't be blank" in errors[:file_name]
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent access (sandbox)
  # ---------------------------------------------------------------------------

  describe "concurrent media operations" do
    test "multiple posts can have media simultaneously" do
      posts =
        for i <- 1..3 do
          create_post!(%{title: "Concurrent Post #{i}"})
        end

      # Add media to each post
      media_ids =
        for post <- posts do
          filename = "file_#{post.id}.txt"
          path = create_temp_file("content for #{post.title}", filename)

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename(filename)
            |> PhxMediaLibrary.to_collection(:images)

          {post.id, media.id}
        end

      # Each post should have exactly one media item
      for {post_id, media_id} <- media_ids do
        post = TestRepo.get!(PhxMediaLibrary.TestPost, post_id)
        media_items = PhxMediaLibrary.get_media(post, :images)

        assert length(media_items) == 1
        assert hd(media_items).id == media_id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # File size validation (3.2)
  # ---------------------------------------------------------------------------

  describe "file size validation" do
    test "rejects file that exceeds collection max_size" do
      post = create_post!()

      # :small_files collection has max_size: 1_000
      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "big.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:error, {:file_too_large, 2_000, 1_000}} = result
    end

    test "accepts file within collection max_size" do
      post = create_post!()

      small_content = String.duplicate("x", 500)
      path = create_temp_file(small_content, "small.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:ok, media} = result
      assert media.size == 500
    end

    test "accepts file exactly at max_size boundary" do
      post = create_post!()

      exact_content = String.duplicate("x", 1_000)
      path = create_temp_file(exact_content, "exact.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:ok, media} = result
      assert media.size == 1_000
    end

    test "collections without max_size accept any file size" do
      post = create_post!()

      large_content = String.duplicate("x", 100_000)
      path = create_temp_file(large_content, "large.jpg")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert {:ok, _media} = result
    end

    test "file size validation runs before storage (no file written on reject)" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "toobig.txt")

      {:error, {:file_too_large, _, _}} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      # No media should have been persisted
      assert PhxMediaLibrary.get_media(post, :small_files) == []
    end

    test "to_collection! raises PhxMediaLibrary.Error on file size violation" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "toobig.txt")

      assert_raise PhxMediaLibrary.Error, ~r/Failed to add media/, fn ->
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection!(:small_files)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Content-based MIME detection (3.3)
  # ---------------------------------------------------------------------------

  describe "content-based MIME type detection" do
    test "detects MIME type from file content, not just extension" do
      post = create_post!()

      # Write PNG magic bytes to a file with .jpg extension
      png_data =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
          0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08,
          0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE,
          0xD4, 0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

      path = create_temp_file(png_data, "actually_png.jpg")

      # :images collection has no MIME type restrictions, so this should succeed
      # but the stored MIME type should be image/png (detected from content)
      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/png"
    end

    test "rejects file whose content doesn't match collection accepts" do
      post = create_post!()

      # Write PNG magic bytes but try to add to :documents (accepts: pdf, text/plain)
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "fake_doc.pdf")

      # Content-based detection will detect image/png, which won't match
      # the :documents collection accepts list
      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      assert {:error, {:invalid_mime_type, "image/png", _accepts}} = result
    end

    test "verify_content_type: false skips content verification" do
      post = create_post!()

      # Write PNG data to a file — :unverified collection has verify_content_type: false
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "anything.bin")

      # Should succeed because verification is disabled
      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:unverified)

      # Content-based detection still sets the correct MIME type
      assert media.mime_type == "image/png"
    end

    test "plain text files pass through to extension-based detection" do
      post = create_post!()

      # Plain text content — magic bytes won't match anything
      path = create_temp_file("Hello, this is a plain text document.", "readme.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      # Falls back to extension-based detection
      assert media.mime_type == "text/plain"
    end
  end

  # ---------------------------------------------------------------------------
  # Reordering (3.4)
  # ---------------------------------------------------------------------------

  describe "reorder/3" do
    test "reorders media items by ID list" do
      post = create_post!()

      ids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.id
        end

      [id1, id2, id3] = ids

      # Reorder: id3, id1, id2
      assert {:ok, 3} = PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])

      reordered = PhxMediaLibrary.get_media(post, :images)
      reordered_ids = Enum.map(reordered, & &1.id)

      assert reordered_ids == [id3, id1, id2]
    end

    test "reorder ignores IDs not in the collection" do
      post = create_post!()

      path = create_temp_file("content", "file.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      fake_id = Ecto.UUID.generate()

      # Include a fake ID — it should be ignored (count reflects actual updates)
      assert {:ok, count} = PhxMediaLibrary.reorder(post, :images, [fake_id, media.id])
      assert count == 1

      [remaining] = PhxMediaLibrary.get_media(post, :images)
      assert remaining.id == media.id
    end

    test "reorder with empty list is a no-op" do
      post = create_post!()

      assert {:ok, 0} = PhxMediaLibrary.reorder(post, :images, [])
    end
  end

  describe "move_to/2" do
    test "moves a media item to the first position" do
      post = create_post!()

      ids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.id
        end

      [_id1, _id2, id3] = ids

      # Move the last item to position 1
      last_media = TestRepo.get!(Media, id3)
      assert {:ok, updated} = PhxMediaLibrary.move_to(last_media, 1)
      assert updated.order_column == 1

      # Verify ordering
      reordered = PhxMediaLibrary.get_media(post, :images)
      assert hd(reordered).id == id3
    end

    test "moves a media item to the last position" do
      post = create_post!()

      ids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.id
        end

      [id1, _id2, _id3] = ids

      # Move the first item to position 3
      first_media = TestRepo.get!(Media, id1)
      assert {:ok, updated} = PhxMediaLibrary.move_to(first_media, 3)
      assert updated.order_column == 3

      # Verify it's last
      reordered = PhxMediaLibrary.get_media(post, :images)
      assert List.last(reordered).id == id1
    end

    test "clamps position to collection size" do
      post = create_post!()

      path = create_temp_file("only item", "solo.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Position 999 should clamp to 1 (only 1 item)
      assert {:ok, updated} = PhxMediaLibrary.move_to(media, 999)
      assert updated.order_column == 1
    end

    test "moves to middle position" do
      post = create_post!()

      ids =
        for i <- 1..4 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.id
        end

      [id1, _id2, _id3, id4] = ids

      # Move id4 (last) to position 2
      last_media = TestRepo.get!(Media, id4)
      assert {:ok, _updated} = PhxMediaLibrary.move_to(last_media, 2)

      reordered = PhxMediaLibrary.get_media(post, :images)
      reordered_ids = Enum.map(reordered, & &1.id)

      # id4 should now be at index 1 (position 2)
      assert Enum.at(reordered_ids, 0) == id1
      assert Enum.at(reordered_ids, 1) == id4
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry events (3.1)
  # ---------------------------------------------------------------------------

  describe "telemetry events" do
    setup do
      test_pid = self()

      :telemetry.attach_many(
        "integration-test-handler-#{System.unique_integer([:positive])}",
        [
          [:phx_media_library, :add, :start],
          [:phx_media_library, :add, :stop],
          [:phx_media_library, :delete, :start],
          [:phx_media_library, :delete, :stop],
          [:phx_media_library, :batch, :start],
          [:phx_media_library, :batch, :stop],
          [:phx_media_library, :storage, :start],
          [:phx_media_library, :storage, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      :ok
    end

    test "emits :add start and stop events on successful upload" do
      post = create_post!()
      path = create_temp_file("telemetry test", "telem.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert_received {:telemetry, [:phx_media_library, :add, :start], %{system_time: _},
                       metadata}

      assert metadata.collection == :images
      assert metadata.source_type == :path

      assert_received {:telemetry, [:phx_media_library, :add, :stop], %{duration: duration},
                       stop_metadata}

      assert duration > 0
      assert %PhxMediaLibrary.Media{} = stop_metadata.media
    end

    test "emits :storage events during upload" do
      post = create_post!()
      path = create_temp_file("storage telemetry", "stor.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert_received {:telemetry, [:phx_media_library, :storage, :start], _, %{operation: :put}}
      assert_received {:telemetry, [:phx_media_library, :storage, :stop], _, %{operation: :put}}
    end

    test "emits :delete events when deleting media" do
      post = create_post!()
      path = create_temp_file("delete me", "del.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Drain add/storage events
      flush_mailbox()

      :ok = PhxMediaLibrary.delete(media)

      assert_received {:telemetry, [:phx_media_library, :delete, :start], _, %{media: _}}
      assert_received {:telemetry, [:phx_media_library, :delete, :stop], %{duration: _}, _}
    end

    test "emits :batch events for clear_collection" do
      post = create_post!()

      for i <- 1..2 do
        path = create_temp_file("item #{i}", "item_#{i}.txt")

        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)
      end

      # Drain add events
      flush_mailbox()

      {:ok, 2} = PhxMediaLibrary.clear_collection(post, :images)

      assert_received {:telemetry, [:phx_media_library, :batch, :start], _,
                       %{operation: :clear_collection}}

      assert_received {:telemetry, [:phx_media_library, :batch, :stop], _,
                       %{operation: :clear_collection, count: 2}}
    end

    test "emits :batch events for reorder" do
      post = create_post!()

      ids =
        for i <- 1..2 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.to_collection(:images)

          media.id
        end

      # Drain add events
      flush_mailbox()

      [id1, id2] = ids
      {:ok, 2} = PhxMediaLibrary.reorder(post, :images, [id2, id1])

      assert_received {:telemetry, [:phx_media_library, :batch, :start], _,
                       %{operation: :reorder}}

      assert_received {:telemetry, [:phx_media_library, :batch, :stop], _,
                       %{operation: :reorder, count: 2}}
    end
  end

  # ---------------------------------------------------------------------------
  # Error struct integration (3.1)
  # ---------------------------------------------------------------------------

  describe "structured error handling" do
    test "to_collection! raises PhxMediaLibrary.Error with metadata" do
      post = create_post!()

      error =
        assert_raise PhxMediaLibrary.Error, fn ->
          post
          |> PhxMediaLibrary.add("/nonexistent/file.txt")
          |> PhxMediaLibrary.to_collection!(:images)
        end

      assert error.reason == :add_failed
      assert error.metadata.collection == :images
    end

    test "file size violation returns tagged tuple (not exception)" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "big.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:error, {:file_too_large, actual_size, max_size}} = result
      assert actual_size == 2_000
      assert max_size == 1_000
    end

    test "MIME type violation returns tagged tuple (not exception)" do
      post = create_post!()

      # PNG data going into :documents (accepts only pdf + text/plain)
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "fake.pdf")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      assert {:error, {:invalid_mime_type, "image/png", _accepted}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Collection config for new fields (3.2 / 3.3)
  # ---------------------------------------------------------------------------

  describe "collection config" do
    test "max_size is accessible via get_media_collection" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:small_files)

      assert config.name == :small_files
      assert config.max_size == 1_000
      assert config.accepts == ~w(text/plain)
    end

    test "verify_content_type defaults to true" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:images)

      assert config.verify_content_type == true
    end

    test "verify_content_type can be set to false" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:unverified)

      assert config.verify_content_type == false
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      10 -> :ok
    end
  end
end
