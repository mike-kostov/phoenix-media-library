defmodule PhxMediaLibrary.RemovalsTest do
  # What 0.9.0 deprecated is gone in 0.10.0 (spec 02, C1).
  use ExUnit.Case, async: true

  test "presigned_upload_url/3 is gone; presigned_upload/3 replaces it" do
    refute function_exported?(PhxMediaLibrary, :presigned_upload_url, 3)
    refute function_exported?(PhxMediaLibrary.Storage.S3, :presigned_upload_url, 3)
    refute function_exported?(PhxMediaLibrary.StorageWrapper, :presigned_upload_url, 3)

    callbacks = PhxMediaLibrary.Storage.behaviour_info(:callbacks)
    refute {:presigned_upload_url, 3} in callbacks
    assert {:presigned_upload, 3} in callbacks
  end

  test "the old repair tasks are gone; the doctor replaces them" do
    for task <- [
          Mix.Tasks.PhxMediaLibrary.Regenerate,
          Mix.Tasks.PhxMediaLibrary.RegenerateWebp,
          Mix.Tasks.PhxMediaLibrary.RegenerateResponsive,
          Mix.Tasks.PhxMediaLibrary.DropOriginals
        ] do
      refute Code.ensure_loaded?(task), "#{inspect(task)} still exists"
    end
  end
end
