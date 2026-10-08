defmodule PhxMediaLibrary.UUIDv7Test do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, UUIDv7}

  doctest UUIDv7

  defp version_and_variant(uuid) do
    {:ok, <<_ms::48, version::4, _seq::12, variant::2, _rand::62>>} = Ecto.UUID.dump(uuid)
    {version, variant}
  end

  test "generate/0 returns version 7 UUIDs (RFC 9562)" do
    assert {7, 2} = version_and_variant(UUIDv7.generate())
  end

  test "ids are strictly increasing, even within one millisecond and across processes" do
    ids =
      1..8
      |> Task.async_stream(fn _ -> for(_ <- 1..2_000, do: UUIDv7.generate()) end)
      |> Enum.flat_map(fn {:ok, ids} -> ids end)

    assert length(Enum.uniq(ids)) == length(ids)

    for _ <- 1..100 do
      a = UUIDv7.generate()
      b = UUIDv7.generate()
      assert a < b
    end
  end

  test "the leading 48 bits are the creation time in milliseconds" do
    before = System.system_time(:millisecond)
    {:ok, <<ms::48, _::80>>} = Ecto.UUID.dump(UUIDv7.generate())
    assert ms >= before and ms <= System.system_time(:millisecond) + 1
  end

  @tag :db
  test "new media get version 7 ids and uuids" do
    png = create_temp_image()
    on_exit(fn -> File.rm(png) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:images, disk: :memory)

    assert {7, 2} = version_and_variant(media.id)
    assert {7, 2} = version_and_variant(media.uuid)
  end

  @tag :db
  test "existing version 4 rows still load" do
    media = create_media(%{disk: "memory"})
    v4 = Ecto.UUID.generate()
    TestRepo.update_all(from(m in Media, where: m.id == ^media.id), set: [id: v4])

    assert %Media{id: ^v4} = TestRepo.get!(Media, v4)
  end
end
