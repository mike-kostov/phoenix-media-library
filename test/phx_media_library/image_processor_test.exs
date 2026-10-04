defmodule PhxMediaLibrary.ImageProcessorTest do
  # Not async: the atom table is global.
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.ImageProcessor.Image, as: Processor

  setup do
    dir =
      Path.join(System.tmp_dir!(), "phx_media_processor_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, image} = Image.new(4, 4, color: :red)
    %{dir: dir, image: image}
  end

  test "saving under unknown extensions creates no atoms", %{dir: dir, image: image} do
    save = fn ->
      Processor.save(image, Path.join(dir, "x.zz#{System.unique_integer([:positive])}"))
    end

    # The first call loads code, which creates atoms of its own.
    save.()
    before = :erlang.system_info(:atom_count)
    for _ <- 1..100, do: save.()

    # The bug created one atom per extension (+100).
    assert :erlang.system_info(:atom_count) - before < 5
  end

  test "known formats still save as that format", %{dir: dir, image: image} do
    for {ext, mime} <- [
          {"jpg", "image/jpeg"},
          {"JPEG", "image/jpeg"},
          {"png", "image/png"},
          {"webp", "image/webp"},
          {"gif", "image/gif"},
          {"tiff", "image/tiff"}
        ] do
      path = Path.join(dir, "out.#{ext}")
      assert {:ok, _} = Processor.save(image, path), ext

      header = path |> File.read!() |> binary_part(0, 32)
      assert PhxMediaLibrary.MimeDetector.detect(header, path) == {:ok, mime}, ext
    end
  end
end
