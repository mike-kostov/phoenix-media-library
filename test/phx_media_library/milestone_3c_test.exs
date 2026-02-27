defmodule PhxMediaLibrary.Milestone3cTest do
  @moduledoc """
  Tests for Milestone 3c — Soft Deletes, Streaming Uploads, and Presigned Upload API.

  Split into three major describe blocks matching the sub-milestones:
    3.5 — Soft Deletes
    3.6 — Streaming Upload Support
    3.7 — Direct S3 Upload (Presigned URLs)
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.Config
  alias PhxMediaLibrary.Media
  alias PhxMediaLibrary.PathGenerator
  alias PhxMediaLibrary.Storage
  alias PhxMediaLibrary.StorageWrapper

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_post!(attrs \\ %{}) do
    default = %{id: Ecto.UUID.generate(), title: "Test Post"}
    struct!(PhxMediaLibrary.TestPost, Map.merge(default, attrs))
  end

  defp create_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "m3c_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp setup_disk_storage(_context) do
    dir = Path.join(System.tmp_dir!(), "phx_media_m3c_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_disks = Application.get_env(:phx_media_library, :disks)
    original_default_disk = Application.get_env(:phx_media_library, :default_disk)

    Application.put_env(:phx_media_library, :disks,
      local: [
        adapter: Storage.Disk,
        root: dir,
        base_url: "/test-uploads"
      ],
      memory: [
        adapter: Storage.Memory,
        base_url: "/test-uploads"
      ]
    )

    Application.put_env(:phx_media_library, :default_disk, :local)
    Storage.Memory.clear()

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)

      if original_default_disk do
        Application.put_env(:phx_media_library, :default_disk, original_default_disk)
      else
        Application.delete_env(:phx_media_library, :default_disk)
      end

      File.rm_rf!(dir)
    end)

    %{storage_dir: dir}
  end

  defp enable_soft_deletes(_context) do
    Application.put_env(:phx_media_library, :soft_deletes, true)

    on_exit(fn ->
      Application.put_env(:phx_media_library, :soft_deletes, false)
    end)

    :ok
  end

  defp disable_soft_deletes(_context) do
    Application.put_env(:phx_media_library, :soft_deletes, false)
    :ok
  end

  defp add_media_to_post!(post, collection, filename, content) do
    path = create_temp_file(content, filename)

    {:ok, media} =
      post
      |> PhxMediaLibrary.add(path)
      |> PhxMediaLibrary.to_collection(collection)

    media
  end

  # =========================================================================
  # 3.5 — Soft Deletes
  # =========================================================================

  describe "soft deletes: configuration" do
    test "soft_deletes_enabled?/0 defaults to false" do
      Application.delete_env(:phx_media_library, :soft_deletes)
      refute Media.soft_deletes_enabled?()
    end

    test "soft_deletes_enabled?/0 returns true when configured" do
      Application.put_env(:phx_media_library, :soft_deletes, true)
      assert Media.soft_deletes_enabled?()
    after
      Application.put_env(:phx_media_library, :soft_deletes, false)
    end

    test "soft_deletes_enabled?/0 returns false when explicitly disabled" do
      Application.put_env(:phx_media_library, :soft_deletes, false)
      refute Media.soft_deletes_enabled?()
    end
  end

  describe "soft deletes: trashed?/1" do
    test "returns false for media without deleted_at" do
      media = %Media{deleted_at: nil}
      refute PhxMediaLibrary.trashed?(media)
    end

    test "returns true for media with deleted_at set" do
      media = %Media{deleted_at: ~U[2026-01-01 00:00:00Z]}
      assert PhxMediaLibrary.trashed?(media)
    end
  end

  describe "soft deletes: soft_delete/1 and restore/1" do
    setup [:setup_disk_storage]

    test "soft_delete/1 sets deleted_at timestamp" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "hello")

      assert is_nil(media.deleted_at)

      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      assert %DateTime{} = trashed.deleted_at
      assert PhxMediaLibrary.trashed?(trashed)
    end

    test "soft_delete/1 persists to database" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "hello")

      {:ok, _trashed} = PhxMediaLibrary.soft_delete(media)

      reloaded = TestRepo.get!(Media, media.id)
      assert %DateTime{} = reloaded.deleted_at
    end

    test "restore/1 clears deleted_at" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "hello")

      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      assert PhxMediaLibrary.trashed?(trashed)

      {:ok, restored} = PhxMediaLibrary.restore(trashed)
      assert is_nil(restored.deleted_at)
      refute PhxMediaLibrary.trashed?(restored)
    end

    test "restore/1 persists to database" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "hello")

      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      {:ok, _restored} = PhxMediaLibrary.restore(trashed)

      reloaded = TestRepo.get!(Media, media.id)
      assert is_nil(reloaded.deleted_at)
    end
  end

  describe "soft deletes: delete/1 respects config" do
    setup [:setup_disk_storage]

    test "delete/1 performs hard delete when soft_deletes disabled" do
      Application.put_env(:phx_media_library, :soft_deletes, false)

      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "gone forever")

      assert :ok = PhxMediaLibrary.delete(media)
      assert is_nil(TestRepo.get(Media, media.id))
    end

    test "delete/1 performs soft delete when soft_deletes enabled" do
      Application.put_env(:phx_media_library, :soft_deletes, true)

      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "soft gone")

      {:ok, trashed} = PhxMediaLibrary.delete(media)
      assert %DateTime{} = trashed.deleted_at

      # Record still exists in DB
      reloaded = TestRepo.get!(Media, media.id)
      assert %DateTime{} = reloaded.deleted_at
    after
      Application.put_env(:phx_media_library, :soft_deletes, false)
    end

    test "permanently_delete/1 hard-deletes even when soft_deletes enabled" do
      Application.put_env(:phx_media_library, :soft_deletes, true)

      post = create_post!()
      media = add_media_to_post!(post, :images, "test.txt", "hard gone")

      assert :ok = PhxMediaLibrary.permanently_delete(media)
      assert is_nil(TestRepo.get(Media, media.id))
    after
      Application.put_env(:phx_media_library, :soft_deletes, false)
    end
  end

  describe "soft deletes: query scoping" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "get_media/2 excludes soft-deleted items" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "visible.txt", "visible")
      m2 = add_media_to_post!(post, :images, "trashed.txt", "trashed")

      {:ok, _} = PhxMediaLibrary.soft_delete(m2)

      media = PhxMediaLibrary.get_media(post, :images)
      ids = Enum.map(media, & &1.id)
      assert m1.id in ids
      refute m2.id in ids
    end

    test "get_first_media/2 skips soft-deleted items" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "first.txt", "first")
      m2 = add_media_to_post!(post, :images, "second.txt", "second")

      {:ok, _} = PhxMediaLibrary.soft_delete(m1)

      first = PhxMediaLibrary.get_first_media(post, :images)
      assert first.id == m2.id
    end

    test "media_query/2 excludes soft-deleted items" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "a.txt", "a")
      m2 = add_media_to_post!(post, :images, "b.txt", "b")

      {:ok, _} = PhxMediaLibrary.soft_delete(m1)

      results = PhxMediaLibrary.media_query(post, :images) |> TestRepo.all()
      ids = Enum.map(results, & &1.id)
      refute m1.id in ids
      assert m2.id in ids
    end

    test "get_media/2 returns all items when soft_deletes is disabled" do
      Application.put_env(:phx_media_library, :soft_deletes, false)

      post = create_post!()
      m1 = add_media_to_post!(post, :images, "a.txt", "a")
      m2 = add_media_to_post!(post, :images, "b.txt", "b")

      # Manually set deleted_at on m2 without going through the soft_delete API
      m2
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> TestRepo.update!()

      media = PhxMediaLibrary.get_media(post, :images)
      ids = Enum.map(media, & &1.id)

      # When soft_deletes config is off, no filtering happens
      assert m1.id in ids
      assert m2.id in ids
    end
  end

  describe "soft deletes: get_trashed_media/2" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "returns only soft-deleted items" do
      post = create_post!()
      _visible = add_media_to_post!(post, :images, "visible.txt", "visible")
      trashable = add_media_to_post!(post, :images, "trash.txt", "trash")

      {:ok, _} = PhxMediaLibrary.soft_delete(trashable)

      trashed = PhxMediaLibrary.get_trashed_media(post, :images)
      assert length(trashed) == 1
      assert hd(trashed).id == trashable.id
    end

    test "returns empty list when no trashed items exist" do
      post = create_post!()
      _m = add_media_to_post!(post, :images, "alive.txt", "alive")

      assert [] == PhxMediaLibrary.get_trashed_media(post, :images)
    end

    test "returns trashed items across all collections when no collection specified" do
      post = create_post!()
      img = add_media_to_post!(post, :images, "img.txt", "img")
      doc = add_media_to_post!(post, :documents, "doc.txt", "doc")

      {:ok, _} = PhxMediaLibrary.soft_delete(img)
      {:ok, _} = PhxMediaLibrary.soft_delete(doc)

      trashed = PhxMediaLibrary.get_trashed_media(post)
      assert length(trashed) == 2
    end
  end

  describe "soft deletes: purge_trashed/2" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "permanently deletes all trashed items for a model" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "a.txt", "a")
      m2 = add_media_to_post!(post, :images, "b.txt", "b")

      {:ok, _} = PhxMediaLibrary.soft_delete(m1)
      {:ok, _} = PhxMediaLibrary.soft_delete(m2)

      {:ok, count} = PhxMediaLibrary.purge_trashed(post)
      assert count == 2

      assert is_nil(TestRepo.get(Media, m1.id))
      assert is_nil(TestRepo.get(Media, m2.id))
    end

    test "purge_trashed with :before option only deletes items older than cutoff" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "old.txt", "old")
      m2 = add_media_to_post!(post, :images, "new.txt", "new")

      # Soft-delete both
      {:ok, _} = PhxMediaLibrary.soft_delete(m1)
      {:ok, _} = PhxMediaLibrary.soft_delete(m2)

      # Backdate m1's deleted_at to 60 days ago
      old_date = DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)

      TestRepo.get!(Media, m1.id)
      |> Ecto.Changeset.change(deleted_at: old_date)
      |> TestRepo.update!()

      # Purge items deleted more than 30 days ago
      cutoff = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
      {:ok, count} = PhxMediaLibrary.purge_trashed(post, before: cutoff)

      assert count == 1
      assert is_nil(TestRepo.get(Media, m1.id))
      # m2 was recently trashed, so it's still there
      assert %Media{} = TestRepo.get(Media, m2.id)
    end

    test "purge_trashed does not affect non-trashed items" do
      post = create_post!()
      alive = add_media_to_post!(post, :images, "alive.txt", "alive")
      dead = add_media_to_post!(post, :images, "dead.txt", "dead")

      {:ok, _} = PhxMediaLibrary.soft_delete(dead)

      {:ok, count} = PhxMediaLibrary.purge_trashed(post)
      assert count == 1
      assert %Media{} = TestRepo.get(Media, alive.id)
    end

    test "purge_trashed returns {:ok, 0} when no trashed items" do
      post = create_post!()
      _alive = add_media_to_post!(post, :images, "alive.txt", "alive")

      {:ok, count} = PhxMediaLibrary.purge_trashed(post)
      assert count == 0
    end

    test "purge_trashed deletes files from storage" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "file.txt", "file contents")

      # Verify file exists
      storage = Config.storage_adapter(media.disk)
      storage_path = PathGenerator.relative_path(media, nil)
      assert StorageWrapper.exists?(storage, storage_path)

      {:ok, _} = PhxMediaLibrary.soft_delete(media)

      # File should still exist after soft delete
      assert StorageWrapper.exists?(storage, storage_path)

      # After purge, file should be gone
      {:ok, 1} = PhxMediaLibrary.purge_trashed(post)
      refute StorageWrapper.exists?(storage, storage_path)
    end
  end

  describe "soft deletes: clear_collection/2 with soft deletes" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "soft-deletes items instead of hard-deleting" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "a.txt", "a")
      m2 = add_media_to_post!(post, :images, "b.txt", "b")

      {:ok, count} = PhxMediaLibrary.clear_collection(post, :images)
      assert count == 2

      # Records still exist but are trashed
      reloaded1 = TestRepo.get!(Media, m1.id)
      reloaded2 = TestRepo.get!(Media, m2.id)
      assert %DateTime{} = reloaded1.deleted_at
      assert %DateTime{} = reloaded2.deleted_at

      # get_media should return empty
      assert [] == PhxMediaLibrary.get_media(post, :images)

      # get_trashed_media should return them
      assert length(PhxMediaLibrary.get_trashed_media(post, :images)) == 2
    end

    test "does not delete files from storage on soft clear" do
      post = create_post!()
      media = add_media_to_post!(post, :images, "file.txt", "contents")

      storage = Config.storage_adapter(media.disk)
      storage_path = PathGenerator.relative_path(media, nil)

      {:ok, _} = PhxMediaLibrary.clear_collection(post, :images)

      # File should still be on disk
      assert StorageWrapper.exists?(storage, storage_path)
    end
  end

  describe "soft deletes: clear_media/1 with soft deletes" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "soft-deletes all media for model" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "img.txt", "img")
      m2 = add_media_to_post!(post, :documents, "doc.txt", "doc")

      {:ok, count} = PhxMediaLibrary.clear_media(post)
      assert count == 2

      assert [] == PhxMediaLibrary.get_media(post)
      assert length(PhxMediaLibrary.get_trashed_media(post)) == 2

      r1 = TestRepo.get!(Media, m1.id)
      r2 = TestRepo.get!(Media, m2.id)
      assert %DateTime{} = r1.deleted_at
      assert %DateTime{} = r2.deleted_at
    end
  end

  describe "soft deletes: clear_collection/2 without soft deletes" do
    setup [:setup_disk_storage, :disable_soft_deletes]

    test "hard-deletes items as before" do
      post = create_post!()
      m1 = add_media_to_post!(post, :images, "a.txt", "a")
      _m2 = add_media_to_post!(post, :images, "b.txt", "b")

      {:ok, count} = PhxMediaLibrary.clear_collection(post, :images)
      assert count == 2

      assert is_nil(TestRepo.get(Media, m1.id))
    end
  end

  describe "soft deletes: deleted_at schema field" do
    test "Media schema has deleted_at field" do
      media = %Media{}
      assert is_nil(media.deleted_at)
    end

    test "deleted_at is included in optional changeset fields" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Media.changeset(%Media{}, %{
          uuid: Ecto.UUID.generate(),
          collection_name: "test",
          name: "test",
          file_name: "test.txt",
          mime_type: "text/plain",
          disk: "memory",
          size: 100,
          mediable_type: "posts",
          mediable_id: Ecto.UUID.generate(),
          deleted_at: now
        })

      assert Ecto.Changeset.get_field(changeset, :deleted_at) == now
    end
  end

  describe "soft deletes: exclude_trashed/1 and only_trashed/1" do
    setup [:setup_disk_storage]

    test "exclude_trashed filters out soft-deleted items when enabled" do
      Application.put_env(:phx_media_library, :soft_deletes, true)

      post = create_post!()
      _m1 = add_media_to_post!(post, :images, "alive.txt", "alive")
      m2 = add_media_to_post!(post, :images, "dead.txt", "dead")

      {:ok, _} = PhxMediaLibrary.soft_delete(m2)

      query = Ecto.Query.from(m in Media)
      filtered = Media.exclude_trashed(query) |> TestRepo.all()
      ids = Enum.map(filtered, & &1.id)
      refute m2.id in ids
    after
      Application.put_env(:phx_media_library, :soft_deletes, false)
    end

    test "exclude_trashed is a no-op when soft deletes disabled" do
      Application.put_env(:phx_media_library, :soft_deletes, false)

      post = create_post!()
      _m1 = add_media_to_post!(post, :images, "alive.txt", "alive")
      m2 = add_media_to_post!(post, :images, "dead.txt", "dead")

      # Manually set deleted_at
      m2
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> TestRepo.update!()

      query = Ecto.Query.from(m in Media)
      all = Media.exclude_trashed(query) |> TestRepo.all()
      ids = Enum.map(all, & &1.id)
      # Not filtered because soft deletes disabled
      assert m2.id in ids
    end

    test "only_trashed returns only soft-deleted items" do
      post = create_post!()
      _m1 = add_media_to_post!(post, :images, "alive.txt", "alive")
      m2 = add_media_to_post!(post, :images, "dead.txt", "dead")

      m2
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> TestRepo.update!()

      query = Ecto.Query.from(m in Media)
      trashed = Media.only_trashed(query) |> TestRepo.all()
      ids = Enum.map(trashed, & &1.id)
      assert m2.id in ids
      assert length(trashed) == 1
    end
  end

  # =========================================================================
  # 3.6 — Streaming Upload Support
  # =========================================================================

  describe "streaming: file is not loaded entirely into memory" do
    setup [:setup_disk_storage]

    test "adds media successfully with streaming pipeline" do
      post = create_post!()
      content = String.duplicate("streaming test data\n", 1000)
      path = create_temp_file(content, "stream_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert String.ends_with?(media.file_name, "stream_test.txt")
      assert media.size == byte_size(content)
    end

    test "checksum is correctly computed during streaming" do
      post = create_post!()
      content = "checksum test content for streaming"
      path = create_temp_file(content, "checksum_stream.txt")

      expected_checksum =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.checksum == expected_checksum
      assert media.checksum_algorithm == "sha256"
    end

    test "checksum matches verify_integrity for streamed upload" do
      post = create_post!()
      content = "integrity check streaming"
      path = create_temp_file(content, "integrity_stream.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert :ok = PhxMediaLibrary.verify_integrity(media)
    end

    test "large file is handled correctly" do
      post = create_post!()
      # Create a ~500KB file (larger than the 64KB stream chunk size)
      content = :crypto.strong_rand_bytes(500_000)
      path = create_temp_file(content, "large_file.bin")

      expected_checksum =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.size == 500_000
      assert media.checksum == expected_checksum
      assert :ok = PhxMediaLibrary.verify_integrity(media)
    end

    test "empty file is handled correctly" do
      post = create_post!()
      path = create_temp_file("", "empty.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      expected_checksum =
        :crypto.hash(:sha256, "")
        |> Base.encode16(case: :lower)

      assert media.size == 0
      assert media.checksum == expected_checksum
    end

    test "stored file content matches original for streamed upload" do
      post = create_post!()
      content = "verify stored content matches original"
      path = create_temp_file(content, "verify_content.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      storage = Config.storage_adapter(media.disk)
      storage_path = PathGenerator.relative_path(media, nil)
      {:ok, stored_content} = StorageWrapper.get(storage, storage_path)

      assert stored_content == content
    end

    test "multiple sequential uploads produce correct checksums" do
      post = create_post!()

      results =
        for i <- 1..5 do
          content = "file number #{i} with unique content #{:rand.uniform(1_000_000)}"
          path = create_temp_file(content, "multi_#{i}.txt")

          expected =
            :crypto.hash(:sha256, content)
            |> Base.encode16(case: :lower)

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.to_collection(:images)

          {media.checksum, expected}
        end

      for {actual, expected} <- results do
        assert actual == expected
      end
    end
  end

  describe "streaming: MIME detection uses header bytes only" do
    setup [:setup_disk_storage]

    test "detects PNG from header bytes without reading entire file" do
      post = create_post!()
      # Create a PNG-like file: valid PNG header + large body
      png_header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

      body = :crypto.strong_rand_bytes(100_000)
      content = png_header <> body
      path = create_temp_file(content, "test.png")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/png"
    end

    test "detects JPEG from header bytes" do
      post = create_post!()
      jpeg_header = <<0xFF, 0xD8, 0xFF, 0xE0>>
      content = jpeg_header <> :crypto.strong_rand_bytes(50_000)
      path = create_temp_file(content, "test.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/jpeg"
    end

    test "falls back to extension when content doesn't match known signatures" do
      post = create_post!()
      content = "just plain text content"
      path = create_temp_file(content, "readme.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "text/plain"
    end
  end

  describe "streaming: with memory storage adapter" do
    setup [:setup_disk_storage]

    test "streams to memory storage correctly" do
      Storage.Memory.clear()
      Application.put_env(:phx_media_library, :default_disk, :memory)

      post = create_post!()
      content = String.duplicate("memory stream ", 5000)
      path = create_temp_file(content, "mem_stream.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Verify content was stored
      storage = Config.storage_adapter("memory")
      storage_path = PathGenerator.relative_path(media, nil)
      {:ok, stored} = StorageWrapper.get(storage, storage_path)

      assert stored == content

      # Reset immediately so subsequent tests aren't affected
      Application.put_env(:phx_media_library, :default_disk, :local)
    end
  end

  describe "streaming: metadata extraction still works" do
    setup [:setup_disk_storage]

    test "metadata is extracted alongside streaming" do
      post = create_post!()
      content = "metadata test"
      path = create_temp_file(content, "meta.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Metadata should be populated (at minimum, extracted_at)
      assert is_map(media.metadata)
    end

    test "without_metadata still works with streaming" do
      post = create_post!()
      content = "no metadata test"
      path = create_temp_file(content, "nometa.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.without_metadata()
        |> PhxMediaLibrary.to_collection(:images)

      assert media.metadata == %{}
    end
  end

  # =========================================================================
  # 3.7 — Direct S3 Upload (Presigned URLs)
  # =========================================================================

  describe "presigned uploads: presigned_upload_url/3" do
    setup [:setup_disk_storage]

    test "returns :not_supported for local disk adapter" do
      post = create_post!()

      result =
        PhxMediaLibrary.presigned_upload_url(post, :images, filename: "photo.jpg")

      assert {:error, :not_supported} = result
    end

    test "returns :not_supported for memory adapter" do
      Application.put_env(:phx_media_library, :default_disk, :memory)

      post = create_post!()

      result =
        PhxMediaLibrary.presigned_upload_url(post, :images, filename: "photo.jpg")

      assert {:error, :not_supported} = result
    after
      Application.put_env(:phx_media_library, :default_disk, :local)
    end

    test "raises when :filename option is missing" do
      post = create_post!()

      assert_raise KeyError, ~r/key :filename not found/, fn ->
        PhxMediaLibrary.presigned_upload_url(post, :images, [])
      end
    end
  end

  describe "presigned uploads: complete_external_upload/4" do
    setup [:setup_disk_storage]

    test "creates a media record from external upload metadata" do
      post = create_post!()

      # Simulate a completed external upload — the file is already in storage,
      # we just need to create the DB record.
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/photo.jpg"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 45_000
        )

      assert media.file_name == "photo.jpg"
      assert media.mime_type == "image/jpeg"
      assert media.size == 45_000
      assert media.collection_name == "images"
      assert media.mediable_id == post.id
    end

    test "stores custom properties" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/doc.pdf"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "doc.pdf",
          content_type: "application/pdf",
          size: 100_000,
          custom_properties: %{"description" => "My document"}
        )

      assert media.custom_properties == %{"description" => "My document"}
    end

    test "stores pre-computed checksum" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/hashed.txt"
      checksum = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "hashed.txt",
          content_type: "text/plain",
          size: 42,
          checksum: checksum,
          checksum_algorithm: "sha256"
        )

      assert media.checksum == checksum
      assert media.checksum_algorithm == "sha256"
    end

    test "creates record without checksum when not provided" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/nochecksum.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "nochecksum.txt",
          content_type: "text/plain",
          size: 10
        )

      assert is_nil(media.checksum)
    end

    test "extracts UUID from storage path" do
      post = create_post!()
      uuid = Ecto.UUID.generate()
      storage_path = "posts/#{post.id}/#{uuid}/photo.jpg"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 1000
        )

      assert media.uuid == uuid
    end

    test "assigns correct order_column" do
      post = create_post!()
      _m1 = add_media_to_post!(post, :images, "first.txt", "first")

      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/second.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "second.txt",
          content_type: "text/plain",
          size: 100
        )

      assert media.order_column == 2
    end

    test "metadata defaults to empty map" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/test.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          content_type: "text/plain",
          size: 5
        )

      assert media.metadata == %{}
    end

    test "raises when required options are missing" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/test.txt"

      assert_raise KeyError, ~r/key :filename not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          content_type: "text/plain",
          size: 5
        )
      end

      assert_raise KeyError, ~r/key :content_type not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          size: 5
        )
      end

      assert_raise KeyError, ~r/key :size not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          content_type: "text/plain"
        )
      end
    end

    test "emits telemetry events" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/telem.txt"

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-external-add-#{inspect(ref)}",
        [:phx_media_library, :add, :stop],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, :add_stop, metadata})
        end,
        nil
      )

      {:ok, _media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "telem.txt",
          content_type: "text/plain",
          size: 10
        )

      assert_receive {:telemetry, :add_stop, metadata}
      assert metadata.collection == :images
      assert metadata.source_type == :external
    after
      :telemetry.detach("test-external-add-#{inspect(make_ref())}")
    end
  end

  describe "presigned uploads: complete_external_upload with soft deletes" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "respects soft delete on subsequent operations" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/ext.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "ext.txt",
          content_type: "text/plain",
          size: 10
        )

      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      assert PhxMediaLibrary.trashed?(trashed)

      # Should be excluded from queries
      assert [] == PhxMediaLibrary.get_media(post, :images)
    end
  end

  # =========================================================================
  # Storage behaviour: presigned_upload_url callback
  # =========================================================================

  describe "storage behaviour: presigned_upload_url/3 optional callback" do
    test "Disk adapter does not export presigned_upload_url/3" do
      Code.ensure_loaded(Storage.Disk)
      refute function_exported?(Storage.Disk, :presigned_upload_url, 3)
    end

    test "Memory adapter does not export presigned_upload_url/3" do
      Code.ensure_loaded(Storage.Memory)
      refute function_exported?(Storage.Memory, :presigned_upload_url, 3)
    end

    test "S3 adapter exports presigned_upload_url/3" do
      Code.ensure_loaded(Storage.S3)
      assert function_exported?(Storage.S3, :presigned_upload_url, 3)
    end
  end

  describe "storage wrapper: presigned_upload_url/3" do
    test "returns {:error, :not_supported} for adapters without the callback" do
      storage = %StorageWrapper{
        adapter: Storage.Memory,
        config: [base_url: "/test"]
      }

      assert {:error, :not_supported} =
               StorageWrapper.presigned_upload_url(storage, "test/path.txt")
    end
  end

  # =========================================================================
  # Combined features: soft deletes + streaming
  # =========================================================================

  describe "combined: soft delete after streamed upload" do
    setup [:setup_disk_storage, :enable_soft_deletes]

    test "full lifecycle: stream upload → soft delete → restore → purge" do
      post = create_post!()
      content = "full lifecycle test with streaming and soft deletes"
      path = create_temp_file(content, "lifecycle.txt")

      # 1. Upload via streaming
      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.checksum != nil
      assert [^media] = PhxMediaLibrary.get_media(post, :images) |> strip_preloads()

      # 2. Soft delete
      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      assert PhxMediaLibrary.trashed?(trashed)
      assert [] == PhxMediaLibrary.get_media(post, :images)

      # File still on disk
      storage = Config.storage_adapter(media.disk)
      storage_path = PathGenerator.relative_path(media, nil)
      assert StorageWrapper.exists?(storage, storage_path)

      # 3. Restore
      {:ok, restored} = PhxMediaLibrary.restore(trashed)
      refute PhxMediaLibrary.trashed?(restored)
      assert [_] = PhxMediaLibrary.get_media(post, :images)

      # 4. Soft delete again and purge
      {:ok, _} = PhxMediaLibrary.soft_delete(restored)
      {:ok, 1} = PhxMediaLibrary.purge_trashed(post)

      # Record and file both gone
      assert is_nil(TestRepo.get(Media, media.id))
      refute StorageWrapper.exists?(storage, storage_path)
    end
  end

  # Strip Ecto preloads for comparison
  defp strip_preloads(media_list) do
    Enum.map(media_list, fn m -> %{m | __meta__: m.__meta__} end)
  end
end
