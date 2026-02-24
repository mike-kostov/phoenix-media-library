defmodule PhxMediaLibrary.Storage.DiskTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Storage.Disk

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    opts = [root: tmp_dir, base_url: "/uploads"]
    {:ok, opts: opts, tmp_dir: tmp_dir}
  end

  describe "put/3" do
    test "stores binary content at the given path", %{opts: opts, tmp_dir: tmp_dir} do
      assert :ok = Disk.put("test/file.txt", "Hello, World!", opts)

      file_path = Path.join(tmp_dir, "test/file.txt")
      assert File.exists?(file_path)
      assert File.read!(file_path) == "Hello, World!"
    end

    test "creates nested directories", %{opts: opts, tmp_dir: tmp_dir} do
      assert :ok = Disk.put("deep/nested/path/file.txt", "Content", opts)

      file_path = Path.join(tmp_dir, "deep/nested/path/file.txt")
      assert File.exists?(file_path)
    end

    test "stores content from a stream", %{opts: opts, tmp_dir: tmp_dir} do
      stream = ["Hello, ", "World!"] |> Stream.map(& &1)
      assert :ok = Disk.put("test/stream.txt", {:stream, stream}, opts)

      file_path = Path.join(tmp_dir, "test/stream.txt")
      assert File.read!(file_path) == "Hello, World!"
    end

    test "overwrites existing files", %{opts: opts, tmp_dir: tmp_dir} do
      Disk.put("test/file.txt", "Original", opts)
      Disk.put("test/file.txt", "Updated", opts)

      file_path = Path.join(tmp_dir, "test/file.txt")
      assert File.read!(file_path) == "Updated"
    end

    test "stores binary data", %{opts: opts, tmp_dir: tmp_dir} do
      binary = <<0, 1, 2, 3, 255>>
      assert :ok = Disk.put("test/binary.bin", binary, opts)

      file_path = Path.join(tmp_dir, "test/binary.bin")
      assert File.read!(file_path) == binary
    end
  end

  describe "get/2" do
    test "returns {:ok, content} when file exists", %{opts: opts, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test/file.txt")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "Content")

      assert {:ok, "Content"} = Disk.get("test/file.txt", opts)
    end

    test "returns {:error, :enoent} when file does not exist", %{opts: opts} do
      assert {:error, :enoent} = Disk.get("nonexistent/file.txt", opts)
    end
  end

  describe "delete/2" do
    test "removes the file at the given path", %{opts: opts, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test/file.txt")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "Content")

      assert :ok = Disk.delete("test/file.txt", opts)
      refute File.exists?(file_path)
    end

    test "returns :ok even when file does not exist", %{opts: opts} do
      assert :ok = Disk.delete("nonexistent/file.txt", opts)
    end
  end

  describe "exists?/2" do
    test "returns true when file exists", %{opts: opts, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test/file.txt")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "Content")

      assert Disk.exists?("test/file.txt", opts)
    end

    test "returns false when file does not exist", %{opts: opts} do
      refute Disk.exists?("nonexistent/file.txt", opts)
    end

    test "returns true for directories (uses File.exists?)", %{opts: opts, tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "test/directory")
      File.mkdir_p!(dir_path)

      # File.exists? returns true for both files and directories
      assert Disk.exists?("test/directory", opts)
    end
  end

  describe "url/2" do
    test "generates URL with base_url", %{opts: opts} do
      url = Disk.url("images/photo.jpg", opts)
      assert url == "/uploads/images/photo.jpg"
    end

    test "handles nested paths" do
      opts = [root: "/tmp", base_url: "/static/uploads"]
      url = Disk.url("users/123/avatar/photo.jpg", opts)
      assert url == "/static/uploads/users/123/avatar/photo.jpg"
    end

    test "uses default base_url when not provided" do
      opts = [root: "/tmp"]
      url = Disk.url("images/photo.jpg", opts)
      assert url == "/uploads/images/photo.jpg"
    end
  end

  describe "path/2" do
    test "returns full filesystem path", %{opts: opts, tmp_dir: tmp_dir} do
      path = Disk.path("images/photo.jpg", opts)
      assert path == Path.join(tmp_dir, "images/photo.jpg")
    end

    test "returns absolute path" do
      opts = [root: "/var/uploads"]
      path = Disk.path("images/photo.jpg", opts)
      assert path == "/var/uploads/images/photo.jpg"
    end
  end

  describe "integration" do
    test "full lifecycle: put, exists, get, delete", %{opts: opts} do
      path = "lifecycle/test-file.txt"
      content = "Lifecycle test content"

      # Initially doesn't exist
      refute Disk.exists?(path, opts)

      # Put the file
      assert :ok = Disk.put(path, content, opts)

      # Now exists
      assert Disk.exists?(path, opts)

      # Can retrieve content
      assert {:ok, ^content} = Disk.get(path, opts)

      # Delete the file
      assert :ok = Disk.delete(path, opts)

      # No longer exists
      refute Disk.exists?(path, opts)
    end

    test "stores and retrieves large content", %{opts: opts} do
      # 1MB of data
      large_content = :crypto.strong_rand_bytes(1024 * 1024)

      assert :ok = Disk.put("large/file.bin", large_content, opts)
      assert {:ok, retrieved} = Disk.get("large/file.bin", opts)
      assert retrieved == large_content
    end
  end
end
