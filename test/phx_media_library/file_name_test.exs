defmodule PhxMediaLibrary.FileNameTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.FileName

  doctest FileName

  describe "safe/1" do
    test "removes control characters" do
      assert FileName.safe("bad\u0000name\n.txt") == "badname.txt"
    end

    test "caps the length at 255 bytes and keeps the extension" do
      name = FileName.safe(String.duplicate("ä", 300) <> ".jpg")
      assert byte_size(name) <= 255
      assert String.ends_with?(name, ".jpg")
      assert String.valid?(name)
    end

    test "falls back to \"file\" for empty or non-string names" do
      assert FileName.safe("") == "file"
      assert FileName.safe("dir/") == "file"
      assert FileName.safe(nil) == "file"
    end
  end
end
