defmodule PhxMediaLibrary.ValidationError do
  @moduledoc """
  Exception raised when a media validation fails.

  This covers pre-storage validations such as file size limits, MIME type
  mismatches, content-type verification failures, and collection constraint
  violations.

  ## Fields

  - `:message` — human-readable error description
  - `:reason` — machine-readable atom identifying the validation failure
    (e.g. `:file_too_large`, `:invalid_mime_type`, `:content_type_mismatch`)
  - `:field` — the field or aspect that failed validation (e.g. `:size`, `:mime_type`)
  - `:value` — the actual value that was rejected, if available
  - `:constraint` — the constraint that was violated (e.g. the max size, the accepted MIME types)
  - `:metadata` — optional map with additional context

  ## Examples

      iex> raise PhxMediaLibrary.ValidationError,
      ...>   message: "file is too large (15 MB, max 10 MB)",
      ...>   reason: :file_too_large,
      ...>   field: :size,
      ...>   value: 15_000_000,
      ...>   constraint: 10_000_000
      ** (PhxMediaLibrary.ValidationError) file is too large (15 MB, max 10 MB)

      iex> error = %PhxMediaLibrary.ValidationError{
      ...>   message: "MIME type not accepted",
      ...>   reason: :invalid_mime_type,
      ...>   field: :mime_type,
      ...>   value: "application/exe",
      ...>   constraint: ["image/jpeg", "image/png"]
      ...> }
      iex> error.reason
      :invalid_mime_type

  """

  @type t :: %__MODULE__{
          message: String.t(),
          reason: atom(),
          field: atom() | nil,
          value: term(),
          constraint: term(),
          metadata: map()
        }

  defexception [:message, :reason, :field, :value, :constraint, :metadata]

  @impl true
  def exception(opts) when is_list(opts) do
    reason = Keyword.get(opts, :reason, :validation_failed)
    field = Keyword.get(opts, :field)
    value = Keyword.get(opts, :value)
    constraint = Keyword.get(opts, :constraint)
    metadata = Keyword.get(opts, :metadata, %{})
    message = Keyword.get(opts, :message, default_message(reason, field, value, constraint))

    %__MODULE__{
      message: message,
      reason: reason,
      field: field,
      value: value,
      constraint: constraint,
      metadata: metadata
    }
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{
      message: message,
      reason: :validation_failed,
      field: nil,
      value: nil,
      constraint: nil,
      metadata: %{}
    }
  end

  defp default_message(:file_too_large, _field, size, max_size)
       when is_integer(size) and is_integer(max_size) do
    "File is too large (#{format_bytes(size)}, maximum allowed is #{format_bytes(max_size)})"
  end

  defp default_message(:invalid_mime_type, _field, mime_type, accepted)
       when is_binary(mime_type) and is_list(accepted) do
    "MIME type #{inspect(mime_type)} is not accepted. Allowed types: #{Enum.join(accepted, ", ")}"
  end

  defp default_message(:content_type_mismatch, _field, {detected, declared}, _constraint) do
    "File content type #{inspect(detected)} does not match declared type #{inspect(declared)}"
  end

  defp default_message(reason, field, _value, _constraint) do
    parts =
      ["Validation failed"]
      |> maybe_append_field(field)
      |> maybe_append_reason(reason)

    Enum.join(parts, "")
  end

  defp maybe_append_field(parts, nil), do: parts
  defp maybe_append_field(parts, field), do: parts ++ [" on #{field}"]

  defp maybe_append_reason(parts, :validation_failed), do: parts
  defp maybe_append_reason(parts, reason), do: parts ++ [": #{reason}"]

  defp format_bytes(bytes) when bytes >= 1_000_000 do
    mb = Float.round(bytes / 1_000_000, 1)
    "#{mb} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_000 do
    kb = Float.round(bytes / 1_000, 1)
    "#{kb} KB"
  end

  defp format_bytes(bytes) do
    "#{bytes} bytes"
  end
end
