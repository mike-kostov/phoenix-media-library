defmodule PhxMediaLibrary.ModelTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Collection, Media, Model}
  alias PhxMediaLibrary.TestRepo, as: Repo

  describe "lookups" do
    test "mediable_type/1 uses the table name" do
      assert Model.mediable_type(create_test_post()) == "posts"
    end

    test "collection/2 accepts atom and string names" do
      post = create_test_post()
      assert %Collection{name: :avatar} = Model.collection(post, :avatar)
      assert %Collection{name: :avatar} = Model.collection(post, "avatar")
      assert Model.collection(post, :nope) == nil
    end

    test "collection/2 returns nil for structs without collections" do
      assert Model.collection(%URI{}, :images) == nil
    end

    test "conversions/2 filters by collection" do
      names = create_test_post() |> Model.conversions(:images) |> Enum.map(& &1.name)
      assert :banner in names
      refute :banner in (create_test_post() |> Model.conversions(:avatar) |> Enum.map(& &1.name))
    end
  end

  describe "collection maintenance" do
    @describetag :db

    defp media_for(post, collection, order) do
      create_media(
        mediable_id: post.id,
        mediable_type: "posts",
        collection_name: to_string(collection),
        order_column: order
      )
    end

    test "next_order/2 continues after the highest order" do
      post = create_test_post()
      assert Model.next_order(post, :gallery) == 1

      media_for(post, :gallery, 7)
      assert Model.next_order(post, :gallery) == 8
    end

    test "single_file keeps only the new media" do
      post = create_test_post()
      old = media_for(post, :avatar, 1)
      new = media_for(post, :avatar, 2)

      assert :ok = Model.enforce_collection_limits(post, :avatar, new)
      refute Repo.get(Media, old.id)
      assert Repo.get(Media, new.id)
    end

    test "max_files deletes the oldest beyond the limit" do
      post = create_test_post()
      [oldest | rest] = for n <- 1..6, do: media_for(post, :gallery, n)

      assert :ok = Model.enforce_collection_limits(post, :gallery, List.last(rest))
      refute Repo.get(Media, oldest.id)
      assert Enum.all?(rest, &Repo.get(Media, &1.id))
    end

    test "single_file never deletes media newer than the new upload" do
      # The racing step: upload A's cleanup runs after B was saved. Before,
      # A deleted B and B's cleanup deleted A, leaving the collection empty.
      post = create_test_post()
      a = media_for(post, :avatar, 1)
      b = media_for(post, :avatar, 2)

      assert :ok = Model.enforce_collection_limits(post, :avatar, a)
      assert Repo.get(Media, a.id)
      assert Repo.get(Media, b.id)

      assert :ok = Model.enforce_collection_limits(post, :avatar, b)
      refute Repo.get(Media, a.id)
      assert Repo.get(Media, b.id)
    end

    test "single_file breaks ties consistently, keeping exactly one" do
      post = create_test_post()
      [a, b] = for _ <- 1..2, do: media_for(post, :avatar, 1)

      Model.enforce_collection_limits(post, :avatar, a)
      Model.enforce_collection_limits(post, :avatar, b)

      assert [_survivor] = Media.for_model(post, :avatar)
    end

    test "respects soft deletes" do
      Application.put_env(:phx_media_library, :soft_deletes, true)
      on_exit(fn -> Application.delete_env(:phx_media_library, :soft_deletes) end)

      post = create_test_post()
      old = media_for(post, :avatar, 1)
      new = media_for(post, :avatar, 2)

      assert :ok = Model.enforce_collection_limits(post, :avatar, new)
      assert %Media{deleted_at: %DateTime{}} = Repo.get(Media, old.id)
    end
  end
end
