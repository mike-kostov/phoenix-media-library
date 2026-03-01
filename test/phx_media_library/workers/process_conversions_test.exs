defmodule PhxMediaLibrary.Workers.ProcessConversionsTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.{Conversion, Fixtures, ModelRegistry}
  alias PhxMediaLibrary.Workers.ProcessConversions

  import ExUnit.CaptureLog

  setup do
    # Ensure TestPost is loaded so find_model_module can discover it
    # via :code.all_loaded() scan
    Code.ensure_loaded!(PhxMediaLibrary.TestPost)

    # Clear the persistent_term cache for model lookups so each test
    # gets a clean discovery. The cache now lives in ModelRegistry.
    :persistent_term.get()
    |> Enum.each(fn
      {{ModelRegistry, :model_lookup, _} = key, _} ->
        :persistent_term.erase(key)

      _ ->
        :ok
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # perform/1 — with mediable_type in args
  # ---------------------------------------------------------------------------

  describe "perform/1 with mediable_type" do
    test "discards job when media record does not exist" do
      assert {:discard, :media_not_found} ==
               Oban.Testing.perform_job(
                 ProcessConversions,
                 %{
                   "media_id" => Ecto.UUID.generate(),
                   "conversions" => ["thumb"],
                   "mediable_type" => "posts"
                 },
                 []
               )
    end

    test "returns :ok when no conversions are resolved" do
      media = Fixtures.create_media(collection_name: "default", mediable_type: "posts")

      log =
        capture_log(fn ->
          assert :ok ==
                   Oban.Testing.perform_job(
                     ProcessConversions,
                     %{
                       "media_id" => media.id,
                       "conversions" => ["nonexistent_conversion"],
                       "mediable_type" => "posts"
                     },
                     []
                   )
        end)

      assert log =~ "No conversion definitions resolved"
    end

    test "returns :ok with empty conversion list" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      log =
        capture_log(fn ->
          assert :ok ==
                   Oban.Testing.perform_job(
                     ProcessConversions,
                     %{
                       "media_id" => media.id,
                       "conversions" => [],
                       "mediable_type" => "posts"
                     },
                     []
                   )
        end)

      assert log =~ "No conversion definitions resolved"
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 — legacy args (no mediable_type)
  # ---------------------------------------------------------------------------

  describe "perform/1 with legacy args (no mediable_type)" do
    test "discards job when media record does not exist" do
      assert {:discard, :media_not_found} ==
               Oban.Testing.perform_job(
                 ProcessConversions,
                 %{
                   "media_id" => Ecto.UUID.generate(),
                   "conversions" => ["thumb"]
                 },
                 []
               )
    end

    test "falls back to media.mediable_type for resolution" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      log =
        capture_log(fn ->
          assert :ok ==
                   Oban.Testing.perform_job(
                     ProcessConversions,
                     %{
                       "media_id" => media.id,
                       "conversions" => ["nonexistent_conversion"]
                     },
                     []
                   )
        end)

      assert log =~ "No conversion definitions resolved"
      assert log =~ "legacy job without mediable_type"
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_conversions/3
  # ---------------------------------------------------------------------------

  describe "resolve_conversions/3" do
    test "resolves full conversion definitions from TestPost" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      conversions = ProcessConversions.resolve_conversions("posts", ["thumb", "preview"], media)

      assert length(conversions) == 2

      thumb = Enum.find(conversions, &(&1.name == :thumb))
      assert %Conversion{} = thumb
      assert thumb.width == 150
      assert thumb.height == 150
      assert thumb.fit == :cover

      preview = Enum.find(conversions, &(&1.name == :preview))
      assert %Conversion{} = preview
      assert preview.width == 800
      assert preview.quality == 85
    end

    test "filters conversions to only those requested" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      conversions = ProcessConversions.resolve_conversions("posts", ["thumb"], media)

      assert length(conversions) == 1
      assert hd(conversions).name == :thumb
    end

    test "respects collection-scoped conversions" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      # :banner is only for :images collection
      conversions = ProcessConversions.resolve_conversions("posts", ["banner"], media)

      assert length(conversions) == 1
      assert hd(conversions).name == :banner
      assert hd(conversions).width == 1200
      assert hd(conversions).height == 400

      # :banner should NOT resolve for :documents collection
      doc_media = Fixtures.create_media(collection_name: "documents", mediable_type: "posts")

      doc_conversions =
        ProcessConversions.resolve_conversions("posts", ["banner"], doc_media)

      assert doc_conversions == []
    end

    test "falls back to name-only conversions for unknown mediable_type" do
      media = Fixtures.create_media(collection_name: "default", mediable_type: "unknown_type")

      log =
        capture_log(fn ->
          conversions =
            ProcessConversions.resolve_conversions("unknown_type", ["thumb"], media)

          assert length(conversions) == 1
          assert hd(conversions).name == :thumb
          # Fallback conversions have default values (no width/height)
          assert hd(conversions).width == nil
          assert hd(conversions).height == nil
        end)

      assert log =~ "Could not find model module"
      assert log =~ "Falling back to name-only conversions"
    end

    test "returns empty list when requested conversions don't match any model definitions" do
      media = Fixtures.create_media(collection_name: "images", mediable_type: "posts")

      # "does_not_exist" is not a conversion defined on TestPost, so it
      # should be filtered out after resolve. Since the model IS found,
      # we get the full list and filter — no match means empty list.
      conversions =
        ProcessConversions.resolve_conversions("posts", ["does_not_exist"], media)

      assert conversions == []
    end
  end

  # ---------------------------------------------------------------------------
  # find_model_module/1 (delegates to ModelRegistry)
  # ---------------------------------------------------------------------------

  describe "find_model_module/1" do
    test "finds TestPost module for 'posts' mediable_type" do
      assert {:ok, PhxMediaLibrary.TestPost} ==
               ProcessConversions.find_model_module("posts")
    end

    test "returns :error for unknown mediable_type" do
      assert :error == ProcessConversions.find_model_module("completely_unknown_table_xyz")
    end

    test "caches result in persistent_term on subsequent calls" do
      # First call discovers the module
      assert {:ok, PhxMediaLibrary.TestPost} ==
               ProcessConversions.find_model_module("posts")

      # Verify it's actually cached (cache key now lives in ModelRegistry)
      cache_key = {ModelRegistry, :model_lookup, "posts"}
      assert :persistent_term.get(cache_key) == PhxMediaLibrary.TestPost

      # Second call should hit the cache and return the same result
      assert {:ok, PhxMediaLibrary.TestPost} ==
               ProcessConversions.find_model_module("posts")
    end

    test "uses explicit model_registry when configured" do
      # Configure a custom registry
      Application.put_env(:phx_media_library, :model_registry, %{
        "custom_type" => PhxMediaLibrary.TestPost
      })

      assert {:ok, PhxMediaLibrary.TestPost} ==
               ProcessConversions.find_model_module("custom_type")

      # Cleanup
      Application.delete_env(:phx_media_library, :model_registry)
    end
  end

  # ---------------------------------------------------------------------------
  # Job construction via ProcessConversions.new/1
  # ---------------------------------------------------------------------------

  describe "ProcessConversions.new/1 builds correct job changesets" do
    test "includes media_id, conversions, and mediable_type in args" do
      media_id = Ecto.UUID.generate()

      changeset =
        ProcessConversions.new(%{
          media_id: media_id,
          conversions: ["thumb", "preview"],
          mediable_type: "posts"
        })

      # Oban changesets store args with atom keys before serialization
      args = changeset.changes.args

      assert args.media_id == media_id
      assert args.conversions == ["thumb", "preview"]
      assert args.mediable_type == "posts"
    end

    test "uses the :media queue with max_attempts of 3" do
      changeset =
        ProcessConversions.new(%{
          media_id: Ecto.UUID.generate(),
          conversions: ["thumb"],
          mediable_type: "posts"
        })

      assert changeset.changes.queue == "media"
      assert changeset.changes.max_attempts == 3
    end
  end

  # ---------------------------------------------------------------------------
  # AsyncProcessor.Oban.process_async/2
  # ---------------------------------------------------------------------------

  describe "AsyncProcessor.Oban.process_async/2" do
    test "constructs job with correct conversion names and mediable_type" do
      # We can't call process_async directly without an Oban instance,
      # but we can verify the worker module builds the right args by
      # testing new/1 with the same args that process_async would build.
      media_id = Ecto.UUID.generate()

      conversions = [
        Conversion.new(:thumb, width: 150, height: 150),
        Conversion.new(:preview, width: 800)
      ]

      conversion_names = Enum.map(conversions, &to_string(&1.name))

      changeset =
        ProcessConversions.new(%{
          media_id: media_id,
          conversions: conversion_names,
          mediable_type: "posts"
        })

      args = changeset.changes.args

      assert args.media_id == media_id
      assert args.conversions == ["thumb", "preview"]
      assert args.mediable_type == "posts"
    end
  end
end
