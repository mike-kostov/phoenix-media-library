defmodule PhxMediaLibrary.Error do
  @moduledoc """
  Base exception for PhxMediaLibrary errors.

  All domain-specific exceptions in PhxMediaLibrary derive from this
  base module's conventions. This struct is used for general errors
  that don't fit a more specific category.

  ## Fields

  - `:message` — human-readable error description
  - `:reason` — machine-readable atom identifying the error (e.g. `:invalid_source`)
  - `:metadata` — optional map with additional context

  ## Examples

      iex> raise PhxMediaLibrary.Error, message: "something went wrong", reason: :unknown
      ** (PhxMediaLibrary.Error) something went wrong

      iex> error = %PhxMediaLibrary.Error{message: "bad input", reason: :invalid_input, metadata: %{field: :name}}
      iex> error.reason
      :invalid_input

  """

  @type t :: %__MODULE__{
          message: String.t(),
          reason: atom(),
          metadata: map()
        }

  defexception [:message, :reason, :metadata]

  @impl true
  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "PhxMediaLibrary error")
    reason = Keyword.get(opts, :reason, :unknown)
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{
      message: message,
      reason: reason,
      metadata: metadata
    }
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{
      message: message,
      reason: :unknown,
      metadata: %{}
    }
  end
end
