defmodule PhxMediaLibrary.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Error, StorageError, ValidationError}

  # ---------------------------------------------------------------------------
  # PhxMediaLibrary.Error
  # ---------------------------------------------------------------------------

  describe "PhxMediaLibrary.Error" do
    test "can be raised with keyword opts" do
      assert_raise Error, "something went wrong", fn ->
        raise Error, message: "something went wrong", reason: :unknown
      end
    end

    test "can be raised with a plain string" do
      assert_raise Error, "boom", fn ->
        raise Error, "boom"
      end
    end

    test "exception/1 with keyword opts sets all fields" do
      error =
        Error.exception(
          message: "bad input",
          reason: :invalid_input,
          metadata: %{field: :name}
        )

      assert %Error{} = error
      assert error.message == "bad input"
      assert error.reason == :invalid_input
      assert error.metadata == %{field: :name}
    end

    test "exception/1 with keyword opts uses defaults" do
      error = Error.exception([])

      assert error.message == "PhxMediaLibrary error"
      assert error.reason == :unknown
      assert error.metadata == %{}
    end

    test "exception/1 with string sets reason to :unknown" do
      error = Error.exception("oops")

      assert error.message == "oops"
      assert error.reason == :unknown
      assert error.metadata == %{}
    end

    test "implements Exception behaviour" do
      error = Error.exception(message: "test")
      assert Exception.message(error) == "test"
    end
  end

  # ---------------------------------------------------------------------------
  # PhxMediaLibrary.StorageError
  # ---------------------------------------------------------------------------

  describe "PhxMediaLibrary.StorageError" do
    test "can be raised with keyword opts" do
      assert_raise StorageError, "failed to write file", fn ->
        raise StorageError,
          message: "failed to write file",
          reason: :write_failed,
          operation: :put,
          path: "posts/abc/image.jpg"
      end
    end

    test "can be raised with a plain string" do
      assert_raise StorageError, "disk full", fn ->
        raise StorageError, "disk full"
      end
    end

    test "exception/1 with keyword opts sets all fields" do
      error =
        StorageError.exception(
          message: "not found",
          reason: :not_found,
          operation: :get,
          path: "posts/abc/image.jpg",
          adapter: PhxMediaLibrary.Storage.Disk,
          metadata: %{disk: :local}
        )

      assert %StorageError{} = error
      assert error.message == "not found"
      assert error.reason == :not_found
      assert error.operation == :get
      assert error.path == "posts/abc/image.jpg"
      assert error.adapter == PhxMediaLibrary.Storage.Disk
      assert error.metadata == %{disk: :local}
    end

    test "exception/1 with keyword opts uses sensible defaults" do
      error = StorageError.exception(reason: :timeout, operation: :put)

      assert error.reason == :timeout
      assert error.operation == :put
      assert error.path == nil
      assert error.adapter == nil
      assert error.metadata == %{}
    end

    test "default message includes operation and reason" do
      error = StorageError.exception(reason: :write_failed, operation: :put)

      assert error.message =~ "Storage error"
      assert error.message =~ "during put"
      assert error.message =~ "write_failed"
    end

    test "default message includes path when provided" do
      error =
        StorageError.exception(
          reason: :not_found,
          operation: :get,
          path: "foo/bar.jpg"
        )

      assert error.message =~ ~s(at path "foo/bar.jpg")
    end

    test "default message omits path when not provided" do
      error = StorageError.exception(reason: :write_failed, operation: :put)

      refute error.message =~ "at path"
    end

    test "exception/1 with string sets all non-message fields to defaults" do
      error = StorageError.exception("oops")

      assert error.message == "oops"
      assert error.reason == :unknown
      assert error.operation == nil
      assert error.path == nil
      assert error.adapter == nil
      assert error.metadata == %{}
    end

    test "implements Exception behaviour" do
      error = StorageError.exception(message: "boom")
      assert Exception.message(error) == "boom"
    end
  end

  # ---------------------------------------------------------------------------
  # PhxMediaLibrary.ValidationError
  # ---------------------------------------------------------------------------

  describe "PhxMediaLibrary.ValidationError" do
    test "can be raised with keyword opts" do
      assert_raise ValidationError,
                   "File is too large (15.0 MB, maximum allowed is 10.0 MB)",
                   fn ->
                     raise ValidationError,
                       reason: :file_too_large,
                       field: :size,
                       value: 15_000_000,
                       constraint: 10_000_000
                   end
    end

    test "can be raised with a plain string" do
      assert_raise ValidationError, "nope", fn ->
        raise ValidationError, "nope"
      end
    end

    test "exception/1 with keyword opts sets all fields" do
      error =
        ValidationError.exception(
          message: "custom message",
          reason: :file_too_large,
          field: :size,
          value: 15_000_000,
          constraint: 10_000_000,
          metadata: %{collection: :images}
        )

      assert %ValidationError{} = error
      assert error.message == "custom message"
      assert error.reason == :file_too_large
      assert error.field == :size
      assert error.value == 15_000_000
      assert error.constraint == 10_000_000
      assert error.metadata == %{collection: :images}
    end

    test "exception/1 with keyword opts uses sensible defaults" do
      error = ValidationError.exception(reason: :file_too_large)

      assert error.reason == :file_too_large
      assert error.field == nil
      assert error.value == nil
      assert error.constraint == nil
      assert error.metadata == %{}
    end

    test "default message for :file_too_large formats bytes" do
      error =
        ValidationError.exception(
          reason: :file_too_large,
          field: :size,
          value: 15_000_000,
          constraint: 10_000_000
        )

      assert error.message =~ "15.0 MB"
      assert error.message =~ "10.0 MB"
    end

    test "default message for :file_too_large formats KB" do
      error =
        ValidationError.exception(
          reason: :file_too_large,
          field: :size,
          value: 500_000,
          constraint: 100_000
        )

      assert error.message =~ "500.0 KB"
      assert error.message =~ "100.0 KB"
    end

    test "default message for :file_too_large formats small bytes" do
      error =
        ValidationError.exception(
          reason: :file_too_large,
          field: :size,
          value: 999,
          constraint: 500
        )

      assert error.message =~ "999 bytes"
      assert error.message =~ "500 bytes"
    end

    test "default message for :invalid_mime_type lists accepted types" do
      error =
        ValidationError.exception(
          reason: :invalid_mime_type,
          field: :mime_type,
          value: "application/exe",
          constraint: ["image/jpeg", "image/png"]
        )

      assert error.message =~ "application/exe"
      assert error.message =~ "image/jpeg, image/png"
    end

    test "default message for :content_type_mismatch shows both types" do
      error =
        ValidationError.exception(
          reason: :content_type_mismatch,
          field: :mime_type,
          value: {"image/png", "application/x-msdownload"}
        )

      assert error.message =~ "image/png"
      assert error.message =~ "application/x-msdownload"
    end

    test "default message for unknown reason includes field" do
      error =
        ValidationError.exception(
          reason: :custom_error,
          field: :checksum
        )

      assert error.message =~ "Validation failed"
      assert error.message =~ "on checksum"
      assert error.message =~ "custom_error"
    end

    test "exception/1 with string sets all non-message fields to defaults" do
      error = ValidationError.exception("bad data")

      assert error.message == "bad data"
      assert error.reason == :validation_failed
      assert error.field == nil
      assert error.value == nil
      assert error.constraint == nil
      assert error.metadata == %{}
    end

    test "implements Exception behaviour" do
      error = ValidationError.exception(message: "test")
      assert Exception.message(error) == "test"
    end
  end
end
