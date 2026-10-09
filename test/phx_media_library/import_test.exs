defmodule PhxMediaLibrary.ImportTest do
  # Spec 02, F2: import_media/2.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversions, Media, Model, RecordingAsyncProcessor, ResponsiveImages}

  @moduletag :db

  setup do
    for key <- [:async_processor, :repo] do
      previous = Application.fetch_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    Application.put_env(:phx_media_library, :async_processor, RecordingAsyncProcessor)
    RecordingAsyncProcessor.record_to(self())

    jpeg = create_temp_image(format: :jpg, width: 400, height: 300)
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> Enum.each([jpeg, txt], &File.rm/1) end)

    on_exit(fn ->
      for media <- TestRepo.all(Media), do: Media.delete_files(media)
    end)

    %{jpeg: jpeg, txt: txt}
  end

  defp stored_files do
    root = Application.get_env(:phx_media_library, :disks)[:local][:root]
    root |> Path.join("**/*.*") |> Path.wildcard() |> MapSet.new()
  end

  defp count_queries(fun) do
    test = self()
    id = "import-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_media_library, :test_repo, :query],
      fn _, _, meta, _ ->
        if meta.source == "media" and meta.query =~ ~r/^(INSERT|UPDATE)/,
          do: send(test, {:write, meta.query |> String.split(" ") |> hd()})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, collect([])}
  end

  defp collect(acc) do
    receive do
      {:write, kind} -> collect([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "entries across records and collections; one job per row makes the rest",
       %{jpeg: jpeg, txt: txt} do
    [post, other] = [create_test_post(), create_test_post()]

    entries = [
      %{
        model: post,
        collection: :avif_responsive,
        source: jpeg,
        custom_properties: %{"alt" => "A"}
      },
      %{
        model: other,
        collection: :images,
        source: {:binary, File.read!(jpeg), "b.jpg"},
        filename: "Shoe.jpg"
      },
      %{model: post, collection: :documents, source: txt}
    ]

    assert {:ok, %{inserted: 3, failed: []}} = PhxMediaLibrary.import_media(entries, disk: :local)

    [photo] = PhxMediaLibrary.get_media(post, :avif_responsive)
    [shoe] = PhxMediaLibrary.get_media(other, :images)
    [notes] = PhxMediaLibrary.get_media(post, :documents)

    assert photo.custom_properties == %{"alt" => "A"}
    assert Media.original_file_name(shoe) == "Shoe.jpg"
    assert Media.processing_status(photo) == :queued
    assert Media.processing_status(notes) == :done

    # Jobs for the images; none for the text file.
    assert_received {:process_async, id, [_ | _]} when id == photo.id
    assert_received {:process_async, id, [_ | _]} when id == shoe.id
    refute_received {:process_async, _, _}

    {:ok, _} = {Conversions.process(photo, Model.conversions(photo, :avif_responsive)), :ran}
    photo = TestRepo.reload!(photo)
    assert is_binary(photo.custom_properties["avif"])
    assert ResponsiveImages.formats(photo, nil) == ["avif", "webp"]
    assert photo.generated_conversions["thumb"] == ["avif", "webp"]
    assert Media.processing_status(photo) == :done
  end

  test "rows go in by batch, with no other write", %{jpeg: jpeg} do
    post = create_test_post()

    entries =
      for i <- 1..5,
          do: %{
            model: post,
            collection: :images,
            source: {:binary, File.read!(jpeg), "p#{i}.jpg"}
          }

    {{:ok, %{inserted: 5}}, writes} =
      count_queries(fn -> PhxMediaLibrary.import_media(entries, batch_size: 2, disk: :local) end)

    assert writes == ["INSERT", "INSERT", "INSERT"]
  end

  test "batches stay within the database's parameter limit" do
    limit = if TestRepo.sqlite?(), do: 32_766, else: 65_535
    max = PhxMediaLibrary.Import.max_batch_size()

    assert max * length(Media.__schema__(:fields)) <= limit
    assert max <= 2_000
  end

  test "positions are looked up once per collection and batch", %{jpeg: jpeg} do
    post = create_test_post()

    entries =
      for i <- 1..4,
          do: %{
            model: post,
            collection: :images,
            source: {:binary, File.read!(jpeg), "p#{i}.jpg"}
          }

    test = self()
    id = "order-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_media_library, :test_repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ ~r/max\(.*order_column/i, do: send(test, :order_query)
      end,
      nil
    )

    {:ok, %{inserted: 4}} = PhxMediaLibrary.import_media(entries, batch_size: 2, disk: :local)
    :telemetry.detach(id)

    assert Enum.count(
             Stream.repeatedly(fn -> receive do: (:order_query -> 1), after: (0 -> nil) end)
             |> Stream.take_while(& &1)
           ) == 2
  end

  test "failures are per entry and leave no files", %{jpeg: jpeg, txt: txt} do
    post = create_test_post()
    before = stored_files()

    entries = [
      %{model: post, collection: :images, source: jpeg},
      %{
        model: post,
        collection: :small_files,
        source: {:binary, String.duplicate("a", 2_000), "big.txt"}
      },
      %{model: post, collection: :documents, source: "/no/such/file.pdf"},
      %{
        model: post,
        collection: :images,
        source: {:stream, Stream.map([1], fn _ -> raise "boom" end), "x.jpg"}
      },
      %{collection: :images, source: txt}
    ]

    assert {:ok, %{inserted: 1, failed: failed}} =
             PhxMediaLibrary.import_media(entries, disk: :local)

    assert [
             {_, {:file_too_large, 2_000, 1_000}},
             {_, :enoent},
             {_, {:exception, "boom"}},
             {_, :invalid_entry}
           ] = failed

    [media] = PhxMediaLibrary.get_media(post, :images)

    assert MapSet.difference(stored_files(), before) ==
             MapSet.new(Media.owned_paths(media), &Path.join("priv/static/uploads", &1))
  end

  test "collection limits hold: the newest win", %{jpeg: jpeg} do
    post = create_test_post()

    entries =
      for i <- 1..3,
          do: %{
            model: post,
            collection: :avatar,
            source: {:binary, File.read!(jpeg), "a#{i}.jpg"}
          }

    assert {:ok, %{inserted: 3}} =
             PhxMediaLibrary.import_media(entries, batch_size: 2, disk: :local)

    assert [avatar] = PhxMediaLibrary.get_media(post, :avatar)
    assert Media.original_file_name(avatar) == "a3.jpg"
  end

  test "a batch the database refuses is reported, and its files removed", %{jpeg: jpeg} do
    post = create_test_post()
    before = stored_files()
    Application.put_env(:phx_media_library, :repo, PhxMediaLibrary.RefusingRepo)

    entries =
      for i <- 1..2,
          do: %{
            model: post,
            collection: :images,
            source: {:binary, File.read!(jpeg), "p#{i}.jpg"}
          }

    assert {:ok, %{inserted: 0, failed: [{_, {:insert_failed, _}}, {_, {:insert_failed, _}}]}} =
             PhxMediaLibrary.import_media(entries, disk: :local)

    assert stored_files() == before
  end
end
