defmodule PhxMediaLibrary.Storage.MemoryTest do
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.Storage.Memory

  setup do
    # Ensure the Memory storage is started and cleared before each test
    Memory.clear()
    :ok
  end

  describe "put/3" do
    test "stores binary content at the given path" do
      assert :ok = Memory.put("test/file.txt", "Hello, World!", [])
      assert {:ok, "Hello, World!"} = Memory.get("test/file.txt")
    end

    test "stores content from a stream" do
      stream = ["Hello, ", "World!"] |> Stream.map(& &1)
      assert :ok = Memory.put("test/stream.txt", {:stream, stream}, [])
      assert {:ok, "Hello, World!"} = Memory.get("test/stream.txt")
    end

    test "overwrites existing content" do
      Memory.put("test/file.txt", "Original", [])
      Memory.put("test/file.txt", "Updated", [])

      assert {:ok, "Updated"} = Memory.get("test/file.txt")
    end

    test "stores binary data" do
      binary = <<0, 1, 2, 3, 255>>
      assert :ok = Memory.put("test/binary.bin", binary, [])
      assert {:ok, ^binary} = Memory.get("test/binary.bin")
    end
  end

  describe "get/2" do
    test "returns {:ok, content} when file exists" do
      Memory.put("test/file.txt", "Content", [])
      assert {:ok, "Content"} = Memory.get("test/file.txt")
    end

    test "returns {:error, :not_found} when file does not exist" do
      assert {:error, :not_found} = Memory.get("nonexistent/file.txt")
    end
  end

  describe "delete/2" do
    test "removes the file at the given path" do
      Memory.put("test/file.txt", "Content", [])
      assert :ok = Memory.delete("test/file.txt")
      assert {:error, :not_found} = Memory.get("test/file.txt")
    end

    test "returns :ok even when file does not exist" do
      assert :ok = Memory.delete("nonexistent/file.txt")
    end
  end

  describe "exists?/2" do
    test "returns true when file exists" do
      Memory.put("test/file.txt", "Content", [])
      assert Memory.exists?("test/file.txt", [])
    end

    test "returns false when file does not exist" do
      refute Memory.exists?("nonexistent/file.txt", [])
    end

    test "returns false after file is deleted" do
      Memory.put("test/file.txt", "Content", [])
      Memory.delete("test/file.txt")
      refute Memory.exists?("test/file.txt", [])
    end
  end

  describe "url/2" do
    test "generates URL with default base_url" do
      url = Memory.url("images/photo.jpg", [])
      assert url == "/memory/images/photo.jpg"
    end

    test "generates URL with custom base_url" do
      url = Memory.url("images/photo.jpg", base_url: "/test-uploads")
      assert url == "/test-uploads/images/photo.jpg"
    end

    test "handles nested paths" do
      url = Memory.url("users/123/avatar/photo.jpg", base_url: "/uploads")
      assert url == "/uploads/users/123/avatar/photo.jpg"
    end
  end

  describe "clear/0" do
    test "removes all stored files" do
      Memory.put("file1.txt", "Content 1", [])
      Memory.put("file2.txt", "Content 2", [])
      Memory.put("dir/file3.txt", "Content 3", [])

      assert Memory.exists?("file1.txt", [])
      assert Memory.exists?("file2.txt", [])
      assert Memory.exists?("dir/file3.txt", [])

      Memory.clear()

      refute Memory.exists?("file1.txt", [])
      refute Memory.exists?("file2.txt", [])
      refute Memory.exists?("dir/file3.txt", [])
    end

    test "returns :ok" do
      assert :ok = Memory.clear()
    end
  end

  describe "all/0" do
    test "returns empty map when no files stored" do
      Memory.clear()
      assert Memory.all() == %{}
    end

    test "returns all stored files" do
      Memory.put("file1.txt", "Content 1", [])
      Memory.put("file2.txt", "Content 2", [])

      all = Memory.all()

      assert all == %{
               "file1.txt" => "Content 1",
               "file2.txt" => "Content 2"
             }
    end
  end

  describe "concurrent access" do
    test "handles concurrent writes safely" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Memory.put("concurrent/file-#{i}.txt", "Content #{i}", [])
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # Verify all files were stored
      for i <- 1..100 do
        assert Memory.exists?("concurrent/file-#{i}.txt", [])
      end
    end

    test "handles concurrent reads safely" do
      Memory.put("shared/file.txt", "Shared Content", [])

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Memory.get("shared/file.txt")
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert Enum.all?(results, &(&1 == {:ok, "Shared Content"}))
    end
  end
end
