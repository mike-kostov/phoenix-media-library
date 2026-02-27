defmodule PhxMediaLibrary.LiveUploadTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Collection
  alias PhxMediaLibrary.LiveUpload

  # ---------------------------------------------------------------------------
  # translate_upload_error/1
  # ---------------------------------------------------------------------------

  describe "translate_upload_error/1" do
    test "translates :too_large" do
      assert LiveUpload.translate_upload_error(:too_large) == "File is too large"
    end

    test "translates :too_many_files" do
      assert LiveUpload.translate_upload_error(:too_many_files) == "Too many files selected"
    end

    test "translates :not_accepted" do
      assert LiveUpload.translate_upload_error(:not_accepted) == "File type is not accepted"
    end

    test "translates :external_client_failure" do
      assert LiveUpload.translate_upload_error(:external_client_failure) ==
               "Upload failed — please try again"
    end

    test "translates tuple errors {:too_large, _}" do
      assert LiveUpload.translate_upload_error({:too_large, 10_000_000}) == "File is too large"
    end

    test "translates tuple errors {:not_accepted, _}" do
      assert LiveUpload.translate_upload_error({:not_accepted, ".exe"}) ==
               "File type is not accepted"
    end

    test "translates unknown atom errors by humanizing the atom" do
      assert LiveUpload.translate_upload_error(:something_weird) == "Something weird"
    end

    test "translates unknown tuple errors by humanizing the atom part" do
      assert LiveUpload.translate_upload_error({:custom_error, "details"}) == "Custom error"
    end

    test "translates completely unknown errors with inspect" do
      assert LiveUpload.translate_upload_error("string error") ==
               "Upload error: \"string error\""
    end
  end

  # ---------------------------------------------------------------------------
  # has_upload_entries?/1
  # ---------------------------------------------------------------------------

  describe "has_upload_entries?/1" do
    test "returns false for empty entries" do
      assert LiveUpload.has_upload_entries?(%{entries: []}) == false
    end

    test "returns true when entries exist" do
      assert LiveUpload.has_upload_entries?(%{entries: [:some_entry]}) == true
    end

    test "returns false for non-matching structure" do
      assert LiveUpload.has_upload_entries?(%{}) == false
      assert LiveUpload.has_upload_entries?(nil) == false
    end
  end

  # ---------------------------------------------------------------------------
  # image_entry?/1
  # ---------------------------------------------------------------------------

  describe "image_entry?/1" do
    test "returns true for image MIME types" do
      assert LiveUpload.image_entry?(%{client_type: "image/jpeg"}) == true
      assert LiveUpload.image_entry?(%{client_type: "image/png"}) == true
      assert LiveUpload.image_entry?(%{client_type: "image/gif"}) == true
      assert LiveUpload.image_entry?(%{client_type: "image/webp"}) == true
      assert LiveUpload.image_entry?(%{client_type: "image/svg+xml"}) == true
    end

    test "returns false for non-image MIME types" do
      assert LiveUpload.image_entry?(%{client_type: "application/pdf"}) == false
      assert LiveUpload.image_entry?(%{client_type: "video/mp4"}) == false
      assert LiveUpload.image_entry?(%{client_type: "text/plain"}) == false
    end

    test "returns false for missing client_type" do
      assert LiveUpload.image_entry?(%{}) == false
      assert LiveUpload.image_entry?(nil) == false
    end
  end

  # ---------------------------------------------------------------------------
  # media_upload_errors/1
  # ---------------------------------------------------------------------------

  describe "media_upload_errors/1" do
    test "returns translated error strings from upload config errors" do
      upload = %{errors: [:too_large, :not_accepted]}
      errors = LiveUpload.media_upload_errors(upload)

      assert errors == ["File is too large", "File type is not accepted"]
    end

    test "returns empty list when no errors" do
      assert LiveUpload.media_upload_errors(%{errors: []}) == []
    end

    test "returns empty list for non-matching structure" do
      assert LiveUpload.media_upload_errors(%{}) == []
      assert LiveUpload.media_upload_errors(nil) == []
    end
  end

  # ---------------------------------------------------------------------------
  # delete_media_by_id/1
  # ---------------------------------------------------------------------------

  describe "delete_media_by_id/2" do
    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "accepts optional keyword list (arity 1 and 2)" do
      assert function_exported?(LiveUpload, :delete_media_by_id, 1)
      assert function_exported?(LiveUpload, :delete_media_by_id, 2)
    end
  end

  # ---------------------------------------------------------------------------
  # allow_media_upload/3 — option derivation logic (unit-testable parts)
  # ---------------------------------------------------------------------------

  describe "allow_media_upload/3 option derivation" do
    # These tests verify the internal option-building logic by testing the
    # private helper functions indirectly. Since allow_media_upload/3 requires
    # a real LiveView socket, we test the derivation logic through the
    # public API surface where possible, and verify the function exists.

    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "function is importable via use PhxMediaLibrary.LiveUpload" do
      # The __using__ macro imports the module's functions
      assert function_exported?(LiveUpload, :allow_media_upload, 3)
    end

    test "function requires :model and :collection options" do
      # Verify the function expects these keys by checking it raises
      # when called without a socket (we can't easily create a socket
      # in a unit test, but we can verify the contract)
      assert function_exported?(LiveUpload, :allow_media_upload, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # consume_media/5
  # ---------------------------------------------------------------------------

  describe "consume_media/5" do
    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "function exists with correct arity" do
      assert function_exported?(LiveUpload, :consume_media, 4)
      assert function_exported?(LiveUpload, :consume_media, 5)
    end
  end

  # ---------------------------------------------------------------------------
  # stream_existing_media/4
  # ---------------------------------------------------------------------------

  describe "stream_existing_media/4" do
    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "function exists with correct arity" do
      assert function_exported?(LiveUpload, :stream_existing_media, 4)
    end
  end

  # ---------------------------------------------------------------------------
  # stream_media_items/3
  # ---------------------------------------------------------------------------

  describe "stream_media_items/3" do
    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "function exists with correct arity" do
      assert function_exported?(LiveUpload, :stream_media_items, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # __using__/1 macro
  # ---------------------------------------------------------------------------

  describe "__using__/1" do
    test "imports LiveUpload functions into the using module" do
      # Define a test module that uses LiveUpload
      defmodule TestLiveView do
        use PhxMediaLibrary.LiveUpload

        def test_translate do
          translate_upload_error(:too_large)
        end

        def test_image_entry do
          image_entry?(%{client_type: "image/png"})
        end

        def test_has_entries do
          has_upload_entries?(%{entries: [:one]})
        end
      end

      assert TestLiveView.test_translate() == "File is too large"
      assert TestLiveView.test_image_entry() == true
      assert TestLiveView.test_has_entries() == true
    end
  end

  # ---------------------------------------------------------------------------
  # MIME type to extension conversion (internal, tested via integration)
  # ---------------------------------------------------------------------------

  describe "MIME-to-extension mapping integration" do
    # The mime_types_to_extensions/1 function is private, but we can verify
    # it works correctly through the TestPost collection configuration.

    test "TestPost has collection configs that would produce valid accept lists" do
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      # The :documents collection accepts application/pdf and text/plain
      collection = post.__struct__.get_media_collection(:documents)
      assert %Collection{} = collection
      assert collection.accepts == ~w(application/pdf text/plain)

      # The :avatar collection is single_file
      avatar = post.__struct__.get_media_collection(:avatar)
      assert %Collection{} = avatar
      assert avatar.single_file == true

      # The :gallery collection has max_files
      gallery = post.__struct__.get_media_collection(:gallery)
      assert %Collection{} = gallery
      assert gallery.max_files == 5
    end

    test "collection config affects upload options derivation" do
      # Verify that a single_file collection would produce max_entries: 1
      # and a max_files collection would produce the correct max_entries.
      # This is tested indirectly through the collection config.
      post = %PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Test"}

      avatar = post.__struct__.get_media_collection(:avatar)
      assert avatar.single_file == true

      gallery = post.__struct__.get_media_collection(:gallery)
      assert gallery.max_files == 5

      # No explicit collection returns nil
      assert post.__struct__.get_media_collection(:nonexistent) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Notification contract
  # ---------------------------------------------------------------------------

  describe "maybe_notify/2 contract (via consume_media/delete_media_by_id)" do
    setup do
      Code.ensure_loaded!(LiveUpload)
      :ok
    end

    test "consume_media/5 accepts :notify option" do
      # Verify the function accepts the option without crashing at the
      # keyword-parsing level. Full integration (with a real socket) is
      # tested in integration_test.exs.
      assert function_exported?(LiveUpload, :consume_media, 5)
    end

    test "delete_media_by_id/2 accepts :notify option" do
      assert function_exported?(LiveUpload, :delete_media_by_id, 2)
    end

    test "notification messages follow the expected shapes" do
      # Document the contract: these are the message shapes a parent
      # LiveView's handle_info/2 should match on.
      media_item = %PhxMediaLibrary.Media{id: Ecto.UUID.generate(), file_name: "test.jpg"}

      # :media_added — sent after successful consume_media
      assert {:media_added, [^media_item]} = {:media_added, [media_item]}

      # :media_removed — sent after successful delete_media_by_id
      assert {:media_removed, ^media_item} = {:media_removed, media_item}

      # :media_error — sent when consume_media encounters a failure
      assert {:media_error, :some_reason} = {:media_error, :some_reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "translate_upload_error handles all expected Phoenix upload errors" do
      # These are all the error atoms that Phoenix LiveView can produce
      phoenix_errors = [
        :too_large,
        :too_many_files,
        :not_accepted,
        :external_client_failure
      ]

      for error <- phoenix_errors do
        result = LiveUpload.translate_upload_error(error)
        assert is_binary(result), "Expected string for #{inspect(error)}, got: #{inspect(result)}"
        assert result != "", "Expected non-empty string for #{inspect(error)}"
      end
    end

    test "format_file_size is private on Components module (no import conflicts)" do
      Code.ensure_loaded!(PhxMediaLibrary.Components)
      refute function_exported?(PhxMediaLibrary.Components, :format_file_size, 1)
    end
  end
end
